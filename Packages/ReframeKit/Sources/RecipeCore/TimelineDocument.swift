import Foundation
import Observation

/// The editable document plus its undo history.
///
/// The UI never mutates `timeline` directly — it calls `perform(_:)`. That single rule is what
/// makes undo total rather than best-effort: there is no edit path that bypasses the stack.
@MainActor
@Observable
public final class TimelineDocument {

    public private(set) var timeline: Timeline
    public private(set) var undoStack: [EditCommand] = []
    public private(set) var redoStack: [EditCommand] = []

    /// Increments on every mutation. Views observe this to invalidate the preview without
    /// diffing the whole timeline.
    public private(set) var revision: Int = 0

    /// While a continuous gesture is open, same-key commands coalesce into one undo step.
    private var openGestureKey: String?

    public init(timeline: Timeline) {
        self.timeline = timeline
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    @discardableResult
    public func perform(_ command: EditCommand) -> Bool {
        do {
            var draft = timeline
            try command.apply(to: &draft)
            timeline = draft
            redoStack.removeAll()

            // Merge into the previous step when a gesture is open and the keys match.
            if let key = command.coalescingKey,
               key == openGestureKey,
               let previous = undoStack.last,
               previous.coalescingKey == key {
                undoStack[undoStack.count - 1] = previous.coalesced(with: command)
            } else {
                undoStack.append(command)
            }
            revision += 1
            return true
        } catch {
            // A command that cannot apply means the timeline is not what the caller thought.
            // Dropping it is correct — applying half of it would corrupt the document.
            return false
        }
    }

    /// Call on gesture begin. Subsequent same-key commands merge until `endGesture()`.
    public func beginGesture(key: String) {
        openGestureKey = key
    }

    public func endGesture() {
        openGestureKey = nil
    }

    @discardableResult
    public func undo() -> String? {
        guard let command = undoStack.popLast() else { return nil }
        do {
            var draft = timeline
            try command.revert(from: &draft)
            timeline = draft
            redoStack.append(command)
            revision += 1
            openGestureKey = nil
            return command.name
        } catch {
            // Revert failed: the stack no longer matches the document. Discard the rest rather
            // than let undo walk the timeline somewhere invalid.
            undoStack.removeAll()
            return nil
        }
    }

    @discardableResult
    public func redo() -> String? {
        guard let command = redoStack.popLast() else { return nil }
        do {
            var draft = timeline
            try command.apply(to: &draft)
            timeline = draft
            undoStack.append(command)
            revision += 1
            return command.name
        } catch {
            redoStack.removeAll()
            return nil
        }
    }

    /// Replaces the document wholesale — regenerating from a new asset assignment, say. Clears
    /// history, because the old commands reference clips that no longer exist.
    public func replace(with newTimeline: Timeline) {
        timeline = newTimeline
        undoStack.removeAll()
        redoStack.removeAll()
        revision += 1
    }

    // MARK: - Persistable history

    /// Undo survives a force-quit. Unusual, nearly free here because commands are `Codable`,
    /// and genuinely nice when a render crashes mid-edit.
    public struct PersistedHistory: Codable, Sendable {
        public var undo: [EditCommand]
        public var redo: [EditCommand]
    }

    public var history: PersistedHistory {
        PersistedHistory(undo: undoStack, redo: redoStack)
    }

    public func restore(history: PersistedHistory) {
        undoStack = history.undo
        redoStack = history.redo
    }
}
