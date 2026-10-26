import AppCore
import AVFoundation
import CoreGraphics
import ImageIO

/// One audio track of the source and what it carries.
public struct AudioTrackInfo: Sendable, Identifiable, Equatable {
    public let trackID: CMPersistentTrackID
    public let role: AudioRole
    /// "System Audio", "Microphone", or "Audio 1/2" when the file doesn't say.
    public let label: String
    public let timeRange: TimeRange

    public var id: CMPersistentTrackID { trackID }
}

/// The recorder's webcam track (ADR-25): drawn as a movable layer.
public struct CameraTrackInfo: Sendable, Equatable {
    public let trackID: CMPersistentTrackID
    /// Upright frame size, pixels.
    public let size: CGSize
    public let orientation: CGImagePropertyOrientation
    public let timeRange: TimeRange
}

/// The source's tracks, resolved for one composition build. Not `Sendable`
/// (`AVAssetTrack` isn't); load it in the isolation domain that uses it.
public struct LoadedTracks {
    public let video: AVAssetTrack
    public let audio: [CMPersistentTrackID: AVAssetTrack]
    public var camera: AVAssetTrack?
}

/// The loaded properties of a source movie, gathered once with the async
/// AVFoundation loaders. `Sendable` (it holds the asset and track IDs, not
/// `AVAssetTrack`s), so exports can take it off the main actor.
public struct SourceMedia: Sendable {
    public let url: URL
    public let asset: AVURLAsset
    /// Editable duration: the asset's, capped at the end of the video track.
    public let duration: Double
    public let videoTrackID: CMPersistentTrackID
    public let videoTimeRange: TimeRange
    /// Upright frame size in pixels (after `preferredTransform`).
    public let size: CGSize
    public let orientation: CGImagePropertyOrientation
    /// The track's display transform, normalized so the upright frame starts
    /// at (0, 0) (some files omit the translation part).
    public let preferredTransform: CGAffineTransform
    /// Best guess at the frame rate (max of nominal and 1/min frame duration, ≤ 60).
    public let frameRate: Double
    /// Average video data rate of the source, bits per second (0 if unknown).
    public let videoBitrate: Double
    public let audioTracks: [AudioTrackInfo]
    /// The webcam, when it was recorded as its own track.
    public let camera: CameraTrackInfo?

    public static func load(url: URL) async throws -> SourceMedia {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        var screenTracks: [AVAssetTrack] = []
        var cameraTrack: AVAssetTrack?
        for track in try await asset.loadTracks(withMediaType: .video) {
            if cameraTrack == nil, await RecordingTracks.name(of: track)?.lowercased() == RecordingTracks.cameraName {
                cameraTrack = track
            } else {
                screenTracks.append(track)
            }
        }
        guard let videoTrack = screenTracks.first else {
            throw VideoEditorError.noVideoTrack
        }
        let (naturalSize, transform, nominalRate, minFrameDuration, videoRange) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .timeRange
        )
        let dataRate = (try? await videoTrack.load(.estimatedDataRate)) ?? 0

        let orientation = Self.orientation(for: transform)
        let size: CGSize = switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: CGSize(width: naturalSize.height, height: naturalSize.width)
        default: naturalSize
        }

        var frameRate = Double(nominalRate)
        if minFrameDuration.isValid, minFrameDuration.seconds > 0 {
            frameRate = max(frameRate, 1 / minFrameDuration.seconds)
        }
        frameRate = min(frameRate, 60)

        var audio: [AVAssetTrack] = []
        var names: [String?] = []
        var ranges: [TimeRange] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let name = await RecordingTracks.name(of: track)
            // The recorder's "Mix" track (system + mic for players that play
            // one track) duplicates the separate tracks the editor mixes itself.
            if name?.lowercased() == RecordingTracks.mixName { continue }
            audio.append(track)
            names.append(name)
            let range = try await track.load(.timeRange)
            ranges.append(TimeRange(start: range.start.seconds, end: range.end.seconds))
        }
        let roles = RecordingTracks.resolveRoles(names: names)
        let audioTracks = audio.indices.map { index in
            AudioTrackInfo(
                trackID: audio[index].trackID,
                role: roles[index].role,
                label: roles[index].label,
                timeRange: ranges[index]
            )
        }

        // Edit the span that has pictures: audio running past the last video
        // frame would otherwise end exports on empty frames.
        var editable = duration.isFinite ? duration : 0
        let videoEnd = videoRange.end.seconds
        if videoEnd.isFinite, videoEnd > 0 { editable = min(editable, videoEnd) }

        var camera: CameraTrackInfo?
        if let cameraTrack {
            let (size, transform, range) = try await cameraTrack.load(.naturalSize, .preferredTransform, .timeRange)
            let orientation = Self.orientation(for: transform)
            let upright: CGSize = switch orientation {
            case .left, .right, .leftMirrored, .rightMirrored: CGSize(width: size.height, height: size.width)
            default: size
            }
            camera = CameraTrackInfo(
                trackID: cameraTrack.trackID, size: upright, orientation: orientation,
                timeRange: TimeRange(start: range.start.seconds, end: range.end.seconds)
            )
        }

        return SourceMedia(
            url: url,
            asset: asset,
            duration: editable,
            videoTrackID: videoTrack.trackID,
            videoTimeRange: TimeRange(start: videoRange.start.seconds, end: videoRange.end.seconds),
            size: size,
            orientation: orientation,
            preferredTransform: Self.normalized(transform, naturalSize: naturalSize),
            frameRate: frameRate,
            videoBitrate: Double(dataRate.isFinite ? dataRate : 0),
            audioTracks: audioTracks,
            camera: camera
        )
    }

    /// Resolves the AVFoundation tracks (cheap: the asset has them loaded).
    public func loadTracks() async throws -> sending LoadedTracks {
        guard let video = try await asset.loadTrack(withTrackID: videoTrackID) else {
            throw VideoEditorError.noVideoTrack
        }
        var audio: [CMPersistentTrackID: AVAssetTrack] = [:]
        for info in audioTracks {
            if let track = try await asset.loadTrack(withTrackID: info.trackID) { audio[info.trackID] = track }
        }
        var camera: AVAssetTrack?
        if let info = self.camera { camera = try await asset.loadTrack(withTrackID: info.trackID) }
        return LoadedTracks(video: video, audio: audio, camera: camera)
    }

    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        // Matrices built with `rotationAngle:` carry float noise (cos π/2 ≈ 6e-17).
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }

    /// Shifts `transform` so the transformed frame's origin is (0, 0).
    static func normalized(_ transform: CGAffineTransform, naturalSize: CGSize) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }
}
