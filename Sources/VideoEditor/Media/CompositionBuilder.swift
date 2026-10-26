import AppCore
import AVFoundation
import CoreGraphics

/// A playable/exportable edit: the composition plus how to draw and mix it.
/// Not `Sendable` (AVFoundation mutable objects); build it where it's used.
public struct EditComposition {
    public let composition: AVMutableComposition
    /// `nil` only for preview of an unedited frame (the player shows the track as is).
    public let videoComposition: AVVideoComposition?
    public let audioMix: AVAudioMix?
    public let plan: RenderPlan
    public let timeline: Timeline
    /// The looped background movie's track in `composition`, if any.
    public let backgroundTrackID: CMPersistentTrackID?
    /// The webcam track in `composition`, if the source has one (ADR-25).
    public let cameraTrackID: CMPersistentTrackID?
    /// Whether at least one unmuted, non-silent audio track is included.
    public let hasAudibleAudio: Bool

    public var duration: Double { composition.duration.seconds }
}

/// Builds `AVMutableComposition` + video composition + audio mix from a
/// project (ARCHITECTURE §4.3). Kept ranges are inserted per track, speed
/// segments are applied with `scaleTimeRange`, and frames are drawn by
/// `VideoEditCompositor` only when something actually changes the picture.
public enum CompositionBuilder {
    /// Timescale for converting model seconds to `CMTime` (divisible by
    /// 24/25/30/48/50/60 fps and fine-grained enough for audio edits).
    public static let timescale: CMTimeScale = 60_000

    public struct Options: Sendable {
        /// MP4 resolution cap (shorter side), `nil` = canvas size.
        public var shortSideCap: Double?
        /// MP4 export size (shorter side, up or down), `nil` = canvas size.
        public var shortSide: Double?
        /// MP4 export size as a fraction of the canvas, `nil` = canvas size.
        public var scale: Double?
        /// GIF width cap, `nil` = canvas width.
        public var width: Int?
        public var frameRate: Int
        public var zoomEnabled: Bool
        /// Exports always need a video composition (sizing, fps); the preview
        /// skips it when frames are unchanged.
        public var forceVideoComposition: Bool
        /// The preview keeps muted tracks so volume changes don't need a rebuild.
        public var includeMutedAudio: Bool

        public init(
            shortSideCap: Double? = nil,
            shortSide: Double? = nil,
            scale: Double? = nil,
            width: Int? = nil,
            frameRate: Int = 30,
            zoomEnabled: Bool = true,
            forceVideoComposition: Bool = true,
            includeMutedAudio: Bool = false
        ) {
            self.shortSideCap = shortSideCap
            self.shortSide = shortSide
            self.scale = scale
            self.width = width
            self.frameRate = frameRate
            self.zoomEnabled = zoomEnabled
            self.forceVideoComposition = forceVideoComposition
            self.includeMutedAudio = includeMutedAudio
        }

        public static func preview(frameRate: Double, zoomEnabled: Bool = true) -> Options {
            // Cap the preview canvas: the window is never larger than this, and
            // the GPU work per frame drops a lot for Retina-sized recordings.
            Options(
                shortSideCap: 1080,
                frameRate: Int(frameRate.rounded()).clamped(to: 24...60),
                zoomEnabled: zoomEnabled,
                forceVideoComposition: false,
                includeMutedAudio: true
            )
        }
    }

    public static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    public static func cmRange(_ range: TimeRange) -> CMTimeRange {
        CMTimeRange(start: cmTime(range.start), end: cmTime(range.end))
    }

    public static func build(source: SourceMedia, project: VideoEditProject, options: Options) async throws -> sending EditComposition {
        let tracks = try await source.loadTracks()
        let background = await BackgroundVideo.load(for: project)
        return try build(source: source, tracks: tracks, project: project, options: options, background: background)
    }

