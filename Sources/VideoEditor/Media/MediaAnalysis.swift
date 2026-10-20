import AppCore
import AVFoundation
import CoreGraphics

/// A filmstrip frame at a source time.
public struct FilmstripFrame: Sendable {
    public let time: Double
    public let image: CGImage
}

/// Filmstrip thumbnails (VE-1). Generated once per source at evenly spaced
/// times; the timeline picks the nearest one for each tile, so resizing the
/// window never regenerates anything.
public enum FilmstripGenerator {
    public static func frames(asset: AVURLAsset, duration: Double, count: Int, maximumSize: CGSize) async -> [FilmstripFrame] {
        guard duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        let tolerance = CMTime(seconds: max(0.05, duration / Double(count) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let step = duration / Double(count)
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: 600) }
        var frames: [FilmstripFrame] = []
        for await result in generator.images(for: times) {
            if Task.isCancelled { break }
            if let image = try? result.image {
                frames.append(FilmstripFrame(time: result.requestedTime.seconds, image: image))
            }
        }
        return frames.sorted { $0.time < $1.time }
    }
}

/// Downsampled audio peaks for a waveform lane (VE-1).
public struct Waveform: Sendable, Equatable {
    /// Source time of the first bucket (the audio track's start).
    public let startTime: Double
    /// Seconds of source per bucket.
    public let bucketDuration: Double
    /// Peak amplitude per bucket, normalized so the loudest bucket is 1.
    public let peaks: [Float]
    /// The loudest bucket before normalizing, 0…1 of full scale.
    public let loudestPeak: Float

    public init(startTime: Double = 0, bucketDuration: Double, peaks: [Float], loudestPeak: Float = 1) {
        self.startTime = startTime
        self.bucketDuration = bucketDuration
        self.peaks = peaks
        self.loudestPeak = loudestPeak
    }

    /// Nothing above about -50 dBFS: e.g. system audio while no app made a sound.
    public var isSilent: Bool { loudestPeak < 0.003 }

    /// Loudest peak within a source time range.
    public func peak(in range: TimeRange) -> Float {
        guard bucketDuration > 0, !peaks.isEmpty, range.end > startTime else { return 0 }
        let first = max(0, Int((range.start - startTime) / bucketDuration))
        let last = min(peaks.count - 1, Int((range.end - startTime) / bucketDuration))
        guard first <= last else { return 0 }
        return peaks[first...last].max() ?? 0
    }
}

public enum WaveformExtractor {
    static let sampleRate: Double = 8_000

    /// Reads one audio track as 8 kHz mono and keeps the peak of every
    /// `1 / bucketsPerSecond` seconds. Runs synchronously on the caller's
    /// executor; call it from a detached task.
    public static func waveform(asset: AVURLAsset, trackID: CMPersistentTrackID, bucketsPerSecond: Double = 50) async throws -> Waveform {
        guard let track = try await asset.loadTrack(withTrackID: trackID) else {
            return Waveform(bucketDuration: 1 / bucketsPerSecond, peaks: [])
        }
        let trackStart = (try? await track.load(.timeRange).start.seconds) ?? 0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return Waveform(bucketDuration: 1 / bucketsPerSecond, peaks: []) }
        reader.add(output)
        guard reader.startReading() else { throw VideoEditorError.compositionFailed("Couldn't read audio") }

        let samplesPerBucket = max(1, Int(sampleRate / bucketsPerSecond))
        var peaks: [Float] = []
        var currentPeak: Int16 = 0
        var inBucket = 0
        var samples: [Int16] = []

        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Int16>.size
            if samples.count < count { samples = Array(repeating: 0, count: count) }
            _ = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Int16>.size, destination: raw.baseAddress!)
            }
            for index in 0..<count {
                let magnitude = samples[index] == .min ? .max : abs(samples[index])
                if magnitude > currentPeak { currentPeak = magnitude }
                inBucket += 1
                if inBucket == samplesPerBucket {
                    peaks.append(Float(currentPeak) / Float(Int16.max))
                    currentPeak = 0
                    inBucket = 0
                }
            }
        }
        if inBucket > 0 { peaks.append(Float(currentPeak) / Float(Int16.max)) }

        let loudest = peaks.max() ?? 0
        if loudest > 0.001 { peaks = peaks.map { $0 / loudest } }
        return Waveform(
            startTime: trackStart.isFinite ? trackStart : 0,
            bucketDuration: Double(samplesPerBucket) / sampleRate,
            peaks: peaks,
            loudestPeak: loudest
        )
    }
}
