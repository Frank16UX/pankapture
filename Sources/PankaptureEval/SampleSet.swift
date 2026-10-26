import Foundation
import Transcription

/// One labeled recording in `<dir>/samples/<split>/<language>-<name>/` (PRD §11.2).
struct Sample: Sendable {
    var name: String
    var split: String
    var directory: URL
    var recording: URL
    var language: TranscriptLanguage
    var labels: [Label]

    static let movieExtensions: Set<String> = ["mp4", "mov", "m4v"]

    struct SampleError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The samples of `split` ("dev", "test", or "all"), sorted by name.
    static func load(root: URL, split: String) throws -> [Sample] {
        let splits = split == "all" ? ["dev", "test"] : [split]
        var samples: [Sample] = []
        for split in splits {
            let folder = root.appendingPathComponent("samples/\(split)", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                samples.append(try load(directory: directory, split: split))
            }
        }
        guard !samples.isEmpty else {
            throw SampleError(message: "No samples in \(root.appendingPathComponent("samples").path)/\(split == "all" ? "{dev,test}" : split). See PRD §11.2.")
        }
        return samples
    }

    static func load(directory: URL, split: String) throws -> Sample {
        let name = directory.lastPathComponent
        guard let code = name.split(separator: "-").first, let language = TranscriptLanguage(rawValue: String(code)) else {
            throw SampleError(message: "\(name): the folder name must start with en- or es-.")
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let movies = files.filter { movieExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { ($0.deletingPathExtension().lastPathComponent == "recording" ? 0 : 1, $0.lastPathComponent)
                < ($1.deletingPathExtension().lastPathComponent == "recording" ? 0 : 1, $1.lastPathComponent) }
        guard let recording = movies.first else {
            throw SampleError(message: "\(name): no recording (recording.mp4) in the folder.")
        }
        let labelsURL = directory.appendingPathComponent("labels.tsv")
        guard let text = try? String(contentsOf: labelsURL, encoding: .utf8) else {
            throw SampleError(message: "\(name): no labels.tsv (an empty one with just the header is fine for controls).")
        }
        let labels: [Label]
        do {
            labels = try LabelParser.parse(text)
        } catch {
            throw SampleError(message: "\(name)/labels.tsv \(error.localizedDescription)")
        }
        return Sample(name: name, split: split, directory: directory, recording: recording, language: language, labels: labels)
    }

    // MARK: Transcript cache

    private struct CachedTranscript: Codable {
        var fingerprint: String
        var transcript: Transcript
    }

    private var cacheURL: URL {
        directory.appendingPathComponent(".cache/transcript-\(language.rawValue).json")
    }

    /// Size and modification date: a re-exported recording invalidates the cache.
    private var fingerprint: String {
        var url = recording
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    func cachedTranscript() -> Transcript? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedTranscript.self, from: data),
              cached.fingerprint == fingerprint else { return nil }
        return cached.transcript
    }

    func saveTranscript(_ transcript: Transcript) throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(CachedTranscript(fingerprint: fingerprint, transcript: transcript)).write(to: cacheURL, options: .atomic)
    }
}
