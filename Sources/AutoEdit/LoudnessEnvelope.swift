import AppCore
import Foundation

/// The microphone's level in 10 ms frames (dBFS), for finding pauses and the
/// quietest points to cut at. Pure and `Sendable`.
public struct LoudnessEnvelope: Codable, Sendable, Equatable {
    public static let frameDuration = 0.01
    /// Level used for digital silence.
    public static let floorLevel: Float = -100

    /// Source time of the first frame.
    public var startTime: Double
    /// dBFS per frame.
    public var levels: [Float]

    public init(startTime: Double = 0, levels: [Float]) {
        self.startTime = startTime
        self.levels = levels
    }

    public var duration: Double { Double(levels.count) * Self.frameDuration }
    public var endTime: Double { startTime + duration }

    public static func dBFS(rms: Float) -> Float {
        rms > 1e-5 ? max(floorLevel, 20 * log10(rms)) : floorLevel
    }

    public func frame(at time: Double) -> Int {
        Int(((time - startTime) / Self.frameDuration).rounded(.down)).clamped(to: 0...max(0, levels.count - 1))
    }

    public func time(ofFrame index: Int) -> Double {
        startTime + Double(index) * Self.frameDuration
    }

    /// The level that separates speech from background, in dBFS.
    public struct Thresholds: Sendable, Equatable {
        public var noiseFloor: Float
        public var speech: Float
    }

    /// A fixed distance above the noise floor (10th percentile), scaled to how
    /// far speech (95th percentile) rises above it.
    public func thresholds() -> Thresholds {
        let audible = levels.filter { $0 > Self.floorLevel }
        guard !audible.isEmpty else { return Thresholds(noiseFloor: Self.floorLevel, speech: -60) }
        let sorted = audible.sorted()
        func percentile(_ p: Double) -> Float { sorted[Int(Double(sorted.count - 1) * p)] }
        // Digital silence (a muted mic) is the floor when it's common.
        let silentShare = Double(levels.count - audible.count) / Double(levels.count)
        let floor = silentShare > 0.1 ? Self.floorLevel : percentile(0.1)
        let base = max(floor, -80)
        let margin = ((percentile(0.95) - base) * 0.3).clamped(to: 6...15)
        return Thresholds(noiseFloor: floor, speech: base + margin)
    }

    /// Spans inside `range` quiet enough to be a pause, at least `minimum`
    /// long. Hysteresis (3 dB) keeps a level hovering at the threshold from
    /// flickering, and loud blips under 60 ms (clicks, pops) don't break a pause.
    public func silentRuns(in range: TimeRange, minimum: Double, thresholds: Thresholds) -> [TimeRange] {
        guard !levels.isEmpty, range.end > startTime, range.start < endTime else { return [] }
        let first = frame(at: max(range.start, startTime))
        let last = frame(at: min(range.end, endTime) - Self.frameDuration / 2)
        guard first <= last else { return [] }

        var runs: [(start: Int, end: Int)] = []
        var quiet = levels[first] < thresholds.speech
        var runStart = first
        for index in first...last {
            let level = levels[index]
            if quiet, level >= thresholds.speech {
                quiet = false
                runs.append((runStart, index))
            } else if !quiet, level < thresholds.speech - 3 {
                quiet = true
                runStart = index
            }
        }
        if quiet { runs.append((runStart, last + 1)) }

        let blipFrames = Int((0.06 / Self.frameDuration).rounded())
        var merged: [(start: Int, end: Int)] = []
        for run in runs where run.end > run.start {
            if let previous = merged.last, run.start - previous.end <= blipFrames {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }
        return merged
            .map { TimeRange(start: max(range.start, time(ofFrame: $0.start)), end: min(range.end, time(ofFrame: $0.end))) }
            .filter { $0.duration >= minimum - 1e-9 }
    }

    /// The frame levels inside `range`.
    public func levels(in range: TimeRange) -> ArraySlice<Float> {
        guard !levels.isEmpty, range.end > startTime, range.start < endTime else { return [] }
        let first = frame(at: max(range.start, startTime))
        let last = frame(at: min(range.end, endTime) - Self.frameDuration / 2)
        return first <= last ? levels[first...last] : []
    }

    /// Time of the quietest 10 ms within `range` (for snapping cuts, AE-9).
    public func quietestTime(in range: TimeRange) -> Double? {
        guard !levels.isEmpty, range.end > startTime, range.start < endTime else { return nil }
        let first = frame(at: max(range.start, startTime))
        let last = frame(at: min(range.end, endTime) - Self.frameDuration / 2)
        guard first <= last else { return nil }
        var best = first
        for index in first...last where levels[index] < levels[best] { best = index }
        return time(ofFrame: best) + Self.frameDuration / 2
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
