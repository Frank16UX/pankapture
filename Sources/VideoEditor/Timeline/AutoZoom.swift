import AppCore
import CoreGraphics
import Foundation

/// Proposes zoom segments that follow recorded clicks (VE-5).
///
/// Clicks close in time *and* space form one cluster; each cluster becomes one
/// zoom centered on the clicks' centroid, starting a little before the first
/// click and holding a little after the last. Pure, so it's fully testable.
public struct AutoZoomSuggester: Sendable {
    /// Clicks further apart than this (seconds) start a new cluster.
    public var maxGap: Double = 2.0
    /// A click further than this from the cluster centroid (normalized, per
    /// axis) starts a new cluster. Half the visible side at 2× is 0.25.
    public var maxDistance: Double = 0.22
    /// Zoom starts this long before the first click (seconds).
    public var leadIn: Double = 0.8
    /// Zoom holds this long after the last click (seconds).
    public var hold: Double = 1.6
    public var minimumDuration: Double = 2.0
    public var scale: Double = ZoomSegment.defaultScale
    public var easeDuration: Double = ZoomSegment.defaultEase

    public init() {}

    public func suggest(clicks: [RecordingSidecar.Click], sourceDuration: Double) -> [ZoomSegment] {
        guard sourceDuration > 0 else { return [] }
        let clusters = cluster(clicks.filter { $0.time >= 0 && $0.time <= sourceDuration })
        var zooms: [ZoomSegment] = clusters.compactMap { cluster in
            guard let first = cluster.first?.time, let last = cluster.last?.time else { return nil }
            var start = first - leadIn
            var end = last + hold
            if end - start < minimumDuration {
                let pad = (minimumDuration - (end - start)) / 2
                start -= pad
                end += pad
            }
            // Keep the full duration when clamping at either edge, if it fits.
            if start < 0 { end = min(sourceDuration, end - start); start = 0 }
            if end > sourceDuration { start = max(0, start - (end - sourceDuration)); end = sourceDuration }
            return ZoomSegment(
                range: TimeRange(start: start, end: end),
                rect: ZoomSegment.rect(center: Self.centroid(of: cluster), scale: scale),
                easeDuration: easeDuration,
                isAutomatic: true
            )
        }
        // Neighbours whose padded ranges overlap meet halfway instead.
        for index in zooms.indices.dropFirst() where zooms[index].range.start < zooms[index - 1].range.end {
            let boundary = (zooms[index].range.start + zooms[index - 1].range.end) / 2
            zooms[index - 1].range.end = boundary
            zooms[index].range.start = boundary
        }
        return zooms.filter { $0.range.duration >= ZoomSegment.minimumDuration }
    }

    /// Groups time-sorted clicks into clusters.
    func cluster(_ clicks: [RecordingSidecar.Click]) -> [[RecordingSidecar.Click]] {
        var clusters: [[RecordingSidecar.Click]] = []
        for click in clicks.sorted(by: { $0.time < $1.time }) {
            if var current = clusters.last, let previous = current.last {
                let center = Self.centroid(of: current)
                let near = abs(click.location.x - center.x) <= maxDistance
                    && abs(click.location.y - center.y) <= maxDistance
                if click.time - previous.time <= maxGap, near {
                    current.append(click)
                    clusters[clusters.count - 1] = current
                    continue
                }
            }
            clusters.append([click])
        }
        return clusters
    }

    static func centroid(of clicks: [RecordingSidecar.Click]) -> CGPoint {
        guard !clicks.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let sum = clicks.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.location.x, y: $0.y + $1.location.y) }
        return CGPoint(x: sum.x / CGFloat(clicks.count), y: sum.y / CGFloat(clicks.count))
    }
}
