import CoreMedia

/// Maps capture (host clock) time to output time with paused spans removed, so
/// pause/resume produces one continuous file (REC-8).
///
/// Pause boundaries are stored as host-clock intervals rather than applied as a
/// running offset. Samples are delivered a little after they're captured, so a
/// frame captured just before the user pressed Pause may arrive just after;
/// comparing each sample's own presentation time against the intervals keeps
/// it in (and drops frames captured during the pause) regardless of delivery
/// order or latency.
///
/// Output time `f(t) = t − (paused time before t)` is continuous and
/// non-decreasing, so retimed samples stay monotonic per track.
public struct PauseTimeline: Equatable, Sendable {
    public struct Interval: Equatable, Sendable {
        public var start: CMTime
        /// `nil` while the pause is still open.
        public var end: CMTime?
    }

    public private(set) var intervals: [Interval] = []

    public init() {}

    public var isPaused: Bool { intervals.last.map { $0.end == nil } ?? false }

    /// Opens a pause at `hostTime`. Ignored if already paused or if `hostTime`
    /// precedes the last resume (clock went backwards).
    public mutating func pause(at hostTime: CMTime) {
        guard !isPaused else { return }
        if let lastEnd = intervals.last?.end, hostTime < lastEnd { return }
        intervals.append(Interval(start: hostTime, end: nil))
    }

    /// Closes the open pause at `hostTime`. Ignored if not paused.
    public mutating func resume(at hostTime: CMTime) {
        guard isPaused, let index = intervals.indices.last else { return }
        intervals[index].end = max(hostTime, intervals[index].start)
    }

    /// Total paused time up to `hostTime` (an open pause counts up to `hostTime`).
    public func pausedDuration(before hostTime: CMTime) -> CMTime {
        var total = CMTime.zero
        for interval in intervals {
            guard interval.start < hostTime else { break }
            let end = interval.end.map { min($0, hostTime) } ?? hostTime
            total = total + (end - interval.start)
        }
        return total
    }

    /// Whether a sample captured at `hostTime` falls inside a pause (and must be dropped).
    public func isPaused(at hostTime: CMTime) -> Bool {
        intervals.contains { interval in
            hostTime >= interval.start && (interval.end.map { hostTime < $0 } ?? true)
        }
    }

    /// Output time for a sample captured at `hostTime`, or `nil` if it was
    /// captured while paused.
    public func outputTime(for hostTime: CMTime) -> CMTime? {
        if isPaused(at: hostTime) { return nil }
        return hostTime - pausedDuration(before: hostTime)
    }

    /// Recorded time between `start` and `now`, excluding pauses.
    public func elapsed(from start: CMTime, to now: CMTime) -> CMTime {
        guard now > start else { return .zero }
        let paused = pausedDuration(before: now) - pausedDuration(before: start)
        return max(.zero, (now - start) - paused)
    }
}

public extension PauseTimeline {
    /// Convenience for the main-actor UI copy, which works in seconds.
    func elapsedSeconds(from start: CMTime, to now: CMTime) -> Double {
        elapsed(from: start, to: now).seconds
    }
}

extension CMTime {
    /// Current host-clock time: the clock ScreenCaptureKit stamps samples with.
    static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
}
