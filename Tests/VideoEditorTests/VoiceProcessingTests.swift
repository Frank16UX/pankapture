import AppCore
import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import VideoEditor

/// Voice cleanup (PRD AU-1–AU-3): the loudness meter and the offline passes.
@Suite("Voice processing")
struct VoiceProcessingTests {
    static func sine(frequency: Double, amplitude: Double, seconds: Double, sampleRate: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    static func loudness(_ samples: [Float], sampleRate: Double) -> Double? {
        var meter = LoudnessMeter(sampleRate: sampleRate)
        // Fed in uneven chunks, like render buffers.
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + 3_000)
            samples[offset..<end].withUnsafeBufferPointer { meter.process($0) }
            offset = end
        }
        return meter.integratedLoudness
    }

    @Test func meterMatchesTheStandardsReferenceTone() throws {
        // BS.1770: a 1 kHz sine at full scale reads −3.01 LUFS; at 0.1, −23.01.
        for sampleRate in [44_100.0, 48_000.0] {
            let reading = try #require(Self.loudness(Self.sine(frequency: 1_000, amplitude: 0.1, seconds: 3, sampleRate: sampleRate), sampleRate: sampleRate))
            #expect(abs(reading - -23.01) < 0.2, "\(sampleRate) Hz: \(reading)")
        }
    }

    @Test func meterGatesSilence() throws {
        let rate = 48_000.0
        #expect(Self.loudness([Float](repeating: 0, count: Int(rate * 2)), sampleRate: rate) == nil)
        #expect(Self.loudness(Self.sine(frequency: 1_000, amplitude: 0.1, seconds: 0.2, sampleRate: rate), sampleRate: rate) == nil)
        // Silence between two tones barely moves the reading (ungated, it
        // would be −26): only the blocks straddling each tone's edge count.
        let tone = Self.sine(frequency: 1_000, amplitude: 0.1, seconds: 2, sampleRate: rate)
        let gapped = tone + [Float](repeating: 0, count: Int(rate * 4)) + tone
        let reading = try #require(Self.loudness(gapped, sampleRate: rate))
        #expect(reading > -23.6 && reading < -23.0, "\(reading)")
    }

    @Test func settingsKeyAndActivity() {
        #expect(!VoiceProcessing().isActive)
        #expect(VoiceProcessing(noiseReduction: .min).isActive)
        #expect(VoiceProcessing(normalizes: true).isActive)
        #expect(VoiceProcessing(noiseReduction: .max, normalizes: true).key == "max-normalized")
        #expect(VoiceProcessing.NoiseReduction.allCases.map(\.mix) == [0, 40, 70, 100])
    }

    @Test func oldProjectsDecodeWithoutVoiceSettings() throws {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/Recording.mp4"), sourceDuration: 10)
        project.voice = nil
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(VideoEditProject.self, from: data)
        #expect(decoded.voice == nil)
        project.voice = VoiceProcessing(noiseReduction: .medium, normalizes: true)
        #expect(!project.isUnedited)
    }

    /// Decode, measure, then gain and limit: a quiet voice comes out near −16 LUFS.
    @Test func normalizesAQuietTrack() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestMovie.make(TestMovie.Spec(duration: 3, audioAmplitudes: [0, 0.03]), in: directory)
        let source = try await SourceMedia.load(url: movie)
        let microphone = try #require(source.audioTracks.first { $0.role == .microphone })

        let decoded = directory.appendingPathComponent("voice.caf")
        let start = try await VoiceProcessor.decode(source: movie, trackID: microphone.trackID, to: decoded)
        #expect(abs(start) < 0.1)

        let measured = directory.appendingPathComponent("measured.caf")
        let before = try #require(try VoiceProcessor.render(input: decoded, output: measured, isolation: .off, limiterGain: nil) { _ in })
        #expect(before < -30)

        let output = directory.appendingPathComponent("voice.m4a")
        let gain = VoiceProcessor.targetLoudness - before
        let after = try #require(try VoiceProcessor.render(input: measured, output: output, isolation: .off, limiterGain: gain) { _ in })
        #expect(abs(after - VoiceProcessor.targetLoudness) < 1.5, "\(after) LUFS")

        let file = try AVAudioFile(forReading: output)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 3) < 0.2)
    }

    /// Writes `seconds` of mono 48 kHz audio: two tones in bursts of
    /// uneven length, so the envelope has a shape to line up.
    static func writeBursts(to url: URL, seconds: Double) throws {
        let rate = 48_000.0
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = Int(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        let pattern = [0.13, 0.31, 0.07, 0.22, 0.41, 0.09, 0.17, 0.27]
        let channel = try #require(buffer.floatChannelData?[0])
        var edge = 0.0
        var on = true
        var step = 0
        for i in 0..<count {
            let t = Double(i) / rate
            if t >= edge {
                edge += pattern[step % pattern.count]
                step += 1
                on.toggle()
            }
            channel[i] = on ? Float(0.3 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 660 * t)) : 0
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
    }

    /// Voice isolation delays its output; the second pass takes the delay
    /// back out, so the cleaned voice lines up with the original.
    @Test func noiseRemovalStaysInSync() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &description) != nil else { return }
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("voice.caf")
        try Self.writeBursts(to: original, seconds: 4)
        let length = try AVAudioFile(forReading: original).length

        let isolated = directory.appendingPathComponent("isolated.caf")
        try VoiceProcessor.render(input: original, output: isolated, isolation: .medium, limiterGain: nil,
                                  extraFrames: AVAudioFramePosition(VoiceProcessor.maximumIsolationDelay)) { _ in }
        let delay = try VoiceProcessor.measureDelay(original: original, processed: isolated, maximum: VoiceProcessor.maximumIsolationDelay)
            ?? VoiceProcessor.typicalIsolationDelay(.medium)

        let aligned = directory.appendingPathComponent("aligned.caf")
        try VoiceProcessor.render(input: isolated, output: aligned, isolation: .off, limiterGain: 0,
                                  startFrame: AVAudioFramePosition(delay), frameCount: length) { _ in }
        #expect(try AVAudioFile(forReading: aligned).length == length)
        let remaining = try #require(try VoiceProcessor.measureDelay(original: original, processed: aligned, maximum: 4_800))
        #expect(remaining <= 48, "still \(remaining) samples late (isolation delay \(delay))")
    }

    /// The composition keeps the processed voice usable after it's loaded,
    /// cuts included (the track alone doesn't keep its file open).
    @Test func compositionUsesTheProcessedVoice() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestMovie.make(TestMovie.Spec(duration: 3, audioAmplitudes: [0.2, 0.05]), in: directory)
        let source = try await SourceMedia.load(url: movie)
        let microphone = try #require(source.audioTracks.first { $0.role == .microphone })
        let settings = VoiceProcessing(normalizes: true)
        let rendered = try await VoiceProcessor.render(source: movie, microphoneTrackID: microphone.trackID, settings: settings, in: directory)

        var tracks = try await source.loadTracks()
        tracks.processedVoice = try await ProcessedVoice.load(VoiceProcessor.Output(url: rendered.url, startTime: rendered.startTime))
        var project = VideoEditProject(sourceURL: movie, sourceDuration: source.duration)
        project.voice = settings
        project.cuts = [TimeRange(start: 1, end: 1.5)]
        let edit = try CompositionBuilder.build(source: source, tracks: tracks, project: project, options: .init(), background: nil)
        let audio = try await edit.composition.loadTracks(withMediaType: .audio)
        #expect(audio.count == 2)
        for track in audio {
            let range = try await track.load(.timeRange)
            #expect(abs(range.duration.seconds - 2.5) < 0.1)
        }
    }

    /// Runs the voice-isolation unit on a tone, where it's installed.
    @Test func noiseRemovalRenders() async throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &description) != nil else { return }
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestMovie.make(TestMovie.Spec(duration: 2, audioAmplitudes: [0.3]), in: directory)
        let source = try await SourceMedia.load(url: movie)
        let track = try #require(source.audioTracks.first)
        let decoded = directory.appendingPathComponent("voice.caf")
        _ = try await VoiceProcessor.decode(source: movie, trackID: track.trackID, to: decoded)

        let output = directory.appendingPathComponent("isolated.caf")
        try VoiceProcessor.render(input: decoded, output: output, isolation: .max, limiterGain: nil) { _ in }
        let file = try AVAudioFile(forReading: output)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 2) < 0.2)
    }
}
