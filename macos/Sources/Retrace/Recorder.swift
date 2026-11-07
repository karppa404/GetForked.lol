import AppKit
import Combine
import RetraceCore

enum RecorderError: LocalizedError {
    case permissionsMissing(String)
    case invalidTarget(String)
    case alreadyRecording
    var errorDescription: String? {
        switch self {
        case .permissionsMissing(let m), .invalidTarget(let m): return m
        case .alreadyRecording: return "A recording is already in progress."
        }
    }
}

/// Records one target application. Capture policy, enforced on every event:
/// 1. The session is in the `.recording` state (not paused/stopping).
/// 2. The frontmost application (NSWorkspace) is the target PID.
/// 3. Pointer events: the element (or window) under the pointer belongs to the target PID.
///    Key events: the Accessibility-focused application is the target PID.
/// Anything else is dropped and only counted. Typed characters are never recorded.
@MainActor
final class Recorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case paused(String)
        case stopping
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var interactionCount = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var droppedCount = 0
    @Published private(set) var targetName: String?
    @Published private(set) var startedAt: Date?
    @Published var notice: String?

    let store: SessionStore
    let maxFrames = 900

    private var target: NSRunningApplication?
    private var targetPID: pid_t = 0
    private var task = ""
    private var sessionId = ""
    private var clock = SessionClock()
    private var capturer: FrameCapturer?
    private var displayFrame: CGRect = .zero

    private var interactions: [Interaction] = []
    private var indexById: [String: Int] = [:]
    private var frames: [String: Frame] = [:]
    private var reservedFrames = 0

    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private var cache: (image: CapturedImage, frameId: String?)?
    private var scheduled: [Int: (target: TimeInterval, task: Task<String?, Never>)] = [:]
    private var outstanding: [UUID: Task<Void, Never>] = [:]
    private var scroll: (id: String, last: TimeInterval, dx: Double, dy: Double, after: Task<Void, Never>?)?
    private var typing: (id: String, last: TimeInterval, after: Task<Void, Never>?)?

    var onAutoStop: ((LocalSession?) -> Void)?

    init(store: SessionStore) { self.store = store }

    var isActive: Bool { state != .idle }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Start / stop

    func start(app: NSRunningApplication, task: String) async throws {
        guard state == .idle else { throw RecorderError.alreadyRecording }
        guard app.processIdentifier != getpid(), app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw RecorderError.invalidTarget("Retrace cannot record itself.")
        }
        guard !app.isTerminated else { throw RecorderError.invalidTarget("\(app.localizedName ?? "That app") is no longer running.") }
        guard Permissions.accessibilityGranted else {
            throw RecorderError.permissionsMissing("Accessibility permission is required to observe clicks and keys in the target app.")
        }
        guard Permissions.screenRecordingGranted else {
            throw RecorderError.permissionsMissing("Screen Recording permission is required for evidence frames.")
        }

        let capturer = FrameCapturer(pid: app.processIdentifier)
        displayFrame = try await capturer.prepare()
        let id = UUID().uuidString.lowercased()
        try store.createSessionDirectory(id: id)

        self.capturer = capturer
        self.target = app
        self.targetPID = app.processIdentifier
        self.targetName = app.localizedName ?? app.bundleIdentifier ?? "App"
        self.task = task
        self.sessionId = id
        self.interactions = []
        self.indexById = [:]
        self.frames = [:]
        self.reservedFrames = 0
        self.cache = nil
        self.scheduled = [:]
        self.outstanding = [:]
        self.scroll = nil
        self.typing = nil
        self.interactionCount = 0
        self.frameCount = 0
        self.droppedCount = 0
        self.notice = nil
        self.clock = SessionClock()
        self.startedAt = clock.startDate

        installMonitors()
        app.activate()
        state = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
            ? .recording : .paused("Waiting for \(targetName ?? "the app") to be frontmost")
        if state == .recording { refreshCache() }
    }

    /// Stops listening immediately, lets in-flight evidence captures finish (bounded), then
    /// writes the local session. Nothing is uploaded.
    func stop() async -> LocalSession? {
        guard state != .idle, state != .stopping else { return nil }
        removeMonitors()
        endTyping(scheduleAfter: true)
        endScroll(scheduleAfter: true)
        let wasRecording = state == .recording
        state = .stopping
        allowCapturesWhileStopping = wasRecording
        await drainOutstanding(timeout: 3.0)
        allowCapturesWhileStopping = false
        let session = finalize()
        state = .idle
        capturer = nil
        target = nil
        cache = nil
        return session
    }

    private var allowCapturesWhileStopping = false

    private func drainOutstanding(timeout: TimeInterval) async {
        let deadline = now + timeout
        while !outstanding.isEmpty {
            if now > deadline { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        for t in outstanding.values { t.cancel() }
        for s in scheduled.values { s.task.cancel() }
        outstanding.removeAll()
        scheduled.removeAll()
    }

    private func finalize() -> LocalSession? {
        let duration = clock.nowMilliseconds()
        let sortedFrames = frames.values.sorted { ($0.timestampMs, $0.id) < ($1.timestampMs, $1.id) }
        let known = Set(sortedFrames.map(\.id))
        let items = interactions.enumerated()
            .sorted { ($0.element.timestampMs, $0.offset) < ($1.element.timestampMs, $1.offset) }
            .map { pair -> Interaction in
                var it = pair.element
                // Drop references to frames that failed to persist.
                if let f = it.beforeFrameId, !known.contains(f) { it.beforeFrameId = nil }
                if let f = it.afterFrameId, !known.contains(f) { it.afterFrameId = nil }
                if let f = it.delayedFrameId, !known.contains(f) { it.delayedFrameId = nil }
                return it
            }
        let bundleId = target?.bundleIdentifier ?? "unknown"
        let manifest = SessionManifest(
            id: sessionId,
            app: AppInfo(name: targetName ?? bundleId, bundleId: bundleId, pid: targetPID),
            task: task,
            startedAt: clock.startedAtISO8601,
            durationMs: max(duration, (sortedFrames.last?.timestampMs ?? 0), (items.last?.timestampMs ?? 0)),
            interactions: items,
            frames: sortedFrames,
            network: [],
            networkStatus: .notCaptured,
            redaction: Redaction(reviewed: false)
        )
        let issues = ManifestValidator.validate(manifest, purpose: .local)
        if !issues.isEmpty {
            notice = "Saved, but the manifest has \(issues.count) validation issue(s): \(issues.first!)"
        }
        do {
            try store.save(manifest: manifest)
            try store.save(review: ReviewState(), sessionId: sessionId)
            return try store.load(id: sessionId)
        } catch {
            notice = "Could not save session: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Monitors and focus

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(m) }

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostChanged(to: app) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.targetTerminated(app) }
        })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause(reason: "Screen locked, asleep or user switched") }
            })
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCache() }
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func frontmostChanged(to app: NSRunningApplication?) {
        let isTarget = app?.processIdentifier == targetPID
        switch state {
        case .recording where !isTarget:
            pause(reason: "\(targetName ?? "Target") is not frontmost (\(app?.localizedName ?? "another app") is)")
        case .paused where isTarget:
            state = .recording
            record(Interaction(timestampMs: clock.nowMilliseconds(), kind: .focusRegained))
            refreshCache()
        default: break
        }
    }

    private func pause(reason: String) {
        guard state == .recording else {
            if case .paused = state { state = .paused(reason) }
            return
        }
        endTyping(scheduleAfter: false)
        endScroll(scheduleAfter: false)
        state = .paused(reason)
        cache = nil
        record(Interaction(timestampMs: clock.nowMilliseconds(), kind: .focusLost))
    }

    private func targetTerminated(_ app: NSRunningApplication?) {
        guard app?.processIdentifier == targetPID, isActive else { return }
        Task { @MainActor in
            let s = await stop()
            notice = "\(targetName ?? "Target") quit; recording stopped and saved locally."
            onAutoStop?(s)
        }
    }

    // MARK: Event filtering

    private var targetIsFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID }

    private func handle(_ event: NSEvent) {
        let pre = CapturePolicy.evaluate(recording: state == .recording, targetPID: targetPID,
                                         frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                         ownerPID: targetPID, kind: .pointer)
        guard pre == .accept else {
            if state != .idle { droppedCount += 1 }
            return
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: handlePointer(event)
        case .scrollWheel: handleScroll(event)
        case .keyDown: handleKey(event)
        default: break
        }
    }

    private struct PointerHit { let point: CGPoint; let snapshot: AccessibilitySnapshot? }

    /// Returns nil (drop) unless the thing under the pointer belongs to the target PID.
    private func verifyPointer(_ event: NSEvent) -> PointerHit? {
        guard let location = event.cgEvent?.location else { return nil }
        let element = AXInspector.element(at: location)
        let owner = element.flatMap(AXInspector.pid(of:)) ?? AXInspector.windowOwnerPID(at: location)
        let decision = CapturePolicy.evaluate(recording: state == .recording, targetPID: targetPID,
                                              frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                              ownerPID: owner, kind: .pointer)
        guard decision == .accept else { return nil }
        let snapshot = element.flatMap { AXInspector.pid(of: $0) == targetPID ? AXInspector.snapshot(of: $0) : nil }
        return PointerHit(point: location, snapshot: snapshot)
    }

    private func displayRelative(_ p: CGPoint) -> (Double?, Double?) {
        guard displayFrame.contains(p) else { return (nil, nil) }
        return ((p.x - displayFrame.minX).rounded(), (p.y - displayFrame.minY).rounded())
    }

    private func handlePointer(_ event: NSEvent) {
        guard let hit = verifyPointer(event) else { droppedCount += 1; return }
        endTyping(scheduleAfter: true)
        endScroll(scheduleAfter: true)
        let kind: InteractionKind
        switch event.type {
        case .rightMouseDown: kind = .rightClick
        case .otherMouseDown: kind = .otherClick
        default: kind = event.clickCount >= 2 ? .doubleClick : .click
        }
        let (x, y) = displayRelative(hit.point)
        let it = Interaction(timestampMs: clock.milliseconds(atUptime: event.timestamp), kind: kind, x: x, y: y,
                             accessibility: hit.snapshot, beforeFrameId: beforeFrame(for: event.timestamp))
        record(it)
        attachFrame(to: it.id, slot: \.afterFrameId, delay: CapturePolicy.afterDelay, from: event.timestamp)
        attachFrame(to: it.id, slot: \.delayedFrameId, delay: CapturePolicy.settledDelay, from: event.timestamp)
    }

    private func handleScroll(_ event: NSEvent) {
        let t = event.timestamp
        if var s = scroll, t - s.last < 0.4 {
            s.dx += Double(event.scrollingDeltaX)
            s.dy += Double(event.scrollingDeltaY)
            s.last = t
            scroll = s
            update(s.id) { $0.scrollDx = s.dx.rounded(); $0.scrollDy = s.dy.rounded() }
            return
        }
        endScroll(scheduleAfter: true)
        guard let hit = verifyPointer(event) else { droppedCount += 1; return }
        endTyping(scheduleAfter: true)
        let (x, y) = displayRelative(hit.point)
        let it = Interaction(timestampMs: clock.milliseconds(atUptime: t), kind: .scroll, x: x, y: y,
                             scrollDx: Double(event.scrollingDeltaX).rounded(), scrollDy: Double(event.scrollingDeltaY).rounded(),
                             accessibility: hit.snapshot, beforeFrameId: beforeFrame(for: t))
        record(it)
        scroll = (it.id, t, Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), nil)
    }

    private func endScroll(scheduleAfter: Bool) {
        guard let s = scroll else { return }
        scroll = nil
        if scheduleAfter { attachFrame(to: s.id, slot: \.afterFrameId, delay: 0.4, from: s.last) }
    }

    private func handleKey(_ event: NSEvent) {
        // Keys must be going to the target per Accessibility as well as NSWorkspace.
        let decision = CapturePolicy.evaluate(recording: state == .recording, targetPID: targetPID,
                                              frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                              ownerPID: AXInspector.focusedApplicationPID(), kind: .key)
        guard decision == .accept else { droppedCount += 1; return }
        var mods: KeyNaming.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        let t = event.timestamp
        let focused = AXInspector.focusedElement(pid: targetPID).map(AXInspector.snapshot(of:))

        switch KeyNaming.classify(keyCode: event.keyCode, modifiers: mods) {
        case .text:
            // Only "typing happened" is recorded; never which keys.
            if var burst = typing, t - burst.last < 2.0 {
                burst.last = t
                burst.after?.cancel()
                burst.after = debouncedAfterFrame(for: burst.id, from: t)
                typing = burst
                return
            }
            endTyping(scheduleAfter: true)
            endScroll(scheduleAfter: true)
            let it = Interaction(timestampMs: clock.milliseconds(atUptime: t), kind: .textInput, key: KeyNaming.redacted,
                                 accessibility: focused, beforeFrameId: beforeFrame(for: t))
            record(it)
            typing = (it.id, t, debouncedAfterFrame(for: it.id, from: t))
        case .named(let name):
            if event.isARepeat { return }
            endTyping(scheduleAfter: true)
            endScroll(scheduleAfter: true)
            let it = Interaction(timestampMs: clock.milliseconds(atUptime: t), kind: .key, key: name,
                                 accessibility: focused, beforeFrameId: beforeFrame(for: t))
            record(it)
            attachFrame(to: it.id, slot: \.afterFrameId, delay: CapturePolicy.afterDelay, from: t)
            attachFrame(to: it.id, slot: \.delayedFrameId, delay: CapturePolicy.settledDelay, from: t)
        }
    }

    private func debouncedAfterFrame(for id: String, from t: TimeInterval) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled, let self, self.typing?.id == id else { return }
            self.endTyping(scheduleAfter: true)
        }
    }

    private func endTyping(scheduleAfter: Bool) {
        guard let burst = typing else { return }
        typing = nil
        burst.after?.cancel()
        if scheduleAfter { attachFrame(to: burst.id, slot: \.afterFrameId, delay: 0.3, from: burst.last) }
    }

    private func record(_ it: Interaction) {
        indexById[it.id] = interactions.count
        interactions.append(it)
        interactionCount = interactions.count
    }

    private func update(_ id: String, _ change: (inout Interaction) -> Void) {
        guard let i = indexById[id] else { return }
        change(&interactions[i])
    }

    // MARK: Evidence frames

    private var capturingAllowed: Bool {
        (state == .recording || (state == .stopping && allowCapturesWhileStopping)) && targetIsFrontmost && capturer != nil
    }

    /// Keeps the most recent frame in memory (not on disk) so an action's "before" frame is
    /// the screen state just prior to the event. Only persisted if an interaction uses it.
    private func refreshCache() {
        guard state == .recording, let capturer else { return }
        track { [weak self] in
            guard let img = try? await capturer.capture() else { return }
            guard let self, self.capturingAllowed else { return }
            if let c = self.cache, c.image.uptime > img.uptime { return }
            self.cache = (img, nil)
        }
    }

    private func beforeFrame(for uptime: TimeInterval) -> String? {
        guard let c = cache, CapturePolicy.isUsableBeforeFrame(frameUptime: c.image.uptime, eventUptime: uptime) else { return nil }
        if let id = c.frameId { return id }
        guard let id = reserveFrame() else { return nil }
        cache?.frameId = id
        let image = c.image
        track { [weak self] in await self?.persist(image, id: id) }
        return id
    }

    private func reserveFrame() -> String? {
        guard reservedFrames < maxFrames else {
            if notice == nil { notice = "Frame limit (\(maxFrames)) reached; further actions are recorded without frames." }
            return nil
        }
        reservedFrames += 1
        return UUID().uuidString.lowercased()
    }

    /// Captures at `from + delay` (coalescing captures within 200 ms) and links the frame.
    private func attachFrame(to interactionId: String, slot: WritableKeyPath<Interaction, String?>, delay: TimeInterval, from base: TimeInterval) {
        let frameTask = scheduledCapture(at: base + delay)
        track { [weak self] in
            guard let frameId = await frameTask.value, let self else { return }
            self.update(interactionId) { $0[keyPath: slot] = frameId }
        }
    }

    private func scheduledCapture(at target: TimeInterval) -> Task<String?, Never> {
        scheduled = scheduled.filter { $0.value.target > now - 5 }
        let bucket = CapturePolicy.coalescingBucket(forUptime: target)
        if let existing = scheduled[bucket] { return existing.task }
        let task = Task { @MainActor [weak self] () -> String? in
            let wait = target - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled, self.capturingAllowed, let capturer = self.capturer else { return nil }
            guard let img = try? await capturer.capture(), self.capturingAllowed || self.state == .stopping else { return nil }
            guard let id = self.reserveFrame() else { return nil }
            if self.state == .recording { self.cache = (img, id) }
            return await self.persist(img, id: id)
        }
        scheduled[bucket] = (target, task)
        return task
    }

    @discardableResult
    private func persist(_ img: CapturedImage, id: String) async -> String? {
        let ts = clock.milliseconds(atUptime: img.uptime)
        let store = self.store
        let sessionId = self.sessionId
        let frame: Frame? = await Task.detached(priority: .userInitiated) {
            guard let data = FrameCapturer.jpegData(img.image) else { return nil }
            return try? store.writeFrame(sessionId: sessionId, frameId: id, timestampMs: ts, data: data,
                                         width: img.image.width, height: img.image.height)
        }.value
        guard let frame else { return nil }
        frames[id] = frame
        frameCount = frames.count
        return id
    }

    private func track(_ body: @escaping @MainActor () async -> Void) {
        let key = UUID()
        let t = Task { @MainActor [weak self] in
            await body()
            self?.outstanding.removeValue(forKey: key)
        }
        outstanding[key] = t
    }
}
