import AppCore
import AVFoundation
import Foundation
import Testing
import Transcription
@testable import AutoEdit

/// Envelope levels: `(dBFS, seconds)` runs at 10 ms per frame.
private func envelope(_ runs: [(Float, Double)], start: Double = 0) -> LoudnessEnvelope {
    LoudnessEnvelope(startTime: start, levels: runs.flatMap { Array(repeating: $0.0, count: Int(($0.1 * 100).rounded())) })
}

@Suite("Loudness envelope")
struct LoudnessEnvelopeTests {
    @Test func thresholdSitsAboveTheNoiseFloor() {
        let thresholds = envelope([(-60, 1), (-20, 1)]).thresholds()
        #expect(thresholds.noiseFloor == -60)
        #expect(thresholds.speech == -48)
    }

    @Test func mutedMicIsTheFloor() {
        let thresholds = envelope([(-100, 1), (-30, 1)]).thresholds()
        #expect(thresholds.noiseFloor == -100)
        #expect(thresholds.speech == -65)
    }

    @Test func silentRunsIgnoreShortBlips() {
        let level = envelope([(-20, 0.5), (-60, 0.4), (-20, 0.05), (-60, 0.4), (-20, 0.5)])
        let runs = level.silentRuns(in: TimeRange(start: 0, end: 1.85), minimum: 0.3, thresholds: level.thresholds())
        #expect(runs.count == 1)
        #expect(abs((runs.first?.start ?? 0) - 0.5) < 0.011)
        #expect(abs((runs.first?.end ?? 0) - 1.35) < 0.011)
    }

    @Test func quietestTimeFindsTheDip() {
        let level = envelope([(-20, 0.3), (-70, 0.01), (-50, 0.3)], start: 2)
        #expect(abs((level.quietestTime(in: TimeRange(start: 2, end: 2.6)) ?? 0) - 2.305) < 0.001)
    }

    @Test func decibels() {
        #expect(LoudnessEnvelope.dBFS(rms: 1) == 0)
        #expect(abs(LoudnessEnvelope.dBFS(rms: 0.1) - -20) < 0.001)
        #expect(LoudnessEnvelope.dBFS(rms: 0) == LoudnessEnvelope.floorLevel)
    }
}

@Suite("Pause detector")
struct PauseDetectorTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    @Test func gapsWithoutAnEnvelopeArePauses() {
        let words = [word("One.", 0, 0.5), word("Two", 1.5, 2), word("three", 2.1, 2.5)]
        let result = PauseDetector.detect(words: words, envelope: nil)
        #expect(result.pauses.map(\.range) == [TimeRange(start: 0.5, end: 1.5)])
        #expect(result.pauses.first?.afterWord == 0)
    }

    @Test func findsSilenceTheRecognizerFoldedIntoAWord() {
        // "configuración." is timed 0–2 s, but the voice stops at 0.8 s.
        let words = [word("configuración.", 0, 2), word("Lo", 2, 2.3)]
        let level = envelope([(-20, 0.8), (-60, 1.2), (-20, 0.5)])
        let result = PauseDetector.detect(words: words, envelope: level)
        #expect(result.pauses.count == 1)
        #expect(abs((result.pauses.first?.range.start ?? 0) - 0.8) < 0.011)
        #expect(abs((result.pauses.first?.range.duration ?? 0) - 1.2) < 0.011)
    }

    @Test func untranscribedSoundBetweenWordsIsReported() {
        // A dropped "eh" in the middle of a 1.2 s gap.
        let words = [word("Hola,", 0, 0.5), word("vamos", 1.7, 2.1)]
        let level = envelope([(-20, 0.5), (-60, 0.45), (-25, 0.25), (-60, 0.5), (-20, 0.5)])
        let result = PauseDetector.detect(words: words, envelope: level)
        #expect(result.voicedGaps.count == 1)
        #expect(abs((result.voicedGaps.first?.range.start ?? 0) - 0.95) < 0.011)
        #expect(result.pauses.count == 2)
    }
}

