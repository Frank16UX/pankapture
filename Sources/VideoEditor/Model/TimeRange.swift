import Foundation

/// A half-open range of seconds, `[start, end)`.
///
/// The edit model stores plain `Double` seconds; conversion to `CMTime` happens
/// only at the AVFoundation boundary (`CompositionBuilder`).
public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
    public var isEmpty: Bool { end <= start }
    public var midpoint: Double { (start + end) / 2 }

    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }

    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }

    /// The overlapping part of both ranges, or `nil` if they don't overlap.
    public func intersection(_ other: TimeRange) -> TimeRange? {
        let result = TimeRange(start: max(start, other.start), end: min(end, other.end))
        return result.isEmpty ? nil : result
    }

    /// Clamps both ends into `bounds`; `nil` if nothing is left.
    public func clamped(to bounds: TimeRange) -> TimeRange? {
        intersection(bounds)
    }

    /// The parts of `self` not covered by `other` (zero, one, or two ranges).
    public func subtracting(_ other: TimeRange) -> [TimeRange] {
        guard overlaps(other) else { return isEmpty ? [] : [self] }
        var parts: [TimeRange] = []
        if other.start > start { parts.append(TimeRange(start: start, end: other.start)) }
        if other.end < end { parts.append(TimeRange(start: other.end, end: end)) }
        return parts
    }

    /// Sorts, drops empty ranges, and merges ranges that overlap or touch
    /// (within `tolerance` seconds).
    public static func merged(_ ranges: [TimeRange], tolerance: Double = 1e-6) -> [TimeRange] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var result: [TimeRange] = []
        for range in sorted {
            if let last = result.last, range.start <= last.end + tolerance {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
