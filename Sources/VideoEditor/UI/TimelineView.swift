import AppCore
import AutoEdit
import AVFoundation
import DesignSystem
import SwiftUI

/// Maps source seconds ↔ x positions across the timeline's width, for the
/// part of the source on screen (`start` and `span`, VE-16).
struct TimelineScale {
    var duration: Double
    var width: CGFloat
    var inset: CGFloat
    /// Source seconds at the left edge of the lanes.
    var start: Double = 0
    /// Seconds across the lanes (`duration` when not zoomed).
    var span: Double

    init(duration: Double, width: CGFloat, inset: CGFloat, viewport: TimelineViewport = TimelineViewport()) {
        self.duration = duration
        self.width = width
        self.inset = inset
        start = viewport.start
        span = viewport.span(duration: duration)
    }

    var usableWidth: CGFloat { max(1, width - 2 * inset) }
    var end: Double { start + span }
    /// Points per second.
    var density: CGFloat { span > 0 ? usableWidth / CGFloat(span) : 0 }

    func x(_ time: Double) -> CGFloat {
        guard span > 0 else { return inset }
        return inset + CGFloat((time - start) / span) * usableWidth
    }

    func time(_ x: CGFloat) -> Double {
        guard span > 0 else { return 0 }
        return (start + Double((x - inset) / usableWidth) * span).clamped(to: 0...duration)
    }

    /// Seconds for a horizontal distance (drags).
    func seconds(_ distance: CGFloat) -> Double {
        density > 0 ? Double(distance / density) : 0
    }

    func width(_ range: TimeRange) -> CGFloat {
        x(range.end) - x(range.start)
    }

    func isVisible(_ time: Double) -> Bool {
        time >= start - 1e-6 && time <= end + 1e-6
    }

    func isVisible(_ range: TimeRange) -> Bool {
        range.end >= start && range.start <= end
    }

    /// Where a lane draws a block for `range`, cut a little past the lane's
    /// ends: zoomed in, a block can run far off screen, and drawn whole it
    /// would be thousands of points wide (VE-16).
    func block(_ range: TimeRange, minimumWidth: CGFloat = 0) -> LaneBlock {
        let margin: CGFloat = 24
        let left = x(range.start), right = x(range.end)
        let shownLeft = max(left, inset - margin)
        let shownRight = min(right, inset + usableWidth + margin)
        return LaneBlock(
            x: shownLeft,
            width: max(minimumWidth, shownRight - shownLeft),
            hidden: max(0, inset - shownLeft),
            showsStart: left >= inset - 0.5,
            showsEnd: right <= inset + usableWidth + 0.5
        )
    }
}

/// A block as drawn on a lane (`TimelineScale.block`).
struct LaneBlock: Equatable {
    var x: CGFloat
    var width: CGFloat
    /// How much of its left side is off the lane: labels move past it.
    var hidden: CGFloat
    /// Whether its ends are on screen, and so get grips.
    var showsStart: Bool
    var showsEnd: Bool

    /// The part on the lane.
    var visibleWidth: CGFloat { width - hidden }
}

/// Hides what a zoomed lane draws past its ends. Unzoomed, `pad` leaves
/// room for grips that stick out at the ends; zoomed, items are cut
/// cleanly at the lane's edge.
private struct LaneMask: View {
    let scale: TimelineScale
    var pad: CGFloat = 8

    var body: some View {
        let pad = scale.span < scale.duration - 1e-9 ? 0 : pad
        Rectangle()
            .frame(width: scale.usableWidth + 2 * pad)
            .offset(x: scale.inset - pad)
    }
}

/// The editor timeline (VE-1…VE-4): ruler with speed changes, filmstrip with
/// trim handles, cuts and range selection, zoom lane, and one waveform lane
/// per audio track. It always shows the whole **source**; removed parts are
/// dimmed or hatched rather than collapsed, so edits stay easy to undo.
struct TimelineView: View {
    @Bindable var model: VideoEditorModel

    /// Coordinate space for drags whose view moves while dragging (handles).
    static let space = "timeline"
    static let inset: CGFloat = 16
    static let rulerHeight: CGFloat = 22
    static let filmstripHeight: CGFloat = 56
    static let zoomLaneHeight: CGFloat = 30
    static let cameraLaneHeight: CGFloat = 30
    static let audioLaneHeight: CGFloat = 34
    static let autoEditLaneHeight: CGFloat = 22
    static let scrollerHeight: CGFloat = 8

    private var hasCameraLane: Bool { model.media?.camera != nil }

