import Foundation

/// Everything the playback engine needs to know about how to run a recording.
public struct PlaybackConfig: Equatable {
    /// 1.0 = original timing. Clamped to `PlaybackTiming.minSpeed...maxSpeed`.
    public var speed: Double = 1.0
    /// Number of times to play (ignored when `infinite`). Values below 1 are treated as 1.
    public var repeatCount: Int = 1
    /// Loop until stopped.
    public var infinite: Bool = false
    /// Pause between repetitions, in seconds (not scaled by speed).
    public var loopDelay: Double = 0
    /// Seconds to count down before the first action.
    public var countdown: Int = 0
    /// Lower bound for gaps between non-movement actions when playing faster than 1x, so UI
    /// has time to react. It never makes a gap longer than the recorded one.
    public var minActionDelay: Double = 0.02
    /// Time between typed characters at 1x.
    public var typingCharDelay: Double = 0.012
    /// Fastest allowed typing, regardless of speed.
    public var minTypingCharDelay: Double = 0.004
    /// If set, playback fails unless this application is frontmost.
    public var requiredBundleID: String?
    public var requiredAppName: String?
    /// Replay only these action indices (a "selected section").
    public var range: Range<Int>?
    /// The first this-many actions of the played section run in the first repetition only.
    public var prefixCount: Int = 0
    /// Hold each click's button down as long as it was held when recorded (scaled by speed).
    public var clickHoldAsRecorded = true
    /// Type recorded text at the pace it was typed (scaled by speed) instead of `typingCharDelay`.
    public var typingAsRecorded = true

    public init() {}
}

public struct SpeedPreset: Equatable, Identifiable {
    public let value: Double
    public let label: String
    public let detail: String
    public var id: Double { value }

    public static let all: [SpeedPreset] = [
        SpeedPreset(value: 0.25, label: "0.25×", detail: "Very slow"),
        SpeedPreset(value: 0.5, label: "0.5×", detail: "Slow"),
        SpeedPreset(value: 1.0, label: "1×", detail: "Original timing"),
        SpeedPreset(value: 1.5, label: "1.5×", detail: "Faster"),
        SpeedPreset(value: 2.0, label: "2×", detail: "Double speed"),
        SpeedPreset(value: 5.0, label: "5×", detail: "Very fast")
    ]

    /// "2× — Double speed" for presets, "3.25× (custom)" otherwise.
    public static func describe(_ speed: Double) -> String {
        if let preset = all.first(where: { abs($0.value - speed) < 0.0001 }) {
            return "\(preset.label) — \(preset.detail)"
        }
        return PlaybackTiming.formatSpeed(speed) + " (custom)"
    }
}

public enum PlaybackTiming {
    public static let minSpeed = 0.05
    public static let maxSpeed = 20.0

    public static func clampSpeed(_ speed: Double) -> Double {
        if speed.isNaN || speed <= 0 { return 1.0 }
        return min(max(speed, minSpeed), maxSpeed)
    }

