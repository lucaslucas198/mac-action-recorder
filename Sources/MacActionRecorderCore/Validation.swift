import Foundation

public struct ValidationIssue: Equatable, CustomStringConvertible {
    public enum Severity: Equatable {
        case error
        case warning
    }

    public var severity: Severity
    /// Zero-based index of the offending action, or nil for recording-level issues.
    public var actionIndex: Int?
    public var message: String

    public init(severity: Severity, actionIndex: Int? = nil, message: String) {
        self.severity = severity
        self.actionIndex = actionIndex
        self.message = message
    }

    public var description: String {
        if let index = actionIndex {
            return "Action \(index + 1): \(message)"
        }
        return message
    }
}

public enum RecordingValidator {
    public static let defaultMaxActions = 500_000
    /// Longest single delay/wait accepted (24 hours).
    public static let maxDelay = 86_400.0
    public static let maxText = 100_000
    public static let maxCoordinate = 100_000.0
    public static let maxScroll = 100_000
    public static let maxKeyCode = 255

    /// Checks a whole recording. Errors block playback; warnings are informational.
    public static func validate(_ recording: Recording, maxActions: Int = defaultMaxActions) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if recording.formatVersion < 1 || recording.formatVersion > RecordingFormat.currentVersion {
            issues.append(ValidationIssue(
                severity: .error,
                message: "Unsupported format version \(recording.formatVersion)."
            ))
        }

        if recording.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ValidationIssue(severity: .warning, message: "The recording has no name."))
        }

        if recording.actions.count > maxActions {
            issues.append(ValidationIssue(
                severity: .error,
                message: "Too many actions (\(recording.actions.count)); the limit is \(maxActions)."
            ))
            // Don't walk an enormous array just to produce more errors.
            return issues
        }

        if recording.actions.isEmpty {
            issues.append(ValidationIssue(severity: .warning, message: "The recording has no actions."))
        }

        for (index, action) in recording.actions.enumerated() {
            issues.append(contentsOf: validate(action: action, index: index))
        }
        return issues
    }

    /// Checks a single action. Used by the editor before accepting changes.
    public static func validate(action: MacroAction, index: Int? = nil) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        func fail(_ message: String) {
            issues.append(ValidationIssue(severity: .error, actionIndex: index, message: message))
        }

        if !action.delay.isFinite || action.delay < 0 || action.delay > maxDelay {
            fail("Delay must be between 0 and \(Int(maxDelay)) seconds.")
        }

        func checkPoint() {
            guard let x = action.x, let y = action.y else {
                fail("\(action.kind.displayName) needs x and y coordinates.")
                return
            }
            if !x.isFinite || !y.isFinite || abs(x) > maxCoordinate || abs(y) > maxCoordinate {
                fail("Coordinates are out of range.")
            }
        }

        switch action.kind {
        case .move:
            checkPoint()

        case .drag, .mouseDown, .mouseUp:
            checkPoint()
            if action.button == nil {
                fail("\(action.kind.displayName) needs a mouse button.")
            }

        case .click:
            checkPoint()
            if action.button == nil {
                fail("Click needs a mouse button.")
            }
            if let count = action.clickCount {
                if count < 1 || count > 3 {
                    fail("Click count must be 1, 2 or 3.")
                }
            } else {
                fail("Click needs a click count.")
            }

        case .scroll:
            if action.scrollX == nil && action.scrollY == nil {
                fail("Scroll needs a horizontal or vertical amount.")
            }
            if let dx = action.scrollX, abs(dx) > maxScroll { fail("Scroll amount is out of range.") }
            if let dy = action.scrollY, abs(dy) > maxScroll { fail("Scroll amount is out of range.") }
            if action.x != nil || action.y != nil {
                checkPoint()
            }

        case .key:
            if let code = action.keyCode {
                if code < 0 || code > maxKeyCode {
                    fail("Key code must be between 0 and \(maxKeyCode).")
                }
            } else {
                fail("Key press needs a key code.")
            }

        case .text:
            if let text = action.text {
                if text.isEmpty { fail("Text must not be empty.") }
                if text.count > maxText { fail("Text is too long.") }
            } else {
                fail("Text action needs text.")
            }

        case .wait:
            if let duration = action.duration {
                if !duration.isFinite || duration < 0 || duration > maxDelay {
                    fail("Wait must be between 0 and \(Int(maxDelay)) seconds.")
                }
            } else {
                fail("Wait needs a duration.")
            }
        }

        if let app = action.app, app.count > 255 {
            fail("The recorded app name is too long.")
        }

        // Clicks and text may carry the time they took when recorded.
        if action.kind == .click || action.kind == .text, let duration = action.duration,
           !duration.isFinite || duration < 0 || duration > maxDelay {
            fail("The recorded duration must be between 0 and \(Int(maxDelay)) seconds.")
        }

        return issues
    }

    public static func errors(in issues: [ValidationIssue]) -> [ValidationIssue] {
        return issues.filter { $0.severity == .error }
    }
}
