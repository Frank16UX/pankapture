// swift-tools-version: 6.0
import PackageDescription

// Pankapture is built as a SwiftPM executable and wrapped into a signed .app
// bundle by `scripts/bundle.sh` (see docs/ARCHITECTURE.md → Build & signing).

let package = Package(
    name: "Pankapture",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Pankapture", targets: ["Pankapture"]),
        .executable(name: "pankapture-eval", targets: ["PankaptureEval"]),
    ],
    targets: [
        // App shell: lifecycle, menu bar, settings, coordinators. Thin by design.
        .executableTarget(
            name: "Pankapture",
            dependencies: ["AppCore", "Capture", "Annotation", "DesignSystem", "Overlay", "Library", "QuickAccess", "Recording", "VideoEditor", "AIProviders", "AutoEdit", "Transcription"]
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

        // Screen recording: SCStream → AVAssetWriter, HUD, countdown, webcam/click/key overlays (M3–M4).
        .target(name: "Recording", dependencies: ["AppCore", "DesignSystem"]),

        // Video editor: edit model, timeline math, composition, zoom/background
        // compositor, MP4/GIF export, editor window (M5).
        .target(name: "VideoEditor", dependencies: ["AppCore", "DesignSystem", "Transcription", "AIProviders", "AutoEdit"]),

        // Capture history (M6): SwiftData index, re-editable originals, OCR, library window.
        .target(name: "Library", dependencies: ["AppCore", "Annotation", "DesignSystem"]),

        // Smart editing (M8, macOS 26+). On-device speech-to-text with word timings.
        .target(name: "Transcription", dependencies: ["AppCore"]),

        // Bring-your-own-key language models: Anthropic + OpenAI-compatible APIs (PRD §5.12).
        .target(name: "AIProviders", dependencies: ["AppCore"]),

        // Auto-edit analysis: pauses, fillers, repeats, retakes; rules + optional model pass.
        .target(name: "AutoEdit", dependencies: ["AppCore", "Transcription", "AIProviders"]),

        // `make eval`: scores providers and prompts against labeled recordings (PRD §11).
        // A developer tool; not part of the app bundle.
        .executableTarget(name: "PankaptureEval", dependencies: ["AppCore", "Transcription", "AIProviders", "AutoEdit"]),

        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
        .testTarget(name: "AnnotationTests", dependencies: ["Annotation"]),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Annotation", "AppCore"]),
        .testTarget(name: "RecordingTests", dependencies: ["Recording", "AppCore"]),
        .testTarget(name: "VideoEditorTests", dependencies: ["VideoEditor", "AutoEdit", "Transcription", "AppCore"]),
        .testTarget(name: "AutoEditTests", dependencies: ["AutoEdit", "Transcription", "AIProviders", "AppCore"]),
        .testTarget(name: "PankaptureEvalTests", dependencies: ["PankaptureEval", "AutoEdit", "AIProviders", "Transcription", "AppCore"]),
    ]
)
