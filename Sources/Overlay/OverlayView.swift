import Annotation
import AppCore
import AppKit
import Capture
import Carbon.HIToolbox
import DesignSystem
import QuartzCore
import SwiftUI

/// How the overlay behaves once an area is selected.
public enum OverlayMode: Equatable, Sendable {
    /// Inline annotation editor with output actions (⇧⌘X).
    case annotate
    /// Pick an area only. With a confirm title, the user adjusts the selection
    /// and confirms (recording, scrolling capture); without one, the area is
    /// returned as soon as the mouse is released (OCR).
    case pick(confirmTitle: String?, confirmSymbol: String = "checkmark")
}

/// One per display: shows the frozen frame, handles selection and drawing.
/// Coordinates are display-local points with a top-left origin (the view is
/// flipped), which is also the space annotations are stored in.
@MainActor
final class OverlayView: NSView {
    let snapshot: DisplaySnapshot
    private unowned let controller: OverlayController
    private let state: EditorState
    private let mode: OverlayMode
    /// Snappable windows in display-local points, front to back.
    private let windowFrames: [CGRect]

    // Subviews, bottom to top.
    private let frozenView: FrozenFrameView
    private let canvas: AnnotationCanvasView
    private let chrome = ChromeLayerView()
    private var toolsHost: NSHostingView<ToolsBar>?
    private var actionsHost: NSHostingView<ActionsBar>?
    private var textEditor: InlineTextEditor?

    private(set) var selection: CGRect?
    private var hoverRect: CGRect?
    private var interaction: Interaction = .none
    private var lastMouse: CGPoint = .zero
    private var spaceHeld = false

    private enum Interaction {
        case none
        case pending(start: CGPoint)
        case creating(anchor: CGPoint)
        case resizing(handle: SelectionHandle, original: CGRect)
        case movingSelection(start: CGPoint, original: CGRect)
        case drawing(tool: AnnotationTool, start: CGPoint, points: [CGPoint])
        case movingAnnotation(original: Annotation, start: CGPoint)
    }

    init(snapshot: DisplaySnapshot, windows: [WindowInfo], state: EditorState, mode: OverlayMode, controller: OverlayController) {
        self.snapshot = snapshot
        self.state = state
        self.mode = mode
        self.controller = controller
        let displaySize = snapshot.frame.size
        self.windowFrames = windows.compactMap { window in
            let local = window.frame.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
            let clipped = local.intersection(CGRect(origin: .zero, size: displaySize))
            return clipped.width >= 40 && clipped.height >= 40 ? clipped : nil
        }
        frozenView = FrozenFrameView(image: snapshot.image)
        canvas = AnnotationCanvasView(state: state, snapshotImage: snapshot.image, scale: snapshot.scale, displaySize: displaySize)
        super.init(frame: CGRect(origin: .zero, size: displaySize))

        wantsLayer = true
        for view in [frozenView, canvas, chrome] as [NSView] {
            addSubview(view)
        }
        frozenView.frame = bounds
        chrome.frame = bounds
        canvas.isHidden = true
        chrome.configure(scale: snapshot.scale)
        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var displayBounds: CGRect { bounds }

    // MARK: - External control

    /// Clears this display's selection (another display became active).
    func resetSelection() {
        commitTextIfNeeded()
        selection = nil
        interaction = .none
        canvas.isHidden = true
        hideToolbars()
        updateChrome()
    }

    /// Pre-selects an area (previous area, automation).
    func select(_ rect: CGRect) {
        selection = SelectionGeometry.integral(SelectionGeometry.clamp(rect, to: displayBounds))
        finishSelectionChange()
    }

    /// Redraws annotations after a document change.
    func documentChanged() {
        canvas.needsDisplay = true
    }

    /// Commits any open text field (before rendering the result).
    func endEditing() {
        commitTextIfNeeded()
    }

    /// Screen rect (AppKit global) of the actions bar, to anchor the share menu.
    var actionsBarView: NSView? { actionsHost }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        controller.mouseEntered(self)
    }

