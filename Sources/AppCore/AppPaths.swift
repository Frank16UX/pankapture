import Foundation

/// Locations of Pankapture's private files. User-facing exports go to the save
/// folder (`Preferences.saveDirectory`); everything here is app-owned.
public enum AppPaths {
    /// `~/Library/Application Support/Pankapture`
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pankapture", isDirectory: true)
    }

    /// Recordings being written right now (fragmented MP4 + manifest). Anything
    /// left here at launch is a recording interrupted by a crash (REC-9).
    public static var recordingsInProgress: URL {
        applicationSupport.appendingPathComponent("Recordings/InProgress", isDirectory: true)
    }

    /// Per-recording metadata (`RecordingSidecar`) for the video editor.
    public static var sidecars: URL {
        applicationSupport.appendingPathComponent("Sidecars", isDirectory: true)
    }

    /// Capture history: originals, annotations, thumbnails, and the index.
    public static var library: URL {
        applicationSupport.appendingPathComponent("Library", isDirectory: true)
    }

    /// Creates `url` (and parents) if needed and returns it.
    @discardableResult
    public static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
