// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Retrace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Retrace", targets: ["Retrace"]),
        .executable(name: "retrace-cli", targets: ["retrace-cli"]),
        .library(name: "RetraceCore", targets: ["RetraceCore"]),
    ],
    targets: [
        // Pure logic: models, timestamps, key naming, validation, review/redaction,
        // local storage, pairing and upload. No permissions are touched here.
        .target(name: "RetraceCore"),
        // Menu bar app: SwiftUI + AppKit + ScreenCaptureKit + Accessibility.
        .executableTarget(
            name: "Retrace",
            dependencies: ["RetraceCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Headless helper for validating session directories (no permissions needed).
        .executableTarget(name: "retrace-cli", dependencies: ["RetraceCore"]),
        .testTarget(
            name: "RetraceCoreTests",
            dependencies: ["RetraceCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
