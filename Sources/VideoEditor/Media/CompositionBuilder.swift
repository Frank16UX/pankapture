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
        /// The preview separates the camera background faster and coarser.
        public var cameraMatteQuality: CameraMatte.Quality

        public init(
            shortSideCap: Double? = nil,
            shortSide: Double? = nil,
            scale: Double? = nil,
            width: Int? = nil,
            frameRate: Int = 30,
            zoomEnabled: Bool = true,
            forceVideoComposition: Bool = true,
            includeMutedAudio: Bool = false,
            cameraMatteQuality: CameraMatte.Quality = .balanced
        ) {
            self.shortSideCap = shortSideCap
            self.shortSide = shortSide
            self.scale = scale
            self.width = width
            self.frameRate = frameRate
            self.zoomEnabled = zoomEnabled
            self.forceVideoComposition = forceVideoComposition
            self.includeMutedAudio = includeMutedAudio
            self.cameraMatteQuality = cameraMatteQuality
        }

        public static func preview(frameRate: Double, zoomEnabled: Bool = true) -> Options {
            // Cap the preview canvas: the window is never larger than this, and
            // the GPU work per frame drops a lot for Retina-sized recordings.
            Options(
                shortSideCap: 1080,
                frameRate: Int(frameRate.rounded()).clamped(to: 24...60),
                zoomEnabled: zoomEnabled,
                forceVideoComposition: false,
                includeMutedAudio: true,
                cameraMatteQuality: .fast
            )
        }
    }

    public static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    public static func cmRange(_ range: TimeRange) -> CMTimeRange {
        CMTimeRange(start: cmTime(range.start), end: cmTime(range.end))
    }

    /// - Parameter voiceProgress: 0…1 while the cleaned-up voice is made
    ///   (only when it isn't cached yet).
    public static func build(
        source: SourceMedia,
        project: VideoEditProject,
        options: Options,
        voiceProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> sending EditComposition {
        var tracks = try await source.loadTracks()
        // Exports get the cleaned-up voice, processing it now if needed.
        if let voice = project.voice, voice.isActive, let microphone = source.audioTracks.first(where: { $0.role == .microphone }) {
            let output = try await VoiceProcessor.process(source: source.url, microphoneTrackID: microphone.trackID,
                                                          settings: voice, progress: voiceProgress)
            tracks.processedVoice = try await ProcessedVoice.load(output)
        }
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
        // `shift`: where the inserted track's time 0 sits on the source timeline
        // (the processed voice file starts at the microphone track's start).
        var audioTracks: [(composition: AVMutableCompositionTrack, source: AudioTrackInfo, track: AVAssetTrack, volume: Double, shift: Double)] = []
        for info in source.audioTracks {
            guard var sourceTrack = tracks.audio[info.trackID] else { continue }
            var shift = 0.0
            if info.role == .microphone, project.voice?.isActive == true, let voice = tracks.processedVoice {
                sourceTrack = voice.track
                shift = voice.startTime
            }
            let volume = project.trackVolumes[info.role].effectiveVolume
            guard options.includeMutedAudio || volume > 0 else { continue }
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            audioTracks.append((track, info, sourceTrack, volume, shift))
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
               var range = segment.source.intersection(info.timeRange)?.intersection(TimeRange(start: 0, end: source.duration)) {
                // A camera that started after the screen shows its first frame
                // until then, rather than popping in late (CAM-7).
                if range.start < info.firstFrameTime, range.end > info.firstFrameTime {
                    let at = pieceStart + cmTime(range.start) - cmTime(segment.source.start)
                    let firstFrame = CMTimeRange(start: cmTime(info.firstFrameTime), duration: CMTime(value: 1, timescale: 600))
                    try cameraTrack.insertTimeRange(firstFrame, of: camera, at: at)
                    cameraTrack.scaleTimeRange(CMTimeRange(start: at, duration: firstFrame.duration),
                                               toDuration: cmTime(info.firstFrameTime) - cmTime(range.start))
                    range.start = info.firstFrameTime
                }
                let offset = cmTime(range.start) - cmTime(segment.source.start)
                try cameraTrack.insertTimeRange(cmRange(range), of: camera, at: pieceStart + offset)
            }
            for audio in audioTracks {
                // Never past the last video frame (see `SourceMedia.duration`).
                guard let range = segment.source.intersection(audio.source.timeRange)?
                    .intersection(TimeRange(start: 0, end: source.duration)) else { continue }
                var offset = cmTime(range.start) - cmTime(segment.source.start)
                var shifted = TimeRange(start: range.start - audio.shift, end: range.end - audio.shift)
                // A file starting after the track's nominal start has nothing before its first sample.
                if shifted.start < 0 {
                    offset = offset + cmTime(-shifted.start)
                    shifted.start = 0
                }
                guard shifted.end > shifted.start else { continue }
                try audio.composition.insertTimeRange(cmRange(shifted), of: audio.track, at: pieceStart + offset)
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
            cameraOrientation: source.camera?.orientation ?? .up,
            cameraMatteQuality: options.cameraMatteQuality
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
            let joins = joinTimes(timeline)
            mix.inputParameters = audioTracks.map { audio in
                mixParameters(for: audio.composition, volume: audio.volume, joins: joins)
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
    public static func audioMix(for composition: AVComposition, source: SourceMedia, volumes: TrackVolumes, timeline: Timeline) -> AVAudioMix? {
        let compositionTracks = composition.tracks(withMediaType: .audio)
        guard compositionTracks.count == source.audioTracks.count, !compositionTracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        let joins = joinTimes(timeline)
        mix.inputParameters = zip(compositionTracks, source.audioTracks).map { track, info in
            mixParameters(for: track, volume: volumes[info.role].effectiveVolume, joins: joins)
        }
        return mix
    }

    /// Length of the fade out and back in at each join (AE-9): long enough
    /// that a cut doesn't click, too short to hear as a dip.
    public static let joinFade = 0.008

    /// Output times where removed footage was spliced out: consecutive
    /// segments that aren't contiguous in the source. Speed changes alone
    /// don't make a join.
    public static func joinTimes(_ timeline: Timeline) -> [Double] {
        zip(timeline.segments, timeline.segments.dropFirst()).compactMap { previous, next in
            abs(previous.source.end - next.source.start) > 1e-6 ? next.outputStart : nil
        }
    }

    /// Constant volume with a short fade out and in around every join.
    static func mixParameters(for track: AVAssetTrack, volume: Double, joins: [Double]) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let level = Float(volume)
        parameters.setVolume(level, at: .zero)
        parameters.audioTimePitchAlgorithm = .spectral
        guard level > 0 else { return parameters }
        var lastEnd = 0.0
        for join in joins.sorted() {
            // Joins closer together than two fades keep the previous ramp.
            let fadeStart = max(lastEnd, join - joinFade)
            guard join - fadeStart > 0.001 else { continue }
            parameters.setVolumeRamp(fromStartVolume: level, toEndVolume: 0, timeRange: CMTimeRange(start: cmTime(fadeStart), end: cmTime(join)))
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: level, timeRange: CMTimeRange(start: cmTime(join), end: cmTime(join + joinFade)))
            lastEnd = join + joinFade
        }
        return parameters
    }
}
