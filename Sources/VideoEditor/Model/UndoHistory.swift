/// Snapshot-based undo/redo, like `AnnotationDocument`: record the value
/// *before* each edit. Edit projects are small, so snapshots are cheap and
/// undo is trivially correct.
public struct UndoHistory<Value> {
    private var undoStack: [Value] = []
    private var redoStack: [Value] = []
    private let limit: Int

    public init(limit: Int = 200) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Call before changing `value`; clears the redo stack.
    public mutating func record(_ value: Value) {
        undoStack.append(value)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// The value to restore, or `nil` if there's nothing to undo.
    public mutating func undo(current: Value) -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: Value) -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}

extension UndoHistory: Sendable where Value: Sendable {}