    private var totalHeight: CGFloat {
        let audio = CGFloat(model.visibleAudioTracks.count)
        let autoEdit: CGFloat = model.project.autoEdit == nil ? 0 : 1
        let camera: CGFloat = hasCameraLane ? 1 : 0
        let lanes = Self.rulerHeight + Self.filmstripHeight + Self.zoomLaneHeight + audio * Self.audioLaneHeight
            + autoEdit * Self.autoEditLaneHeight + camera * Self.cameraLaneHeight + Self.scrollerHeight
        return lanes + PK.Spacing.xs * (3 + audio + autoEdit + camera)
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = TimelineScale(duration: model.duration, width: geometry.size.width, inset: Self.inset,
                                      viewport: model.timelineViewport)
            // Leading-aligned and exactly as wide as the timeline, so a lane
            // drawing past its ends can't center (shift) the others.
            VStack(alignment: .leading, spacing: PK.Spacing.xs) {
                RulerLane(model: model, scale: scale)
                    .frame(height: Self.rulerHeight)
                FilmstripLane(model: model, scale: scale)
                    .frame(height: Self.filmstripHeight)
                if let layer = model.project.autoEdit {
                    AutoEditLane(model: model, layer: layer, scale: scale)
                        .frame(height: Self.autoEditLaneHeight)
                }
                ZoomLane(model: model, scale: scale)
                    .frame(height: Self.zoomLaneHeight)
                if hasCameraLane {
                    CameraLayoutLane(model: model, scale: scale)
                        .frame(height: Self.cameraLaneHeight)
                }
                ForEach(model.visibleAudioTracks) { track in
                    WaveformLane(model: model, scale: scale, track: track)
                        .frame(height: Self.audioLaneHeight)
                }
                TimelineScroller(model: model, scale: scale)
                    .frame(height: Self.scrollerHeight)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                Playhead(model: model, scale: scale, height: geometry.size.height - Self.scrollerHeight - PK.Spacing.xs)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named(Self.space))
            .clipped()
            .background {
                ScrollWheelCatcher { event, x in handleScroll(event, x: x, scale: scale) }
            }
        }
        .frame(height: totalHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
        .accessibilityValue(model.timelineViewport.isZoomed ? String(format: "Zoomed in %.1f times", model.timelineViewport.zoom) : "")
        .accessibilityAction(named: "Zoom In") { model.zoomTimeline(by: 1.5) }
        .accessibilityAction(named: "Zoom Out") { model.zoomTimeline(by: 1 / 1.5) }
        .accessibilityAction(named: "Zoom to Fit") { model.fitTimeline() }
    }

    /// ⌘-scroll (or pinch) zooms around the pointer; once zoomed, plain
    /// scrolling pans (VE-16). Returns whether the event was used.
    private func handleScroll(_ event: NSEvent, x: CGFloat, scale: TimelineScale) -> Bool {
        let anchor = scale.time(x)
        switch event.type {
        case .magnify:
            model.zoomTimeline(by: 1 + Double(event.magnification), around: anchor)
            return true
        case .scrollWheel:
            let precise = event.hasPreciseScrollingDeltas
            if event.modifierFlags.contains(.command) {
                // The way the fingers or wheel moved, whatever the scrolling
                // direction setting: away from you zooms in.
                let delta = Double(event.scrollingDeltaY) * (event.isDirectionInvertedFromDevice ? -1 : 1)
                guard delta != 0 else { return true }
                model.zoomTimeline(by: exp(delta * (precise ? 0.01 : 0.15)), around: anchor)
                return true
            }
            guard model.timelineViewport.isZoomed else { return false }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let delta = abs(dx) >= abs(dy) ? dx : dy
            guard delta != 0 else { return true }
            model.panTimeline(by: -scale.seconds(delta * (precise ? 1 : 16)))
            return true
        default:
            return false
        }
    }
}

/// Where the zoomed timeline is within the whole source: drag the thumb or
/// click the track to scroll (VE-16). Empty when the whole source shows.
private struct TimelineScroller: View {
    @Bindable var model: VideoEditorModel
    let scale: TimelineScale

    @State private var dragStart: Double?

    var body: some View {
        let viewport = model.timelineViewport
        if viewport.isZoomed, model.duration > 0 {
            let track = scale.usableWidth
            let thumbWidth = max(24, track * CGFloat(scale.span / model.duration))
            let travel = max(1, track - thumbWidth)
            let maxStart = max(0.001, model.duration - scale.span)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let fraction = Double((location.x - thumbWidth / 2) / travel).clamped(to: 0...1)
                        model.scrollTimeline(toStart: fraction * maxStart)
                    }
                Capsule()
                    .fill(.secondary)
                    .frame(width: thumbWidth)
                    .offset(x: CGFloat(viewport.start / maxStart) * travel)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStart == nil { dragStart = model.timelineViewport.start }
                                guard let dragStart else { return }
                                model.scrollTimeline(toStart: dragStart + Double(value.translation.width / travel) * maxStart)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .frame(width: track, height: 6)
            .padding(.leading, scale.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel("Timeline scroller")
            .accessibilityValue("\(Format.time(scale.start)) to \(Format.time(scale.end))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.panTimeline(by: scale.span * 0.5)
                case .decrement: model.panTimeline(by: -scale.span * 0.5)
                @unknown default: break
                }
            }
        }
    }
}

