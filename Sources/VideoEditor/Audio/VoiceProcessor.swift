import AppCore
import AudioToolbox
import AVFoundation
import Foundation

/// Voice cleanup settings for a recording (PRD AU-1, AU-2).
public struct VoiceProcessing: Codable, Hashable, Sendable {
    public enum NoiseReduction: String, Codable, CaseIterable, Sendable, Identifiable {
        case off
        case min
        case medium
        case max

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .off: "Off"
            case .min: "Min"
            case .medium: "Medium"
            case .max: "Max"
            }
        }

        /// `AUSoundIsolation`'s wet/dry mix, percent.
        var mix: Float {
            switch self {
            case .off: 0
            case .min: 40
            case .medium: 70
            case .max: 100
            }
        }
    }

    public var noiseReduction: NoiseReduction
    /// Bring the voice to −16 LUFS, peaks at or below −1 dBFS.
    public var normalizes: Bool

    public init(noiseReduction: NoiseReduction = .off, normalizes: Bool = false) {
        self.noiseReduction = noiseReduction
        self.normalizes = normalizes
    }

    public var isActive: Bool { noiseReduction != .off || normalizes }

    /// Part of the cached file's name.
    var key: String { "\(noiseReduction.rawValue)\(normalizes ? "-normalized" : "")" }
}

/// Renders a cleaned-up copy of the microphone track, offline and faster
/// than real time (ADR-37):
/// 1. decode the track to 48 kHz mono;
/// 2. `AUSoundIsolation` at the preset's wet/dry mix, measuring loudness;
/// 3. gain to −16 LUFS through `AUPeakLimiter`, −1 dBFS ceiling, AAC.
/// The result is cached per setting; `CompositionBuilder` swaps it in for
/// the microphone track. System audio is never processed.
public enum VoiceProcessor {
    public static let targetLoudness = -16.0
    static let sampleRate = 48_000.0
    /// Ceiling after the limiter (−1 dBFS).
    static let ceiling: Float = 0.891

    /// A processed voice ready to use: its file and where it starts on the
    /// recording's timeline.
    public struct Output: Sendable, Equatable {
        public let url: URL
        public let startTime: Double
    }

