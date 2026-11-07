import AppKit
import SwiftUI

/// The generated mark is a template in the menu bar, so macOS supplies the right contrast.
struct RetraceMark: View {
    var size: CGFloat = 18
    var template = true

    // SwiftPM's generated lookup assumes a command-line executable; packaged apps
    // keep the resource bundle under Contents/Resources instead.
    private static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "Retrace_Retrace", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()

    private static let image: NSImage = {
        if let url = resources.url(forResource: "RetraceMenuBarTemplate@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            return image
        }
        return NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)!
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(template ? .template : .original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