/// Hands scroll-wheel and pinch events over the timeline to `handler`
/// (SwiftUI has no modifier-aware scroll-wheel hook). A local monitor
/// rather than an overlay, so clicks and drags still reach the lanes.
private struct ScrollWheelCatcher: NSViewRepresentable {
    var handler: (NSEvent, CGFloat) -> Bool

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handler = handler
    }

    final class CatcherView: NSView {
        var handler: ((NSEvent, CGFloat) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            // Local monitors run on the main thread, inside the app's event loop.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.attachedSheet == nil else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), let handler = self.handler else { return event }
                return handler(event, point.x) ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Only this view reads `playhead`, so playback (30 updates/s) doesn't
/// re-evaluate the lanes.
private struct Playhead: View {
    let model: VideoEditorModel
    let scale: TimelineScale
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .frame(width: 12, height: 10)
            Rectangle()
                .frame(width: 2, height: max(0, height - 10))
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 12)
        .offset(x: scale.x(model.playhead) - 6)
        // Off screen while zoomed elsewhere.
        .opacity(model.playhead >= scale.start - 1e-6 && model.playhead <= scale.end + 1e-6 ? 1 : 0)
    }
}

// MARK: Ruler

private struct RulerLane: View {
    @Bindable var model: VideoEditorModel
    let scale: TimelineScale

    var body: some View {
        Canvas { context, size in
            guard model.duration > 0 else { return }
            let step = Self.tickStep(duration: scale.span, width: scale.usableWidth)
            var time = (scale.start / step).rounded(.down) * step
            let last = min(model.duration, scale.end)
            while time <= last + 1e-9 {
                let x = scale.x(time)
                context.fill(Path(CGRect(x: x - 0.5, y: size.height - 6, width: 1, height: 6)), with: .style(.secondary))
                let label = context.resolve(
                    Text(Format.time(time, precise: step < 1)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                )
                if x + 3 + label.measure(in: size).width <= size.width {
                    context.draw(label, at: CGPoint(x: x + 3, y: 1), anchor: .topLeading)
                }
                let minor = step / 2
                if time + minor <= last {
                    let mx = scale.x(time + minor)
                    context.fill(Path(CGRect(x: mx - 0.5, y: size.height - 3, width: 1, height: 3)), with: .style(.tertiary))
                }
                time += step
            }
            // Speed changes (VE-11).
            for segment in model.project.speedSegments where segment.range.end >= scale.start && segment.range.start <= scale.end {
                let rect = CGRect(x: scale.x(segment.range.start), y: size.height - 9, width: scale.width(segment.range), height: 8)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.orange.opacity(0.85)))
                if rect.width > 24 {
                    context.draw(
                        Text(Format.rate(segment.rate)).font(.system(size: 8, weight: .bold)).foregroundStyle(.white),
                        at: CGPoint(x: rect.midX, y: rect.midY)
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { model.seek(toSource: scale.time($0.location.x)) }
        )
        .accessibilityLabel("Time ruler")
        .accessibilityHint("Drag to scrub")
    }

    /// A "nice" tick interval that keeps labels roughly 80 pt apart.
    static func tickStep(duration: Double, width: CGFloat) -> Double {
        let target = duration / Double(max(1, width / 80))
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        return steps.first { $0 >= target } ?? 3600
    }
}

// MARK: Filmstrip, trim, cuts, selection

private struct FilmstripLane: View {
    @Bindable var model: VideoEditorModel
    let scale: TimelineScale

    @State private var dragOrigin: Double?
    @State private var trimDragStart: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            laneContent
                .mask(alignment: .topLeading) { LaneMask(scale: scale, pad: CutEdgeHandle.width) }

            let trim = model.project.trim
            if scale.isVisible(trim.start) {
                TrimHandle(edge: .leading)
                    .offset(x: scale.x(trim.start) - TrimHandle.width)
                    .gesture(trimGesture(isStart: true))
            }
            if scale.isVisible(trim.end) {
                TrimHandle(edge: .trailing)
                    .offset(x: scale.x(trim.end))
                    .gesture(trimGesture(isStart: false))
            }
        }
        .contentShape(Rectangle())
        .gesture(selectGesture)
        .accessibilityLabel("Filmstrip")
        .accessibilityHint("Drag to select a range. Click to move the playhead and, once split, select a segment.")
    }

