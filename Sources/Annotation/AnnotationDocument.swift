import Foundation

/// The editable list of annotations on a capture, with snapshot-based undo/redo.
///
/// Snapshots (rather than inverse commands) keep undo trivially correct; a
/// capture rarely has more than a few dozen annotations, so the cost is negligible.
public struct AnnotationDocument: Sendable, Equatable {
    public private(set) var annotations: [Annotation] = []

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let undoLimit: Int

    public init(annotations: [Annotation] = [], undoLimit: Int = 200) {
        self.annotations = annotations
        self.undoLimit = undoLimit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isEmpty: Bool { annotations.isEmpty }

    /// The number the next numbered-step annotation should show.
    public var nextCounterNumber: Int {
        let numbers = annotations.compactMap { annotation -> Int? in
            if case let .counter(_, number) = annotation.shape { return number }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    public mutating func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    /// Replaces an annotation in place (e.g. after a move or restyle).
    public mutating func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        checkpoint()
        annotations[index] = annotation
    }

    public mutating func remove(id: Annotation.ID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        guard !annotations.isEmpty else { return }
        checkpoint()
        annotations.removeAll()
    }

    /// Forgets undo/redo history (e.g. after loading a saved document).
    public mutating func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    private mutating func checkpoint() {
        undoStack.append(annotations)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }
}
