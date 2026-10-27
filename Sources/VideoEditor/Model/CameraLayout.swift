import AppCore
import Foundation

/// A stretch of the recording where the camera is shown differently from its
/// usual place (PRD CAM-6): filling the whole frame, or hidden. Outside these
/// the camera layer is drawn as `CameraOverlay` says. In source seconds, like
/// zooms, so cuts and speed changes keep them on the same footage.
public struct CameraLayoutSegment: Codable, Hashable, Sendable, Identifiable {
    public enum Layout: String, Codable, CaseIterable, Sendable, Identifiable {
        /// The camera fills the frame, over the screen.
        case fullFrame
        /// Only the screen; the camera is hidden.
        case hidden

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .fullFrame: "Camera Only"
            case .hidden: "Screen Only"
            }
        }

        public var symbol: String {
            switch self {
            case .fullFrame: "person.crop.rectangle"
            case .hidden: "rectangle.on.rectangle.slash"
            }
        }
    }

    public var id: UUID
    public var range: TimeRange
    public var layout: Layout

    public init(id: UUID = UUID(), range: TimeRange, layout: Layout) {
        self.id = id
        self.range = range
        self.layout = layout
    }

    /// Seconds the camera takes to change at each end of a segment.
    public static let transition: Double = 0.4
    public static let minimumDuration: Double = 0.5
    public static let defaultDuration: Double = 3
}

/// How the camera layer is drawn at one moment.
public struct CameraLayoutState: Equatable, Sendable {
    /// 0 = in its usual place and shape, 1 = filling the frame.
    public var fullness: Double
    /// 0 = hidden, 1 = shown.
    public var visibility: Double

    public static let usual = CameraLayoutState(fullness: 0, visibility: 1)
    public static let hidden = CameraLayoutState(fullness: 0, visibility: 0)
}

/// Pure evaluation of camera layouts; called per frame by the compositor.
public enum CameraLayoutMath {
    /// The camera at source `time`. `isVisible` is what the layer does
    /// outside the segments (Show Camera): a hidden camera still fills the
    /// frame where a Camera Only segment says so, fading in rather than
    /// growing out of a bubble that isn't there.
    public static func state(at time: Double, segments: [CameraLayoutSegment], isVisible: Bool) -> CameraLayoutState {
        let base: CameraLayoutState = isVisible ? .usual : .hidden
        guard let (segment, progress) = active(at: time, segments: segments) else { return base }
        switch segment.layout {
        case .fullFrame:
            return isVisible
                ? CameraLayoutState(fullness: progress, visibility: 1)
                : CameraLayoutState(fullness: 1, visibility: progress)
        case .hidden:
            return CameraLayoutState(fullness: 0, visibility: base.visibility * (1 - progress))
        }
    }

    /// The segment at `time` and how far into its layout the camera is (> 0).
    static func active(at time: Double, segments: [CameraLayoutSegment]) -> (CameraLayoutSegment, Double)? {
        for segment in segments {
            let range = segment.range
            guard range.duration > 0, time > range.start, time < range.end else { continue }
            let ease = max(1e-3, min(CameraLayoutSegment.transition, range.duration / 2))
            let progress = ZoomMath.ease(min(1, (time - range.start) / ease, (range.end - time) / ease))
            if progress > 0 { return (segment, progress) }
        }
        return nil
    }

    /// Whether the camera shows anywhere: the layer is drawn at all.
    public static func showsCamera(segments: [CameraLayoutSegment], isVisible: Bool) -> Bool {
        isVisible || segments.contains { $0.layout == .fullFrame }
    }
}

// MARK: Editing

extension VideoEditProject {
    /// Adds a layout from `time`, in the free space there (segments don't
    /// overlap). `nil` when `time` is inside a segment or there's no room.
    @discardableResult
    public mutating func addCameraLayout(_ layout: CameraLayoutSegment.Layout, at time: Double,
                                         duration: Double = CameraLayoutSegment.defaultDuration) -> CameraLayoutSegment? {
        guard let gap = freeCameraLayoutRange(around: time) else { return nil }
        let start = min(time.clamped(to: gap.start...gap.end), gap.end - CameraLayoutSegment.minimumDuration)
        let segment = CameraLayoutSegment(range: TimeRange(start: start, end: min(gap.end, start + duration)), layout: layout)
        cameraLayouts.append(segment)
        cameraLayouts.sort { $0.range.start < $1.range.start }
        return segment
    }

    /// Replaces the segment with `segment`'s id, kept inside the source and
    /// clear of its neighbors, at least `minimumDuration` long.
    public mutating func updateCameraLayout(_ segment: CameraLayoutSegment) {
        guard let index = cameraLayouts.firstIndex(where: { $0.id == segment.id }) else { return }
        let (lower, upper) = cameraLayoutBounds(of: cameraLayouts[index])
        let minimum = min(CameraLayoutSegment.minimumDuration, upper - lower)
        var updated = segment
        updated.range.start = updated.range.start.clamped(to: lower...(upper - minimum))
        updated.range.end = updated.range.end.clamped(to: (updated.range.start + minimum)...upper)
        cameraLayouts[index] = updated
    }

    /// Moves a segment by `shift` seconds as a whole, stopping at its
    /// neighbors and the ends of the source.
    public mutating func moveCameraLayout(_ segment: CameraLayoutSegment, by shift: Double) {
        guard let index = cameraLayouts.firstIndex(where: { $0.id == segment.id }) else { return }
        let (lower, upper) = cameraLayoutBounds(of: segment)
        let clamped = shift.clamped(to: (lower - segment.range.start)...max(lower - segment.range.start, upper - segment.range.end))
        cameraLayouts[index].range = TimeRange(start: segment.range.start + clamped, end: segment.range.end + clamped)
    }

    public mutating func removeCameraLayout(id: CameraLayoutSegment.ID) {
        cameraLayouts.removeAll { $0.id == id }
    }

    /// Where `segment` may extend to: its neighbors' edges, or the source's.
    private func cameraLayoutBounds(of segment: CameraLayoutSegment) -> (lower: Double, upper: Double) {
        let others = cameraLayouts.filter { $0.id != segment.id }
        let lower = others.map(\.range.end).filter { $0 <= segment.range.start + 1e-9 }.max() ?? 0
        let upper = others.map(\.range.start).filter { $0 >= segment.range.end - 1e-9 }.min() ?? sourceDuration
        return (lower, max(lower, upper))
    }

    /// The free stretch (no layout) containing `time`, or `nil` if `time` is
    /// inside a segment or the stretch is too short for one.
    func freeCameraLayoutRange(around time: Double) -> TimeRange? {
        if cameraLayouts.contains(where: { time >= $0.range.start && time < $0.range.end }) { return nil }
        let start = cameraLayouts.map(\.range.end).filter { $0 <= time }.max() ?? 0
        let end = cameraLayouts.map(\.range.start).filter { $0 > time }.min() ?? sourceDuration
        return end - start >= CameraLayoutSegment.minimumDuration ? TimeRange(start: start, end: end) : nil
    }
}