    @ViewBuilder private var laneContent: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let lane = CGRect(x: scale.inset, y: 0, width: scale.usableWidth, height: size.height)
                let shape = Path(roundedRect: lane, cornerRadius: PK.Radius.control)
                context.fill(shape, with: .style(.quaternary))
                context.clip(to: shape)
                drawFrames(in: &context, lane: lane)
                drawRemovedParts(in: &context, lane: lane)
                drawAutoEditCuts(in: &context, lane: lane)
            }

            ForEach(model.project.cuts.filter(scale.isVisible), id: \.self) { cut in
                let shown = scale.block(cut, minimumWidth: 2)
                CutMarker(isSelected: model.selectedCut == cut, hatchPhase: shown.x - scale.x(cut.start))
                    .frame(width: shown.width, height: TimelineView.filmstripHeight)
                    .offset(x: shown.x)
                    .allowsHitTesting(false)
            }

            // The selected cut's edges move (AE-8).
            if let cut = model.selectedCut {
                if scale.isVisible(cut.start) {
                    CutEdgeHandle()
                        .offset(x: scale.x(cut.start) - CutEdgeHandle.width / 2)
                        .gesture(cutEdgeGesture(cut, isStart: true))
                        .accessibilityLabel("Cut start")
                }
                if scale.isVisible(cut.end) {
                    CutEdgeHandle()
                        .offset(x: scale.x(cut.end) - CutEdgeHandle.width / 2)
                        .gesture(cutEdgeGesture(cut, isStart: false))
                        .accessibilityLabel("Cut end")
                }
            }

            if let selection = model.selection, scale.isVisible(selection) {
                let shown = scale.block(selection, minimumWidth: 2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.22))
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .frame(width: shown.width, height: TimelineView.filmstripHeight)
                    .offset(x: shown.x)
                    .allowsHitTesting(false)
            }

            ForEach(model.project.visibleSplits.filter(scale.isVisible), id: \.self) { split in
                SplitMarker()
                    .offset(x: scale.x(split) - SplitMarker.width / 2)
                    .allowsHitTesting(false)
            }

            // Kept-range frame between the handles, limited to what's on
            // screen so a zoomed-in frame isn't thousands of points wide.
            let trim = model.project.trim
            let left = max(scale.x(trim.start), scale.inset - 4)
            let right = min(scale.x(trim.end), scale.inset + scale.usableWidth + 4)
            if right > left {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: max(2, right - left), height: TimelineView.filmstripHeight)
                    .offset(x: left)
                    .allowsHitTesting(false)
            }
        }
    }

    private func drawFrames(in context: inout GraphicsContext, lane: CGRect) {
        let frames = model.filmstrip
        guard !frames.isEmpty, let first = frames.first else { return }
        let aspect = CGFloat(first.image.width) / CGFloat(max(1, first.image.height))
        let tileWidth = max(8, lane.height * aspect)
        // Tiles sit at fixed times, so they scroll with the footage.
        var x = lane.minX - (lane.minX - scale.x(0)).truncatingRemainder(dividingBy: tileWidth)
        while x < lane.maxX {
            let time = scale.time(x + tileWidth / 2)
            let frame = frames.min { abs($0.time - time) < abs($1.time - time) } ?? first
            context.draw(Image(decorative: frame.image, scale: 1), in: CGRect(x: x, y: 0, width: tileWidth, height: lane.height))
            x += tileWidth
        }
    }

    /// Auto-edit's removals: dimmed, without the user cuts' hatching, so the
    /// two layers stay distinguishable (AE-7).
    private func drawAutoEditCuts(in context: inout GraphicsContext, lane: CGRect) {
        // Only what the timeline actually removes (auto-edit is ignored when
        // it would leave almost nothing).
        let project = model.project
        guard let auto = project.autoEdit?.cuts, !auto.isEmpty, project.effectiveCuts != project.cuts else { return }
        let cuts = auto
        let dim = GraphicsContext.Shading.color(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        for cut in cuts where scale.isVisible(cut) {
            context.fill(Path(CGRect(x: scale.x(cut.start), y: 0, width: max(1, scale.width(cut)), height: lane.height)), with: dim)
        }
    }

    private func drawRemovedParts(in context: inout GraphicsContext, lane: CGRect) {
        let trim = model.project.trim
        let dim = GraphicsContext.Shading.color(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        context.fill(Path(CGRect(x: lane.minX, y: 0, width: scale.x(trim.start) - lane.minX, height: lane.height)), with: dim)
        context.fill(Path(CGRect(x: scale.x(trim.end), y: 0, width: lane.maxX - scale.x(trim.end), height: lane.height)), with: dim)
    }

    @State private var cutDrag: (original: TimeRange, current: TimeRange)?

    private func cutEdgeGesture(_ cut: TimeRange, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineView.space))
            .onChanged { value in
                if cutDrag == nil {
                    cutDrag = (cut, cut)
                    model.beginContinuousEdit()
                }
                guard let drag = cutDrag else { return }
                let edge = isStart ? drag.original.start : drag.original.end
                let time = scale.time(scale.x(edge) + value.translation.width)
                model.moveCutEdge(drag.current, start: isStart, to: time)
                if let selected = model.selectedCut { cutDrag?.current = selected }
            }
            .onEnded { _ in
                cutDrag = nil
                model.endContinuousEdit()
            }
    }

    /// Moves the edge by the drag's translation from where it was grabbed, so
    /// a click on the handle doesn't jump the trim to the pointer.
    private func trimGesture(isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineView.space))
            .onChanged { value in
                if trimDragStart == nil {
                    trimDragStart = isStart ? model.project.trim.start : model.project.trim.end
                    model.beginContinuousEdit()
                }
                guard let start = trimDragStart else { return }
                let time = scale.time(scale.x(start) + value.translation.width)
                model.edit { isStart ? $0.setTrimStart(time) : $0.setTrimEnd(time) }
            }
            .onEnded { _ in
                trimDragStart = nil
                model.endContinuousEdit()
            }
    }

    private var selectGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if abs(value.translation.width) < 3 { return }
                let start = dragOrigin ?? scale.time(value.startLocation.x)
                dragOrigin = start
                let current = scale.time(value.location.x)
                model.selectedCut = nil
                model.selectedZoomID = nil
                model.selectedAutoItem = nil
                model.selection = TimeRange(start: min(start, current), end: max(start, current))
            }
            .onEnded { value in
                defer { dragOrigin = nil }
                guard abs(value.translation.width) < 3 else { return }
                // A click: select the cut under the pointer, or move the
                // playhead (and select the segment there, once split).
                let time = scale.time(value.location.x)
                model.selection = nil
                model.selectedZoomID = nil
                model.selectedAutoItem = nil
                if let cut = model.project.cuts.first(where: { $0.contains(time) }) {
                    model.selectedCut = cut
                    model.inspectorSection = .cuts
                } else {
                    model.selectedCut = nil
                    model.seek(toSource: time)
                    model.selectSegment(at: time)
                }
            }
    }
}

