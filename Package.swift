// swift-tools-version: 6.0
import PackageDescription

// Pankapture is built as a SwiftPM executable and wrapped into a signed .app
// bundle by `scripts/bundle.sh` (see docs/ARCHITECTURE.md → Build & signing).

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
            dependencies: ["AppCore", "Capture", "Annotation", "DesignSystem", "Overlay", "Library", "QuickAccess"]
        ),

        // Settings, hot keys, permissions, file naming, logging. No UI.
        .target(name: "AppCore"),

        // ScreenCaptureKit screenshots (and, from M3, recording) + image output.
        .target(name: "Capture", dependencies: ["AppCore"]),

        // Annotation document model, tools, undo, CoreGraphics renderer. Pure + testable.
        .target(name: "Annotation"),

        // Theme, tokens, and shared native UI building blocks.
        .target(name: "DesignSystem"),

        // Frozen-frame selection overlay, loupe, inline + full annotation editor (M1–M2).
        .target(name: "Overlay", dependencies: ["AppCore", "Capture", "Annotation", "DesignSystem"]),

        // Floating windows: quick-access thumbnails and pinned images (M2).
        .target(name: "QuickAccess", dependencies: ["AppCore", "Capture", "DesignSystem"]),

        // Capture history (M6): SwiftData index, re-editable originals, OCR, library window.
        .target(name: "Library", dependencies: ["AppCore", "Annotation", "DesignSystem"]),

        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
        .testTarget(name: "AnnotationTests", dependencies: ["Annotation"]),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Annotation", "AppCore"]),
    ]
)