    /// - Parameter background: the project's background movie (load it with
    ///   `BackgroundVideo.load(for:)`); ignored unless the fill is that movie.
    public static func build(
        source: SourceMedia,
        tracks: LoadedTracks,
        project: VideoEditProject,
        options: Options,
        background: BackgroundVideo? = nil
    ) throws -> EditComposition {
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("buildComposition", id: signpostID)
        defer { Log.signposter.endInterval("buildComposition", interval) }

        let timeline = Timeline(project: project)
        guard timeline.outputDuration > 0 else { throw VideoEditorError.emptyTimeline }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoEditorError.compositionFailed("Couldn't add a video track")
        }
        videoTrack.preferredTransform = source.preferredTransform

        // The webcam, edited exactly like the screen (same cuts and speeds).
        var cameraTrack: AVMutableCompositionTrack?
        if source.camera != nil, tracks.camera != nil {
            cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        // Audio tracks, each tagged with its role for the mix.
        var audioTracks: [(composition: AVMutableCompositionTrack, source: AudioTrackInfo, track: AVAssetTrack, volume: Double)] = []
        for info in source.audioTracks {
            guard let sourceTrack = tracks.audio[info.trackID] else { continue }
            let volume = project.trackVolumes[info.role].effectiveVolume
            guard options.includeMutedAudio || volume > 0 else { continue }
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            audioTracks.append((track, info, sourceTrack, volume))
        }

        // Insert kept pieces back to back; scale the ones with a speed change.
        var cursor = CMTime.zero
        for segment in timeline.segments {
            let pieceStart = cursor
            let pieceDuration = cmTime(segment.source.end) - cmTime(segment.source.start)
            guard pieceDuration > .zero else { continue }

            if let range = segment.source.intersection(source.videoTimeRange) {
                let offset = cmTime(range.start) - cmTime(segment.source.start)
                try videoTrack.insertTimeRange(cmRange(range), of: tracks.video, at: pieceStart + offset)
            }
            if let cameraTrack, let camera = tracks.camera, let info = source.camera,
               let range = segment.source.intersection(info.timeRange)?.intersection(TimeRange(start: 0, end: source.duration)) {
                let offset = cmTime(range.start) - cmTime(segment.source.start)
                try cameraTrack.insertTimeRange(cmRange(range), of: camera, at: pieceStart + offset)
            }
            for audio in audioTracks {
                // Never past the last video frame (see `SourceMedia.duration`).
                guard let range = segment.source.intersection(audio.source.timeRange)?
                    .intersection(TimeRange(start: 0, end: source.duration)) else { continue }
                let offset = cmTime(range.start) - cmTime(segment.source.start)
                try audio.composition.insertTimeRange(cmRange(range), of: audio.track, at: pieceStart + offset)
            }

            if abs(segment.rate - 1) > 1e-6 {
                let scaled = CMTimeMultiplyByFloat64(pieceDuration, multiplier: 1 / segment.rate)
                composition.scaleTimeRange(CMTimeRange(start: pieceStart, duration: pieceDuration), toDuration: scaled)
                cursor = pieceStart + scaled
            } else {
                cursor = pieceStart + pieceDuration
            }
        }

        // The background movie, looped over the whole output. Inserted after
        // the speed changes: `scaleTimeRange` would otherwise retime it too.
        var backgroundTrackID: CMPersistentTrackID?
        if let background, background.url == project.background.fill.videoURL,
           let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let total = composition.duration
            let loop = cmTime(background.duration)
            var at = CMTime.zero
            while at < total {
                let piece = CMTimeMinimum(loop, total - at)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: background.track, at: at)
                at = at + piece
            }
            backgroundTrackID = track.trackID
        }

        let plan = RenderPlan(
            project: project,
            sourceSize: source.size,
            orientation: source.orientation,
            shortSideCap: options.shortSideCap,
            shortSide: options.shortSide,
            scale: options.scale,
            width: options.width,
            zoomEnabled: options.zoomEnabled,
            backgroundOrientation: background?.orientation ?? .up,
            hasCameraTrack: cameraTrack != nil,
            cameraOrientation: source.camera?.orientation ?? .up
        )
        let videoComposition = makeVideoComposition(
            plan: plan,
            source: source,
            videoTrackID: videoTrack.trackID,
            backgroundTrackID: backgroundTrackID,
            cameraTrackID: cameraTrack?.trackID,
            duration: composition.duration,
            frameRate: options.frameRate,
            force: options.forceVideoComposition
        )

        var audioMix: AVMutableAudioMix?
        if !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { audio in
                let parameters = AVMutableAudioMixInputParameters(track: audio.composition)
                parameters.setVolume(Float(audio.volume), at: .zero)
                parameters.audioTimePitchAlgorithm = .spectral
                return parameters
            }
            audioMix = mix
        }

        return EditComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            plan: plan,
            timeline: timeline,
            backgroundTrackID: backgroundTrackID,
            cameraTrackID: cameraTrack?.trackID,
            hasAudibleAudio: audioTracks.contains { $0.volume > 0 }
        )
    }

    /// The video composition for `plan` over a composition whose video track is
    /// `videoTrackID`. The editor calls this directly when only zoom or
    /// background changed, to swap it on the current player item.
    ///
    /// - Parameter force: return a built-in-compositor composition (orient +
    ///   scale) when the plan doesn't need the custom one; otherwise `nil`.
    public static func makeVideoComposition(
        plan: RenderPlan,
        source: SourceMedia,
        videoTrackID: CMPersistentTrackID,
        backgroundTrackID: CMPersistentTrackID? = nil,
        cameraTrackID: CMPersistentTrackID? = nil,
        duration: CMTime,
        frameRate: Int,
        force: Bool
    ) -> AVVideoComposition? {
        let outputRange = CMTimeRange(start: .zero, duration: duration)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))

        let videoComposition: AVMutableVideoComposition
        if plan.needsCustomCompositor {
            videoComposition = AVMutableVideoComposition()
            videoComposition.customVideoCompositorClass = VideoEditCompositor.self
            videoComposition.instructions = [
                VideoEditInstruction(
                    timeRange: outputRange,
                    sourceTrackID: videoTrackID,
                    backgroundTrackID: backgroundTrackID,
                    cameraTrackID: plan.camera == nil ? nil : cameraTrackID,
                    renderer: FrameRenderer(plan: plan)
                ),
            ]
        } else if force || cameraTrackID != nil {
            // Built-in compositor: orient + scale only. Much cheaper per frame.
            // Also when a (hidden) camera track exists: without a video
            // composition the player would stack both video tracks.
            videoComposition = AVMutableVideoComposition()
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = outputRange
            let layer = AVMutableVideoCompositionLayerInstruction()
            layer.trackID = videoTrackID
            let scale = CGAffineTransform(
                scaleX: plan.renderSize.width / max(1, source.size.width),
                y: plan.renderSize.height / max(1, source.size.height)
            )
            layer.setTransform(source.preferredTransform.concatenating(scale), at: .zero)
            instruction.layerInstructions = [layer]
            videoComposition.instructions = [instruction]
        } else {
            return nil
        }
        videoComposition.renderSize = plan.renderSize
        videoComposition.frameDuration = frameDuration
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return videoComposition
    }

    /// A fresh audio mix for the preview player when only volumes changed.
    public static func audioMix(for composition: AVComposition, source: SourceMedia, volumes: TrackVolumes) -> AVAudioMix? {
        let compositionTracks = composition.tracks(withMediaType: .audio)
        guard compositionTracks.count == source.audioTracks.count, !compositionTracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = zip(compositionTracks, source.audioTracks).map { track, info in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(volumes[info.role].effectiveVolume), at: .zero)
            parameters.audioTimePitchAlgorithm = .spectral
            return parameters
        }
        return mix
    }
}