/// Where the footage was split (VE-3): a bright line across the filmstrip.
private struct SplitMarker: View {
    static let width: CGFloat = 3

    var body: some View {
        // Content over arbitrary video frames: fixed light line with a dark edge.
        Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.35), lineWidth: PK.Metrics.hairline))
            .frame(width: Self.width, height: TimelineView.filmstripHeight)
            .accessibilityHidden(true)
    }
}

/// Removed segment: hatched, tinted red.
private struct CutMarker: View {
    let isSelected: Bool
    /// How far right of the cut's start the marker begins (when its start
    /// is off screen), so the hatching scrolls with the footage.
    var hatchPhase: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.75)))
            context.fill(Path(rect), with: .color(.red.opacity(0.18)))
            var hatch = Path()
            var x = -size.height - hatchPhase.truncatingRemainder(dividingBy: 7)
            while x < size.width {
                hatch.move(to: CGPoint(x: x, y: size.height))
                hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            context.clip(to: Path(rect))
            context.stroke(hatch, with: .color(.red.opacity(0.55)), lineWidth: 1)
        }
        .overlay(Rectangle().strokeBorder(Color.red.opacity(isSelected ? 1 : 0.6), lineWidth: isSelected ? 2 : 1))
        .overlay {
            Image(systemName: "scissors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
}

private struct TrimHandle: View {
    enum Edge { case leading, trailing }
    static let width: CGFloat = 12
    let edge: Edge

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? PK.Radius.control : 0,
            bottomLeadingRadius: edge == .leading ? PK.Radius.control : 0,
            bottomTrailingRadius: edge == .trailing ? PK.Radius.control : 0,
            topTrailingRadius: edge == .trailing ? PK.Radius.control : 0,
            style: .continuous
        )
        .fill(Color.accentColor)
        .overlay {
            Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
        }
        .frame(width: Self.width, height: TimelineView.filmstripHeight)
        .contentShape(Rectangle().inset(by: -4))
        .pointerStyle(.columnResize)
        .accessibilityLabel(edge == .leading ? "Trim start" : "Trim end")
    }
}

/// Grip on an edge of the selected cut: drag to resize it (AE-8).
private struct CutEdgeHandle: View {
    static let width: CGFloat = 8

    var body: some View {
        Capsule()
            .fill(Color.red)
            .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1.5))
            .frame(width: Self.width, height: TimelineView.filmstripHeight - 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
    }
}

// MARK: Auto-edit lane

/// Auto-edit's suggestions (PRD AE-7): one block per removal or shortened
/// pause, tinted by group; off ones are outlined. Click to select and
/// review; drag the selected block's edges to adjust it (AE-8).
private struct AutoEditLane: View {
    @Bindable var model: VideoEditorModel
    let layer: AutoEditLayer
    let scale: TimelineScale

    @State private var drag: (item: AutoEditItem, original: TimeRange)?

    private struct Block: Identifiable {
        var item: AutoEditItem
        var range: TimeRange
        var group: AutoEditGroup
        var applies: Bool
        var id: AutoEditItem { item }
    }

    private var blocks: [Block] {
        var blocks: [Block] = layer.pauses.compactMap { pause in
            guard let cut = pause.cut(pacing: layer.pacing) else { return nil }
            return Block(item: .pause(pause.id), range: cut, group: .pauses, applies: layer.groups.contains(.pauses))
        }
        blocks += layer.removals.map { removal in
            Block(item: .removal(removal.id), range: removal.range, group: removal.group,
                  applies: removal.isEnabled && layer.groups.contains(removal.group))
        }
        return blocks
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                .fill(.quaternary.opacity(0.4))
                .frame(width: scale.usableWidth, height: TimelineView.autoEditLaneHeight)
                .offset(x: scale.inset)
                .onTapGesture { model.selectedAutoItem = nil }

            ForEach(blocks.filter { scale.isVisible($0.range) }) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mask(alignment: .topLeading) { LaneMask(scale: scale) }
        .accessibilityLabel("Auto-edit suggestions")
    }

