import Foundation

/// The result of reading a language model's drafted steps.
public struct MacroDraft: Equatable {
    public var actions: [MacroAction]
    /// Lines that were not understood and were left out.
    public var skippedLines: Int
    /// The model said the request cannot be done with the keyboard.
    public var unsupported: Bool
}

/// Turns the on-device model's reply to "describe what the macro should do" into real actions.
///
/// The model may only use three line formats:
///
///     KEY <shortcut>     for example KEY cmd+k, KEY return, KEY shift+return
///     TYPE <text>        the exact text to type
///     WAIT <seconds>     0.1 to 10
///
/// Everything else is ignored. The result is a list of ordinary keyboard actions with no screen
/// coordinates, and the app shows it to the user before anything is added to a macro.
public enum AIMacroDrafter {
    public static let maxActions = 30
    public static let maxTextLength = 500
    public static let minWait = 0.1
    public static let maxWait = 10.0

    /// Delay before a step that follows a shortcut such as ⌘K, which opens a panel.
    static let afterShortcutDelay = 0.5
    /// Delay before pressing Return after typing, so suggestion lists can update.
    static let beforeReturnDelay = 0.4
    static let defaultDelay = 0.2

    public static func parse(_ reply: String) -> MacroDraft {
        var actions: [MacroAction] = []
        var skipped = 0
        var unsupported = false
        var previous: MacroAction?

        for rawLine in reply.components(separatedBy: .newlines) {
            if actions.count >= maxActions { break }
            let line = AIEditParser.clean(rawLine)
            if line.isEmpty { continue }
            if line.uppercased() == "UNSUPPORTED" {
                unsupported = true
                continue
            }

            let verb = line.prefix(while: { !$0.isWhitespace }).uppercased()
            let rest = line.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)

            var action: MacroAction?
            switch verb {
            case "KEY":
                if let parsed = parseKey(rest) {
                    action = .key(parsed.keyCode, modifiers: parsed.modifiers)
                }
            case "TYPE":
                let text = unquote(rest)
                if !text.isEmpty && text.count <= maxTextLength {
                    action = .text(text)
                }
            case "WAIT":
                let letters = CharacterSet.letters
                if let seconds = Double(rest.lowercased().trimmingCharacters(in: letters.union(.whitespaces))),
                   seconds.isFinite {
                    action = .wait(min(maxWait, max(minWait, seconds)))
                }
            default:
                break
            }

            guard var built = action else {
                // Prose, code fences and blank markdown are expected; count only real attempts.
                if verb == "KEY" || verb == "TYPE" || verb == "WAIT" { skipped += 1 }
                continue
            }

            if let before = previous, built.kind != .wait {
                built.delay = delay(after: before, before: built)
            }
            actions.append(built)
            previous = built
        }
        return MacroDraft(actions: actions, skippedLines: skipped, unsupported: unsupported && actions.isEmpty)
    }

    // MARK: Pieces

    private static func delay(after previous: MacroAction, before next: MacroAction) -> Double {
        if previous.kind == .key, let modifiers = previous.modifiers,
           !modifiers.intersection([.command, .control, .option]).isEmpty {
            return afterShortcutDelay
        }
        if previous.kind == .text, next.kind == .key, next.keyCode == KeyCodes.returnKey,
           (next.modifiers ?? []).isEmpty {
            return beforeReturnDelay
        }
        return defaultDelay
    }

    private static func unquote(_ text: String) -> String {
        var result = text
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in pairs where result.count >= 2 && result.first == open && result.last == close {
            result = String(result.dropFirst().dropLast())
            break
        }
        return result
    }

    /// Parses a shortcut such as "cmd+k", "shift+return" or "tab".
    static func parseKey(_ text: String) -> (keyCode: Int, modifiers: KeyModifiers)? {
        let parts = text.lowercased()
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }

        var modifiers: KeyModifiers = []
        for name in parts.dropLast() {
            switch name {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard let code = keyCodes[keyName] else { return nil }
        return (code, modifiers)
    }

    /// Names the model may use, mapped to macOS virtual key codes (ANSI layout).
    static let keyCodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36,
        "tab": 48, "space": 49,
        "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}
