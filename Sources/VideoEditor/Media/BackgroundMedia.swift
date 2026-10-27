import AppCore
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Private copies of pictures and movies used as video backgrounds (VE-6),
/// at `<Application Support>/Pankapture/Backgrounds/<uuid>.<ext>`. Projects
/// point at the copy, so they keep working if the original moves.
public enum BackgroundLibrary {
    public enum Kind: Sendable {
        case image
        case video
    }

    public static var directory: URL { BackgroundFiles.directory }

    /// Whether `url` is a picture or a movie we can use, by file type.
    public static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    /// Copies `url` into the library and returns the fill for it.
    public static func importFile(_ url: URL) throws -> VideoBackground.Fill {
        guard let kind = kind(of: url) else { throw VideoEditorError.unsupportedBackground }
        return fill(kind, try BackgroundFiles.copyIn(url))
    }

    private static func fill(_ kind: Kind, _ url: URL) -> VideoBackground.Fill {
        kind == .image ? .image(url) : .video(url)
    }
}

/// A background movie's video track, loaded for one composition build. Not
/// `Sendable` (`AVAssetTrack` isn't); load it where it's used.
public struct BackgroundVideo {
    public let url: URL
    /// Kept alive here: a track only holds its asset weakly.
    public let asset: AVURLAsset
    public let track: AVAssetTrack
    /// Seconds of picture; the composition loops it.
    public let duration: Double
    public let orientation: CGImagePropertyOrientation

    public static func load(url: URL) async throws -> sending BackgroundVideo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEditorError.noVideoTrack
        }
        let (range, transform) = try await track.load(.timeRange, .preferredTransform)
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0.05 else { throw VideoEditorError.noVideoTrack }
        return BackgroundVideo(url: url, asset: asset, track: track, duration: duration, orientation: SourceMedia.orientation(for: transform))
    }

    /// The project's background movie, or `nil` if it has none or it can't
    /// be read (the frame then shows the shadow over black).
    public static func load(for project: VideoEditProject) async -> sending BackgroundVideo? {
        guard let url = project.background.fill.videoURL else { return nil }
        do {
            return try await load(url: url)
        } catch {
            Log.editor.error("Background video unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