    private func blockView(_ block: Block) -> some View {
        let isSelected = model.selectedAutoItem == block.item
        let shown = scale.block(block.range, minimumWidth: 3)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(block.group.color.opacity(block.applies ? (isSelected ? 0.95 : 0.7) : 0.12))
            .strokeBorder(isSelected ? Color.primary : block.group.color.opacity(block.applies ? 0 : 0.7), lineWidth: isSelected ? 1.5 : 1)
            .frame(width: shown.width, height: TimelineView.autoEditLaneHeight - 6)
            .overlay(alignment: .leading) {
                if isSelected, shown.showsStart { edgeHandle(block, isStart: true).offset(x: -4) }
            }
            .overlay(alignment: .trailing) {
                if isSelected, shown.showsEnd { edgeHandle(block, isStart: false).offset(x: 4) }
            }
            .contentShape(Rectangle().inset(by: -2))
            .offset(x: shown.x, y: 3)
            .onTapGesture { model.selectAutoItem(block.item) }
            .help(help(for: block))
            .accessibilityElement()
            .accessibilityLabel("\(block.group.title) at \(Format.time(block.range.start))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selectAutoItem(block.item) }
            .accessibilityAction(named: "Restore") { model.restoreAutoItem(block.item) }
    }

    private func help(for block: Block) -> String {
        switch block.item {
        case .pause(let id):
            let kind = layer.pauses.first { $0.id == id }?.pause.kind.title ?? "Pause"
            return "\(kind): shortened. Drag the ends to adjust; ⌫ keeps it as is."
        case .removal(let id):
            guard let removal = layer.removals.first(where: { $0.id == id }) else { return "" }
            return "\(removal.suggestion.kind.title): \(removal.suggestion.reason). ⌫ keeps it."
        }
    }

    private func edgeHandle(_ block: Block, isStart: Bool) -> some View {
        Capsule()
            .fill(Color.white)
            .overlay(Capsule().strokeBorder(block.group.color, lineWidth: 1.5))
            .frame(width: 7, height: TimelineView.autoEditLaneHeight - 4)
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineView.space))
                    .onChanged { value in
                        if drag == nil {
                            drag = (block.item, block.range)
                            model.beginContinuousEdit()
                        }
                        guard let drag else { return }
                        let edge = isStart ? drag.original.start : drag.original.end
                        model.moveAutoItemEdge(drag.item, start: isStart, to: scale.time(scale.x(edge) + value.translation.width))
                    }
                    .onEnded { _ in
                        drag = nil
                        model.endContinuousEdit()
                    }
            )
            .accessibilityLabel(isStart ? "Suggestion start" : "Suggestion end")
    }
}

// MARK: Zoom lane

private struct ZoomLane: View {
    @Bindable var model: VideoEditorModel
    let scale: TimelineScale

    @State private var dragStart: ZoomSegment?
    @State private var hoveredZoomID: ZoomSegment.ID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                .fill(.quaternary.opacity(0.6))
                .frame(width: scale.usableWidth, height: TimelineView.zoomLaneHeight)
                .offset(x: scale.inset)
                .overlay(alignment: .leading) {
                    if model.project.zooms.isEmpty {
                        Label("Zoom — add one at the playhead", systemImage: "plus.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, scale.inset + PK.Spacing.s)
                            .allowsHitTesting(false)
                    }
                }
                .onTapGesture(count: 2) { model.addZoomAtPlayhead() }
                .onTapGesture { model.selectedZoomID = nil }

            ForEach(model.project.zooms.filter { scale.isVisible($0.range) }) { zoom in
                zoomBlock(zoom)
            }
        }
        // Full width, leading-aligned: the timeline's VStack would otherwise
        // center this lane and shift every block off its time by the inset.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mask(alignment: .topLeading) { LaneMask(scale: scale) }
        .accessibilityLabel("Zoom segments")
    }

    private func zoomBlock(_ zoom: ZoomSegment) -> some View {
        let isSelected = model.selectedZoomID == zoom.id
        let isActive = isSelected || hoveredZoomID == zoom.id
        let shown = scale.block(zoom.range, minimumWidth: EdgeHandle.width * 2)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.purple.opacity(isSelected ? 0.95 : 0.6))
            .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2)
            .overlay(alignment: .leading) {
                if shown.visibleWidth > 56 {
                    Label(String(format: "%.1f×", zoom.scale), systemImage: zoom.isAutomatic ? "cursorarrow.click" : "plus.magnifyingglass")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.leading, shown.hidden + EdgeHandle.width + PK.Spacing.xxs)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: isSelected ? Color.purple.opacity(0.6) : .clear, radius: 4)
            .frame(width: shown.width, height: TimelineView.zoomLaneHeight - 4)
            // Blocks are never narrower than both grips, so a short zoom can
            // still be resized.
            .overlay(alignment: .leading) {
                if isActive, shown.showsStart { edgeHandle(zoom, isStart: true) }
            }
            .overlay(alignment: .trailing) {
                if isActive, shown.showsEnd { edgeHandle(zoom, isStart: false) }
            }
            .contentShape(Rectangle())
            .offset(x: shown.x, y: 2)
            .onHover { hovering in
                if hovering { hoveredZoomID = zoom.id } else if hoveredZoomID == zoom.id { hoveredZoomID = nil }
            }
            .gesture(moveGesture(zoom))
            .simultaneousGesture(TapGesture().onEnded { select(zoom) })
            .help("Drag to move. Drag the ends to change the duration. ⌫ removes it.")
            .accessibilityElement()
            .accessibilityLabel("Zoom \(String(format: "%.1f", zoom.scale))× from \(Format.time(zoom.range.start)) to \(Format.time(zoom.range.end))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(zoom) }
            .accessibilityAction(named: "Remove") {
                select(zoom)
                model.removeSelectedZoom()
            }
    }

    private func select(_ zoom: ZoomSegment) {
        model.selection = nil
        model.selectedCut = nil
        model.selectedZoomID = zoom.id
        model.inspectorSection = .zoom
        // Show content inside the zoom so its rectangle can be positioned.
        model.seek(toSource: zoom.range.start + min(zoom.easeDuration, zoom.range.duration / 2))
    }

    private func edgeHandle(_ zoom: ZoomSegment, isStart: Bool) -> some View {
        EdgeHandle(isStart: isStart)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineView.space))
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = zoom
                            model.selection = nil
                            model.selectedCut = nil
                            model.selectedZoomID = zoom.id
                            model.inspectorSection = .zoom
                            model.beginContinuousEdit()
                        }
                        guard let start = dragStart else { return }
                        // Relative to where the edge was grabbed (no jump on click).
                        let edge = isStart ? start.range.start : start.range.end
                        let time = scale.time(scale.x(edge) + value.translation.width)
                        var updated = start
                        if isStart {
                            updated.range.start = min(time, start.range.end - ZoomSegment.minimumDuration)
                        } else {
                            updated.range.end = max(time, start.range.start + ZoomSegment.minimumDuration)
                        }
                        updated.isAutomatic = false
                        model.edit { $0.updateZoom(updated) }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        model.endContinuousEdit()
                    }
            )
            .accessibilityLabel(isStart ? "Zoom start" : "Zoom end")
    }

    private func moveGesture(_ zoom: ZoomSegment) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = zoom
                    model.beginContinuousEdit()
                }
                guard let start = dragStart else { return }
                let delta = scale.seconds(value.translation.width)
                let shift = delta.clamped(to: -start.range.start...(model.duration - start.range.end))
                var updated = start
                updated.range = TimeRange(start: start.range.start + shift, end: start.range.end + shift)
                model.edit { $0.updateZoom(updated) }
            }
            .onEnded { _ in
                dragStart = nil
                model.endContinuousEdit()
            }
    }
}

