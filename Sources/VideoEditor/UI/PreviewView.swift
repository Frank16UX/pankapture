import AVKit
import DesignSystem
import SwiftUI

/// `AVPlayerView` showing the live composition; transport is our own.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        // No Live Text on the preview: it loads Visual Intelligence and
        // analyzes paused frames for nothing.
        view.allowsVideoFrameAnalysis = false
        view.setAccessibilityLabel("Video preview")
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Preview plus, while a zoom segment is selected, a draggable rectangle to
/// set its target area (VE-4).
struct PreviewArea: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        ZStack {
            PlayerSurface(player: model.player)
            if let zoom = model.selectedZoom, let plan = model.previewPlan {
                ZoomRectEditor(model: model, zoom: zoom, plan: plan)
            } else if let camera = model.project.camera, model.isCameraInUsualPlace, let plan = model.previewPlan, plan.camera != nil {
                CameraLayerEditor(model: model, camera: camera, plan: plan)
            }
            if let error = model.loadError {
                ContentUnavailableView("Can't Open Video", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.media == nil {
                LoadingStatus(model: model)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if model.selectedZoomID == nil { model.togglePlayback() } }
    }
}

/// Rectangle editor over the (unzoomed) preview. Move by dragging inside;
/// resize from any corner around the rectangle's center. The rectangle keeps
/// the video's aspect ratio (square in normalized units).
private struct ZoomRectEditor: View {
    @Bindable var model: VideoEditorModel
    let zoom: ZoomSegment
    let plan: RenderPlan

    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let video = videoRect(in: geometry.size)
            let rect = CGRect(
                x: video.minX + zoom.rect.minX * video.width,
                y: video.minY + zoom.rect.minY * video.height,
                width: zoom.rect.width * video.width,
                height: zoom.rect.height * video.height
            )
            ZStack(alignment: .topLeading) {
                // Dim outside the target. Overlay chrome over arbitrary video
                // content uses the fixed overlay tokens (DESIGN §2).
                Path { path in
                    path.addRect(video)
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(PK.Overlay.dimOpacity), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(PK.Overlay.selectionStroke, lineWidth: 1.5)
                    .background(Color.black.opacity(0.001))
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topLeading) {
                        Text(String(format: "%.1f×", zoom.scale))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, PK.Spacing.xs)
                            .padding(.vertical, PK.Spacing.xxs)
                            .background(.regularMaterial, in: Capsule())
                            .padding(PK.Spacing.xs)
                    }
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(moveGesture(video: video))
                    .accessibilityLabel("Zoom area")

                ForEach(Corner.allCases, id: \.self) { corner in
                    let point = corner.point(in: rect)
                    Rectangle()
                        .fill(PK.Overlay.selectionStroke)
                        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.4), lineWidth: PK.Metrics.hairline))
                        .frame(width: PK.Overlay.handleSize + 3, height: PK.Overlay.handleSize + 3)
                        .contentShape(Rectangle().inset(by: -6))
                        .position(point)
                        .gesture(resizeGesture(video: video))
                }
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    private static let space = "zoomRectEditor"

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    /// The video's frame within the view (aspect-fit canvas, then the plan's video rect).
    private func videoRect(in size: CGSize) -> CGRect {
        let canvas = CanvasLayout.aspectFit(plan.renderSize, in: CGRect(origin: .zero, size: size))
        let sx = canvas.width / max(1, plan.renderSize.width)
        let sy = canvas.height / max(1, plan.renderSize.height)
        // `videoRect` is centered, so top-left and bottom-left origins agree.
        return CGRect(
            x: canvas.minX + plan.videoRect.minX * sx,
            y: canvas.minY + plan.videoRect.minY * sy,
            width: plan.videoRect.width * sx,
            height: plan.videoRect.height * sy
        )
    }

    private func moveGesture(video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = zoom.rect
                    model.beginContinuousEdit()
                }
                guard let start = dragStart, video.width > 0, video.height > 0 else { return }
                var updated = zoom
                updated.rect = start.offsetBy(
                    dx: value.translation.width / video.width,
                    dy: value.translation.height / video.height
                )
                updated.isAutomatic = false
                model.edit { $0.updateZoom(updated) }
            }
            .onEnded { _ in
                dragStart = nil
                model.endContinuousEdit()
            }
    }

    private func resizeGesture(video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = zoom.rect
                    model.beginContinuousEdit()
                }
                guard let start = dragStart, video.width > 0, video.height > 0 else { return }
                let point = CGPoint(
                    x: (value.location.x - video.minX) / video.width,
                    y: (value.location.y - video.minY) / video.height
                )
                let center = CGPoint(x: start.midX, y: start.midY)
                let half = max(abs(point.x - center.x), abs(point.y - center.y))
                let scale = (1 / max(0.01, 2 * half)).clamped(to: ZoomSegment.scaleRange)
                var updated = zoom
                updated.rect = ZoomSegment.rect(center: center, scale: scale)
                updated.isAutomatic = false
                model.edit { $0.updateZoom(updated) }
            }
            .onEnded { _ in
                dragStart = nil
                model.endContinuousEdit()
            }
    }
}

