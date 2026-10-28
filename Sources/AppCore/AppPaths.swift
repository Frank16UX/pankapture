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

    /// OpenRouter's public model list with prices (PRD AI-8), refetched daily.
    public static var modelCatalog: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pankapture/openrouter-models.json")
    }

    /// Per-recording metadata (`RecordingSidecar`) for the video editor.
    public static var sidecars: URL {
        applicationSupport.appendingPathComponent("Sidecars", isDirectory: true)
    }

    /// Capture history: originals, annotations, thumbnails, and the index.
    public static var library: URL {
        applicationSupport.appendingPathComponent("Library", isDirectory: true)
    }

    /// On-device transcripts of recordings, `<video>.<language>.json` (PRD AE-1),
    /// cached so auto-edit and captions don't transcribe twice.
    public static var transcripts: URL {
        applicationSupport.appendingPathComponent("Transcripts", isDirectory: true)
    }

    /// Cleaned-up copies of recordings' microphone tracks (noise removal,
    /// loudness), one per setting; deletable, regenerated on demand (PRD AU-1).
    public static var processedAudio: URL {
        applicationSupport.appendingPathComponent("ProcessedAudio", isDirectory: true)
    }

    /// Layered originals of recordings made with the camera as its own track
    /// (ADR-25). The save folder gets a composited copy with the same name;
    /// the video editor opens the original from here.
    public static var recordingSources: URL {
        applicationSupport.appendingPathComponent("Recordings/Sources", isDirectory: true)
    }

    /// The file to edit for `url`: its layered original, if there is one.
    public static func editableRecording(for url: URL) -> URL {
        let source = recordingSources.appendingPathComponent(url.lastPathComponent)
        guard url.deletingLastPathComponent().standardizedFileURL != recordingSources.standardizedFileURL,
              FileManager.default.fileExists(atPath: source.path) else { return url }
        return source
    }

    /// Creates `url` (and parents) if needed and returns it.
    @discardableResult
    public static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
