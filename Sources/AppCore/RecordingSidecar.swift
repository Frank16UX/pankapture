import CoreGraphics
import Foundation

/// Metadata captured alongside a screen recording and consumed by the video
/// editor (auto-zoom from clicks, VE-5). Shared by the `Recording` (writer) and
/// `VideoEditor` (reader) modules, which never import each other.
///
/// Stored as JSON at `RecordingSidecar.location(for:)`, keyed by the video's
/// file name, so the user's save folder stays free of extra files.
public struct RecordingSidecar: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Pixel size of the recorded video frames.
    public var videoSize: CGSize
    /// Seconds of output timeline (pauses already removed).
    public var duration: Double
    public var clicks: [Click]

    public init(version: Int = Self.currentVersion, videoSize: CGSize, duration: Double, clicks: [Click] = []) {
        self.version = version
        self.videoSize = videoSize
        self.duration = duration
        self.clicks = clicks
    }

    public struct Click: Codable, Equatable, Sendable {
        /// Seconds from the start of the output timeline (pauses removed).
        public var time: Double
        /// Normalized position in the video frame: (0,0) top-left, (1,1) bottom-right.
        public var location: CGPoint
        public var isRightClick: Bool

        public init(time: Double, location: CGPoint, isRightClick: Bool = false) {
            self.time = time
            self.location = location
            self.isRightClick = isRightClick
        }
    }

    public static func location(for videoURL: URL) -> URL {
        AppPaths.sidecars.appendingPathComponent(videoURL.lastPathComponent).appendingPathExtension("json")
    }

    public static func load(for videoURL: URL) -> RecordingSidecar? {
        guard let data = try? Data(contentsOf: location(for: videoURL)) else { return nil }
        return try? JSONDecoder().decode(RecordingSidecar.self, from: data)
    }

    public func save(for videoURL: URL) throws {
        try AppPaths.ensure(AppPaths.sidecars)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.location(for: videoURL), options: .atomic)
    }
}