    override func mouseExited(with event: NSEvent) {
        chrome.hideLoupe()
        chrome.setCrosshair(nil, in: displayBounds)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouse = point
        updateCursor(at: point)

        if selection == nil {
            let newHover = windowFrames.first { $0.contains(point) }
            if newHover != hoverRect {
                hoverRect = newHover
                updateChrome()
            }
            chrome.showLoupe(at: point, snapshot: snapshot, in: displayBounds)
            chrome.setCrosshair(point, in: displayBounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouse = point
        window?.makeFirstResponder(self)

        if textEditor != nil {
            commitTextIfNeeded()
            return
        }
        controller.activate(self)

        guard let selection else {
            interaction = .pending(start: point)
            return
        }

        if event.clickCount == 2, selection.contains(point), state.tool == nil || mode != .annotate {
            perform(mode == .annotate ? .done : .confirmPick)
            return
        }

        if let handle = SelectionGeometry.handle(at: point, in: selection, hitRadius: PK.Overlay.handleSize) {
            interaction = .resizing(handle: handle, original: selection)
            hideToolbars()
            return
        }

        guard selection.contains(point) else {
            interaction = .pending(start: point)
            return
        }

        guard mode == .annotate, !spaceHeld else {
            interaction = .movingSelection(start: point, original: selection)
            return
        }

        if let hit = state.document.hitTest(point) {
            if state.tool == .text, case .text = hit.shape {
                beginTextEditing(at: point, existing: hit)
                return
            }
            state.selectedAnnotationID = hit.id
            interaction = .movingAnnotation(original: hit, start: point)
            canvas.needsDisplay = true
            return
        }

        if state.selectedAnnotationID != nil {
            state.selectedAnnotationID = nil
            canvas.needsDisplay = true
        }

        switch state.tool {
        case nil:
            interaction = .movingSelection(start: point, original: selection)
        case .text:
            beginTextEditing(at: point)
        case .counter:
            state.add(Annotation(shape: .counter(center: point, number: state.document.nextCounterNumber), style: state.style))
        case let tool?:
            interaction = .drawing(tool: tool, start: point, points: [point])
            state.draft = makeDraft(tool: tool, start: point, current: point, points: [point], modifiers: event.modifierFlags)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGVector(dx: point.x - lastMouse.x, dy: point.y - lastMouse.y)
        lastMouse = point
        drag(to: point, delta: delta, modifiers: event.modifierFlags)
    }

    private func drag(to point: CGPoint, delta: CGVector, modifiers: NSEvent.ModifierFlags) {
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)

        switch interaction {
        case .none:
            return

        case let .pending(start):
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            controller.activate(self)
            commitTextIfNeeded()
            selection = nil
            hoverRect = nil
            hideToolbars()
            canvas.isHidden = true
            interaction = .creating(anchor: start)
            drag(to: point, delta: .zero, modifiers: modifiers)

        case var .creating(anchor):
            if spaceHeld {
                // Space + drag moves the whole selection while creating it (SC-3).
                anchor = CGPoint(x: anchor.x + delta.dx, y: anchor.y + delta.dy)
                interaction = .creating(anchor: anchor)
            }
            let rect = ShapeConstraints.rect(from: anchor, to: point, square: shift, fromCenter: option)
            selection = SelectionGeometry.clamp(rect, to: displayBounds)
            updateChrome(loupeAt: point)

        case let .resizing(handle, original):
            selection = SelectionGeometry.resize(original, handle: handle, to: point, keepAspect: shift,
                                                 fromCenter: option, bounds: displayBounds)
            updateChrome(loupeAt: point)

        case let .movingSelection(start, original):
            selection = SelectionGeometry.move(original, by: CGVector(dx: point.x - start.x, dy: point.y - start.y),
                                               within: displayBounds)
            hideToolbars()
            updateChrome()

        case let .drawing(tool, start, points):
            var points = points
            if tool == .pen || tool == .highlighter {
                points.append(point)
                interaction = .drawing(tool: tool, start: start, points: points)
            }
            state.draft = makeDraft(tool: tool, start: start, current: point, points: points, modifiers: modifiers)

        case let .movingAnnotation(original, start):
            var moved = original
            moved.shape = original.shape.translated(by: CGVector(dx: point.x - start.x, dy: point.y - start.y))
            state.draft = moved
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let finished = interaction
        interaction = .none

        switch finished {
        case .none:
            return

        case .pending:
            // A click without dragging selects the window under the cursor,
            // or the whole display (SC-4).
            controller.activate(self)
            selection = windowFrames.first { $0.contains(point) } ?? displayBounds
            hoverRect = nil
            finishSelectionChange()

        case .creating:
            if let rect = selection, rect.width >= 2, rect.height >= 2 {
                selection = SelectionGeometry.integral(rect)
            } else {
                selection = windowFrames.first { $0.contains(point) } ?? displayBounds
            }
            finishSelectionChange()

        case .resizing, .movingSelection:
            if let rect = selection {
                guard rect.width >= 2, rect.height >= 2 else {
                    resetSelection()
                    return
                }
                selection = SelectionGeometry.integral(rect)
            }
            finishSelectionChange()

        case .drawing:
            if let draft = state.draft, isMeaningful(draft) {
                state.commitDraft()
            } else {
                state.draft = nil
            }

        case let .movingAnnotation(original, _):
            if let draft = state.draft, draft.shape != original.shape {
                state.commitDraft()
            } else {
                state.draft = nil
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right-click with nothing selected cancels, like Esc.
        if selection == nil { controller.cancel() }
    }

    override func flagsChanged(with event: NSEvent) {
        // Re-apply ⇧/⌥ constraints live without waiting for the next mouse move.
        drag(to: lastMouse, delta: .zero, modifiers: event.modifierFlags)
    }

    private func finishSelectionChange() {
        guard let selection else { return }
        chrome.hideLoupe()
        chrome.setCrosshair(nil, in: displayBounds)
        canvas.setSelection(selection)
        canvas.isHidden = mode != .annotate
        updateChrome()
        showToolbars()
        controller.selectionDidChange(self, rect: selection)

        if case .pick(confirmTitle: nil, _) = mode {
            controller.perform(.confirmPick, from: self)
        }
    }

    // MARK: - Drawing helpers

    private func makeDraft(tool: AnnotationTool, start: CGPoint, current: CGPoint, points: [CGPoint],
                           modifiers: NSEvent.ModifierFlags) -> Annotation {
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        let id = state.draft?.id ?? UUID()
        let snapped = shift ? ShapeConstraints.snap45(from: start, to: current) : current
        let rect = ShapeConstraints.rect(from: start, to: current, square: shift, fromCenter: option)
        let shape: AnnotationShape = switch tool {
        case .pen: .freehand(points: shift ? [start, snapped] : points)
        case .highlighter: .highlighter(points: shift ? [start, snapped] : points)
        case .line: .line(from: start, to: snapped)
        case .arrow: .arrow(from: start, to: snapped)
        case .rectangle: .rectangle(rect)
        case .ellipse: .ellipse(rect)
        case .blur: .blur(rect)
        case .pixelate: .pixelate(rect)
        case .text, .counter: .counter(center: current, number: 0) // placed by clicking, never dragged
        }
        return Annotation(id: id, shape: shape, style: state.style)
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        let bounds = annotation.shape.geometryBounds
        switch annotation.shape {
        case .freehand, .highlighter:
            return true // a single click leaves a dot
        case .line, .arrow:
            return hypot(bounds.width, bounds.height) >= 3
        default:
            return bounds.width >= 3 && bounds.height >= 3
        }
    }

    // MARK: - Text

    private func beginTextEditing(at point: CGPoint, existing: Annotation? = nil) {
        let fontSize: Double
        let origin: CGPoint
        let string: String
        let color: RGBAColor
        if let existing, case let .text(existingOrigin, existingString, existingSize) = existing.shape {
            origin = existingOrigin
            string = existingString
            fontSize = existingSize
            color = existing.style.color
            state.editingTextID = existing.id
            state.selectedAnnotationID = nil
            canvas.needsDisplay = true
        } else {
            fontSize = state.size.fontSize
            // The click marks the middle of the first line.
            origin = CGPoint(x: point.x, y: point.y - TextMetrics.size(of: "X", fontSize: fontSize).height / 2)
            string = ""
            color = state.color
        }

        let editor = InlineTextEditor(origin: origin, string: string, fontSize: fontSize, color: color)
        editor.existingID = existing?.id
        editor.onCommit = { [weak self] in self?.commitTextIfNeeded() }
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
    }

    private func commitTextIfNeeded() {
        guard let editor = textEditor else { return }
        textEditor = nil
        editor.onCommit = nil
        let string = editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : editor.string
        let shape = AnnotationShape.text(origin: editor.textOrigin, string: string, fontSize: editor.fontSize)
        let style = AnnotationStyle(color: editor.color, lineWidth: state.size.lineWidth)
        editor.removeFromSuperview()
        state.editingTextID = nil

        if let id = editor.existingID {
            if string.isEmpty {
                state.remove(id: id)
            } else {
                state.update(Annotation(id: id, shape: shape, style: style))
            }
        } else if !string.isEmpty {
            state.add(Annotation(shape: shape, style: style))
        }
        canvas.needsDisplay = true
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space { spaceHeld = false }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While typing, let the text view (and the standard Edit menu) handle ⌘ keys.
        if textEditor != nil { return super.performKeyEquivalent(with: event) }
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        return handleKey(event) || super.performKeyEquivalent(with: event)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let keyCode = Int(event.keyCode)

        switch keyCode {
        case kVK_Escape:
            controller.cancel()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if selection != nil { perform(mode == .annotate ? .done : .confirmPick) }
            return true
        case kVK_Delete, kVK_ForwardDelete:
            if let id = state.selectedAnnotationID { state.remove(id: id) }
            return true
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudge(keyCode: keyCode, by: flags.contains(.shift) ? 10 : 1)
            return true
        case kVK_Space:
            spaceHeld = true
            return true
        default:
            break
        }

        if flags.contains(.command) {
            switch key {
            case "z": perform(flags.contains(.shift) ? .redo : .undo)
            case "c": if selection != nil { perform(mode == .annotate ? .copy : .confirmPick) }
            case "s": if selection != nil, mode == .annotate { perform(flags.contains(.shift) ? .saveAs : .save) }
            case "p": if selection != nil, mode == .annotate { perform(.print) }
            case "a":
                controller.activate(self)
                selection = displayBounds
                finishSelectionChange()
            case "w": controller.cancel()
            default: return false
            }
            return true
        }

        if flags.contains(.option), key == "p" || key == "π", selection != nil, mode == .annotate {
            perform(.pin)
            return true
        }

        if flags.isDisjoint(with: [.command, .control, .option]), mode == .annotate,
           let tool = AnnotationTool.allCases.first(where: { String($0.keyEquivalent) == key }) {
            state.tool = tool
            state.selectedAnnotationID = nil
            canvas.needsDisplay = true
            updateCursor(at: lastMouse)
            return true
        }
        return false
    }

    private func nudge(keyCode: Int, by step: CGFloat) {
        let delta: CGVector = switch keyCode {
        case kVK_LeftArrow: CGVector(dx: -step, dy: 0)
        case kVK_RightArrow: CGVector(dx: step, dy: 0)
        case kVK_UpArrow: CGVector(dx: 0, dy: -step)
        default: CGVector(dx: 0, dy: step)
        }
        if var annotation = state.selectedAnnotation {
            annotation.shape = annotation.shape.translated(by: delta)
            state.update(annotation)
        } else if let selection {
            self.selection = SelectionGeometry.move(selection, by: delta, within: displayBounds)
            finishSelectionChange()
        }
    }

    private func perform(_ command: EditorCommand) {
        commitTextIfNeeded()
        controller.perform(command, from: self)
    }

    // MARK: - Chrome

    private func updateChrome(loupeAt loupePoint: CGPoint? = nil) {
        let shown = selection ?? hoverRect
        let dragging: Bool = if case .creating = interaction { true } else { false }
        chrome.update(selection: shown, isHover: selection == nil, in: displayBounds,
                      showsHandles: selection != nil && !dragging)
        if let loupePoint {
            chrome.showLoupe(at: loupePoint, snapshot: snapshot, in: displayBounds)
            chrome.setCrosshair(nil, in: displayBounds)
        }
        if let selection {
            canvas.setSelection(selection)
            layoutToolbars()
        }
    }

    private func showToolbars() {
        guard selection != nil else { return }
        if case .pick(confirmTitle: nil, _) = mode { return }
        if toolsHost == nil, mode == .annotate {
            let host = NSHostingView(rootView: ToolsBar(state: state))
            host.sizingOptions = [.intrinsicContentSize]
            addSubview(host)
            toolsHost = host
        }
        if actionsHost == nil {
            let style: ActionsBarStyle = switch mode {
            case .annotate: .output
            case let .pick(title, symbol): .confirm(title: title ?? "Done", symbol: symbol)
            }
            let host = NSHostingView(rootView: ActionsBar(state: state, style: style))
            host.sizingOptions = [.intrinsicContentSize]
            addSubview(host)
            actionsHost = host
        }
        toolsHost?.isHidden = false
        actionsHost?.isHidden = false
        layoutToolbars()
    }

    private func hideToolbars() {
        toolsHost?.isHidden = true
        actionsHost?.isHidden = true
    }

    private func layoutToolbars() {
        guard let selection else { return }
        let layout = ToolbarLayout.compute(
            selection: selection,
            bounds: displayBounds,
            toolsSize: toolsHost?.fittingSize,
            actionsSize: actionsHost?.fittingSize ?? .zero,
            badgeSize: chrome.badgeSize,
            gap: PK.Metrics.toolbarOffset
        )
        if let tools = layout.tools { toolsHost?.frame = tools }
        actionsHost?.frame = layout.actions
        chrome.placeBadge(at: layout.badge.origin)
    }

    // MARK: - Cursor

    private func updateCursor(at point: CGPoint) {
        guard let selection else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = SelectionGeometry.handle(at: point, in: selection, hitRadius: PK.Overlay.handleSize) {
            Self.cursor(for: handle).set()
        } else if selection.contains(point) {
            if mode != .annotate || state.tool == nil || spaceHeld || state.document.hitTest(point) != nil {
                NSCursor.openHand.set()
            } else if state.tool == .text {
                NSCursor.iBeam.set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    private static func cursor(for handle: SelectionHandle) -> NSCursor {
        let position: NSCursor.FrameResizePosition = switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}

// MARK: - Frozen frame

/// Shows the snapshot as GPU-backed layer contents (no per-frame drawing).
private final class FrozenFrameView: NSView {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
    }
}
