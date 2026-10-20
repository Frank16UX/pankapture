import Annotation
import AppCore
import Foundation
import Observation

/// What the floating toolbars can ask the overlay to do.
public enum EditorCommand: Sendable {
    case copy, save, saveAs, print, share, pin, done, close
    case undo, redo
    case confirmPick
}

/// Shared, observable editing state: the toolbars (SwiftUI) read and write it,
/// the AppKit canvas renders from it. One instance per overlay session.
@MainActor
@Observable
final class EditorState {
    var tool: AnnotationTool? {
        didSet { persist() }
    }
    var color: RGBAColor {
        didSet { persist() }
    }
    var size: StrokeSize {
        didSet { persist() }
    }

    private(set) var document = AnnotationDocument()
    var selectedAnnotationID: Annotation.ID?

    /// In-progress shape (being drawn or dragged). Not in the document (and not
    /// in undo history) until committed; replaces the annotation with the same id.
    @ObservationIgnored var draft: Annotation? {
        didSet { documentDidChange?() }
    }
    /// Text annotation hidden from the canvas while its inline editor is open.
    @ObservationIgnored var editingTextID: Annotation.ID?

    /// Set by the overlay view; called after any document change so the canvas redraws.
    @ObservationIgnored var documentDidChange: (() -> Void)?
    /// Toolbar → overlay commands.
    @ObservationIgnored var perform: ((EditorCommand) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tool = defaults.string(forKey: PreferenceKey.editorTool).flatMap(AnnotationTool.init(rawValue:))
        color = defaults.data(forKey: PreferenceKey.editorColor)
            .flatMap { try? JSONDecoder().decode(RGBAColor.self, from: $0) } ?? .red
        size = defaults.string(forKey: PreferenceKey.editorSize).flatMap(StrokeSize.init(rawValue:)) ?? .medium
    }

    var style: AnnotationStyle { AnnotationStyle(color: color, lineWidth: size.lineWidth) }
    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }

    var selectedAnnotation: Annotation? {
        selectedAnnotationID.flatMap { id in document.annotations.first { $0.id == id } }
    }

    // MARK: Tool & style

    /// Selecting the active tool again deselects it (back to move mode).
    func toggle(_ newTool: AnnotationTool) {
        tool = tool == newTool ? nil : newTool
        selectedAnnotationID = nil
        documentDidChange?()
    }

    /// Changes the current color and restyles the selected annotation, if any.
    func setColor(_ newColor: RGBAColor) {
        color = newColor
        restyleSelection()
    }

    func setSize(_ newSize: StrokeSize) {
        size = newSize
        restyleSelection()
    }

    private func restyleSelection() {
        guard var annotation = selectedAnnotation else { return }
        annotation.style = style
        if case let .text(origin, string, _) = annotation.shape {
            annotation.shape = .text(origin: origin, string: string, fontSize: size.fontSize)
        }
        update(annotation)
    }

    // MARK: Document edits

    /// Adds or updates the draft in a single undo step.
    func commitDraft() {
        guard let draft else { return }
        self.draft = nil
        if document.annotations.contains(where: { $0.id == draft.id }) {
            update(draft)
        } else {
            add(draft)
        }
    }

    /// Annotations as they should appear right now (draft applied, editing text hidden).
    var visibleAnnotations: [Annotation] {
        var result = document.annotations.filter { $0.id != editingTextID }
        if let draft {
            if let index = result.firstIndex(where: { $0.id == draft.id }) {
                result[index] = draft
            } else {
                result.append(draft)
            }
        }
        return result
    }

    func add(_ annotation: Annotation) {
        document.add(annotation)
        documentDidChange?()
    }

    func update(_ annotation: Annotation) {
        document.update(annotation)
        documentDidChange?()
    }

    func remove(id: Annotation.ID) {
        document.remove(id: id)
        if selectedAnnotationID == id { selectedAnnotationID = nil }
        documentDidChange?()
    }

    /// Starts over with an empty document (selection moved to another display).
    func resetDocument() {
        document = AnnotationDocument()
        draft = nil
        selectedAnnotationID = nil
        editingTextID = nil
        documentDidChange?()
    }

    func clearHistory() {
        document.clearHistory()
    }

    func undo() {
        document.undo()
        dropStaleSelection()
        documentDidChange?()
    }

    func redo() {
        document.redo()
        dropStaleSelection()
        documentDidChange?()
    }

    private func dropStaleSelection() {
        if selectedAnnotation == nil { selectedAnnotationID = nil }
    }

    private func persist() {
        defaults.set(tool?.rawValue, forKey: PreferenceKey.editorTool)
        defaults.set(size.rawValue, forKey: PreferenceKey.editorSize)
        if let data = try? JSONEncoder().encode(color) {
            defaults.set(data, forKey: PreferenceKey.editorColor)
        }
    }
}
