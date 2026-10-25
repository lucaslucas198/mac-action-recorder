import Foundation

/// One proposed change to a macro. Nothing is applied until the user chooses it.
public struct MacroEdit: Identifiable, Equatable {
    public enum Source: Equatable {
        /// A fixed rule in this app.
        case rule
        /// A suggestion parsed from the on-device language model's reply.
        case ai
    }

    public enum Operation: Equatable {
        /// Delete these actions. Their delays are added to the next surviving action.
        case delete([UUID])
        /// Join each listed text action onto the text action directly before it.
        case mergeText([UUID])
        /// Raise the delay before each listed action to at least `seconds`.
        case setMinimumDelay([UUID], seconds: Double)
        /// Shorten every delay or wait longer than `above` seconds to `to` seconds.
        case capPauses(above: Double, to: Double)
    }

    public let id: String
    public let source: Source
    public let operation: Operation
    public let title: String
    public let reason: String

    public init(id: String, source: Source, operation: Operation, title: String, reason: String) {
        self.id = id
        self.source = source
        self.operation = operation
        self.title = title
        self.reason = reason
    }
}

/// Fixed rules that tidy a macro and make common failures less likely. They run locally and
/// deterministically; no language model is involved.
public enum MacroOptimizer {
    /// Shortest run of consecutive mouse moves that is worth removing.
    public static let minMoveRun = 3
    /// Typed chunks closer together than this (seconds) are joined into one.
    public static let maxMergeGap = 1.0
    /// Typing right after a click or shortcut waits at least this long (seconds).
    public static let settleDelay = 0.35

    public static func plan(for recording: Recording) -> [MacroEdit] {
        let actions = recording.actions
        guard !actions.isEmpty else { return [] }
        var edits: [MacroEdit] = []

        // 1. Mouse paths. A click already carries its position, so the path before it adds
        //    steps but no behaviour. Before anything else, the last position is kept.
        var moveIDs: [UUID] = []
        var index = 0
        while index < actions.count {
            guard actions[index].kind == .move else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < actions.count && actions[end + 1].kind == .move {
                end += 1
            }
            if end - index + 1 >= minMoveRun {
                let next: ActionKind? = end + 1 < actions.count ? actions[end + 1].kind : nil
                let dropAll = next == .click || next == .mouseDown
                let last = dropAll ? end : end - 1
                for position in index...last {
                    moveIDs.append(actions[position].id)
                }
            }
            index = end + 1
        }
        if !moveIDs.isEmpty {
            edits.append(MacroEdit(
                id: "rule-remove-moves",
                source: .rule,
                operation: .delete(moveIDs),
                title: "Remove \(moveIDs.count) mouse-movement steps",
                reason: "A click already includes where to click, so the pointer jumps straight there. Keep the movements if something only appears when you hover."
            ))
        }

        // 2. Typing split into several chunks in a row.
        var mergeIDs: [UUID] = []
        if actions.count > 1 {
            for position in 1..<actions.count {
                if actions[position].kind == .text, actions[position - 1].kind == .text,
                   actions[position].delay <= maxMergeGap {
                    mergeIDs.append(actions[position].id)
                }
            }
        }
        if !mergeIDs.isEmpty {
            edits.append(MacroEdit(
                id: "rule-merge-text",
                source: .rule,
                operation: .mergeText(mergeIDs),
                title: "Combine consecutive typing steps (\(mergeIDs.count) fewer)",
                reason: "Text typed back to back is one step. The text and its order stay the same; only the short gaps between chunks are dropped."
            ))
        }

        // 3. Typing right after a click or shortcut, before the app has caught up.
        var settleIDs: [UUID] = []
        if actions.count > 1 {
            for position in 1..<actions.count {
                let action = actions[position]
                let previous = actions[position - 1]
                guard action.kind == .text, action.delay < settleDelay else { continue }
                let afterClick = previous.kind == .click
                let shortcutKeys: KeyModifiers = [.command, .control, .option]
                let afterShortcut = previous.kind == .key
                    && !(previous.modifiers ?? []).intersection(shortcutKeys).isEmpty
                if afterClick || afterShortcut {
                    settleIDs.append(action.id)
                }
            }
        }
        if !settleIDs.isEmpty {
            edits.append(MacroEdit(
                id: "rule-settle-text",
                source: .rule,
                operation: .setMinimumDelay(settleIDs, seconds: settleDelay),
                title: "Wait a moment before \(settleIDs.count) typing step(s)",
                reason: "Text typed immediately after a click or shortcut can be lost if the text field is not focused yet. This waits at least \(ActionDescriber.formatSeconds(settleDelay)) first."
            ))
        }

        // 4. Idle time from the recording session.
        var longPauses = 0
        for action in actions {
            if action.delay > MacroAnalyzer.longPause { longPauses += 1 }
            if action.kind == .wait, (action.duration ?? 0) > MacroAnalyzer.longPause { longPauses += 1 }
        }
        if longPauses > 0 {
            edits.append(MacroEdit(
                id: "rule-cap-pauses",
                source: .rule,
                operation: .capPauses(above: MacroAnalyzer.longPause, to: MacroAnalyzer.pauseCap),
                title: "Shorten \(longPauses) long pause(s) to \(Int(MacroAnalyzer.pauseCap)) s",
                reason: "Pauses over \(Int(MacroAnalyzer.longPause)) seconds are usually thinking time from recording. Keep them if the app really needs that long to load."
            ))
        }

        return edits
    }
}

// MARK: - Applying edits

