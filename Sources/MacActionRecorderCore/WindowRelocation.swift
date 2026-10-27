import Foundation

/// Keeps recorded click positions correct when the target app's window has moved.
///
/// A macro stores absolute screen positions. If the window that was in front when recording
/// started is now somewhere else but has the same size, every point that was inside that window
/// can be shifted by the same amount and will land on the same control again. If the size is
/// different, positions cannot be corrected with any certainty and nothing is changed.
public enum WindowRelocation {
    public enum Assessment: Equatable {
        /// Same position and size (within the tolerance).
        case same
        /// Same size, different position.
        case moved(dx: Double, dy: Double)
        /// A different size: recorded positions no longer line up.
        case resized
    }

    public static func assess(recorded: WindowFrame, current: WindowFrame, tolerance: Double = 2) -> Assessment {
        guard recorded.hasSameSize(as: current, tolerance: tolerance) else { return .resized }
        let dx = current.x - recorded.x
        let dy = current.y - recorded.y
        if abs(dx) <= 1 && abs(dy) <= 1 { return .same }
        return .moved(dx: dx, dy: dy)
    }

    /// Shifts every pointer position that was inside `recorded` by (dx, dy). Positions outside the
    /// window (the menu bar, the Dock, another app) are left alone.
    public static func translate(_ actions: [MacroAction], recorded: WindowFrame, dx: Double, dy: Double) -> [MacroAction] {
        return actions.map { action in
            guard isPositional(action.kind), let x = action.x, let y = action.y,
                  recorded.contains(x: x, y: y, margin: 1) else { return action }
            var moved = action
            moved.x = x + dx
            moved.y = y + dy
            return moved
        }
    }

    /// True when the macro has at least one position that depends on where the window is.
    public static func hasPositions(_ actions: [MacroAction], inside recorded: WindowFrame? = nil) -> Bool {
        return actions.contains { action in
            guard isPositional(action.kind), let x = action.x, let y = action.y else { return false }
            if let frame = recorded { return frame.contains(x: x, y: y, margin: 1) }
            return true
        }
    }

    public static func isPositional(_ kind: ActionKind) -> Bool {
        switch kind {
        case .move, .drag, .mouseDown, .mouseUp, .click, .scroll: return true
        case .key, .text, .wait: return false
        }
    }
}
