// swift-tools-version: 6.0
import PackageDescription

// Pankapture is built as a SwiftPM executable and wrapped into a signed .app
// bundle by `scripts/bundle.sh` (see docs/ARCHITECTURE.md → Build & signing).
// Xcode is optional: everything here builds with the Command Line Tools.

let package = Package(
    name: "Pankapture",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Pankapture", targets: ["Pankapture"]),
    ],
    targets: [
        // App shell: lifecycle, menu bar, settings, coordinators. Thin by design.
        .executableTarget(
            name: "Pankapture",
            dependencies: ["AppCore", "Capture", "Annotation", "DesignSystem"]
        ),

        // Settings, hot keys, permissions, file naming, logging. No UI.
        .target(name: "AppCore"),

        // ScreenCaptureKit screenshots (and, from M3, recording) + image output.
        .target(name: "Capture", dependencies: ["AppCore"]),

        // Annotation document model, tools, undo, CoreGraphics renderer. Pure + testable.
        .target(name: "Annotation"),

        // Theme, tokens, and shared native UI building blocks.
        .target(name: "DesignSystem"),

        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
        .testTarget(name: "AnnotationTests", dependencies: ["Annotation"]),
    ]
)