/// Drag the webcam layer to move it; drag its corner grip to resize (ADR-25).
private struct CameraLayerEditor: View {
    @Bindable var model: VideoEditorModel
    let camera: CameraOverlay
    let plan: RenderPlan

    @State private var dragStart: CameraOverlay?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let canvas = CanvasLayout.aspectFit(plan.renderSize, in: CGRect(origin: .zero, size: geometry.size))
            let scale = canvas.width / max(1, plan.renderSize.width)
            let pixels = camera.frame(video: plan.videoRect, canvas: CGRect(origin: .zero, size: plan.renderSize))
            let rect = CGRect(x: canvas.minX + pixels.minX * scale, y: canvas.minY + pixels.minY * scale,
                              width: pixels.width * scale, height: pixels.height * scale)
            let shape = RoundedRectangle(cornerRadius: camera.cornerRadius(for: rect.size))
            ZStack(alignment: .topLeading) {
                shape
                    // Overlay chrome over arbitrary video: fixed overlay tokens (DESIGN §2).
                    .strokeBorder(PK.Overlay.selectionStroke.opacity(isHovering || dragStart != nil ? 0.9 : 0), lineWidth: 1.5)
                    .contentShape(shape)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .onHover { isHovering = $0 }
                    .pointerStyle(.grabActive)
                    .gesture(moveGesture(scale: scale))
                    .help("Drag to move the camera")
                    .accessibilityLabel("Camera")
                    .accessibilityHint("Drag to move")

                Circle()
                    .fill(PK.Overlay.selectionStroke)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: PK.Metrics.hairline))
                    .frame(width: PK.Overlay.handleSize + 5, height: PK.Overlay.handleSize + 5)
                    .contentShape(Circle().inset(by: -6))
                    .position(x: rect.maxX - rect.width * 0.15, y: rect.maxY - rect.height * 0.15)
                    .opacity(isHovering || dragStart != nil ? 1 : 0.6)
                    .pointerStyle(.frameResize(position: .bottomTrailing))
                    .gesture(resizeGesture(canvas: canvas, scale: scale))
                    .help("Drag to resize the camera")
                    .accessibilityLabel("Camera size")
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    private static let space = "cameraLayerEditor"

    private func moveGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = camera
                    model.beginContinuousEdit()
                }
                guard let start = dragStart, scale > 0 else { return }
                let pixels = start.frame(video: plan.videoRect, canvas: CGRect(origin: .zero, size: plan.renderSize))
                var updated = start
                updated.setCenter(
                    CGPoint(x: pixels.midX + value.translation.width / scale, y: pixels.midY + value.translation.height / scale),
                    video: plan.videoRect
                )
                model.edit { $0.camera = updated }
            }
            .onEnded { _ in
                dragStart = nil
                model.endContinuousEdit()
            }
    }

    private func resizeGesture(canvas: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = camera
                    model.beginContinuousEdit()
                }
                guard let start = dragStart, scale > 0 else { return }
                let pixels = start.frame(video: plan.videoRect, canvas: CGRect(origin: .zero, size: plan.renderSize))
                let pointer = CGPoint(x: (value.location.x - canvas.minX) / scale, y: (value.location.y - canvas.minY) / scale)
                let aspect = CGFloat(start.shape.aspect)
                // The grip sits 0.35 × the width from the center (see `position`).
                let width = max(abs(pointer.x - pixels.midX), abs(pointer.y - pixels.midY) * aspect) / 0.35
                var updated = start
                updated.size = Double(width / max(1, min(plan.videoRect.width, plan.videoRect.height)))
                    .clamped(to: CameraOverlay.sizeRange)
                model.edit { $0.camera = updated }
            }
            .onEnded { _ in
                dragStart = nil
                model.endContinuousEdit()
            }
    }
}

