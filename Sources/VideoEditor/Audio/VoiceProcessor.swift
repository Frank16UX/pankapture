import Accelerate
import AppCore
import AudioToolbox
import AVFoundation
import CryptoKit
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
/// than real time (ADR-38):
/// 1. decode the track to 48 kHz mono;
/// 2. `AUSoundIsolation` at the preset's wet/dry mix, measuring loudness and
///    the delay the isolation adds;
/// 3. drop that delay, gain to −16 LUFS through `AUPeakLimiter` (−1 dBFS
///    ceiling), AAC.
/// The result is cached per setting; `CompositionBuilder` swaps it in for
/// the microphone track. System audio is never processed.
public enum VoiceProcessor {
    public static let targetLoudness = -16.0
    static let sampleRate = 48_000.0
    /// Ceiling after the limiter (−1 dBFS).
    static let ceiling: Float = 0.891
    /// Bumped whenever the processing changes, so older cached files are made again.
    static let pipelineVersion = 2
    /// Voice isolation delays its output without reporting it, so the delay
    /// is measured on each render. These are the fallbacks for audio with too
    /// little voice to measure, measured at 48 kHz.
    static func typicalIsolationDelay(_ preset: VoiceProcessing.NoiseReduction) -> Int {
        preset == .max ? 4_439 : 2_705
    }
    /// The longest delay looked for (0.25 s).
    static let maximumIsolationDelay = 12_000

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

    // MARK: Cache

    /// `<video>-<path hash>.<setting>.m4a`: the hash keeps recordings with
    /// the same name in different folders apart.
    static func cacheURL(for source: URL, settings: VoiceProcessing) -> URL {
        AppPaths.processedAudio.appendingPathComponent("\(cacheStem(for: source)).\(settings.key).m4a")
    }

