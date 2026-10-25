import Foundation

/// A one-click change that resolves a finding.
public enum MacroFix: Equatable {
    /// Delete every plain mouse-move action (clicks jump straight to their position).
    case removeMouseMoves
    /// Shorten every pause or wait longer than `maxSeconds` to `maxSeconds`.
    case capLongPauses(maxSeconds: Double)
    /// Set the delay between repetitions.
    case setLoopDelay(seconds: Double)
    /// Turn on "only play while the recorded app is in front".
    case enableForegroundCheck
}

public struct MacroFinding: Identifiable, Equatable {
    public enum Severity: Equatable {
        case info
        case warning
    }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let fix: MacroFix?
    public let fixLabel: String?

    public init(
        id: String,
        severity: Severity,
        title: String,
        detail: String,
        fix: MacroFix? = nil,
        fixLabel: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fix = fix
        self.fixLabel = fixLabel
    }
}

/// Fixed rules that look for things that commonly make macros unreliable or risky.
/// Everything here runs locally and deterministically; there is no model involved.
public enum MacroAnalyzer {
    public static let longPause = 10.0
    public static let pauseCap = 2.0
    public static let minLoopDelay = 3.0
    public static let suggestedLoopDelay = 5.0
    /// Mouse moves must be at least this many, and this share of all actions, to be flagged.
    public static let manyMovesCount = 20
    public static let manyMovesShare = 0.5

    public static func analyze(
        recording: Recording,
        playback: PlaybackDefaults,
        verifyForeground: Bool,
        currentScreen: ScreenSize?
    ) -> [MacroFinding] {
        let actions = recording.actions
        guard !actions.isEmpty else { return [] }

        var findings: [MacroFinding] = []

        let moveCount = actions.filter { $0.kind == .move }.count
        let hasClicks = actions.contains { $0.kind == .click || $0.kind == .mouseDown }
        let hasText = actions.contains { $0.kind == .text }

        // Typed text that looks like a password.
        let secretCount = actions.filter { $0.kind == .text && looksLikeSecret($0.text ?? "") }.count
        if secretCount > 0 {
            findings.append(MacroFinding(
                id: "secret-text",
                severity: .warning,
                title: "Typed text may contain a password",
                detail: "\(secretCount) text action(s) look like a password or key (a single long word mixing letters, digits and symbols). Saved macros and exported files store typed text in plain, readable form. Delete those actions if they are secrets."
            ))
        }

        // Display changed since recording.
        if let recorded = recording.recordedScreen, let now = currentScreen,
           abs(recorded.width - now.width) > 1 || abs(recorded.height - now.height) > 1,
           hasClicks {
            findings.append(MacroFinding(
                id: "screen-changed",
                severity: .warning,
                title: "The display size changed",
                detail: "Recorded on \(Int(recorded.width))×\(Int(recorded.height)); the main display is now \(Int(now.width))×\(Int(now.height)). Recorded click positions may land in the wrong place."
            ))
        }

        // Fast repeated messaging.
        let hasPlainReturn = actions.contains {
            $0.kind == .key && ($0.keyCode == KeyCodes.returnKey || $0.keyCode == KeyCodes.keypadEnter)
                && ($0.modifiers ?? []).isEmpty
        }
        let repeatsALot = playback.repeatCount == 0 || playback.repeatCount >= 5
        if hasText && hasPlainReturn && repeatsALot && playback.loopDelay < minLoopDelay {
            findings.append(MacroFinding(
                id: "rapid-messages",
                severity: .warning,
                title: "This may send messages very quickly",
                detail: "The macro types text and presses Return, and repeats \(playback.repeatCount == 0 ? "until stopped" : "\(playback.repeatCount) times") with less than \(Int(minLoopDelay)) seconds between repetitions. Sending many messages fast can be treated as spam, and Discord may rate-limit or restrict the account. Add a longer delay between repetitions.",
                fix: .setLoopDelay(seconds: suggestedLoopDelay),
                fixLabel: "Set \(Int(suggestedLoopDelay)) s between repeats"
            ))
        }

        // Foreground check.
        if hasClicks || hasText {
            if recording.targetApp != nil && !verifyForeground {
                findings.append(MacroFinding(
                    id: "foreground-off",
                    severity: .warning,
                    title: "Nothing checks which app is in front",
                    detail: "If another window is in front when playback starts, the clicks and typing go there. Turning on the foreground check makes playback stop instead.",
                    fix: .enableForegroundCheck,
                    fixLabel: "Turn on foreground check"
                ))
            } else if recording.targetApp == nil {
                findings.append(MacroFinding(
                    id: "no-target-app",
                    severity: .info,
                    title: "No target app was recorded",
                    detail: "The foreground check needs to know which app this macro belongs to. Record it again with the target app in front to enable that check."
                ))
            }
        }

        // Many mouse-move actions.
        if moveCount >= manyMovesCount && Double(moveCount) / Double(actions.count) >= manyMovesShare {
            findings.append(MacroFinding(
                id: "many-moves",
                severity: .info,
                title: "\(moveCount) of \(actions.count) actions are mouse movements",
                detail: "Long movement paths make a macro slow to edit and add little. Removing them makes the pointer jump straight to each click. Keep them if something only appears when you hover.",
                fix: .removeMouseMoves,
                fixLabel: "Remove mouse movements"
            ))
        }

        // Long pauses.
        var longPauses = 0
        for action in actions {
            if action.delay > longPause { longPauses += 1 }
            if action.kind == .wait, (action.duration ?? 0) > longPause { longPauses += 1 }
        }
        if longPauses > 0 {
            findings.append(MacroFinding(
                id: "long-pauses",
                severity: .info,
                title: "\(longPauses) pause(s) longer than \(Int(longPause)) seconds",
                detail: "These are usually idle time while you were thinking during recording, not time the app needs. Shortening them speeds up the macro. Keep them if the app really needs that long to load.",
                fix: .capLongPauses(maxSeconds: pauseCap),
                fixLabel: "Shorten to \(Int(pauseCap)) s"
            ))
        }

        // Click-based macros are fragile.
        if hasClicks {
            findings.append(MacroFinding(
                id: "click-based",
                severity: .info,
                title: "This macro clicks at fixed screen positions",
                detail: "It breaks if the window moves or resizes, the display changes, or the app's layout changes. Where an app has a keyboard shortcut for the same step (for example Discord's Quick Switcher, ⌘K), a shortcut is more reliable than a click. Test at a slow speed first."
            ))
        }

        return findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity == .warning }
            return false
        }
    }

    /// Heuristic: one long word with at least three of: lowercase, uppercase, digits, symbols.
    /// Web addresses are excluded. It can be wrong in both directions; callers say "may".
    public static func looksLikeSecret(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count >= 8, characters.count <= 64 else { return false }
        if characters.contains(where: { $0.isWhitespace }) { return false }
        if text.lowercased().hasPrefix("http") { return false }

        var classes = 0
        if characters.contains(where: { $0.isLowercase }) { classes += 1 }
        if characters.contains(where: { $0.isUppercase }) { classes += 1 }
        if characters.contains(where: { $0.isNumber }) { classes += 1 }
        if characters.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        return classes >= 3
    }
}