extension Recording {
    /// Applies the edits in order. An edit that no longer matches anything (for example an action
    /// that an earlier edit already removed) is skipped. Returns how many edits changed something.
    @discardableResult
    public mutating func applyEdits(_ edits: [MacroEdit]) -> Int {
        var applied = 0
        for edit in edits {
            if applyOperation(edit.operation) {
                applied += 1
            }
        }
        return applied
    }

    private mutating func applyOperation(_ operation: MacroEdit.Operation) -> Bool {
        switch operation {
        case .delete(let ids):
            let existing = Set(actions.map { $0.id }).intersection(ids)
            guard !existing.isEmpty else { return false }
            deleteActions(ids: existing)
            return true

        case .mergeText(let ids):
            var changed = false
            for id in ids {
                guard let index = actions.firstIndex(where: { $0.id == id }), index > 0,
                      actions[index].kind == .text, actions[index - 1].kind == .text,
                      let first = actions[index - 1].text, let second = actions[index].text,
                      first.count + second.count <= RecordingValidator.maxText else { continue }
                actions[index - 1].text = first + second
                actions.remove(at: index)
                changed = true
            }
            return changed

        case .setMinimumDelay(let ids, let seconds):
            guard seconds.isFinite, seconds >= 0 else { return false }
            let target = min(seconds, RecordingValidator.maxDelay)
            var changed = false
            for index in actions.indices where ids.contains(actions[index].id) && actions[index].delay < target {
                actions[index].delay = target
                changed = true
            }
            return changed

        case .capPauses(let above, let to):
            guard above.isFinite, to.isFinite, to >= 0, to <= above else { return false }
            var changed = false
            for index in actions.indices {
                if actions[index].delay > above {
                    actions[index].delay = to
                    changed = true
                }
                if actions[index].kind == .wait, let duration = actions[index].duration, duration > above {
                    actions[index].duration = to
                    changed = true
                }
            }
            return changed
        }
    }
}

// MARK: - Reading a language model's reply

/// Turns the on-device model's text reply into edits the app is willing to apply.
///
/// The model may only ask for two things, in a fixed line format:
///
///     DELETE <step> | <reason>
///     PAUSE <step> <seconds> | <reason>
///
/// Anything else is ignored: unknown words, step numbers that do not exist, mouse-movement steps
/// (the rules handle those), wild values, and more than a few deletions. The model can never write
/// text, coordinates or key codes into a macro, and the user still has to choose each change.
public enum AIEditParser {
    public static let maxEdits = 12
    public static let maxPause = 5.0

    public static func parse(_ reply: String, recording: Recording) -> [MacroEdit] {
        let actions = recording.actions
        guard !actions.isEmpty else { return [] }
        let editableCount = actions.filter { $0.kind != .move && $0.kind != .drag }.count
        let maxDeletes = max(1, editableCount / 2)

        var edits: [MacroEdit] = []
        var seen = Set<String>()
        var deletes = 0

        for rawLine in reply.components(separatedBy: .newlines) {
            if edits.count >= maxEdits { break }
            let line = clean(rawLine)
            if line.isEmpty { continue }

            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let command = String(parts[0])
            var reason = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if reason.isEmpty { reason = "Suggested by the on-device AI." }
            if reason.count > 160 { reason = String(reason.prefix(157)) + "…" }

            let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let verb = words.first?.uppercased() else { continue }
            let tokens = [verb] + words.dropFirst().filter { $0.lowercased() != "step" }
            guard tokens.count >= 2, let step = stepNumber(tokens[1]),
                  step >= 1, step <= actions.count else { continue }
            let action = actions[step - 1]
            if action.kind == .move || action.kind == .drag { continue }
            let described = ActionDescriber.describe(action)

            switch verb {
            case "DELETE", "REMOVE":
                let key = "delete-\(action.id.uuidString)"
                guard !seen.contains(key), deletes < maxDeletes else { continue }
                seen.insert(key)
                deletes += 1
                edits.append(MacroEdit(
                    id: "ai-" + key,
                    source: .ai,
                    operation: .delete([action.id]),
                    title: "Delete step \(step): \(described)",
                    reason: reason
                ))

            case "PAUSE", "WAIT":
                guard tokens.count >= 3, let seconds = number(tokens[2]),
                      seconds.isFinite, seconds > 0 else { continue }
                let clamped = min(seconds, maxPause)
                let key = "pause-\(action.id.uuidString)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                edits.append(MacroEdit(
                    id: "ai-" + key,
                    source: .ai,
                    operation: .setMinimumDelay([action.id], seconds: clamped),
                    title: "Wait at least \(ActionDescriber.formatSeconds(clamped)) before step \(step): \(described)",
                    reason: reason
                ))

            default:
                continue
            }
        }
        return edits
    }

    /// Removes list bullets, numbering and markdown emphasis from the start of a line.
    static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
        text = text.trimmingCharacters(in: .whitespaces)
        while let first = text.first, first == "-" || first == "•" || first == ">" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        // "1. DELETE 3" or "2) DELETE 3"
        let digits = text.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let rest = text.dropFirst(digits.count)
            if let mark = rest.first, mark == "." || mark == ")" {
                text = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    private static func stepNumber(_ token: String) -> Int? {
        return Int(token.trimmingCharacters(in: CharacterSet(charactersIn: "#:,.")))
    }

    private static func number(_ token: String) -> Double? {
        let letters = CharacterSet.letters.union(CharacterSet(charactersIn: ","))
        return Double(token.lowercased().trimmingCharacters(in: letters))
    }
}