    private static func cacheStem(for source: URL) -> String {
        let digest = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8))
        return source.lastPathComponent + "-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Written next to the processed file: which recording and pipeline it
    /// came from, and where it starts.
    private struct Sidecar: Codable {
        var version: Int
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
              sidecar.version == pipelineVersion,
              sidecar.fingerprint == fingerprint(of: source) else { return nil }
        return Output(url: url, startTime: sidecar.startTime)
    }

    /// Keeps the two most recently made settings of a recording; the rest
    /// are made again if they're chosen again.
    static func pruneVariants(of source: URL, keeping kept: URL) {
        let prefix = cacheStem(for: source)
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: AppPaths.processedAudio, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let variants = files
            .filter { $0.lastPathComponent.hasPrefix(prefix + ".") && $0.pathExtension == "m4a" && $0 != kept }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first > second
            }
        for old in variants.dropFirst() {
            try? manager.removeItem(at: sidecarURL(for: old))
            try? manager.removeItem(at: old)
        }
    }

    // MARK: Processing

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

        let fingerprint = fingerprint(of: source)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Pankapture-Voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let rendered = try await render(source: source, microphoneTrackID: microphoneTrackID, settings: settings, in: work, progress: progress)

        // Moved into place whole: the preview and an export may process the
        // same voice at once, and neither may see a partial file.
        let output = cacheURL(for: source, settings: settings)
        let manager = FileManager.default
        try AppPaths.ensure(AppPaths.processedAudio)
        try? manager.removeItem(at: sidecarURL(for: output))
        if manager.fileExists(atPath: output.path) {
            _ = try manager.replaceItemAt(output, withItemAt: rendered.url)
        } else {
            do {
                try manager.moveItem(at: rendered.url, to: output)
            } catch where manager.fileExists(atPath: output.path) {
                // The other run got there first with the same result.
            }
        }
        let sidecar = Sidecar(version: pipelineVersion, fingerprint: fingerprint, startTime: rendered.startTime)
        try JSONEncoder().encode(sidecar).write(to: sidecarURL(for: output), options: .atomic)
        pruneVariants(of: source, keeping: output)
        progress(1)
        Log.editor.info("Voice processed (\(settings.key, privacy: .public)), loudness \(rendered.loudness ?? .nan) LUFS, isolation delay \(rendered.isolationDelay) samples")
        return Output(url: output, startTime: rendered.startTime)
    }

    struct Rendered {
        var url: URL
        var startTime: Double
        /// Loudness before the gain, LUFS.
        var loudness: Double?
        var isolationDelay: Int
    }

    /// The whole pipeline into `directory` (`voice.m4a`), without the cache.
    static func render(
        source: URL,
        microphoneTrackID: CMPersistentTrackID,
        settings: VoiceProcessing,
        in directory: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Rendered {
        let decoded = directory.appendingPathComponent("voice.caf")
        let start = try await decode(source: source, trackID: microphoneTrackID, to: decoded)
        let length = try AVAudioFile(forReading: decoded).length
        progress(0.2)
        try Task.checkCancellation()

        let isolates = settings.noiseReduction != .off
        let isolated = directory.appendingPathComponent("isolated.caf")
        let loudness = try render(input: decoded, output: isolated, isolation: settings.noiseReduction, limiterGain: nil,
                                  extraFrames: isolates ? AVAudioFramePosition(maximumIsolationDelay) : 0) {
            progress(0.2 + 0.5 * $0)
        }
        try Task.checkCancellation()
        let delay = isolates
            ? (try measureDelay(original: decoded, processed: isolated, maximum: maximumIsolationDelay) ?? typicalIsolationDelay(settings.noiseReduction))
            : 0

        let gain = settings.normalizes ? loudness.map { (targetLoudness - $0).clamped(to: -12...24) } : nil
        let output = directory.appendingPathComponent("voice.m4a")
        try render(input: isolated, output: output, isolation: .off, limiterGain: gain,
                   startFrame: AVAudioFramePosition(delay), frameCount: length) { progress(0.7 + 0.3 * $0) }
        return Rendered(url: output, startTime: start, loudness: loudness, isolationDelay: delay)
    }

    /// Decodes one audio track to 48 kHz mono Float32; returns where its
    /// first sample sits on the recording's timeline. The read blocks on
    /// AVFoundation, so it runs on its own queue rather than the cooperative pool.
    static func decode(source: URL, trackID: CMPersistentTrackID, to url: URL) async throws -> Double {
        try await withBlockingExecutor(label: "com.franklinperez.Pankapture.audio.decode") {
            try await read(source: source, trackID: trackID, to: url)
        }
    }

    private static func read(source: URL, trackID: CMPersistentTrackID, to url: URL) async throws -> Double {
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
    /// - Parameters:
    ///   - startFrame, frameCount: the part of the input to use (all of it by default).
    ///   - extraFrames: silence rendered past the end, so a delayed effect's tail comes out.
    @discardableResult
    static func render(
        input: URL,
        output: URL,
        isolation: VoiceProcessing.NoiseReduction,
        limiterGain: Double?,
        startFrame: AVAudioFramePosition = 0,
        frameCount: AVAudioFramePosition? = nil,
        extraFrames: AVAudioFramePosition = 0,
        progress: (Double) -> Void
    ) throws -> Double? {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let start = min(max(0, startFrame), file.length)
        let available = file.length - start
        let count = min(frameCount ?? available, available)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var last: AVAudioNode = player
        // The limiter reports its look-ahead; that many leading frames are dropped.
        var latencyFrames: AVAudioFramePosition = 0

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
            latencyFrames = AVAudioFramePosition((limiter.auAudioUnit.latency * format.sampleRate).rounded())
        }
        engine.connect(last, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        defer { engine.stop() }
        if count > 0 {
            player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(count), at: nil)
        }
        player.play()

        let settings: [String: Any] = output.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 160_000]
            : format.settings
        let writer = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount),
              let trimmed = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw Failure.renderFailed("no buffer")
        }
        var meter = LoudnessMeter(sampleRate: format.sampleRate)
        let total = count + extraFrames + latencyFrames
        var rendered: AVAudioFramePosition = 0
        var toDrop = latencyFrames
        var retries = 0
        var reported = 0.0
        while rendered < total {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), total - rendered))
            switch try engine.renderOffline(frames, to: buffer) {
            case .success:
                retries = 0
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                // Not ready yet: try again (Apple's offline rendering does the same).
                retries += 1
                if retries > 1_000 { throw Failure.renderFailed("the audio engine stalled") }
                continue
            case .error:
                throw Failure.renderFailed("the audio engine failed")
            @unknown default:
                throw Failure.renderFailed("the audio engine failed")
            }
            rendered += AVAudioFramePosition(buffer.frameLength)
            var out = buffer
            if toDrop > 0 {
                let dropped = min(toDrop, AVAudioFramePosition(buffer.frameLength))
                toDrop -= dropped
                let kept = Int(buffer.frameLength) - Int(dropped)
                guard kept > 0 else { continue }
                if let from = buffer.floatChannelData?[0], let to = trimmed.floatChannelData?[0] {
                    to.update(from: from + Int(dropped), count: kept)
                }
                trimmed.frameLength = AVAudioFrameCount(kept)
                out = trimmed
            }
            try writer.write(from: out)
            if let channel = out.floatChannelData?[0] {
                meter.process(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
            let fraction = Double(rendered) / Double(max(1, total))
            if fraction - reported >= 0.01 {
                reported = fraction
                progress(fraction)
            }
        }
        return meter.integratedLoudness
    }

    /// The delay of `processed` against `original`, in samples (0…`maximum`),
    /// from their loudness envelopes; `nil` when they don't match well
    /// enough to tell (too little sound).
    static func measureDelay(original: URL, processed: URL, maximum: Int) throws -> Int? {
        let block = 48  // 1 ms at 48 kHz
        let first = try envelope(of: original, block: block)
        let second = try envelope(of: processed, block: block)
        let lags = maximum / block
        guard first.count > lags * 4, second.count >= first.count else { return nil }
        let a = centered(first)
        let b = centered(second)
        let n = vDSP_Length(a.count - lags)
        var best = 0
        var bestScore = -Float.infinity
        for lag in 0...lags {
            var score: Float = 0
            b.withUnsafeBufferPointer { b in
                a.withUnsafeBufferPointer { a in vDSP_dotpr(a.baseAddress!, 1, b.baseAddress! + lag, 1, &score, n) }
            }
            if score > bestScore {
                bestScore = score
                best = lag
            }
        }
        var energyA: Float = 0
        var energyB: Float = 0
        a.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!, 1, &energyA, n) }
        b.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + best, 1, &energyB, n) }
        guard energyA > 0, energyB > 0, bestScore / (energyA * energyB).squareRoot() > 0.3 else { return nil }
        return best * block
    }

    /// Mean absolute level per `block` samples.
    private static func envelope(of url: URL, block: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block * 1_024)) else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(Int(file.length) / block + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            var index = 0
            let length = Int(buffer.frameLength)
            while index + block <= length {
                var level: Float = 0
                vDSP_meamgv(channel + index, 1, &level, vDSP_Length(block))
                levels.append(level)
                index += block
            }
        }
        return levels
    }

    private static func centered(_ values: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        return values.map { $0 - mean }
    }

    private static func effect(_ subtype: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype,
                                  componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }
}
