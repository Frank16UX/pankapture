import AppCore
import AVFoundation
import Foundation

/// Adds a mixed audio track to a finished recording that has both system
/// audio and microphone (ADR-22).
///
/// The writer keeps the two sources on separate tracks (ADR-16) so the editor
/// can set their volumes independently. Most players (browsers, chat apps,
/// Quick Look) play only the **first** audio track, though, so the mic was
/// missing everywhere but in apps that mix every track. The rewritten file is:
///
/// 1. video (passthrough),
/// 2. **"Mix"**: system + mic mixed to stereo AAC, enabled, the default of the
///    audio alternate group,
/// 3. "System" and 4. "Microphone" (passthrough), disabled, in the same group.
///
/// The video editor skips the "Mix" track and reads the separate ones.
enum AudioMixdown {
    /// Rewrites `url` in place when it has two or more audio tracks. Returns
    /// `false` (leaving the file untouched) when there's nothing to mix.
    @discardableResult
    static func addMixedTrack(to url: URL) async throws -> Bool {
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("audioMixdown", id: signpostID)
        defer { Log.signposter.endInterval("audioMixdown", interval) }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count >= 2, let video = try await asset.loadTracks(withMediaType: .video).first else { return false }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-mix-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let job = try await MixdownJob(asset: asset, video: video, audio: audio, output: temporary)
        try await job.run()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        Log.recording.info("Added mixed audio track to \(url.lastPathComponent, privacy: .public)")
        return true
    }
}

/// One reader → writer pass for `AudioMixdown`.
///
/// `@unchecked Sendable`: AVAssetReader/Writer and their outputs/inputs aren't
/// `Sendable`, but after `init` they're only touched on `queue` (same pattern
/// as the editor's MP4 export job).
private final class MixdownJob: @unchecked Sendable {
    private struct Pass {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        var isDone = false
    }

    private let queue = DispatchQueue(label: "com.franklinperez.Pankapture.recording.mixdown", qos: .userInitiated)
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private var passes: [Pass] = []
    private var continuation: CheckedContinuation<Void, any Error>?

    init(asset: AVAsset, video: AVAssetTrack, audio: [AVAssetTrack], output: URL) async throws {
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // Video, untouched.
        let (videoFormats, transform) = try await video.load(.formatDescriptions, .preferredTransform)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormats.first)
        videoInput.transform = transform
        try add(AVAssetReaderTrackOutput(track: video, outputSettings: nil), videoInput)

        // The mix: first audio track, so players that pick one play this.
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let mixInput = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingWriter.aacSettings(sampleRate: 48_000, channels: 2))
        mixInput.metadata = [RecordingWriter.trackNameItem(RecordingWriter.TrackName.mix)]
        try add(mixOutput, mixInput)

        // The separate tracks, kept for the editor but off by default.
        var groupInputs = [mixInput]
        for track in audio {
            let (formats, metadata) = try await track.load(.formatDescriptions, .metadata)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
            input.metadata = metadata
            input.marksOutputTrackAsEnabled = false
            try add(AVAssetReaderTrackOutput(track: track, outputSettings: nil), input)
            groupInputs.append(input)
        }

        let group = AVAssetWriterInputGroup(inputs: groupInputs, defaultInput: mixInput)
        if writer.canAdd(group) { writer.add(group) }
    }

    private func add(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput) throws {
        output.alwaysCopiesSampleData = false
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(output), writer.canAdd(input) else {
            throw RecordingError.writerFailed("Mixdown track rejected")
        }
        reader.add(output)
        writer.add(input)
        passes.append(Pass(output: output, input: input))
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { self.start(continuation) }
        }
    }

    private func start(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
        guard reader.startReading() else {
            return complete(.failure(RecordingError.writerFailed(reader.error?.localizedDescription ?? "Reader failed")))
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            return complete(.failure(RecordingError.writerFailed(writer.error?.localizedDescription ?? "Writer failed")))
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
            guard let sample = pass.output.copyNextSampleBuffer() else {
                passes[index].isDone = true
                pass.input.markAsFinished()
                if passes.allSatisfy(\.isDone) { finish() }
                return
            }
            if !pass.input.append(sample) {
                reader.cancelReading()
                let message = writer.error?.localizedDescription ?? "Couldn't write a sample"
                writer.cancelWriting()
                complete(.failure(RecordingError.writerFailed(message)))
                return
            }
        }
    }

    private func finish() {
        if reader.status == .failed {
            writer.cancelWriting()
            return complete(.failure(RecordingError.writerFailed(reader.error?.localizedDescription ?? "Reading failed")))
        }
        writer.finishWriting { [self] in
            queue.async { [self] in
                if writer.status == .completed {
                    complete(.success(()))
                } else {
                    complete(.failure(RecordingError.writerFailed(writer.error?.localizedDescription ?? "Writing failed")))
                }
            }
        }
    }

    private func complete(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
