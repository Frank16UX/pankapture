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
    /// Last area selection, for "Capture Previous Area" (SC-8). JSON `{displayID, rect}`.
    public static let lastSelection = "capture.lastSelection"
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
