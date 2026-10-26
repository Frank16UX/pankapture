import AppCore
import Foundation

/// Transcripts of recordings, cached in `AppPaths.transcripts` and keyed by
/// the video's file name and language, like sidecars (so the user's save
/// folder stays free of extra files).
public enum TranscriptStore {
    public static func url(for videoURL: URL, language: TranscriptLanguage) -> URL {
        AppPaths.transcripts.appendingPathComponent("\(videoURL.lastPathComponent).\(language.rawValue).json")
    }

    /// A cached transcript is only reused for the same file: a recording
    /// replaced under the same name gets transcribed again.
    private struct Cached: Codable {
        var fingerprint: String
        var transcript: Transcript
    }

    /// Size and modification date of the video.
    static func fingerprint(of videoURL: URL) -> String {
        var url = videoURL
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    public static func load(for videoURL: URL, language: TranscriptLanguage) -> Transcript? {
        guard let data = try? Data(contentsOf: url(for: videoURL, language: language)),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              cached.fingerprint == fingerprint(of: videoURL) else { return nil }
        return cached.transcript
    }

    public static func save(_ transcript: Transcript, for videoURL: URL) throws {
        try AppPaths.ensure(AppPaths.transcripts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let cached = Cached(fingerprint: fingerprint(of: videoURL), transcript: transcript)
        try encoder.encode(cached).write(to: url(for: videoURL, language: transcript.language), options: .atomic)
    }

    /// Removes a recording's transcripts (when the recording is deleted).
    public static func delete(for videoURL: URL) {
        for language in TranscriptLanguage.allCases {
            try? FileManager.default.removeItem(at: url(for: videoURL, language: language))
        }
    }
}