// MARK: Camera layout lane

/// Where the camera fills the frame or is hidden (CAM-6).
private struct CameraLayoutLane: View {
    @Bindable var model: VideoEditorModel
    let scale: TimelineScale

    @State private var dragStart: CameraLayoutSegment?
    @State private var hoveredID: CameraLayoutSegment.ID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                .fill(.quaternary.opacity(0.6))
                .frame(width: scale.usableWidth, height: TimelineView.cameraLaneHeight)
                .offset(x: scale.inset)
                .overlay(alignment: .leading) {
                    if model.project.cameraLayouts.isEmpty {
                        Label("Camera — double-click for Camera Only at the playhead", systemImage: "person.crop.rectangle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, scale.inset + PK.Spacing.s)
                            .allowsHitTesting(false)
                    }
                }
                .onTapGesture(count: 2) { model.addCameraLayoutAtPlayhead(.fullFrame) }
                .onTapGesture { model.selectedCameraLayoutID = nil }

            ForEach(model.project.cameraLayouts.filter { scale.isVisible($0.range) }) { segment in
                block(segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mask(alignment: .topLeading) { LaneMask(scale: scale) }
        .accessibilityLabel("Camera layouts")
    }

    private func color(_ layout: CameraLayoutSegment.Layout) -> Color {
        layout == .fullFrame ? .teal : .gray
    }

    private func block(_ segment: CameraLayoutSegment) -> some View {
        let isSelected = model.selectedCameraLayoutID == segment.id
        let isActive = isSelected || hoveredID == segment.id
        let shown = scale.block(segment.range, minimumWidth: EdgeHandle.width * 2)
        let tint = color(segment.layout)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.opacity(isSelected ? 0.95 : 0.6))
            .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2)
            .overlay(alignment: .leading) {
                if shown.visibleWidth > 56 {
                    Label(segment.layout.title, systemImage: segment.layout.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.leading, shown.hidden + EdgeHandle.width + PK.Spacing.xxs)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: isSelected ? tint.opacity(0.6) : .clear, radius: 4)
            .frame(width: shown.width, height: TimelineView.cameraLaneHeight - 4)
            .overlay(alignment: .leading) {
                if isActive, shown.showsStart { edgeHandle(segment, isStart: true) }
            }
            .overlay(alignment: .trailing) {
                if isActive, shown.showsEnd { edgeHandle(segment, isStart: false) }
            }
            .contentShape(Rectangle())
            .offset(x: shown.x, y: 2)
            .onHover { hovering in
                if hovering { hoveredID = segment.id } else if hoveredID == segment.id { hoveredID = nil }
            }
            .gesture(moveGesture(segment))
            .simultaneousGesture(TapGesture().onEnded { select(segment) })
            .help("Drag to move. Drag the ends to change the duration. ⌫ removes it.")
            .accessibilityElement()
            .accessibilityLabel("\(segment.layout.title) from \(Format.time(segment.range.start)) to \(Format.time(segment.range.end))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(segment) }
            .accessibilityAction(named: "Remove") {
                select(segment)
                model.removeSelectedCameraLayout()
            }
    }

    private func select(_ segment: CameraLayoutSegment) {
        model.selectCameraLayout(segment.id)
        // Show the layout in effect, past its transition.
        model.seek(toSource: segment.range.start + min(CameraLayoutSegment.transition, segment.range.duration / 2))
    }

    private func edgeHandle(_ segment: CameraLayoutSegment, isStart: Bool) -> some View {
        EdgeHandle(isStart: isStart)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineView.space))
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = segment
                            model.selectCameraLayout(segment.id)
                            model.beginContinuousEdit()
                        }
                        guard let start = dragStart else { return }
                        // Relative to where the edge was grabbed (no jump on click).
                        let edge = isStart ? start.range.start : start.range.end
                        let time = scale.time(scale.x(edge) + value.translation.width)
                        var updated = start
                        if isStart {
                            updated.range.start = min(time, start.range.end - CameraLayoutSegment.minimumDuration)
                        } else {
                            updated.range.end = max(time, start.range.start + CameraLayoutSegment.minimumDuration)
                        }
                        model.edit { $0.updateCameraLayout(updated) }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        model.endContinuousEdit()
                    }
            )
            .accessibilityLabel(isStart ? "Layout start" : "Layout end")
    }

    private func moveGesture(_ segment: CameraLayoutSegment) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = segment
                    model.beginContinuousEdit()
                }
                guard let start = dragStart else { return }
                let delta = scale.seconds(value.translation.width)
                model.edit { $0.moveCameraLayout(start, by: delta) }
            }
            .onEnded { _ in
                dragStart = nil
                model.endContinuousEdit()
            }
    }
}

