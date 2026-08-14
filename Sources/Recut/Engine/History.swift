import Foundation

/// Undo/redo stacks, kept apart from the editor so the awkward parts — the
/// redo branch being discarded, the depth limit dropping the *oldest* entry —
/// can be tested without standing up an `AppState`.
///
/// Holds whole snapshots rather than reversible operations. `EditModel` is a
/// value type of a few hundred bytes, so sixty of them cost less than one video
/// frame, and there's no way for an inverse operation to be subtly wrong.
struct History<Value> {

    private(set) var undoStack: [Value] = []
    private(set) var redoStack: [Value] = []
    let limit: Int

    init(limit: Int = 60) {
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records the state from *before* a change.
    ///
    /// Anything previously undone is dropped: once you undo and then edit, the
    /// branch you undid is no longer reachable, and offering to redo onto a
    /// different history is how editors lose people's work.
    mutating func record(_ value: Value) {
        undoStack.append(value)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Returns the state to restore, given whatever is current.
    mutating func undo(current: Value) -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(current: Value) -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
