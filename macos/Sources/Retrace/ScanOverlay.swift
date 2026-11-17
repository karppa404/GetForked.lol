import AppKit
import SwiftUI

/// Tells the person a scan is driving their Mac: a red glow around every screen plus a status pill
/// with Wrap Up and Stop buttons. Both are click-through or non-activating, so they never take focus from the
/// app Codex is operating, and they ask capture tools to exclude them.
@MainActor
final class ScanOverlay {
    private var windows: [NSWindow] = []
    private weak var scanner: CodexScanner?

    init(scanner: CodexScanner) { self.scanner = scanner }

    func show(targetName: String) {
        hide()
        guard let scanner else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for screen in NSScreen.screens {
            windows.append(Self.overlayWindow(frame: screen.frame, clickThrough: true,
                                              content: ScanEdgeGlow(animated: !reduceMotion)))
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let size = CGSize(width: 600, height: 64)
            let visible = screen.visibleFrame
            let frame = CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14,
                               width: size.width, height: size.height)
            windows.append(Self.overlayWindow(frame: frame, clickThrough: false,
                                              content: ScanStatusPill(scanner: scanner, targetName: targetName, animated: !reduceMotion)))
        }
        windows.forEach { $0.orderFrontRegardless() }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private static func overlayWindow<Content: View>(frame: CGRect, clickThrough: Bool, content: Content) -> NSWindow {
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = clickThrough
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        // Keep the overlay out of screenshots (Retrace's capture is app-only already; this covers others).
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: frame.size)
        window.contentView = host
        return window
    }
}

private let scanRed = Color(red: 1, green: 0.27, blue: 0.23)

/// Inset red glow along the screen edges, pulsing slowly unless Reduce Motion is on.
private struct ScanEdgeGlow: View {
    let animated: Bool
    @State private var bright = false

    var body: some View {
        ZStack {
            // Soft inner bloom, then a crisp edge line on top.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(scanRed.opacity(bright ? 0.35 : 0.2), lineWidth: 28)
                .blur(radius: 16)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(scanRed.opacity(bright ? 1 : 0.7), lineWidth: 5)
                .shadow(color: scanRed.opacity(bright ? 0.9 : 0.55), radius: 12)
        }
        .padding(1)
        .allowsHitTesting(false)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

private struct ScanStatusPill: View {
    @ObservedObject var scanner: CodexScanner
    let targetName: String
    let animated: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(scanRed)
                .frame(width: 10, height: 10)
                .shadow(color: scanRed, radius: pulse ? 6 : 2)
                .opacity(pulse ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex is using your Mac — please step away")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(scanner.isWrappingUp ? "Wrapping Up…" : "Wrap Up") { scanner.wrapUp() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(scanner.isWrappingUp)
                .help("Stop exploring and have Codex write its report now")
            Button("Stop") { scanner.cancel() }
                .buttonStyle(.borderedProminent)
                .tint(scanRed)
                .controlSize(.small)
                .help("Stop the scan and keep the evidence gathered so far")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(scanRed.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .onAppear {
            guard animated else { pulse = true; return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var detail: String {
        let steps = scanner.steps == 1 ? "1 step" : "\(scanner.steps) steps"
        return "Scanning \(targetName) · \(steps) · \(scanner.status)"
    }
}
