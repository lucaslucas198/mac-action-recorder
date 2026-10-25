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

    /// Estimated duration of one pass over `actions` (excludes time the system takes to post events).
    public static func estimatedDuration(of actions: [MacroAction], config: PlaybackConfig) -> Double {
        var total = 0.0
        for action in actions {
            total += scaledDelay(for: action, config: config)
            if action.kind == .text {
                let count = max(0, (action.text ?? "").count - 1)
                total += Double(count) * typingDelay(config: config)
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
