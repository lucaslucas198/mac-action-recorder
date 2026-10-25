import Foundation

/// A compact plain-text description of a macro, small enough for a language model with a
/// short context window. Long mouse paths are collapsed into one line.
public enum MacroSummary {
    public static func text(for recording: Recording, maxLines: Int = 60) -> String {
        var lines: [String] = []
        var pointerSteps = 0

        func flushPointer() {
            if pointerSteps > 0 {
                lines.append("Move the mouse (\(pointerSteps) steps)")
                pointerSteps = 0
            }
        }

        for action in recording.actions {
            if action.kind == .move || action.kind == .drag {
                pointerSteps += 1
                continue
            }
            flushPointer()
            var line = ActionDescriber.describe(action)
            if action.delay >= 1 {
                line += " (after a \(ActionDescriber.formatSeconds(action.delay)) pause)"
            }
            lines.append(line)
        }
        flushPointer()

        let limit = max(4, maxLines)
        if lines.count > limit {
            let head = (limit * 2) / 3
            let tail = limit - head
            let omitted = lines.count - head - tail
            let kept = Array(lines[..<head]) + ["… \(omitted) steps omitted …"] + Array(lines[(lines.count - tail)...])
            lines = kept
        }

        var output = "Macro: \(recording.name)\n"
        if let app = recording.targetApp {
            output += "Recorded in: \(app.name)\n"
        }
        output += "Total actions: \(recording.actions.count)\nSteps:\n"
        for (index, line) in lines.enumerated() {
            output += "\(index + 1). \(line)\n"
        }
        return output
    }
}
