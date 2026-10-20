import Foundation

/// UserDefaults keys shared by the settings UI (`@AppStorage`) and services.
/// Keep every persisted preference here so keys never drift between call sites.
public enum PreferenceKey {
    public static let appearance = "appearance"
    public static let saveDirectory = "output.saveDirectory"
    public static let imageFormat = "output.imageFormat"
    public static let copyToClipboardAfterCapture = "output.copyAfterCapture"
    public static let saveAfterCapture = "output.saveAfterCapture"
    public static let playSounds = "general.playSounds"
    /// Post a notification after each capture (saved / copied), with Open and Show in Finder.
    public static let showNotifications = "general.showNotifications"
    /// Lets `pankapture://` URLs run captures that finish without user interaction.
    /// Off by default: any web page can open these URLs.
    public static let allowsURLAutomation = "general.allowsURLAutomation"

    // MARK: Inline editor (AN-8: tool, color, and size persist between captures)
    public static let editorTool = "editor.tool"
    public static let editorColor = "editor.color"
    public static let editorSize = "editor.size"
    /// Last background/beautify options used in the editor window (JSON).
    public static let editorBeautify = "editor.beautify"
    // MARK: Quick-access thumbnail (QA-1…QA-4) and after-capture behavior (GL-9)
    /// Show the floating thumbnail after captures that don't open the inline editor.
    public static let showThumbnail = "quickAccess.showThumbnail"
    /// "left" or "right" screen corner.
    public static let thumbnailPosition = "quickAccess.position"
    /// Seconds before an untouched thumbnail hides itself; 0 = never.
    public static let thumbnailAutoDismissSeconds = "quickAccess.autoDismissSeconds"
    /// Open the full editor window after window/fullscreen captures.
    public static let openEditorAfterCapture = "output.openEditor"

    // MARK: Screenshot options (SC-6, SC-7, SC-10)
    /// Include the window's drop shadow in window captures.
    public static let windowCaptureShadow = "capture.windowShadow"
    /// Fullscreen captures every display (one file each) instead of the one under the cursor.
    public static let fullscreenAllDisplays = "capture.fullscreenAllDisplays"
    public static let captureShowsCursor = "capture.showsCursor"
    public static let captureHidesDesktopIcons = "capture.hidesDesktopIcons"

    /// Last area selection, for "Capture Previous Area" (SC-8). JSON `{displayID, rect}`.
    public static let lastSelection = "capture.lastSelection"

    // MARK: Recording

    public static let recordingSystemAudio = "recording.systemAudio"
    public static let recordingMicrophone = "recording.microphone"
    /// `AVCaptureDevice.uniqueID`; empty means the system default input.
    public static let recordingMicrophoneDeviceID = "recording.microphoneDeviceID"
    public static let recordingCamera = "recording.camera"
    /// `AVCaptureDevice.uniqueID`; empty means the system default camera.
    public static let recordingCameraDeviceID = "recording.cameraDeviceID"
    /// `circle` or `roundedRectangle`.
    public static let recordingCameraShape = "recording.cameraShape"
    public static let recordingCameraMirrored = "recording.cameraMirrored"
    /// Webcam bubble width in points.
    public static let recordingCameraSize = "recording.cameraSize"
    /// 30 or 60.
    public static let recordingFrameRate = "recording.frameRate"
    /// `h264` or `hevc`.
    public static let recordingCodec = "recording.codec"
    /// `low`, `medium`, or `high`.
    public static let recordingQuality = "recording.quality"
    /// Seconds: 0, 3, or 5.
    public static let recordingCountdown = "recording.countdown"
    public static let recordingShowsCursor = "recording.showsCursor"
    public static let recordingHighlightClicks = "recording.highlightClicks"
    /// Named click-ring color (`yellow`, `red`, `blue`, `green`, `white`).
    public static let recordingClickColor = "recording.clickColor"
    /// Click-ring diameter in points.
    public static let recordingClickSize = "recording.clickSize"
    public static let recordingShowKeystrokes = "recording.showKeystrokes"
    /// Show every key, not only ⌘/⌃/⌥ combinations.
    public static let recordingKeystrokesAllKeys = "recording.keystrokesAllKeys"
    public static let recordingHideDesktopIcons = "recording.hideDesktopIcons"
    /// `video` (MP4) or `gif` (the app converts the MP4 after recording).
    public static let recordingOutputKind = "recording.outputKind"
}