    public enum Failure: LocalizedError {
        case noMicrophone
        case renderFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noMicrophone: "The recording has no microphone track to clean up."
            case .renderFailed(let detail): "The voice couldn't be processed: \(detail)"
            }
        }
    }

    static func cacheURL(for source: URL, settings: VoiceProcessing) -> URL {
        AppPaths.processedAudio.appendingPathComponent("\(source.lastPathComponent).\(settings.key).m4a")
    }

    /// Written next to the processed file: which recording it came from and
    /// where it starts.
    private struct Sidecar: Codable {
        var fingerprint: String
        var startTime: Double
    }

    static func sidecarURL(for cached: URL) -> URL {
        cached.appendingPathExtension("json")
    }

    /// Size and modification date of the recording, so a recording replaced
    /// under the same name is processed again.
    static func fingerprint(of source: URL) -> String {
        var url = source
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// The processed file for these settings, if it's already made from this recording.
    public static func cached(for source: URL, settings: VoiceProcessing) -> Output? {
        let url = cacheURL(for: source, settings: settings)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: sidecarURL(for: url)),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
              sidecar.fingerprint == fingerprint(of: source) else { return nil }
        return Output(url: url, startTime: sidecar.startTime)
    }

    /// The processed voice, from the cache or rendered now.
    public static func process(
        source: URL,
        microphoneTrackID: CMPersistentTrackID,
        settings: VoiceProcessing,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Output {
        if let cached = cached(for: source, settings: settings) { return cached }
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("voiceProcessing", id: signpostID)
        defer { Log.signposter.endInterval("voiceProcessing", interval) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Pankapture-Voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let decoded = work.appendingPathComponent("voice.caf")
        let start = try await decode(source: source, trackID: microphoneTrackID, to: decoded)
        progress(0.2)
        try Task.checkCancellation()

        let isolated = work.appendingPathComponent("isolated.caf")
        let loudness = try render(input: decoded, output: isolated, isolation: settings.noiseReduction, limiterGain: nil) {
            progress(0.2 + 0.5 * $0)
        }
        try Task.checkCancellation()

        let gain = settings.normalizes ? loudness.map { (targetLoudness - $0).clamped(to: -12...24) } : nil
        // Rendered aside and moved into place: the preview and an export may
        // process the same voice at once, and neither may see a partial file.
        let rendered = work.appendingPathComponent("voice.m4a")
        _ = try render(input: isolated, output: rendered, isolation: .off, limiterGain: gain) { progress(0.7 + 0.3 * $0) }
        let output = cacheURL(for: source, settings: settings)
        try AppPaths.ensure(AppPaths.processedAudio)
        try? FileManager.default.removeItem(at: sidecarURL(for: output))
        try? FileManager.default.removeItem(at: output)
        do {
            try FileManager.default.moveItem(at: rendered, to: output)
        } catch where FileManager.default.fileExists(atPath: output.path) {
            // The other run got there first with the same result.
        }
        let sidecar = Sidecar(fingerprint: fingerprint(of: source), startTime: start)
        try JSONEncoder().encode(sidecar).write(to: sidecarURL(for: output), options: .atomic)
        progress(1)
        Log.editor.info("Voice processed (\(settings.key, privacy: .public)), loudness \(loudness ?? .nan) LUFS")
        return Output(url: output, startTime: start)
    }

    /// Decodes one audio track to 48 kHz mono Float32; returns its start time.
    static func decode(source: URL, trackID: CMPersistentTrackID, to url: URL) async throws -> Double {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTrack(withTrackID: trackID) else { throw Failure.noMicrophone }
        let start = (try? await track.load(.timeRange).start.seconds) ?? 0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw Failure.renderFailed("unsupported audio") }
        reader.add(output)
        guard reader.startReading(), let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw Failure.renderFailed(reader.error?.localizedDescription ?? "can't read the track")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var first: Double?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            if first == nil { first = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: channel)
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
        }
        if reader.status == .failed { throw Failure.renderFailed(reader.error?.localizedDescription ?? "reading failed") }
        return first.flatMap { $0.isFinite ? $0 : nil } ?? start
    }

    /// One offline pass: optional voice isolation, optional limiter with
    /// pre-gain (and the −1 dBFS ceiling). Returns the output's loudness.
    /// The output is AAC when the file name ends in .m4a.
    @discardableResult
    static func render(
        input: URL,
        output: URL,
        isolation: VoiceProcessing.NoiseReduction,
        limiterGain: Double?,
        progress: (Double) -> Void
    ) throws -> Double? {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var last: AVAudioNode = player

        if isolation != .off {
            // A gentle high-pass first: rumble only confuses the isolation.
            let highPass = AVAudioUnitEQ(numberOfBands: 1)
            highPass.bands[0].filterType = .highPass
            highPass.bands[0].frequency = 80
            highPass.bands[0].bypass = false
            let isolator = AVAudioUnitEffect(audioComponentDescription: effect(kAudioUnitSubType_AUSoundIsolation))
            let parameters = isolator.auAudioUnit.parameterTree
            parameters?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value = isolation.mix
            if isolation == .max {
                parameters?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))?.value =
                    AUValue(kAUSoundIsolationSoundType_HighQualityVoice)
            }
            engine.attach(highPass)
            engine.attach(isolator)
            engine.connect(last, to: highPass, format: format)
            engine.connect(highPass, to: isolator, format: format)
            last = isolator
        }
        if let limiterGain {
            let limiter = AVAudioUnitEffect(audioComponentDescription: effect(kAudioUnitSubType_PeakLimiter))
            // The ceiling below lowers everything by about 1 dB; the pre-gain
            // makes up for it so the result lands on the target.
            let makeUp = -20 * log10(Double(ceiling))
            limiter.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kLimiterParam_PreGain))?.value =
                AUValue(limiterGain + makeUp)
            engine.attach(limiter)
            engine.connect(last, to: limiter, format: format)
            last = limiter
            engine.mainMixerNode.outputVolume = ceiling
        }
        engine.connect(last, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        defer { engine.stop() }
        player.scheduleFile(file, at: nil)
        player.play()

        let settings: [String: Any] = output.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 160_000]
            : format.settings
        let writer = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw Failure.renderFailed("no buffer")
        }
        var meter = LoudnessMeter(sampleRate: format.sampleRate)
        while engine.manualRenderingSampleTime < file.length {
            try Task.checkCancellation()
            let frames = min(AVAudioFrameCount(file.length - engine.manualRenderingSampleTime), buffer.frameCapacity)
            guard try engine.renderOffline(frames, to: buffer) == .success else { break }
            try writer.write(from: buffer)
            if let channel = buffer.floatChannelData?[0] {
                meter.process(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            progress(Double(engine.manualRenderingSampleTime) / Double(max(1, file.length)))
        }
        return meter.integratedLoudness
    }

    private static func effect(_ subtype: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype,
                                  componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }
}
