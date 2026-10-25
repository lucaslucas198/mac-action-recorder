import Foundation

/// Pure editing operations on a recording's action list. The UI calls these, and they are
/// unit-tested independently of SwiftUI.
extension Recording {
    /// Deletes the given actions. The delay that preceded each deleted action is added to the
    /// next surviving action, so removing a step never silently shortens the pauses around it.
    public mutating func deleteActions(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var result: [MacroAction] = []
        result.reserveCapacity(actions.count)
        var carry = 0.0
        for action in actions {
            if ids.contains(action.id) {
                carry += action.delay
            } else {
                var kept = action
                kept.delay += carry
                carry = 0
                result.append(kept)
            }
        }
        actions = result
    }

    /// Duplicates the selected actions as a block, inserted after the last selected action.
    /// Returns the ids of the new copies.
    @discardableResult
    public mutating func duplicateActions(ids: Set<UUID>) -> [UUID] {
        let selectedIndices = actions.indices.filter { ids.contains(actions[$0].id) }
        guard let last = selectedIndices.last else { return [] }
        var copies: [MacroAction] = []
        for index in selectedIndices {
            var copy = actions[index]
            copy.id = UUID()
            copies.append(copy)
        }
        actions.insert(contentsOf: copies, at: last + 1)
        return copies.map { $0.id }
    }

    /// Moves actions using the same semantics as SwiftUI's `onMove` (destination is an index
    /// in the original array, before removal).
    public mutating func moveActions(from source: IndexSet, to destination: Int) {
        let valid = Array(source).filter { $0 >= 0 && $0 < actions.count }.sorted()
        guard !valid.isEmpty else { return }
        let clampedDestination = max(0, min(destination, actions.count))
        let moving = valid.map { actions[$0] }
        let removedBefore = valid.filter { $0 < clampedDestination }.count
        for index in valid.reversed() {
            actions.remove(at: index)
        }
        let insertionPoint = clampedDestination - removedBefore
        actions.insert(contentsOf: moving, at: insertionPoint)
    }

    /// Moves the selected actions up one position (each swaps with the unselected neighbour above).
    public mutating func moveUp(ids: Set<UUID>) {
        guard actions.count > 1 else { return }
        var index = 1
        while index < actions.count {
            if ids.contains(actions[index].id) && !ids.contains(actions[index - 1].id) {
                actions.swapAt(index, index - 1)
            }
            index += 1
        }
    }

    /// Moves the selected actions down one position.
    public mutating func moveDown(ids: Set<UUID>) {
        guard actions.count > 1 else { return }
        var index = actions.count - 2
        while index >= 0 {
            if ids.contains(actions[index].id) && !ids.contains(actions[index + 1].id) {
                actions.swapAt(index, index + 1)
            }
            index -= 1
        }
    }

    /// Inserts a wait after the action with `afterID`, or at the end when nil/unknown.
    @discardableResult
    public mutating func insertWait(seconds: Double, after afterID: UUID?) -> UUID {
        let wait = MacroAction.wait(seconds)
        if let afterID = afterID, let index = actions.firstIndex(where: { $0.id == afterID }) {
            actions.insert(wait, at: index + 1)
        } else {
            actions.append(wait)
        }
        return wait.id
    }

    /// Inserts a block of actions after the action with `afterID`, or at the end.
    public mutating func insertActions(_ newActions: [MacroAction], after afterID: UUID?) {
        if let afterID = afterID, let index = actions.firstIndex(where: { $0.id == afterID }) {
            actions.insert(contentsOf: newActions, at: index + 1)
        } else {
            actions.append(contentsOf: newActions)
        }
    }

    /// Replaces the action that has the same id as `action`. Returns false if none matches.
    @discardableResult
    public mutating func replaceAction(_ action: MacroAction) -> Bool {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return false }
        actions[index] = action
        return true
    }
}