public enum ImageFormat: String, CaseIterable, Sendable, Identifiable {
    case png
    case jpeg
    case heic

    public var id: String { rawValue }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var title: String { rawValue.uppercased() }
}

public enum Preferences {
    /// Default save folder: ~/Pictures/Pankapture (keeps the Desktop clean;
    /// the capture history is the primary way to browse captures).
    public static var defaultSaveDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Pankapture", isDirectory: true)
    }

    public static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            PreferenceKey.appearance: "system",
            PreferenceKey.saveDirectory: defaultSaveDirectory.path,
            PreferenceKey.imageFormat: ImageFormat.png.rawValue,
            PreferenceKey.copyToClipboardAfterCapture: true,
            PreferenceKey.saveAfterCapture: true,
            PreferenceKey.playSounds: true,
            PreferenceKey.showNotifications: true,
            PreferenceKey.allowsURLAutomation: false,
            PreferenceKey.showThumbnail: true,
            PreferenceKey.thumbnailPosition: "right",
            PreferenceKey.thumbnailAutoDismissSeconds: 10.0,
            PreferenceKey.openEditorAfterCapture: false,
            PreferenceKey.windowCaptureShadow: true,
            PreferenceKey.fullscreenAllDisplays: false,
            PreferenceKey.captureShowsCursor: false,
            PreferenceKey.captureHidesDesktopIcons: false,
        ])
        registerRecordingDefaults(in: defaults)
    }

    // MARK: Recording

    static func registerRecordingDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [
            PreferenceKey.recordingSystemAudio: true,
            PreferenceKey.recordingMicrophone: false,
            PreferenceKey.recordingMicrophoneDeviceID: "",
            PreferenceKey.recordingCamera: false,
            PreferenceKey.recordingCameraDeviceID: "",
            PreferenceKey.recordingCameraShape: "circle",
            PreferenceKey.recordingCameraMirrored: true,
            PreferenceKey.recordingCameraSize: 200.0,
            PreferenceKey.recordingFrameRate: 60,
            PreferenceKey.recordingCodec: "h264",
            PreferenceKey.recordingQuality: "medium",
            PreferenceKey.recordingCountdown: 3,
            PreferenceKey.recordingShowsCursor: true,
            PreferenceKey.recordingHighlightClicks: false,
            PreferenceKey.recordingClickColor: "yellow",
            PreferenceKey.recordingClickSize: 44.0,
            PreferenceKey.recordingShowKeystrokes: false,
            PreferenceKey.recordingKeystrokesAllKeys: false,
            PreferenceKey.recordingHideDesktopIcons: false,
            PreferenceKey.recordingOutputKind: "video",
        ])
    }

    public static func saveDirectory(in defaults: UserDefaults = .standard) -> URL {
        let path = defaults.string(forKey: PreferenceKey.saveDirectory) ?? defaultSaveDirectory.path
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static func imageFormat(in defaults: UserDefaults = .standard) -> ImageFormat {
        defaults.string(forKey: PreferenceKey.imageFormat).flatMap(ImageFormat.init(rawValue:)) ?? .png
    }
}

// MARK: Library

public extension PreferenceKey {
    /// Record captures in the history library (HI-1). Default: true.
    static let historyEnabled = "history.enabled"
    /// Keep captures that were closed without saving (OUT-8). Default: true.
    static let historyKeepsUnsavedCaptures = "history.keepsUnsavedCaptures"
    /// Retention raw value: "forever", "days30", or "days90" (HI-5). Default: "forever".
    static let historyRetention = "history.retention"
    /// Library storage cap in GB; 0 means no cap (HI-5). Default: 0.
    static let historyStorageCapGB = "history.storageCapGB"
}
