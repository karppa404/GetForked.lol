import AppKit
import SwiftUI

/// The Retrace R. As a template (the default) it is the monochrome menu-bar glyph built by
/// scripts/build-menubar-glyph.swift, which macOS tints for light/dark menu bars and highlight;
/// with `template: false` it is the full-color coral mark for in-app chrome.
struct RetraceMark: View {
    var size: CGFloat = 18
    var template = true
    /// Template variant with a recording dot knocked into the top-right corner.
    var recording = false

    // SwiftPM's generated lookup assumes a command-line executable; packaged apps
    // keep the resource bundle under Contents/Resources instead.
    private static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "Retrace_Retrace", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()

    private static func load(_ name: String, _ ext: String, template: Bool, fallback: String) -> NSImage {
        if let url = resources.url(forResource: name, withExtension: ext),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = template
            return image
        }
        let image = NSImage(systemSymbolName: fallback, accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }

    private static let glyph = load("RetraceMenuBarTemplate", "pdf", template: true, fallback: "arrow.uturn.backward")
    private static let recordingGlyph = load("RetraceMenuBarRecordingTemplate", "pdf", template: true,
                                             fallback: "record.circle")
    private static let color = load("RetraceMark@2x", "png", template: false, fallback: "arrow.uturn.backward")

    var body: some View {
        Image(nsImage: template ? (recording ? Self.recordingGlyph : Self.glyph) : Self.color)
            .renderingMode(template ? .template : .original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