/// Play/pause, time, and quick actions under the preview.
struct TransportBar: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        HStack(spacing: PK.Spacing.s) {
            Button { model.seek(toSource: model.project.trim.start) } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(PKToolButtonStyle())
            .help("Go to Start")
            .accessibilityLabel("Go to start")

            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(PKToolButtonStyle())
            .help(model.isPlaying ? "Pause — Space" : "Play — Space")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Text("\(Format.time(model.timeline.nearestOutputTime(forSource: model.playhead))) / \(Format.time(model.outputDuration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Position")

            Spacer(minLength: PK.Spacing.s)

            if let selection = model.selection {
                Text("Selected \(Format.time(selection.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Delete", systemImage: "trash", action: model.cutSelection)
                    .help("Remove the selected part — ⌫")
            } else if let cut = model.selectedCut {
                Button("Restore Cut", systemImage: "arrow.uturn.backward") { model.removeCut(cut) }
                    .help("Restore the removed part — ⌫")
            }

            Button("Split", systemImage: "scissors", action: model.splitAtPlayhead)
                .help("Split at Playhead — S. Click a part to select it, then press ⌫ to remove it.")

            Divider().frame(height: 16)

            Button("Set In", systemImage: "arrow.right.to.line", action: model.setTrimInAtPlayhead)
                .labelStyle(.iconOnly)
                .buttonStyle(PKToolButtonStyle())
                .help("Trim Start at Playhead — I")
            Button("Set Out", systemImage: "arrow.left.to.line", action: model.setTrimOutAtPlayhead)
                .labelStyle(.iconOnly)
                .buttonStyle(PKToolButtonStyle())
                .help("Trim End at Playhead — O")

            Divider().frame(height: 16)

            TimelineZoomControl(model: model)
        }
        .controlSize(.small)
    }
}

/// Timeline zoom (VE-16): out, a slider, in, and fit. ⌘-scroll or pinch
/// over the timeline does the same around the pointer.
private struct TimelineZoomControl: View {
    @Bindable var model: VideoEditorModel

    /// The slider moves on a log scale, so each step zooms by the same factor.
    private var position: Binding<Double> {
        Binding {
            let maximum = TimelineViewport.maximumZoom(duration: model.duration)
            return maximum > 1 ? log(model.timelineViewport.zoom) / log(maximum) : 0
        } set: { value in
            let maximum = TimelineViewport.maximumZoom(duration: model.duration)
            model.setTimelineZoom(exp(value * log(maximum)))
        }
    }

    var body: some View {
        let viewport = model.timelineViewport
        let canZoom = TimelineViewport.maximumZoom(duration: model.duration) > 1
        HStack(spacing: PK.Spacing.xxs) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoomTimeline(by: 1 / 1.5) }
                .disabled(!viewport.isZoomed)
                .help("Zoom Out the Timeline — ⌘−")
            Slider(value: position, in: 0...1)
                .frame(width: 80)
                .accessibilityLabel("Timeline zoom")
                .accessibilityValue(String(format: "%.1f×", viewport.zoom))
                .help("Zoom the timeline. ⌘-scroll or pinch over it to zoom around the pointer.")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoomTimeline(by: 1.5) }
                .disabled(viewport.zoom >= TimelineViewport.maximumZoom(duration: model.duration) - 0.001)
                .help("Zoom In the Timeline — ⌘=")
            Button("Zoom to Fit", systemImage: "arrow.left.and.right") { model.fitTimeline() }
                .disabled(!viewport.isZoomed)
                .help("Show the Whole Timeline — ⌘0")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(PKToolButtonStyle())
        .disabled(!canZoom || model.media == nil)
    }
}
