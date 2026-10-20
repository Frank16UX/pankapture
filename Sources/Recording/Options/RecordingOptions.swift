import AppCore
import CoreGraphics
import Foundation

/// The user's recording choices, persisted in UserDefaults under the
/// `PreferenceKey.recording*` keys. Combined with a chosen source and the
/// overlay window IDs it becomes a `RecordingConfiguration`.
public struct RecordingOptions: Equatable, Sendable {
    public enum SourceKind: String, CaseIterable, Sendable, Identifiable {
        case area
        case window
        case display

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .area: "Area"
            case .window: "Window"
            case .display: "Display"
            }
        }
        public var symbolName: String {
            switch self {
            case .area: "rectangle.dashed"
            case .window: "macwindow"
            case .display: "display"
            }
        }
    }

    /// GIF mode (REC-14): the recorder always writes MP4; for `.gif` the app
    /// converts the finished MP4 with the video editor's GIF exporter.
    public enum OutputKind: String, CaseIterable, Sendable, Identifiable {
        case video
        case gif

        public var id: String { rawValue }
        public var title: String { self == .video ? "MP4" : "GIF" }
    }

    public enum CameraShape: String, CaseIterable, Sendable, Identifiable {
        case circle
        case roundedRectangle

        public var id: String { rawValue }
        public var title: String { self == .circle ? "Circle" : "Rounded" }
        public var symbolName: String { self == .circle ? "circle" : "rectangle" }
    }

    /// Click-ring colors. These are *content* (they're recorded), so they're
    /// fixed sRGB values that look the same in light and dark mode.
    public enum ClickColor: String, CaseIterable, Sendable, Identifiable {
        case yellow
        case red
        case blue
        case green
        case white

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
        public var rgb: (red: Double, green: Double, blue: Double) {
            switch self {
            case .yellow: (1.0, 0.80, 0.0)
            case .red: (1.0, 0.23, 0.19)
            case .blue: (0.0, 0.48, 1.0)
            case .green: (0.20, 0.78, 0.35)
            case .white: (1.0, 1.0, 1.0)
            }
        }
    }

    public static let frameRates = [30, 60]
    public static let countdowns = [0, 3, 5]
    public static let cameraSizeRange: ClosedRange<Double> = 120...480
    public static let clickSizeRange: ClosedRange<Double> = 24...96

    public var capturesSystemAudio = true
    public var capturesMicrophone = false
    /// `nil` = system default input.
    public var microphoneDeviceID: String?
    public var showsCamera = false
    /// `nil` = system default camera.
    public var cameraDeviceID: String?
    public var cameraShape: CameraShape = .circle
    public var cameraMirrored = true
    /// Bubble width in points.
    public var cameraSize: Double = 200
    public var framesPerSecond = 60
    public var codec: RecordingConfiguration.Codec = .h264
    public var quality: RecordingConfiguration.Quality = .medium
    public var countdown = 3
    public var showsCursor = true
    public var highlightsClicks = false
    public var clickColor: ClickColor = .yellow
    /// Click-ring diameter in points.
    public var clickSize: Double = 44
    public var showsKeystrokes = false
    /// Show every key, not only ⌘/⌃/⌥ combinations.
    public var keystrokesShowAllKeys = false
    public var hidesDesktopIcons = false
    public var outputKind: OutputKind = .video

    public init() {}

    // MARK: Configuration

    /// Builds the engine configuration for `source`. `overlayWindowIDs` are the
    /// webcam/click/keystroke panels that must be recorded.
    public func makeConfiguration(
        source: RecordingConfiguration.Source,
        overlayWindowIDs: [CGWindowID] = []
    ) -> RecordingConfiguration {
        // GIFs have no audio track, so don't capture any.
        let wantsAudio = outputKind == .video
        return RecordingConfiguration(
            source: source,
            framesPerSecond: Self.frameRates.contains(framesPerSecond) ? framesPerSecond : 60,
            codec: codec,
            quality: quality,
            capturesSystemAudio: wantsAudio && capturesSystemAudio,
            capturesMicrophone: wantsAudio && capturesMicrophone,
            microphoneDeviceID: microphoneDeviceID,
            showsCursor: showsCursor,
            hidesDesktopIcons: hidesDesktopIcons,
            countdown: Self.countdowns.contains(countdown) ? countdown : 0,
            includedOverlayWindowIDs: overlayWindowIDs
        )
    }

    // MARK: Persistence

    public static func load(from defaults: UserDefaults = .standard) -> RecordingOptions {
        var options = RecordingOptions()
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { (defaults.object(forKey: key) as? NSNumber)?.intValue ?? fallback }
        func string(_ key: String) -> String? { defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }

        options.capturesSystemAudio = bool(PreferenceKey.recordingSystemAudio, options.capturesSystemAudio)
        options.capturesMicrophone = bool(PreferenceKey.recordingMicrophone, options.capturesMicrophone)
        options.microphoneDeviceID = string(PreferenceKey.recordingMicrophoneDeviceID)
        options.showsCamera = bool(PreferenceKey.recordingCamera, options.showsCamera)
        options.cameraDeviceID = string(PreferenceKey.recordingCameraDeviceID)
        options.cameraShape = string(PreferenceKey.recordingCameraShape).flatMap(CameraShape.init(rawValue:)) ?? options.cameraShape
        options.cameraMirrored = bool(PreferenceKey.recordingCameraMirrored, options.cameraMirrored)
        options.cameraSize = double(PreferenceKey.recordingCameraSize, options.cameraSize)
            .clamped(to: cameraSizeRange)
        options.framesPerSecond = int(PreferenceKey.recordingFrameRate, options.framesPerSecond)
        options.codec = string(PreferenceKey.recordingCodec).flatMap(RecordingConfiguration.Codec.init(rawValue:)) ?? options.codec
        options.quality = string(PreferenceKey.recordingQuality).flatMap(RecordingConfiguration.Quality.init(rawValue:)) ?? options.quality
        options.countdown = int(PreferenceKey.recordingCountdown, options.countdown)
        options.showsCursor = bool(PreferenceKey.recordingShowsCursor, options.showsCursor)
        options.highlightsClicks = bool(PreferenceKey.recordingHighlightClicks, options.highlightsClicks)
        options.clickColor = string(PreferenceKey.recordingClickColor).flatMap(ClickColor.init(rawValue:)) ?? options.clickColor
        options.clickSize = double(PreferenceKey.recordingClickSize, options.clickSize).clamped(to: clickSizeRange)
        options.showsKeystrokes = bool(PreferenceKey.recordingShowKeystrokes, options.showsKeystrokes)
        options.keystrokesShowAllKeys = bool(PreferenceKey.recordingKeystrokesAllKeys, options.keystrokesShowAllKeys)
        options.hidesDesktopIcons = bool(PreferenceKey.recordingHideDesktopIcons, options.hidesDesktopIcons)
        options.outputKind = string(PreferenceKey.recordingOutputKind).flatMap(OutputKind.init(rawValue:)) ?? options.outputKind
        return options
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(capturesSystemAudio, forKey: PreferenceKey.recordingSystemAudio)
        defaults.set(capturesMicrophone, forKey: PreferenceKey.recordingMicrophone)
        defaults.set(microphoneDeviceID ?? "", forKey: PreferenceKey.recordingMicrophoneDeviceID)
        defaults.set(showsCamera, forKey: PreferenceKey.recordingCamera)
        defaults.set(cameraDeviceID ?? "", forKey: PreferenceKey.recordingCameraDeviceID)
        defaults.set(cameraShape.rawValue, forKey: PreferenceKey.recordingCameraShape)
        defaults.set(cameraMirrored, forKey: PreferenceKey.recordingCameraMirrored)
        defaults.set(cameraSize, forKey: PreferenceKey.recordingCameraSize)
        defaults.set(framesPerSecond, forKey: PreferenceKey.recordingFrameRate)
        defaults.set(codec.rawValue, forKey: PreferenceKey.recordingCodec)
        defaults.set(quality.rawValue, forKey: PreferenceKey.recordingQuality)
        defaults.set(countdown, forKey: PreferenceKey.recordingCountdown)
        defaults.set(showsCursor, forKey: PreferenceKey.recordingShowsCursor)
        defaults.set(highlightsClicks, forKey: PreferenceKey.recordingHighlightClicks)
        defaults.set(clickColor.rawValue, forKey: PreferenceKey.recordingClickColor)
        defaults.set(clickSize, forKey: PreferenceKey.recordingClickSize)
        defaults.set(showsKeystrokes, forKey: PreferenceKey.recordingShowKeystrokes)
        defaults.set(keystrokesShowAllKeys, forKey: PreferenceKey.recordingKeystrokesAllKeys)
        defaults.set(hidesDesktopIcons, forKey: PreferenceKey.recordingHideDesktopIcons)
        defaults.set(outputKind.rawValue, forKey: PreferenceKey.recordingOutputKind)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
