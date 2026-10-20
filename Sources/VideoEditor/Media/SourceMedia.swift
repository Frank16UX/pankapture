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

/// The source's tracks, resolved for one composition build. Not `Sendable`
/// (`AVAssetTrack` isn't); load it in the isolation domain that uses it.
public struct LoadedTracks {
    public let video: AVAssetTrack
    public let audio: [CMPersistentTrackID: AVAssetTrack]
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

    public static func load(url: URL) async throws -> SourceMedia {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
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

        let audio = try await asset.loadTracks(withMediaType: .audio)
        var names: [String?] = []
        var ranges: [TimeRange] = []
        for track in audio {
            names.append(await Self.name(of: track))
            let range = try await track.load(.timeRange)
            ranges.append(TimeRange(start: range.start.seconds, end: range.end.seconds))
        }
        let roles = Self.resolveRoles(names: names)
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
            audioTracks: audioTracks
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
        return LoadedTracks(video: video, audio: audio)
    }

    /// Track roles from track names when present ("…mic…" / "…system…");
    /// otherwise by order (first = system, second = microphone, REC-4) with
    /// neutral labels, since the order is only a convention.
    static func resolveRoles(names: [String?]) -> [(role: AudioRole, label: String)] {
        var result: [(role: AudioRole, label: String)?] = Array(repeating: nil, count: names.count)
        for (index, name) in names.enumerated() {
            guard let name = name?.lowercased() else { continue }
            if name.contains("mic") || name.contains("voice") {
                result[index] = (.microphone, "Microphone")
            } else if name.contains("system") {
                result[index] = (.system, "System Audio")
            }
        }
        var free = AudioRole.allCases.filter { role in !result.contains { $0?.role == role } }
        for index in result.indices where result[index] == nil {
            let role = free.isEmpty ? AudioRole.system : free.removeFirst()
            result[index] = (role, names.count == 1 ? "Audio" : "Audio \(index + 1)")
        }
        return result.map { $0 ?? (.system, "Audio") }
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

    private static func name(of track: AVAssetTrack) async -> String? {
        guard let items = try? await track.load(.metadata) else { return nil }
        let identifiers: Set<AVMetadataIdentifier> = [
            .quickTimeUserDataTrackName, .commonIdentifierTitle, .quickTimeMetadataDisplayName,
        ]
        for item in items {
            guard let identifier = item.identifier, identifiers.contains(identifier) else { continue }
            if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
        }
        return nil
    }
}
