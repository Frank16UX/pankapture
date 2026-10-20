import Foundation

/// Written next to every in-progress recording (`<id>.json` beside `<id>.mp4`
/// in `AppPaths.recordingsInProgress`) and deleted when the recording is
/// finalized or discarded. Anything left behind at launch is a crashed
/// recording that `RecordingRecovery` can restore (REC-9).
public struct RecordingManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var startDate: Date
    public var configuration: RecordingConfiguration
    /// Folder the finished MP4 should land in (the save folder at start time).
    public var destinationDirectory: URL

    public init(
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        startDate: Date = .now,
        configuration: RecordingConfiguration,
        destinationDirectory: URL
    ) {
        self.version = version
        self.id = id
        self.startDate = startDate
        self.configuration = configuration
        self.destinationDirectory = destinationDirectory
    }

    public static func movieURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("mp4")
    }

    public static func manifestURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    public func write(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.manifestURL(for: id, in: directory), options: .atomic)
    }

    public static func read(from url: URL) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingManifest.self, from: Data(contentsOf: url))
    }
}
