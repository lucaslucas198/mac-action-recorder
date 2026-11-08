import Foundation

// MARK: - Model

/// A daily time window in which repetitions may start, in local time.
///
/// `start` and `end` are minutes after local midnight (0...1439). A window whose end is earlier
/// than its start runs past midnight (22:00 to 02:00). A window whose start equals its end is
/// invalid.
public struct SendWindow: Codable, Equatable, Hashable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Length in minutes (1...1439 for a valid window).
    public var lengthInMinutes: Int {
        let s = SendWindow.clampMinute(start)
        let e = SendWindow.clampMinute(end)
        return e > s ? e - s : 24 * 60 - s + e
    }

    public var isValid: Bool {
        return (0..<1440).contains(start) && (0..<1440).contains(end) && start != end
    }

    static func clampMinute(_ value: Int) -> Int {
        return min(1439, max(0, value))
    }

    /// "09:00–17:30"
    public var displayText: String {
        return SendWindow.clock(start) + "–" + SendWindow.clock(end)
    }

    public static func clock(_ minute: Int) -> String {
        let m = clampMinute(minute)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

/// Settings for repeating a macro as a "campaign": a list of messages and Discord channels that
/// change on every repetition, the times of day repetitions may start, and a daily cap.
///
/// It works through the normal desktop interface: `{message}` and `{channel}` in a macro's
/// "Type text" steps are replaced before each repetition, and with channels set every repetition
/// first opens the channel with Discord's Quick Switcher (⌘K). Nothing here talks to Discord
/// directly.
///
/// Order (each repetition is one "run"): the current message goes to every channel in order,
/// then the next message starts. With messages 1, 2 and channels A, B the runs are
/// 1→A, 1→B, 2→A, 2→B, 1→A, ...
public struct Campaign: Codable, Equatable {
    /// Text that replaces `{message}`, one entry per variant. Blank entries are skipped.
    public var messages: [String]
    /// Text that replaces `{channel}` (a channel or person name for the Quick Switcher).
    /// Blank entries are skipped.
    public var channels: [String]
    /// When repetitions may start. Empty means any time.
    public var sendWindows: [SendWindow]
    /// The most repetitions that may finish per local day for this macro. nil = no limit.
    public var dailyLimit: Int?
    /// The next run in the rotation. Stopping keeps it, so the next play carries on where it
    /// stopped; duplicating a macro starts the copy from the first message and channel.
    public var position: Int

    public init(
        messages: [String] = [],
        channels: [String] = [],
        sendWindows: [SendWindow] = [],
        dailyLimit: Int? = nil,
        position: Int = 0
    ) {
        self.messages = messages
        self.channels = channels
        self.sendWindows = sendWindows
        self.dailyLimit = dailyLimit
        self.position = position
    }

    public init(from decoder: Decoder) throws {
        // Lenient: a bad field is dropped instead of making the whole recording unreadable.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try? c.decodeIfPresent([String].self, forKey: .messages)) ?? []
        channels = (try? c.decodeIfPresent([String].self, forKey: .channels)) ?? []
        sendWindows = (try? c.decodeIfPresent([SendWindow].self, forKey: .sendWindows)) ?? []
        dailyLimit = try? c.decodeIfPresent(Int.self, forKey: .dailyLimit)
        position = max(0, (try? c.decodeIfPresent(Int.self, forKey: .position)) ?? 0)
    }

    public static let messagePlaceholder = "{message}"
    public static let channelPlaceholder = "{channel}"
    public static let maxEntries = 50
    public static let maxWindows = 8

    public var activeMessages: [String] {
        return messages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var activeChannels: [String] {
        return channels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// True when the campaign changes anything about a run.
    public var isEffective: Bool {
        return !activeMessages.isEmpty || !activeChannels.isEmpty || !sendWindows.isEmpty || dailyLimit != nil
    }

    /// Runs in one full cycle through every message and channel (at least 1).
    public var cycleLength: Int {
        return max(1, activeMessages.count) * max(1, activeChannels.count)
    }

    /// What run number `position` uses.
    public func step(at position: Int) -> CampaignStep {
        let p = max(0, position)
        let messages = activeMessages
        let channels = activeChannels
        let channelCount = max(1, channels.count)
        var step = CampaignStep(position: p)
        if !channels.isEmpty {
            step.channelIndex = p % channelCount
            step.channel = channels[p % channelCount]
        }
        if !messages.isEmpty {
            let index = (p / channelCount) % messages.count
            step.messageIndex = index
            step.message = messages[index]
        }
        return step
    }
}

/// The message and channel one run uses.
public struct CampaignStep: Equatable {
    /// The rotation position this run used.
    public var position: Int
    /// Zero-based index into `Campaign.activeMessages`, nil when there are no messages.
    public var messageIndex: Int?
    public var message: String?
    public var channelIndex: Int?
    public var channel: String?

    public init(position: Int, messageIndex: Int? = nil, message: String? = nil, channelIndex: Int? = nil, channel: String? = nil) {
        self.position = position
        self.messageIndex = messageIndex
        self.message = message
        self.channelIndex = channelIndex
        self.channel = channel
    }

    /// "Message 2 → general"
    public var summary: String {
        var parts: [String] = []
        if let index = messageIndex { parts.append("Message \(index + 1)") }
        if let channel = channel { parts.append(channel) }
        return parts.isEmpty ? "Run \(position + 1)" : parts.joined(separator: " → ")
    }

    /// Replaces `{message}` and `{channel}` in the "Type text" steps. Placeholders with nothing
    /// to put in are left as they are (the analyzer warns about those).
    public func apply(to actions: [MacroAction]) -> [MacroAction] {
        guard message != nil || channel != nil else { return actions }
        return actions.map { action in
            guard action.kind == .text, var text = action.text else { return action }
            if let message = message {
                text = text.replacingOccurrences(of: Campaign.messagePlaceholder, with: message)
            }
            if let channel = channel {
                text = text.replacingOccurrences(of: Campaign.channelPlaceholder, with: channel)
            }
            var copy = action
            copy.text = text
            return copy
        }
    }
}

extension Recording {
    /// True when a "Type text" step contains `placeholder`.
    public func usesPlaceholder(_ placeholder: String) -> Bool {
        return actions.contains { $0.kind == .text && ($0.text ?? "").contains(placeholder) }
    }
}

// MARK: - Schedule

/// Time-of-day and per-day arithmetic for campaigns. Pure functions, so they can be tested with
/// any date and calendar.
public enum SendSchedule {
    /// True when `date` is inside one of the windows (or there are none).
    public static func isAllowed(_ date: Date, windows: [SendWindow], calendar: Calendar = .current) -> Bool {
        return nextAllowed(from: date, windows: windows, calendar: calendar) == date
    }

    /// `date` itself when a run may start then, otherwise the start of the next window.
    /// Invalid windows are ignored; with no valid window the answer is `date`.
    public static func nextAllowed(from date: Date, windows: [SendWindow], calendar: Calendar = .current) -> Date {
        let valid = windows.filter { $0.isValid }
        guard !valid.isEmpty else { return date }
        let today = calendar.startOfDay(for: date)
        var soonest: Date?
        // Yesterday's windows can still be open after midnight; a week ahead is more than enough.
        for offset in -1...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for window in valid {
                guard let open = calendar.date(byAdding: .minute, value: window.start, to: day),
                      let close = calendar.date(byAdding: .minute, value: window.lengthInMinutes, to: open) else { continue }
                if open <= date && date < close { return date }
                if open > date, soonest.map({ open < $0 }) ?? true {
                    soonest = open
                }
            }
        }
        return soonest ?? date
    }

    /// Local midnight at the start of the day after `date`.
    public static func startOfNextDay(after date: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400)
    }
}

// MARK: - Waiting

/// Why playback is waiting before the next repetition.
public enum PlaybackWaitReason: Equatable {
    /// The "delay between repetitions".
    case loopDelay
    /// Outside every send window.
    case sendWindow
    /// The macro's daily limit has been reached.
    case dailyLimit
}

public struct PlaybackWait: Equatable {
    public var until: Date
    public var reason: PlaybackWaitReason

    public init(until: Date, reason: PlaybackWaitReason) {
        self.until = until
        self.reason = reason
    }
}
