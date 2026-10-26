import AppCore
import AVFoundation
import Foundation

/// The recording's microphone track, decoded once for auto-edit: a 16 kHz
/// mono file for the transcriber and the loudness envelope for pauses.
public struct ExtractedAudio: Sendable {
    /// 16 kHz mono Float32 CAF.
    public let url: URL
    /// Source time of the first sample (the track's start in the movie).
    public let startTime: Double
    public let duration: Double
    public let envelope: LoudnessEnvelope
    /// Which track it came from ("Microphone", or the only one there is).
    public let trackLabel: String
}

public enum MicrophoneAudio {
    public static let sampleRate = 16_000.0

    public enum Failure: LocalizedError {
        case noAudio
        case noMicrophone
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudio: "The recording has no audio to analyze."
            case .noMicrophone: "The recording has no microphone track: it was made with the microphone off."
            case .readFailed(let detail): "The recording's audio couldn't be read: \(detail)"
            }
        }
    }

    /// Decodes the microphone track of `movieURL` to `outputURL`. Prefers the
    /// track titled "Microphone" (REC-4); a file with one audio track uses it.
    /// Gaps in the track are filled with silence so times stay aligned with
    /// the movie. Runs synchronously on the caller's executor; call it from a
    /// task that may block.
    public static func extract(from movieURL: URL, to outputURL: URL) async throws -> ExtractedAudio {
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("extractMicrophone", id: signpostID)
        defer { Log.signposter.endInterval("extractMicrophone", interval) }

        let asset = AVURLAsset(url: movieURL)
        let (track, label) = try await microphoneTrack(in: asset)
        let trackStart = (try? await track.load(.timeRange).start.seconds) ?? 0

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.readFailed("unsupported audio format") }
        reader.add(output)
        guard reader.startReading() else { throw Failure.readFailed(reader.error?.localizedDescription ?? "unknown") }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw Failure.readFailed("no audio format")
        }
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        var writer = EnvelopeWriter(file: file, format: format)
        var startTime: Double?
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let presentation = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if startTime == nil { startTime = presentation.isFinite ? presentation : trackStart }
            // Fill a gap (an empty edit) with silence so later samples keep their time.
            if presentation.isFinite, let startTime {
                let expected = startTime + Double(writer.sampleCount) / sampleRate
                let gap = Int(((presentation - expected) * sampleRate).rounded())
                if gap > Int(sampleRate * 0.01) { try writer.append(silence: gap) }
            }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if samples.count < count { samples = Array(repeating: 0, count: count) }
            _ = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: raw.baseAddress!)
            }
            try writer.append(samples[0..<count])
        }
        if reader.status == .failed { throw Failure.readFailed(reader.error?.localizedDescription ?? "unknown") }
        try writer.finish()
        guard writer.sampleCount > 0 else { throw Failure.noAudio }

        let start = startTime ?? trackStart
        return ExtractedAudio(
            url: outputURL,
            startTime: start,
            duration: Double(writer.sampleCount) / sampleRate,
            envelope: LoudnessEnvelope(startTime: start, levels: writer.levels),
            trackLabel: label
        )
    }

    /// The audio track auto-edit listens to: the microphone, else the only track.
    static func microphoneTrack(in asset: AVAsset) async throws -> (AVAssetTrack, String) {
        var tracks: [AVAssetTrack] = []
        var names: [String?] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let name = await RecordingTracks.name(of: track)
            if name?.lowercased() == RecordingTracks.mixName { continue }
            tracks.append(track)
            names.append(name)
        }
        guard !tracks.isEmpty else { throw Failure.noAudio }
        let roles = RecordingTracks.resolveRoles(names: names)
        if let index = roles.firstIndex(where: { $0.role == .microphone }), names[index] != nil || tracks.count > 1 {
            return (tracks[index], roles[index].label)
        }
        // A recording with only system audio has nothing to transcribe; an
        // imported movie with one unnamed track is presumably a voice.
        if names[0] != nil, roles[0].role == .system { throw Failure.noMicrophone }
        return (tracks[0], roles[0].label)
    }

    /// Writes samples to the file in chunks and measures RMS per 10 ms frame.
    private struct EnvelopeWriter {
        let file: AVAudioFile
        let format: AVAudioFormat
        let frameLength = Int(MicrophoneAudio.sampleRate * LoudnessEnvelope.frameDuration)
        private(set) var sampleCount = 0
        private(set) var levels: [Float] = []
        private var sumOfSquares: Float = 0
        private var inFrame = 0
        private var pending: [Float] = []

        init(file: AVAudioFile, format: AVAudioFormat) {
            self.file = file
            self.format = format
            pending.reserveCapacity(Int(MicrophoneAudio.sampleRate))
        }

        mutating func append(_ samples: ArraySlice<Float>) throws {
            for sample in samples {
                sumOfSquares += sample * sample
                inFrame += 1
                if inFrame == frameLength { closeFrame() }
            }
            pending.append(contentsOf: samples)
            sampleCount += samples.count
            if pending.count >= Int(MicrophoneAudio.sampleRate) { try flush() }
        }

        mutating func append(silence count: Int) throws {
            try append(ArraySlice(repeatElement(Float(0), count: count)))
        }

        mutating func finish() throws {
            if inFrame > 0 { closeFrame() }
            try flush()
        }

        private mutating func closeFrame() {
            levels.append(LoudnessEnvelope.dBFS(rms: (sumOfSquares / Float(max(1, inFrame))).squareRoot()))
            sumOfSquares = 0
            inFrame = 0
        }

        private mutating func flush() throws {
            guard !pending.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pending.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            pending.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: pending.count) }
            buffer.frameLength = AVAudioFrameCount(pending.count)
            try file.write(from: buffer)
            pending.removeAll(keepingCapacity: true)
        }
    }
}