@Suite("Microphone audio")
struct MicrophoneAudioTests {
    @Test func extractsTheMicrophoneTrackWithItsPauses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // System: a steady tone. Microphone: tone, 1 s of silence, tone.
        let movie = try await TestAudioMovie.make(in: directory, duration: 2, tracks: [
            ("System", { _ in 0.3 }),
            ("Microphone", { time in time < 0.5 || time >= 1.5 ? 0.5 : 0 }),
        ])
        let audio = try await MicrophoneAudio.extract(from: movie, to: directory.appendingPathComponent("mic.caf"))
        #expect(audio.trackLabel == "Microphone")
        #expect(abs(audio.duration - 2) < 0.1)
        let runs = audio.envelope.silentRuns(in: TimeRange(start: 0, end: 2), minimum: 0.3, thresholds: audio.envelope.thresholds())
        #expect(runs.count == 1)
        #expect(abs((runs.first?.duration ?? 0) - 1) < 0.1)
        #expect(FileManager.default.fileExists(atPath: audio.url.path))
    }

    @Test func aFileWithOneUnnamedTrackUsesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestAudioMovie.make(in: directory, duration: 1, tracks: [(nil, { _ in 0.4 })])
        let audio = try await MicrophoneAudio.extract(from: movie, to: directory.appendingPathComponent("mic.caf"))
        #expect(audio.trackLabel == "Audio")
        #expect(audio.envelope.levels.allSatisfy { $0 > -20 })
    }

    @Test func systemAudioAloneIsNotTranscribed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestAudioMovie.make(in: directory, duration: 1, tracks: [("System", { _ in 0.4 })])
        await #expect(throws: MicrophoneAudio.Failure.self) {
            try await MicrophoneAudio.extract(from: movie, to: directory.appendingPathComponent("mic.caf"))
        }
    }

    @Test func pixelChangeShare() {
        let still = [UInt8](repeating: 100, count: 100)
        var moved = still
        for index in 0..<5 { moved[index] = 200 }
        #expect(ScreenActivityProbe.changedFraction(still, still) == 0)
        #expect(ScreenActivityProbe.changedFraction(still, moved) == 0.05)
    }
}

/// Writes audio-only MP4s whose tracks follow an amplitude envelope (a
/// 440 Hz tone scaled by `amplitude(time)`), titled like the recorder's.
enum TestAudioMovie {
    static let sampleRate = 44_100.0

    static func make(in directory: URL, duration: Double, tracks: [(title: String?, amplitude: @Sendable (Double) -> Double)]) async throws -> URL {
        let url = directory.appendingPathComponent("audio-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let inputs = tracks.map { track -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            if let title = track.title {
                let item = AVMutableMetadataItem()
                item.identifier = .commonIdentifierTitle
                item.value = title as NSString
                item.extendedLanguageTag = "und"
                input.metadata = [item]
            }
            writer.add(input)
            return input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let chunk = 1024
        let total = Int(duration * sampleRate)
        var next = Array(repeating: 0, count: inputs.count)
        let deadline = Date().addingTimeInterval(20)
        while next.contains(where: { $0 < total }) {
            var progressed = false
            for (index, input) in inputs.enumerated() where next[index] < total && input.isReadyForMoreMediaData {
                let count = min(chunk, total - next[index])
                input.append(try buffer(start: next[index], count: count, amplitude: tracks[index].amplitude))
                next[index] += count
                if next[index] >= total { input.markAsFinished() }
                progressed = true
            }
            if !progressed {
                if Date() > deadline || writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func buffer(start: Int, count: Int, amplitude: (Double) -> Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = (0..<count).map { index -> Int16 in
            let time = Double(start + index) / sampleRate
            return Int16(amplitude(time) * Double(Int16.max) * sin(2 * .pi * 440 * time))
        }
        let length = count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        guard let block, let format else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }
}
