import AppCore
import AVFoundation
import Foundation

/// What an export produced. The app can record it in the capture history.
public struct VideoExportResult: Sendable, Equatable {
    public var url: URL
    public var format: ExportFormat
    public var sourceURL: URL
    /// Seconds.
    public var duration: Double
    public var pixelSize: CGSize
    public var byteCount: Int64
}

/// MP4 export (VE-8, VE-9) via `AVAssetReader` → `AVAssetWriter`, which (unlike
/// `AVAssetExportSession`) lets us set the H.264 bitrate for the quality
/// presets, so the size estimate shown beforehand is meaningful.
public enum VideoExporter {
    /// Exports `project` to `url` (overwritten). `progress` (0…1) is called on
    /// an arbitrary queue. Cancelling the calling task cancels the export and
    /// removes the partial file.
    public static func exportMP4(
        source: SourceMedia,
        project: VideoEditProject,
        settings: ExportSettings,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VideoExportResult {
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("exportMP4", id: signpostID)
        defer { Log.signposter.endInterval("exportMP4", interval) }

        let fps = settings.frameRate.resolve(sourceFrameRate: source.frameRate)
        // Loads the tracks and the background, and the cleaned-up voice if the project has one.
        let edit = try await CompositionBuilder.build(
            source: source,
            project: project,
            options: .init(shortSide: settings.resolution.shortSide, frameRate: fps)
        )
        let bitrate = ExportEstimator.videoBitrate(renderSize: edit.plan.renderSize, fps: fps, quality: settings.quality)

        try? FileManager.default.removeItem(at: url)
        let job = try MP4WriterJob(edit: edit, url: url, fps: fps, bitrate: bitrate, progress: progress)
        Log.editor.info("MP4 export started: \(Int(edit.plan.renderSize.width))×\(Int(edit.plan.renderSize.height)) @ \(fps) fps, \(Int(bitrate / 1000)) kbps")
        do {
            try await job.run()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        Log.editor.info("MP4 export finished: \(bytes) bytes")
        return VideoExportResult(
            url: url,
            format: .mp4,
            sourceURL: source.url,
            duration: edit.duration,
            pixelSize: edit.plan.renderSize,
            byteCount: bytes
        )
    }
}

/// One reader → writer pass.
///
/// `@unchecked Sendable`: AVAssetReader/Writer and their outputs/inputs aren't
/// `Sendable`, but every access after `init` happens on `queue` (the
/// `requestMediaDataWhenReady` callbacks, `start`, `cancel`, `finish`), so
/// the mutable state is confined to one serial queue.
final class MP4WriterJob: @unchecked Sendable {
    private struct Pass {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
        var isDone = false
    }

    private let queue = DispatchQueue(label: "com.franklinperez.Pankapture.export.mp4", qos: .userInitiated)
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private var passes: [Pass]
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private var isCancelled = false
    private var isFinishing = false

    init(edit: EditComposition, url: URL, fps: Int, bitrate: Double, progress: @escaping @Sendable (Double) -> Void) throws {
        self.duration = max(edit.duration, 0.001)
        self.progress = progress
        reader = try AVAssetReader(asset: edit.composition)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // Video
        let videoTracks = edit.composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = edit.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        let size = edit.plan.renderSize
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw VideoEditorError.exportFailed("Video settings not supported")
        }
        reader.add(videoOutput)
        writer.add(videoInput)
        passes = [Pass(output: videoOutput, input: videoInput, isVideo: true)]

        // Audio: every included track mixed down to one stereo AAC track (REC-4).
        let audioTracks = edit.composition.tracks(withMediaType: .audio)
        if edit.hasAudibleAudio, !audioTracks.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            audioOutput.audioMix = edit.audioMix
            audioOutput.audioTimePitchAlgorithm = .spectral
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: Int(ExportEstimator.audioBitrate),
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                passes.append(Pass(output: audioOutput, input: audioInput, isVideo: false))
            }
        }
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            queue.async { self.cancel() }
        }
    }

    private func start(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
        guard !isCancelled else { return complete(.failure(CancellationError())) }
        guard reader.startReading() else {
            return complete(.failure(VideoEditorError.exportFailed(reader.error?.localizedDescription ?? "Reader failed")))
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            return complete(.failure(VideoEditorError.exportFailed(writer.error?.localizedDescription ?? "Writer failed")))
        }
        writer.startSession(atSourceTime: .zero)
        for index in passes.indices {
            passes[index].input.requestMediaDataWhenReady(on: queue) { [self] in pump(index) }
        }
    }

    private func pump(_ index: Int) {
        guard !passes[index].isDone, continuation != nil else { return }
        let pass = passes[index]
        while pass.input.isReadyForMoreMediaData {
            if isCancelled { return }
            guard let sample = pass.output.copyNextSampleBuffer() else {
                finishPass(index)
                return
            }
            if pass.isVideo {
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if time.isFinite { progress(min(1, max(0, time / duration))) }
            }
            if !pass.input.append(sample) {
                reader.cancelReading()
                let message = writer.error?.localizedDescription ?? "Couldn't write a sample"
                writer.cancelWriting()
                complete(.failure(VideoEditorError.exportFailed(message)))
                return
            }
        }
    }

    private func finishPass(_ index: Int) {
        passes[index].isDone = true
        passes[index].input.markAsFinished()
        guard passes.allSatisfy(\.isDone) else { return }

        if reader.status == .failed {
            let message = reader.error?.localizedDescription ?? "Reading failed"
            writer.cancelWriting()
            complete(.failure(VideoEditorError.exportFailed(message)))
            return
        }
        isFinishing = true
        writer.finishWriting { [self] in
            queue.async { [self] in
                if writer.status == .completed {
                    progress(1)
                    complete(.success(()))
                } else {
                    complete(.failure(VideoEditorError.exportFailed(writer.error?.localizedDescription ?? "Writing failed")))
                }
            }
        }
    }

    private func cancel() {
        // Once every sample is in, let `finishWriting` settle; cancelling the
        // writer mid-finish races its completion and the file cleanup.
        guard !isCancelled, !isFinishing else { return }
        isCancelled = true
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// The shareable copy of a recording whose webcam is its own track (ADR-25):
/// the webcam drawn where the bubble was, nothing else changed.
public enum CameraComposite {
    /// Exports `sourceURL` to `destination` at the recording's frame rate,
    /// high quality. `resolution` sizes it down (never up): the encode time
    /// scales with the pixel count, so smaller copies are ready sooner.
    public static func export(
        recordingAt sourceURL: URL,
        to destination: URL,
        resolution: ExportResolution = .original,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VideoExportResult {
        let source = try await SourceMedia.load(url: sourceURL)
        let project = VideoEditProject.initial(for: source)
        let sourceShortSide = min(source.size.width, source.size.height)
        let size = resolution.shortSide.map { $0 < sourceShortSide } == true ? resolution : .original
        let settings = ExportSettings(format: .mp4, resolution: size, quality: .high, frameRate: .original)
        return try await VideoExporter.exportMP4(source: source, project: project, settings: settings, to: destination, progress: progress)
    }
}
