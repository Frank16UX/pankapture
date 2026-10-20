import AppCore
import AVFoundation
import CoreMedia
import VideoToolbox

/// Writes ScreenCaptureKit sample buffers into one MP4 (ADR-4).
///
/// An actor whose executor **is** its serial `DispatchQueue`. ScreenCaptureKit
/// delivers samples on that same queue, so the stream output appends
/// synchronously through `assumeIsolated` (no hop, no copy), while the main
/// actor drives pause/resume/finish with ordinary `await`s. All writer state is
/// therefore compiler-checked as isolated to one queue.
///
/// File layout:
/// - Fragmented MP4 (`movieFragmentInterval` = 2 s) so a crash loses at most ~2 s (REC-9).
/// - Track 1: video (H.264/HEVC, hardware).
/// - Audio tracks in a fixed order (REC-4): **System** first (if enabled), then
///   **Microphone** (if enabled). Each audio track also carries a track-level
///   title of exactly `"System"` or `"Microphone"` (`RecordingWriter.TrackName`),
///   written as `.commonIdentifierTitle`; in MP4 it's stored as ISO user data
///   `uiso/titl`. Read it with `track.load(.metadata)` and pick the item whose
///   `commonKey == .commonKeyTitle`.
/// - With the camera on, a second video track titled `"Camera"`, disabled so
///   players show only the screen (ADR-25).
public actor RecordingWriter {
    /// Track names written into each audio track's metadata. The video editor
    /// should identify tracks by these names, falling back to track order.
    public enum TrackName {
        public static let systemAudio = "System"
        public static let microphone = "Microphone"
        /// System + mic mixed for players that play one track (`AudioMixdown`).
        /// The editor ignores it.
        public static let mix = "Mix"
        /// The webcam video track (ADR-25).
        public static let camera = "Camera"
    }

    public struct Settings: Sendable {
        public var url: URL
        public var codec: RecordingConfiguration.Codec
        public var quality: RecordingConfiguration.Quality
        public var framesPerSecond: Int
        public var capturesSystemAudio: Bool
        public var capturesMicrophone: Bool
        /// Expected mic format if no mic sample has arrived by the first video frame.
        public var microphoneSampleRate: Double
        public var microphoneChannels: Int
        /// Pixel size of the camera frames; `nil` = no camera track.
        public var cameraSize: CGSize?

        public init(
            url: URL,
            codec: RecordingConfiguration.Codec,
            quality: RecordingConfiguration.Quality,
            framesPerSecond: Int,
            capturesSystemAudio: Bool,
            capturesMicrophone: Bool,
            microphoneSampleRate: Double = 48_000,
            microphoneChannels: Int = 1,
            cameraSize: CGSize? = nil
        ) {
            self.url = url
            self.codec = codec
            self.quality = quality
            self.framesPerSecond = framesPerSecond
            self.capturesSystemAudio = capturesSystemAudio
            self.capturesMicrophone = capturesMicrophone
            self.microphoneSampleRate = microphoneSampleRate
            self.microphoneChannels = microphoneChannels
            self.cameraSize = cameraSize
        }
    }

    public struct Summary: Sendable, Equatable {
        public var url: URL
        /// Seconds of output timeline.
        public var duration: Double
        public var videoSize: CGSize
        public var framesWritten: Int
        public var framesDropped: Int
    }

    public enum AudioSource: Sendable {
        case system
        case microphone
    }

    nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let settings: Settings
    private let levelHandler: @Sendable (Float) -> Void
    private let failureHandler: @Sendable (any Error) -> Void

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var cameraInput: AVAssetWriterInput?
    private var lastCameraTime: CMTime = .negativeInfinity

    private var timeline = PauseTimeline()
    /// Host time of the first written video frame; the output timeline starts here.
    private var sessionStart: CMTime?
    private var lastVideoTime: CMTime = .negativeInfinity
    private var lastAudioEnd: [AudioSource: CMTime] = [:]
    private var latestMicrophoneFormat: CMFormatDescription?
    private var isMicrophoneMuted = false
    private var isFinishing = false
    private var failure: (any Error)?
    private var lastLevelReport: CMTime = .negativeInfinity

    private(set) var videoSize: CGSize = .zero
    private(set) var framesWritten = 0
    private(set) var framesDropped = 0

    public init(
        settings: Settings,
        levelHandler: @escaping @Sendable (Float) -> Void = { _ in },
        failureHandler: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
        self.settings = settings
        self.levelHandler = levelHandler
        self.failureHandler = failureHandler
        self.queue = DispatchSerialQueue(label: "com.franklinperez.Pankapture.recording.writer", qos: .userInteractive)
    }

    public var hasStarted: Bool { sessionStart != nil }
    /// Host time of the first written frame (output time zero), once known.
    public var sessionStartTime: CMTime? { sessionStart }
    public var outputURL: URL { settings.url }

    // MARK: Samples (called on `queue`)

    /// Appends a screen frame. Frames before the first one are what start the
    /// session, so audio that arrives earlier is dropped.
    public func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing, failure == nil, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if writer == nil {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            do {
                try setUpWriter(width: width, height: height, startTime: hostTime)
            } catch {
                fail(error)
                return
            }
        }

        guard let videoInput, let outputTime = timeline.outputTime(for: hostTime) else { return }
        guard outputTime > lastVideoTime else { return }
        guard videoInput.isReadyForMoreMediaData else {
            framesDropped += 1
            Log.signposter.emitEvent("Dropped frame")
            return
        }
        guard let retimed = AudioBuffers.retimed(sampleBuffer, by: hostTime - outputTime) else { return }
        if videoInput.append(retimed) {
            lastVideoTime = outputTime
            framesWritten += 1
        } else {
            checkWriterStatus()
        }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer, from source: AudioSource) {
        guard !isFinishing, failure == nil, CMSampleBufferIsValid(sampleBuffer) else { return }

        if source == .microphone {
            latestMicrophoneFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
            reportLevel(sampleBuffer)
        }

        guard let sessionStart else { return }
        let input: AVAssetWriterInput? = source == .system ? systemInput : microphoneInput
        guard let input else { return }

        let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard hostTime >= sessionStart, let outputTime = timeline.outputTime(for: hostTime) else { return }

        // Drop a buffer that would overlap the previous one (only happens for
        // the first buffer after a resume); 5 ms tolerance for clock jitter.
        if let lastEnd = lastAudioEnd[source], outputTime < lastEnd - CMTime(value: 5, timescale: 1000) { return }
        guard input.isReadyForMoreMediaData else { return }

        var buffer = sampleBuffer
        if source == .microphone, isMicrophoneMuted {
            guard let silent = AudioBuffers.silencedCopy(of: sampleBuffer) else { return }
            buffer = silent
        }
        guard let retimed = AudioBuffers.retimed(buffer, by: hostTime - outputTime) else { return }
        if input.append(retimed) {
            let duration = CMSampleBufferGetDuration(retimed)
            lastAudioEnd[source] = duration.isValid ? outputTime + duration : outputTime
        } else {
            checkWriterStatus()
        }
    }

    /// Appends a camera frame (host-clock timestamps) to the camera track.
    /// Frames before the first screen frame are dropped.
    public func appendCamera(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing, failure == nil, let sessionStart, let cameraInput,
              CMSampleBufferIsValid(sampleBuffer) else { return }
        let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard hostTime >= sessionStart, let outputTime = timeline.outputTime(for: hostTime),
              outputTime > lastCameraTime, cameraInput.isReadyForMoreMediaData,
              let retimed = AudioBuffers.retimed(sampleBuffer, by: hostTime - outputTime) else { return }
        if cameraInput.append(retimed) {
            lastCameraTime = outputTime
        } else {
            checkWriterStatus()
        }
    }

    public var hasCameraTrack: Bool { cameraInput != nil }

    // MARK: Control (called from the main actor)

    public func pause(at hostTime: CMTime) { timeline.pause(at: hostTime) }
    public func resume(at hostTime: CMTime) { timeline.resume(at: hostTime) }
    public func setMicrophoneMuted(_ muted: Bool) {
        isMicrophoneMuted = muted
        if muted { levelHandler(0) }
    }

    /// Finalizes the file. `hostTime` is when the user pressed Stop; the movie
    /// ends there even if the screen was static (no new frames) for a while.
    public func finish(at hostTime: CMTime) async throws -> Summary {
        guard !isFinishing else { throw RecordingError.invalidState }
        isFinishing = true

        if let failure { throw failure }
        guard let writer, let sessionStart else {
            try? FileManager.default.removeItem(at: settings.url)
            throw RecordingError.noFramesCaptured
        }

        let state = Log.signposter.beginInterval("Finish writing")
        defer { Log.signposter.endInterval("Finish writing", state) }

        let stopTime = max(hostTime, sessionStart)
        let endTime = max(stopTime - timeline.pausedDuration(before: stopTime), lastVideoTime)
        videoInput?.markAsFinished()
        systemInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        cameraInput?.markAsFinished()
        writer.endSession(atSourceTime: endTime)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        let duration = (endTime - sessionStart).seconds
        Log.recording.info("Wrote \(self.framesWritten) frames (\(self.framesDropped) dropped), \(duration, format: .fixed(precision: 2)) s")
        return Summary(
            url: settings.url,
            duration: duration,
            videoSize: videoSize,
            framesWritten: framesWritten,
            framesDropped: framesDropped
        )
    }

    /// Stops writing and deletes the file.
    public func cancel() {
        isFinishing = true
        if let writer, writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: settings.url)
    }

    // MARK: Setup

    private func setUpWriter(width: Int, height: Int, startTime: CMTime) throws {
        let writer = try AVAssetWriter(outputURL: settings.url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(width: width, height: height))
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecordingError.writerFailed("Video track rejected") }
        writer.add(video)
        videoInput = video

        if settings.capturesSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(sampleRate: 48_000, channels: 2))
            input.expectsMediaDataInRealTime = true
            input.metadata = [Self.trackNameItem(TrackName.systemAudio)]
            if writer.canAdd(input) { writer.add(input); systemInput = input }
        }

        if settings.capturesMicrophone {
            var sampleRate = settings.microphoneSampleRate
            var channels = settings.microphoneChannels
            if let format = latestMicrophoneFormat,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                sampleRate = asbd.mSampleRate
                channels = Int(asbd.mChannelsPerFrame)
            }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.aacSettings(sampleRate: Self.aacSampleRate(for: sampleRate), channels: channels >= 2 ? 2 : 1),
                sourceFormatHint: latestMicrophoneFormat
            )
            input.expectsMediaDataInRealTime = true
            input.metadata = [Self.trackNameItem(TrackName.microphone)]
            if writer.canAdd(input) { writer.add(input); microphoneInput = input }
        }

        if let cameraSize = settings.cameraSize {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.cameraSettings(for: cameraSize))
            input.expectsMediaDataInRealTime = true
            input.marksOutputTrackAsEnabled = false
            input.metadata = [Self.trackNameItem(TrackName.camera)]
            if writer.canAdd(input) { writer.add(input); cameraInput = input }
        }

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: startTime)
        self.writer = writer
        sessionStart = startTime
        videoSize = CGSize(width: width, height: height)
        Log.recording.info("Writer started: \(width)×\(height) \(self.settings.codec.rawValue, privacy: .public) @ \(self.settings.framesPerSecond) fps")
    }

    private func videoSettings(width: Int, height: Int) -> [String: Any] {
        let bitRate = RecordingConfiguration.videoBitRate(
            width: width, height: height, fps: settings.framesPerSecond,
            codec: settings.codec, quality: settings.quality
        )
        let profile: String = settings.codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel as String
            : AVVideoProfileLevelH264HighAutoLevel
        return [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: profile,
            ] as [String: Any],
        ]
    }

    /// H.264 for the camera track, at most 1280 px wide (it's shown small).
    static func cameraSettings(for size: CGSize) -> [String: Any] {
        let scale = min(1, 1280 / max(size.width, 1))
        let width = max(2, Int((size.width * scale / 2).rounded()) * 2)
        let height = max(2, Int((size.height * scale / 2).rounded()) * 2)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }

    static func aacSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels >= 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels >= 2 ? 2 : 1,
            AVEncoderBitRateKey: channels >= 2 ? 160_000 : 96_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    /// AAC encodes 44.1 and 48 kHz everywhere; other device rates are resampled.
    static func aacSampleRate(for deviceRate: Double) -> Double {
        abs(deviceRate - 44_100) < 1 ? 44_100 : 48_000
    }

    static func trackNameItem(_ name: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = name as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    // MARK: Status

    private func reportLevel(_ sampleBuffer: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // ~15 Hz is plenty for a meter and keeps main-actor hops cheap.
        guard time - lastLevelReport >= CMTime(value: 1, timescale: 15) else { return }
        lastLevelReport = time
        levelHandler(isMicrophoneMuted ? 0 : AudioBuffers.meterValue(forPeak: AudioBuffers.peakLevel(of: sampleBuffer)))
    }

    private func checkWriterStatus() {
        guard let writer, writer.status == .failed else { return }
        fail(RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown error"))
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        Log.recording.error("Writer failed: \(error.localizedDescription, privacy: .public)")
        failureHandler(error)
    }
}
