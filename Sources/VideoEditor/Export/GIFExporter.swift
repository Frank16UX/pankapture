import AppCore
import AVFoundation
import Foundation

/// Animated GIF export (VE-8). Frames come from the same composition as the
/// preview and MP4 (trim, cuts, speed, zoom, background), are decoded in order
/// with `AVAssetReader`, and are streamed to disk by `StreamingGIFWriter`
/// (ImageIO per-frame palettes, constant memory), looping forever by default.
///
/// Public so the app can also turn direct-GIF recordings (REC-14) into GIFs:
/// record to a temporary MP4, then call `convert(videoAt:to:options:)`.
public enum GIFExporter {
    /// Exports an edited project.
    public static func export(
        source: SourceMedia,
        project: VideoEditProject,
        options: GIFOptions,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VideoExportResult {
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("exportGIF", id: signpostID)
        defer { Log.signposter.endInterval("exportGIF", interval) }

        let fps = options.fps.clamped(to: 1...50)
        let tracks = try await source.loadTracks()
        let background = await BackgroundVideo.load(for: project)
        let edit = try CompositionBuilder.build(
            source: source,
            tracks: tracks,
            project: project,
            options: .init(width: options.width, frameRate: fps, includeMutedAudio: false),
            background: background
        )
        try? FileManager.default.removeItem(at: url)
        let job = try GIFWriterJob(edit: edit, url: url, fps: fps, loopCount: options.loopCount, progress: progress)
        let frames: Int
        do {
            frames = try await job.run()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        Log.editor.info("GIF export finished: \(frames) frames, \(bytes) bytes")
        return VideoExportResult(
            url: url,
            format: .gif,
            sourceURL: source.url,
            duration: edit.duration,
            pixelSize: edit.plan.renderSize,
            byteCount: bytes
        )
    }

    /// Converts a whole movie (no edits) to a GIF. `outputURL` defaults to a
    /// uniquely named file in the user's save folder.
    public static func convert(
        videoAt videoURL: URL,
        to outputURL: URL? = nil,
        options: GIFOptions = GIFOptions(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VideoExportResult {
        let source = try await SourceMedia.load(url: videoURL)
        let project = VideoEditProject.initial(for: source)
        let url = try outputURL ?? ExportDestination.newFileURL(for: .gif)
        return try await export(source: source, project: project, options: options, to: url, progress: progress)
    }
}

/// Reads composed frames and appends them to a GIF.
///
/// `@unchecked Sendable`: the reader, its output, and the GIF writer aren't
/// `Sendable`, but after `init` they're only touched inside the single
/// `queue.async` block in `run()` (cancellation only flips a `Mutex`).
final class GIFWriterJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.franklinperez.Pankapture.export.gif", qos: .userInitiated)
    private let reader: AVAssetReader
    private let output: AVAssetReaderVideoCompositionOutput
    private let writer: StreamingGIFWriter
    private let frameDelay: Double
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private let cancelled = CancellationFlag()

    init(edit: EditComposition, url: URL, fps: Int, loopCount: Int, progress: @escaping @Sendable (Double) -> Void) throws {
        self.duration = max(edit.duration, 0.001)
        self.progress = progress
        self.frameDelay = 1 / Double(fps)
        reader = try AVAssetReader(asset: edit.composition)
        output = AVAssetReaderVideoCompositionOutput(
            videoTracks: edit.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = edit.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoEditorError.exportFailed("GIF reader setup failed") }
        reader.add(output)
        do {
            writer = try StreamingGIFWriter(
                url: url,
                width: Int(edit.plan.renderSize.width),
                height: Int(edit.plan.renderSize.height),
                loopCount: loopCount
            )
        } catch {
            throw VideoEditorError.exportFailed("Couldn't create the GIF file")
        }
    }

    /// Returns the number of frames written.
    func run() async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
                queue.async { continuation.resume(with: Result { try self.encode() }) }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private func encode() throws -> Int {
        guard reader.startReading() else {
            writer.abandon()
            throw VideoEditorError.exportFailed(reader.error?.localizedDescription ?? "Reader failed")
        }
        do {
            while let sample = output.copyNextSampleBuffer() {
                if cancelled.isSet { throw CancellationError() }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue } // no picture (e.g. marker)
                guard let image = Self.makeImage(buffer) else {
                    throw VideoEditorError.exportFailed("Couldn't read a video frame")
                }
                try autoreleasepool { try writer.append(image, duration: frameDelay) }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if time.isFinite { progress(min(0.99, time / duration)) }
            }
            if reader.status == .failed {
                throw VideoEditorError.exportFailed(reader.error?.localizedDescription ?? "Reading failed")
            }
            if cancelled.isSet { throw CancellationError() }
            guard writer.frameCount > 0 else { throw VideoEditorError.exportFailed("No frames to write") }
            try writer.finish()
        } catch {
            reader.cancelReading()
            writer.abandon()
            if error is CancellationError || error is VideoEditorError { throw error }
            throw VideoEditorError.exportFailed("Couldn't write the GIF")
        }
        progress(1)
        return writer.frameCount
    }

    /// Copies the frame into its own bitmap so the reader's buffer pool can
    /// recycle the pixel buffer right away.
    private static func makeImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