/// Grip at either end of a zoom or layout block: drag to change when it
/// starts or stops.
private struct EdgeHandle: View {
    static let width: CGFloat = 10
    let isStart: Bool

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isStart ? 5 : 0,
            bottomLeadingRadius: isStart ? 5 : 0,
            bottomTrailingRadius: isStart ? 0 : 5,
            topTrailingRadius: isStart ? 0 : 5,
            style: .continuous
        )
        .fill(Color.white)
        .overlay {
            Capsule()
                .fill(Color.purple)
                .frame(width: 2, height: 10)
        }
        .frame(width: Self.width, height: TimelineView.zoomLaneHeight - 4)
        .contentShape(Rectangle().inset(by: -3))
        .pointerStyle(.columnResize)
    }
}

// MARK: Waveforms

private struct WaveformLane: View {
    @Bindable var model: VideoEditorModel
    let scale: TimelineScale
    let track: AudioTrackInfo

    var body: some View {
        let volume = model.project.trackVolumes[track.role]
        Canvas { context, size in
            let lane = CGRect(x: scale.inset, y: 0, width: scale.usableWidth, height: size.height)
            let shape = Path(roundedRect: lane, cornerRadius: PK.Radius.control)
            context.fill(shape, with: .style(.quaternary.opacity(0.6)))
            context.clip(to: shape)
            guard let waveform = model.waveforms[track.trackID], model.duration > 0 else { return }

            let gain = CGFloat(volume.effectiveVolume)
            let mid = size.height / 2
            let column: CGFloat = 2
            var bars = Path()
            var x = lane.minX
            while x < lane.maxX {
                let range = TimeRange(start: scale.time(x), end: scale.time(x + column))
                let peak = CGFloat(waveform.peak(in: range)) * max(gain, 0.15)
                let height = max(1, peak * (size.height - 6))
                bars.addRect(CGRect(x: x, y: mid - height / 2, width: column - 0.5, height: height))
                x += column
            }
            context.fill(bars, with: .style(volume.isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)))

            let trim = model.project.trim
            let dim = GraphicsContext.Shading.color(Color(nsColor: .windowBackgroundColor).opacity(0.7))
            context.fill(Path(CGRect(x: lane.minX, y: 0, width: scale.x(trim.start) - lane.minX, height: size.height)), with: dim)
            context.fill(Path(CGRect(x: scale.x(trim.end), y: 0, width: lane.maxX - scale.x(trim.end), height: size.height)), with: dim)
            for cut in model.project.effectiveCuts {
                context.fill(Path(CGRect(x: scale.x(cut.start), y: 0, width: scale.width(cut), height: size.height)), with: dim)
            }
        }
        .overlay(alignment: .topLeading) {
            Label(track.label, systemImage: volume.isMuted ? "speaker.slash.fill" : (track.role == .microphone ? "mic.fill" : "speaker.wave.2.fill"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, PK.Spacing.xs)
                .padding(.vertical, 1)
                .background(.regularMaterial, in: Capsule())
                .padding(.leading, scale.inset + PK.Spacing.xs)
                .padding(.top, PK.Spacing.xxs)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { location in model.seek(toSource: scale.time(location.x)) }
        .accessibilityLabel("\(track.label) waveform")
    }
}
