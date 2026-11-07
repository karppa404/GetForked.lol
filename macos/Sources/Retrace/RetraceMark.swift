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

    var body: some View {
        Image("RetraceMenuBarTemplate", bundle: Self.resources)
            .renderingMode(template ? .template : .original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
