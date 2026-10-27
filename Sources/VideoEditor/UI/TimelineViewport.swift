import AppCore
import Foundation

/// The part of the source the timeline shows (VE-14). At zoom 1 it shows the
/// whole source; at zoom `z` it shows `duration / z` seconds starting at
/// `start`. View state only: not saved and not undoable.
struct TimelineViewport: Equatable {
    /// The closest zoom shows about this many seconds.
    static let minimumSpan = 1.5

    var zoom: Double = 1
    /// Source seconds at the left edge.
    var start: Double = 0

    var isZoomed: Bool { zoom > 1.0001 }

    static func maximumZoom(duration: Double) -> Double {
        max(1, duration / minimumSpan)
    }

    func span(duration: Double) -> Double {
        duration / max(1, zoom)
    }

    func end(duration: Double) -> Double {
        start + span(duration: duration)
    }

    func contains(_ time: Double, duration: Double) -> Bool {
        time >= start && time <= end(duration: duration)
    }

    /// Zooms by `factor`, keeping `anchor` (source seconds) where it is on screen.
    mutating func zoom(by factor: Double, around anchor: Double, duration: Double) {
        guard factor.isFinite, factor > 0 else { return }
        setZoom(zoom * factor, around: anchor, duration: duration)
    }

    mutating func setZoom(_ newZoom: Double, around anchor: Double, duration: Double) {
        guard duration > 0, newZoom.isFinite else { return }
        let oldSpan = span(duration: duration)
        let fraction = ((anchor - start) / oldSpan).clamped(to: 0...1)
        zoom = newZoom.clamped(to: 1...Self.maximumZoom(duration: duration))
        start = anchor - fraction * span(duration: duration)
        clamp(duration: duration)
    }

    /// Moves the visible window by `seconds` (negative = earlier).
    mutating func pan(by seconds: Double, duration: Double) {
        start += seconds
        clamp(duration: duration)
    }

    /// Scrolls just enough to show `range` (its start, when it's longer
    /// than the window). Returns whether the window moved.
    @discardableResult
    mutating func reveal(_ range: TimeRange, duration: Double) -> Bool {
        guard isZoomed else { return false }
        let span = span(duration: duration)
        let margin = span * 0.1
        let old = start
        if range.start < start || range.duration > span - 2 * margin {
            start = range.start - margin
        } else if range.end > start + span {
            start = range.end + margin - span
        }
        clamp(duration: duration)
        return start != old
    }

    /// During playback: when the playhead leaves the window, the next page
    /// starts just before it.
    @discardableResult
    mutating func follow(playhead: Double, duration: Double) -> Bool {
        guard isZoomed, !contains(playhead, duration: duration) else { return false }
        let old = start
        start = playhead - span(duration: duration) * 0.05
        clamp(duration: duration)
        return start != old
    }

    mutating func fit() {
        zoom = 1
        start = 0
    }

    mutating func clamp(duration: Double) {
        zoom = zoom.clamped(to: 1...Self.maximumZoom(duration: duration))
        start = start.clamped(to: 0...max(0, duration - span(duration: duration)))
    }
}

/// Timeline zoom and scrolling (VE-14).
extension VideoEditorModel {
    /// Zooms around `time`, or around the playhead (the middle when it's off screen).
    func zoomTimeline(by factor: Double, around time: Double? = nil) {
        var viewport = timelineViewport
        viewport.zoom(by: factor, around: time ?? zoomAnchor(viewport), duration: duration)
        timelineViewport = viewport
    }

    func setTimelineZoom(_ zoom: Double) {
        var viewport = timelineViewport
        viewport.setZoom(zoom, around: zoomAnchor(viewport), duration: duration)
        timelineViewport = viewport
    }

    func panTimeline(by seconds: Double) {
        var viewport = timelineViewport
        viewport.pan(by: seconds, duration: duration)
        if viewport != timelineViewport { timelineViewport = viewport }
    }

    func scrollTimeline(toStart start: Double) {
        panTimeline(by: start - timelineViewport.start)
    }

    func fitTimeline() {
        timelineViewport.fit()
    }

    /// Scrolls the zoomed timeline to show `range` (e.g. a suggestion picked in the review list).
    func revealOnTimeline(_ range: TimeRange) {
        var viewport = timelineViewport
        if viewport.reveal(range, duration: duration) { timelineViewport = viewport }
    }

    private func zoomAnchor(_ viewport: TimelineViewport) -> Double {
        viewport.contains(playhead, duration: duration) ? playhead : viewport.start + viewport.span(duration: duration) / 2
    }
}
