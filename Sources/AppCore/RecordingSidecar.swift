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
    /// Where the webcam bubble was, when the camera was recorded as its own
    /// track ("Camera"). `nil` for recordings without one.
    public var camera: Camera?

    public init(version: Int = Self.currentVersion, videoSize: CGSize, duration: Double, clicks: [Click] = [], camera: Camera? = nil) {
        self.version = version
        self.videoSize = videoSize
        self.duration = duration
        self.clicks = clicks
        self.camera = camera
    }

    /// The bubble as it looked on screen, relative to the recorded frame.
    public struct Camera: Codable, Equatable, Sendable {
        /// Bubble center, normalized to the recorded frame: (0,0) top-left.
        public var center: CGPoint
        /// Bubble width as a fraction of the recorded frame's shorter side.
        public var size: Double
        /// `true` for a circle, `false` for a rounded rectangle (4:3).
        public var isCircle: Bool
        /// Whether the preview was mirrored (the track itself never is).
        public var isMirrored: Bool

        public init(center: CGPoint, size: Double, isCircle: Bool, isMirrored: Bool) {
            self.center = center
            self.size = size
            self.isCircle = isCircle
            self.isMirrored = isMirrored
        }
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
