import Foundation

public enum RecordingFormat {
    /// The file-format version written by this build. See docs/RECORDING_FORMAT.md.
    public static let currentVersion = 1
    /// Recordings are stored as `<uuid>.macro.json`.
    public static let fileExtension = "macro.json"
}

public enum MouseButton: String, Codable, CaseIterable, Equatable, Hashable {
    case left
    case right
    case other

    public var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .other: return "Middle"
        }
    }
}

public enum ActionKind: String, Codable, CaseIterable, Equatable {
    /// Move the pointer.
    case move
    /// Move the pointer with a button held down.
    case drag
    /// Press a mouse button and keep it down.
    case mouseDown
    /// Release a mouse button.
    case mouseUp
    /// Press and release a button (clickCount 2 = double-click).
    case click
    /// Scroll wheel / trackpad scroll.
    case scroll
    /// Press and release one key, optionally with modifiers (shortcuts, Return, arrows...).
    case key
    /// Type a string of text, layout-independent.
    case text
    /// Pause for `duration` seconds.
    case wait

    public var displayName: String {
        switch self {
        case .move: return "Move"
        case .drag: return "Drag"
        case .mouseDown: return "Mouse down"
        case .mouseUp: return "Mouse up"
        case .click: return "Click"
        case .scroll: return "Scroll"
        case .key: return "Key"
        case .text: return "Type text"
        case .wait: return "Wait"
        }
    }
}

/// One step of a macro.
///
/// `delay` is the time in seconds to wait *before* this action, measured from the end of
/// the previous action, at original (1x) speed. Using relative delays keeps editing simple:
/// reordering or deleting actions never leaves stale absolute timestamps behind.
public struct MacroAction: Codable, Identifiable, Equatable {
    public var id: UUID
    public var kind: ActionKind
    public var delay: Double

    // Pointer position in global screen coordinates (points, origin top-left of the main display).
    public var x: Double?
    public var y: Double?
    public var button: MouseButton?
    public var clickCount: Int?

    // Scroll amounts in pixels.
    public var scrollX: Int?
    public var scrollY: Int?

    // Keyboard.
    public var keyCode: Int?
    public var modifiers: KeyModifiers?
    public var text: String?

    // Wait.
    public var duration: Double?

    public init(
        id: UUID = UUID(),
        kind: ActionKind,
        delay: Double = 0,
        x: Double? = nil,
        y: Double? = nil,
        button: MouseButton? = nil,
        clickCount: Int? = nil,
        scrollX: Int? = nil,
        scrollY: Int? = nil,
        keyCode: Int? = nil,
        modifiers: KeyModifiers? = nil,
        text: String? = nil,
        duration: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.delay = delay
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.text = text
        self.duration = duration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try c.decode(ActionKind.self, forKey: .kind)
        self.delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        self.x = try c.decodeIfPresent(Double.self, forKey: .x)
        self.y = try c.decodeIfPresent(Double.self, forKey: .y)
        self.button = try c.decodeIfPresent(MouseButton.self, forKey: .button)
        self.clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount)
        self.scrollX = try c.decodeIfPresent(Int.self, forKey: .scrollX)
        self.scrollY = try c.decodeIfPresent(Int.self, forKey: .scrollY)
        self.keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode)
        self.modifiers = try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.duration = try c.decodeIfPresent(Double.self, forKey: .duration)
    }
}

// MARK: - Convenience constructors

extension MacroAction {
    public static func move(x: Double, y: Double, delay: Double = 0) -> MacroAction {
        MacroAction(kind: .move, delay: delay, x: x, y: y)
    }

    public static func drag(x: Double, y: Double, button: MouseButton = .left, delay: Double = 0) -> MacroAction {
        MacroAction(kind: .drag, delay: delay, x: x, y: y, button: button)
    }

    public static func mouseDown(x: Double, y: Double, button: MouseButton = .left, delay: Double = 0) -> MacroAction {
        MacroAction(kind: .mouseDown, delay: delay, x: x, y: y, button: button)
    }

    public static func mouseUp(x: Double, y: Double, button: MouseButton = .left, delay: Double = 0) -> MacroAction {
        MacroAction(kind: .mouseUp, delay: delay, x: x, y: y, button: button)
    }

    public static func click(
        x: Double, y: Double, button: MouseButton = .left, count: Int = 1, delay: Double = 0
    ) -> MacroAction {
        MacroAction(kind: .click, delay: delay, x: x, y: y, button: button, clickCount: count)
    }

    public static func scroll(
        dx: Int = 0, dy: Int = 0, x: Double? = nil, y: Double? = nil, delay: Double = 0
    ) -> MacroAction {
        MacroAction(kind: .scroll, delay: delay, x: x, y: y, scrollX: dx, scrollY: dy)
    }

    public static func key(_ keyCode: Int, modifiers: KeyModifiers = [], delay: Double = 0) -> MacroAction {
        MacroAction(kind: .key, delay: delay, keyCode: keyCode, modifiers: modifiers)
    }

    public static func text(_ text: String, delay: Double = 0) -> MacroAction {
        MacroAction(kind: .text, delay: delay, text: text)
    }

    public static func wait(_ seconds: Double, delay: Double = 0) -> MacroAction {
        MacroAction(kind: .wait, delay: delay, duration: seconds)
    }
}

public struct ScreenSize: Codable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// The application a recording was made against (used for the optional foreground check).
public struct TargetApp: Codable, Equatable, Hashable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Playback settings stored with a recording so they travel with the file.
public struct PlaybackDefaults: Codable, Equatable {
    public var speed: Double
    /// Number of repetitions; 0 means "loop until stopped".
    public var repeatCount: Int
    public var loopDelay: Double

    public init(speed: Double = 1.0, repeatCount: Int = 1, loopDelay: Double = 0) {
        self.speed = speed
        self.repeatCount = repeatCount
        self.loopDelay = loopDelay
    }
}

public struct Recording: Codable, Identifiable, Equatable {
    public var formatVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var targetApp: TargetApp?
    /// Size of the main display when recorded; used to warn about geometry changes.
    public var recordedScreen: ScreenSize?
    public var playbackDefaults: PlaybackDefaults?
    public var notes: String?
    public var actions: [MacroAction]

    public init(
        formatVersion: Int = RecordingFormat.currentVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        targetApp: TargetApp? = nil,
        recordedScreen: ScreenSize? = nil,
        playbackDefaults: PlaybackDefaults? = nil,
        notes: String? = nil,
        actions: [MacroAction] = []
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.targetApp = targetApp
        self.recordedScreen = recordedScreen
        self.playbackDefaults = playbackDefaults
        self.notes = notes
        self.actions = actions
    }

    /// Total recorded time at 1x: all delays plus explicit waits (typing time not included).
    public var originalDuration: Double {
        var total = 0.0
        for action in actions {
            total += action.delay
            if action.kind == .wait {
                total += action.duration ?? 0
            }
        }
        return total
    }
}
