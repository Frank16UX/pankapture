import Foundation

/// Maps between **source** time (seconds in the original file) and **output**
/// time (seconds in the edited result) for a given trim, cuts, and speed changes.
///
/// The output is the concatenation of `segments`, each a piece of source played
/// at a constant rate. Pure and `Sendable`, so the custom compositor can carry
/// it in its instruction and evaluate it on AVFoundation's render queue.
public struct Timeline: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        /// Source seconds covered by this segment.
        public var source: TimeRange
        /// Where the segment starts on the output timeline.
        public var outputStart: Double
        /// Playback rate (2 = twice as fast, so half the output duration).
        public var rate: Double

        public var outputDuration: Double { source.duration / rate }
        public var outputEnd: Double { outputStart + outputDuration }
        public var output: TimeRange { TimeRange(start: outputStart, end: outputEnd) }
    }

    public let sourceDuration: Double
    public let segments: [Segment]

    public var outputDuration: Double { segments.last?.outputEnd ?? 0 }
    /// The kept source ranges (trim minus cuts), merged.
    public var keptRanges: [TimeRange] { TimeRange.merged(segments.map(\.source)) }

    public init(project: VideoEditProject) {
        self.init(
            sourceDuration: project.sourceDuration,
            trim: project.trim,
            cuts: project.cuts,
            speedSegments: project.speedSegments
        )
    }

    public init(sourceDuration: Double, trim: TimeRange? = nil, cuts: [TimeRange] = [], speedSegments: [SpeedSegment] = []) {
        self.sourceDuration = max(0, sourceDuration)
        let kept = Self.keptRanges(sourceDuration: sourceDuration, trim: trim, cuts: cuts)
        let speeds = Self.normalizedSpeeds(speedSegments)

        var segments: [Segment] = []
        var cursor = 0.0
        for range in kept {
            for (piece, rate) in Self.split(range, by: speeds) {
                let segment = Segment(source: piece, outputStart: cursor, rate: rate)
                segments.append(segment)
                cursor = segment.outputEnd
            }
        }
        self.segments = segments
    }

    // MARK: Building blocks

    /// Trim minus cuts, with cuts clamped to the source, sorted, and merged.
    /// Pieces shorter than a microsecond are dropped.
    public static func keptRanges(sourceDuration: Double, trim: TimeRange?, cuts: [TimeRange]) -> [TimeRange] {
        let full = TimeRange(start: 0, end: max(0, sourceDuration))
        guard let trimmed = (trim ?? full).clamped(to: full) else { return [] }
        var kept = [trimmed]
        for cut in TimeRange.merged(cuts.compactMap { $0.clamped(to: full) }) {
            kept = kept.flatMap { $0.subtracting(cut) }
        }
        return kept.filter { $0.duration > 1e-6 }
    }

    /// Sorted, non-overlapping speed segments with sane rates. When two
    /// overlap, the one that starts first wins the shared part.
    static func normalizedSpeeds(_ speeds: [SpeedSegment]) -> [(range: TimeRange, rate: Double)] {
        var result: [(range: TimeRange, rate: Double)] = []
        for segment in speeds.sorted(by: { $0.range.start < $1.range.start }) {
            guard !segment.range.isEmpty, segment.rate.isFinite, segment.rate > 0 else { continue }
            var range = segment.range
            if let last = result.last, range.start < last.range.end {
                range.start = last.range.end
            }
            guard range.duration > 1e-6 else { continue }
            result.append((range, segment.rate.clamped(to: SpeedSegment.rateRange)))
        }
        return result
    }

    /// Splits a kept range into constant-rate pieces.
    static func split(_ range: TimeRange, by speeds: [(range: TimeRange, rate: Double)]) -> [(TimeRange, Double)] {
        var pieces: [(TimeRange, Double)] = []
        var cursor = range.start
        for speed in speeds where speed.range.overlaps(range) {
            guard let overlap = speed.range.intersection(range) else { continue }
            if overlap.start > cursor + 1e-9 {
                pieces.append((TimeRange(start: cursor, end: overlap.start), 1))
            }
            pieces.append((overlap, speed.rate))
            cursor = overlap.end
        }
        if range.end > cursor + 1e-9 {
            pieces.append((TimeRange(start: cursor, end: range.end), 1))
        }
        return pieces.filter { $0.0.duration > 1e-6 }
    }

    // MARK: Mapping

    /// Output time at which source `time` plays, or `nil` if that moment was
    /// trimmed or cut.
    public func outputTime(forSource time: Double) -> Double? {
        for segment in segments where time >= segment.source.start && time <= segment.source.end {
            return segment.outputStart + (time - segment.source.start) / segment.rate
        }
        return nil
    }

    /// Like `outputTime(forSource:)`, but a removed moment snaps to the start
    /// of the next kept segment (or the end of the output if none follows).
    public func nearestOutputTime(forSource time: Double) -> Double {
        if let exact = outputTime(forSource: time) { return exact }
        if let next = segments.first(where: { $0.source.start >= time }) { return next.outputStart }
        return outputDuration
    }

    /// Source time shown at output `time` (clamped to the output's extent).
    public func sourceTime(forOutput time: Double) -> Double {
        guard let first = segments.first, let last = segments.last else { return 0 }
        if time <= 0 { return first.source.start }
        if time >= last.outputEnd { return last.source.end }
        // Segment boundaries belong to the *next* segment, like `[start, end)`.
        let segment = segments.first { time < $0.outputEnd } ?? last
        return segment.source.start + (time - segment.outputStart) * segment.rate
    }

    /// The segment playing at output `time`.
    public func segment(atOutput time: Double) -> Segment? {
        segments.first { time >= $0.outputStart && time < $0.outputEnd } ?? (time >= outputDuration ? segments.last : nil)
    }

    /// Whether source `time` survives trim and cuts.
    public func isKept(source time: Double) -> Bool {
        outputTime(forSource: time) != nil
    }

    /// Output duration of a source range (only its kept parts count).
    public func outputDuration(ofSource range: TimeRange) -> Double {
        segments.reduce(0) { total, segment in
            guard let overlap = segment.source.intersection(range) else { return total }
            return total + overlap.duration / segment.rate
        }
    }
}