    public static func formatSpeed(_ speed: Double) -> String {
        let rounded = (speed * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))×"
        }
        return "\(rounded)×"
    }

    /// Kinds that need the target app to be frontmost (pointer moves and waits do not).
    public static func requiresForeground(_ kind: ActionKind) -> Bool {
        switch kind {
        case .move, .wait: return false
        default: return true
        }
    }

    /// Seconds to wait before performing `action` at the configured speed.
    ///
    /// - Recorded delays are divided by the speed, so order is preserved and all gaps scale
    ///   consistently (movement included).
    /// - Above 1x, gaps before clicks/keys/text/scrolls are never shorter than
    ///   `min(recorded gap, minActionDelay)` so slow-reacting UI stays reliable.
    /// - A `wait` action contributes its duration, scaled the same way.
    public static func scaledDelay(for action: MacroAction, config: PlaybackConfig) -> Double {
        let speed = clampSpeed(config.speed)
        var base = max(0, action.delay)
        if action.kind == .wait {
            base += max(0, action.duration ?? 0)
        }
        var scaled = base / speed

        switch action.kind {
        case .move, .drag, .wait:
            break
        default:
            if speed > 1.0 && base > 0 {
                let floor = min(base, max(0, config.minActionDelay))
                scaled = max(scaled, floor)
            }
        }
        return scaled
    }

    /// Seconds between typed characters at the configured speed.
    public static func typingDelay(config: PlaybackConfig) -> Double {
        let speed = clampSpeed(config.speed)
        let scaled = max(0, config.typingCharDelay) / speed
        return max(scaled, max(0, config.minTypingCharDelay))
    }

    /// Seconds between the characters of this text action: its recorded pace spread evenly over
    /// the characters when `typingAsRecorded` is on and the pace is known, otherwise
    /// `typingDelay`. Never faster than `minTypingCharDelay`.
    public static func typingDelay(for action: MacroAction, config: PlaybackConfig) -> Double {
        let count = (action.text ?? "").count
        guard config.typingAsRecorded, count > 1, let recorded = action.duration, recorded.isFinite, recorded > 0 else {
            return typingDelay(config: config)
        }
        let speed = clampSpeed(config.speed)
        let gap = recorded / Double(count - 1) / speed
        return max(gap, max(0, config.minTypingCharDelay))
    }

    /// How long each press of a click is held and the gap between presses. With a recorded time
    /// (first press to last release, already scaled for speed) a single click holds for exactly that
    /// long and a double or triple click spreads it over its presses, keeping each press short and
    /// the gaps inside the system's double-click time. Without one, the timing settings are used.
    public static func pressTiming(count: Int, recorded: Double?, clickHold: Double, doubleClickGap: Double) -> (hold: Double, gap: Double) {
        guard let total = recorded, total.isFinite, total > 0 else {
            return (clickHold, doubleClickGap)
        }
        if count <= 1 {
            return (min(total, maxClickHold), doubleClickGap)
        }
        let presses = Double(count)
        let hold = max(0.001, min(clickHold, total / (2 * presses - 1)))
        let gap = min(0.4, max(0.005, (total - presses * hold) / (presses - 1)))
        return (hold, gap)
    }

    /// How long performing this action is meant to take at the configured speed: the click's hold
    /// or the time between its first and last typed character. Zero for everything else.
    public static func plannedSpan(of action: MacroAction, config: PlaybackConfig) -> Double {
        switch action.kind {
        case .click:
            return clickHold(for: action, config: config) ?? 0
        case .text:
            let count = (action.text ?? "").count
            return count > 1 ? Double(count - 1) * typingDelay(for: action, config: config) : 0
        default:
            return 0
        }
    }

        /// Longest single click hold that is replayed; longer recorded holds are shortened to this.
    public static let maxClickHold = 30.0

    /// How long to hold the button for this click at the configured speed, or nil to use the
    /// performer's own click timing (no recorded hold, or the option is off). For a double or
    /// triple click this is the whole time from the first press to the last release.
    public static func clickHold(for action: MacroAction, config: PlaybackConfig) -> Double? {
        guard action.kind == .click, config.clickHoldAsRecorded,
              let recorded = action.duration, recorded.isFinite, recorded > 0 else { return nil }
        let speed = clampSpeed(config.speed)
        return min(recorded, maxClickHold) / speed
    }

    /// Estimated duration of one pass over `actions` (excludes time the system takes to post events).
    public static func estimatedDuration(of actions: [MacroAction], config: PlaybackConfig) -> Double {
        var total = 0.0
        for action in actions {
            total += scaledDelay(for: action, config: config)
            if action.kind == .text {
                let count = max(0, (action.text ?? "").count - 1)
                total += Double(count) * typingDelay(for: action, config: config)
            }
            if let hold = clickHold(for: action, config: config) {
                total += hold
            }
        }
        return total
    }

    /// Number of passes, or nil for "until stopped".
    public static func totalIterations(config: PlaybackConfig) -> Int? {
        if config.infinite { return nil }
        return max(1, config.repeatCount)
    }

    /// Estimated total time for the whole run, or nil when looping forever.
    public static func estimatedTotal(of actions: [MacroAction], config: PlaybackConfig) -> Double? {
        guard let iterations = totalIterations(config: config) else { return nil }
        let single = estimatedDuration(of: actions, config: config)
        let gaps = Double(max(0, iterations - 1)) * max(0, config.loopDelay)
        return single * Double(iterations) + gaps + Double(max(0, config.countdown))
    }
}
