import Foundation

/// Options for stopping playback by itself. Every rule only fires on a fact the app can read
/// from macOS (which app is running, where its window is, how big the display is). There is no
/// guessing: if the app cannot be certain something is wrong, it does not stop.
public struct SafetyOptions: Codable, Equatable {
    /// Master switch for the checks below (not for "only play while the recorded app is in front",
    /// which has its own setting).
    public var enabled = true
    /// Stop if the target app quits or has no window on screen.
    public var stopIfTargetGone = true
    /// Stop if the target window changed size, or moved while "follow the window" is off.
    public var stopIfWindowChanged = true
    /// Stop if the main display has a different size than when the macro was recorded.
    public var stopIfDisplayChanged = true
    /// Stop if the pointer is somewhere other than where the macro put it (you grabbed the mouse).
    public var stopIfUserMovesMouse = false

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, enabled)
        stopIfTargetGone = c.value(.stopIfTargetGone, stopIfTargetGone)
        stopIfWindowChanged = c.value(.stopIfWindowChanged, stopIfWindowChanged)
        stopIfDisplayChanged = c.value(.stopIfDisplayChanged, stopIfDisplayChanged)
        stopIfUserMovesMouse = c.value(.stopIfUserMovesMouse, stopIfUserMovesMouse)
    }
}

/// What the app knows about the macro it is about to run.
public struct SafetyContext: Equatable {
    public var target: TargetApp?
    public var recordedWindow: WindowFrame?
    public var recordedScreen: ScreenSize?
    /// Whether clicks are being shifted to follow the window (see `WindowRelocation`).
    public var followWindow: Bool

    public init(target: TargetApp?, recordedWindow: WindowFrame?, recordedScreen: ScreenSize?, followWindow: Bool) {
        self.target = target
        self.recordedWindow = recordedWindow
        self.recordedScreen = recordedScreen
        self.followWindow = followWindow
    }
}

/// A reading of the system taken just before an action. `nil` means "could not be read", and a
/// value that could not be read never causes a stop.
public struct SafetySnapshot: Equatable {
    /// Whether the target app is running.
    public var targetRunning: Bool?
    /// The target app's front window on screen. `nil` with `windowKnown == true` means "has none".
    public var window: WindowFrame?
    /// True when the window list could be read at all (so a missing window is a fact, not a gap).
    public var windowKnown: Bool
    public var screen: ScreenSize?
    /// Distance in points between where the macro last put the pointer and where it is now.
    public var pointerDrift: Double?

    public init(
        targetRunning: Bool? = nil,
        window: WindowFrame? = nil,
        windowKnown: Bool = false,
        screen: ScreenSize? = nil,
        pointerDrift: Double? = nil
    ) {
        self.targetRunning = targetRunning
        self.window = window
        self.windowKnown = windowKnown
        self.screen = screen
        self.pointerDrift = pointerDrift
    }
}

public enum SafetyWatchdog {
    public static let messagePrefix = "Safety stop: "
    /// A pointer further than this from where the macro put it counts as "moved by someone else".
    public static let driftThreshold = 12.0

    /// Returns the reason to stop before performing an action of `kind`, or nil to carry on.
    public static func evaluate(
        options: SafetyOptions,
        context: SafetyContext,
        snapshot: SafetySnapshot,
        actionKind: ActionKind
    ) -> String? {
        guard options.enabled else { return nil }
        let positional = WindowRelocation.isPositional(actionKind)
        let name = context.target?.name ?? "The target app"

        if options.stopIfTargetGone, context.target != nil {
            if snapshot.targetRunning == false {
                return messagePrefix + "\(name) is not running any more."
            }
            if snapshot.windowKnown, snapshot.targetRunning == true, snapshot.window == nil, context.recordedWindow != nil {
                return messagePrefix + "\(name) has no window on screen (it was closed, minimized or is on another desktop)."
            }
        }

        var windowOK = false
        if options.stopIfWindowChanged, positional, let recorded = context.recordedWindow, let current = snapshot.window {
            switch WindowRelocation.assess(recorded: recorded, current: current) {
            case .same:
                windowOK = true
            case .resized:
                return messagePrefix + "The \(name) window changed size (recorded \(Int(recorded.width))×\(Int(recorded.height)), now \(Int(current.width))×\(Int(current.height))), so the recorded click positions no longer line up."
            case .moved(let dx, let dy):
                if context.followWindow {
                    windowOK = true
                } else {
                    return messagePrefix + "The \(name) window moved (by \(Int(dx)), \(Int(dy)) points), and \"follow the window\" is off, so clicks would land in the wrong place."
                }
            }
        }

        if options.stopIfDisplayChanged, positional, !windowOK,
           let recorded = context.recordedScreen, let now = snapshot.screen,
           abs(recorded.width - now.width) > 1 || abs(recorded.height - now.height) > 1 {
            return messagePrefix + "The main display changed from \(Int(recorded.width))×\(Int(recorded.height)) to \(Int(now.width))×\(Int(now.height)), so recorded positions may be wrong."
        }

        if options.stopIfUserMovesMouse, let drift = snapshot.pointerDrift, drift > driftThreshold {
            return messagePrefix + "The mouse pointer was moved by something other than the macro."
        }
        return nil
    }
}
