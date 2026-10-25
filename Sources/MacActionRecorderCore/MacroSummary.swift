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

    /// A numbered list for asking a language model to suggest edits. Each line is labelled with the
    /// action's real position in the macro (`#7` is the 7th action), so a reply that refers to
    /// "step 7" can be mapped back to the right action. Mouse movements are collapsed into one
    /// unnumbered line. Long macros keep their first and last lines; the numbers stay correct.
    public static func numberedText(for recording: Recording, maxLines: Int = 60) -> String {
        var lines: [String] = []
        var pointerSteps = 0

        func flushPointer() {
            if pointerSteps > 0 {
                lines.append("(mouse movements: \(pointerSteps), not editable)")
                pointerSteps = 0
            }
        }

        for (index, action) in recording.actions.enumerated() {
            if action.kind == .move || action.kind == .drag {
                pointerSteps += 1
                continue
            }
            flushPointer()
            var line = "#\(index + 1) " + ActionDescriber.describe(action)
            if action.delay >= 0.05 {
                line += " (after \(ActionDescriber.formatSeconds(action.delay)))"
            }
            lines.append(line)
        }
        flushPointer()

        let limit = max(4, maxLines)
        if lines.count > limit {
            let head = (limit * 2) / 3
            let tail = limit - head
            let omitted = lines.count - head - tail
            lines = Array(lines[..<head]) + ["… \(omitted) lines omitted …"] + Array(lines[(lines.count - tail)...])
        }

        var output = "Macro: \(recording.name)\n"
        if let app = recording.targetApp {
            output += "Recorded in: \(app.name)\n"
        }
        output += "Total actions: \(recording.actions.count)\nSteps:\n"
        for line in lines {
            output += line + "\n"
        }
        return output
    }
}
