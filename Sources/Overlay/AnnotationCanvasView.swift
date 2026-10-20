import Annotation
import AppKit

/// Draws the annotations of the active selection. Its frame is the selection
/// rectangle and its bounds origin is the selection origin, so it draws in
/// display-local points and clips to the selection for free (AN-7: resizing the
/// selection never moves annotations relative to the screen content).
final class AnnotationCanvasView: NSView {
    private let state: EditorState
    private let snapshotImage: CGImage
    private let scale: CGFloat
    private let displaySize: CGSize
    private let filterCache = FilterCache()

    init(state: EditorState, snapshotImage: CGImage, scale: CGFloat, displaySize: CGSize) {
        self.state = state
        self.snapshotImage = snapshotImage
        self.scale = scale
        self.displaySize = displaySize
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Events are handled by the overlay view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Positions the canvas over `selection` (display-local points).
    func setSelection(_ selection: CGRect) {
        frame = selection
        bounds = CGRect(origin: selection.origin, size: selection.size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let annotations = state.visibleAnnotations

        // Multiply-blended highlighter needs real pixels underneath to match the
        // exported result; draw the frozen frame only when it matters.
        if annotations.contains(where: { if case .highlighter = $0.shape { true } else { false } }) {
            context.saveGState()
            context.translateBy(x: 0, y: displaySize.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(snapshotImage, in: CGRect(origin: .zero, size: displaySize))
            context.restoreGState()
        }

        for annotation in annotations where annotation.visualBounds.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            AnnotationRenderer.draw(annotation, in: context, imageScale: scale, source: snapshotImage, cache: filterCache)
        }

        if let id = state.selectedAnnotationID, let shown = annotations.first(where: { $0.id == id }) {
            drawSelectionIndicator(around: shown, in: context)
        }
    }

    private func drawSelectionIndicator(around annotation: Annotation, in context: CGContext) {
        let rect = annotation.visualBounds.insetBy(dx: -4, dy: -4)
        context.saveGState()
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.stroke(rect)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)
        context.restoreGState()
    }
}
