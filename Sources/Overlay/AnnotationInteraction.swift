import Annotation
import AppKit

/// Mouse and keyboard handling for annotation tools: drawing, selecting,
/// moving, text editing. Shared by the selection overlay and the editor window.
/// Points are in the annotation space of the host's canvas.
@MainActor
final class AnnotationInteraction {
    private let state: EditorState
    /// Hosts the inline text field; must use the same (flipped) coordinates.
    private unowned let host: NSView
    private let redraw: () -> Void

    private var gesture: Gesture = .none
    private var textEditor: InlineTextEditor?
    private(set) var lastPoint: CGPoint = .zero

    private enum Gesture {
        case none
        case drawing(tool: AnnotationTool, start: CGPoint, points: [CGPoint])
        case moving(original: Annotation, start: CGPoint)
    }

    init(state: EditorState, host: NSView, redraw: @escaping () -> Void) {
        self.state = state
        self.host = host
        self.redraw = redraw
    }

    var isEditingText: Bool { textEditor != nil }
    var isActive: Bool {
        if case .none = gesture { return false }
        return true
    }

    // MARK: Mouse

    /// Returns false when nothing was hit and no tool is active, so the host can
    /// treat the drag as something else (e.g. moving the selection).
    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        lastPoint = point
        if let hit = state.document.hitTest(point) {
            if state.tool == .text, case .text = hit.shape {
                beginTextEditing(at: point, existing: hit)
                return true
            }
            state.selectedAnnotationID = hit.id
            gesture = .moving(original: hit, start: point)
            redraw()
            return true
        }

        if state.selectedAnnotationID != nil {
            state.selectedAnnotationID = nil
            redraw()
        }

        switch state.tool {
        case nil:
            return false
        case .text:
            beginTextEditing(at: point)
        case .counter:
            state.add(Annotation(shape: .counter(center: point, number: state.document.nextCounterNumber), style: state.style))
        case let tool?:
            gesture = .drawing(tool: tool, start: point, points: [point])
            state.draft = makeDraft(tool: tool, start: point, current: point, points: [point], modifiers: modifiers)
        }
        return true
    }

    func mouseDragged(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        lastPoint = point
        switch gesture {
        case .none:
            return
        case let .drawing(tool, start, points):
            var points = points
            if tool == .pen || tool == .highlighter {
                points.append(point)
                gesture = .drawing(tool: tool, start: start, points: points)
            }
            state.draft = makeDraft(tool: tool, start: start, current: point, points: points, modifiers: modifiers)
        case let .moving(original, start):
            var moved = original
            moved.shape = original.shape.translated(by: CGVector(dx: point.x - start.x, dy: point.y - start.y))
            state.draft = moved
        }
    }

    func mouseUp() {
        let finished = gesture
        gesture = .none
        switch finished {
        case .none:
            return
        case .drawing:
            if let draft = state.draft, Self.isMeaningful(draft) {
                state.commitDraft()
            } else {
                state.draft = nil
            }
        case let .moving(original, _):
            if let draft = state.draft, draft.shape != original.shape {
                state.commitDraft()
            } else {
                state.draft = nil
            }
        }
    }

    /// Re-applies ⇧/⌥ constraints when modifiers change mid-drag.
    func flagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        mouseDragged(to: lastPoint, modifiers: modifiers)
    }

    // MARK: Keyboard

    /// Handles delete, nudge, and single-key tool shortcuts. Returns true if consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch Int(event.keyCode) {
        case 51, 117: // delete, forward delete
            guard let id = state.selectedAnnotationID else { return false }
            state.remove(id: id)
            return true
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control, .option]),
           let tool = AnnotationTool.allCases.first(where: { String($0.keyEquivalent) == key }) {
            state.tool = tool
            state.selectedAnnotationID = nil
            redraw()
            return true
        }
        return false
    }

    /// Moves the selected annotation; returns false if none is selected.
    func nudgeSelection(by delta: CGVector) -> Bool {
        guard var annotation = state.selectedAnnotation else { return false }
        annotation.shape = annotation.shape.translated(by: delta)
        state.update(annotation)
        return true
    }

    // MARK: Cursor

    func cursor(at point: CGPoint) -> NSCursor {
        if state.tool == nil || state.document.hitTest(point) != nil { return .openHand }
        if state.tool == .text { return .iBeam }
        return .crosshair
    }

    // MARK: Text

    func beginTextEditing(at point: CGPoint, existing: Annotation? = nil) {
        commitText()
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
            redraw()
        } else {
            fontSize = state.size.fontSize
            // The click marks the middle of the first line.
            origin = CGPoint(x: point.x, y: point.y - TextMetrics.size(of: "X", fontSize: fontSize).height / 2)
            string = ""
            color = state.color
        }

        let editor = InlineTextEditor(origin: origin, string: string, fontSize: fontSize, color: color)
        editor.existingID = existing?.id
        editor.onCommit = { [weak self] in self?.commitText() }
        host.addSubview(editor)
        textEditor = editor
        host.window?.makeFirstResponder(editor)
    }

    func commitText() {
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
        redraw()
        host.window?.makeFirstResponder(host)
    }

    // MARK: Drafts

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

    private static func isMeaningful(_ annotation: Annotation) -> Bool {
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
}
