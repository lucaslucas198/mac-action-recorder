import Foundation

/// How exactly clicks and key presses are sent. The defaults suit most apps; raise them if an
/// app (or Discord's hover menus) misses fast input.
public struct InputTiming: Codable, Equatable {
    /// Wait after moving the pointer onto a click position, before pressing (hover state settles).
    public var settleBeforeClick = 0.012
    /// How long a mouse button stays down for a click.
    public var clickHold = 0.010
    /// Gap between the clicks of a double or triple click.
    public var doubleClickGap = 0.030
    /// How long a key stays down for a key press.
    public var keyHold = 0.008

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settleBeforeClick = c.value(.settleBeforeClick, settleBeforeClick)
        clickHold = c.value(.clickHold, clickHold)
        doubleClickGap = c.value(.doubleClickGap, doubleClickGap)
        keyHold = c.value(.keyHold, keyHold)
    }

    func sanitized() -> InputTiming {
        var t = self
        t.settleBeforeClick = Num.clamp(t.settleBeforeClick, 0...1)
        t.clickHold = Num.clamp(t.clickHold, 0.001...1)
        t.doubleClickGap = Num.clamp(t.doubleClickGap, 0.005...1)
        t.keyHold = Num.clamp(t.keyHold, 0.001...1)
        return t
    }
}

/// What the app knows about how you use Discord. It is used to make the Discord presets and the
/// optional on-device AI suggestions fit you. It is stored only on this Mac.
public struct DiscordProfile: Codable, Equatable {
    /// Channels or people you open often (typed into Discord's Quick Switcher).
    public var favoriteChannels: [String] = []
    /// Messages you send often.
    public var messageTemplates: [String] = []
    /// The shortest gap you want between messages. Discord can rate-limit fast senders.
    public var minSecondsBetweenMessages = 4.0
    /// Free text about what you use macros for ("moderating a server, welcoming new members").
    public var about = ""
    /// Rules that only apply to you ("never type @everyone", "server needs 10 s between posts").
    public var rules = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favoriteChannels = c.value(.favoriteChannels, favoriteChannels)
        messageTemplates = c.value(.messageTemplates, messageTemplates)
        minSecondsBetweenMessages = c.value(.minSecondsBetweenMessages, minSecondsBetweenMessages)
        about = c.value(.about, about)
        rules = c.value(.rules, rules)
    }

    /// True for the Discord desktop app (stable, PTB or Canary). It looks at the bundle ID prefix
    /// Discord's own releases use and at the app name, so a renamed copy is still found by name.
    public static func isDiscord(bundleID: String, name: String) -> Bool {
        return bundleID.lowercased().hasPrefix("com.hnc.discord") || name.lowercased().contains("discord")
    }

    func sanitized() -> DiscordProfile {
        var p = self
        p.minSecondsBetweenMessages = Num.clamp(p.minSecondsBetweenMessages, 0...3600)
        p.favoriteChannels = Array(p.favoriteChannels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(30))
        p.messageTemplates = Array(p.messageTemplates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(30))
        p.about = String(p.about.prefix(600))
        p.rules = String(p.rules.prefix(600))
        return p
    }

    /// A short block of text for the AI prompt (always includes the message spacing).
    public var promptContext: String {
        var lines: [String] = []
        if !favoriteChannels.isEmpty {
            lines.append("Channels or people the user opens often: " + favoriteChannels.joined(separator: ", ") + ".")
        }
        if !messageTemplates.isEmpty {
            lines.append("Messages the user sends often: " + messageTemplates.map { "\"\($0)\"" }.joined(separator: "; ") + ".")
        }
        lines.append("The user wants at least \(Int(minSecondsBetweenMessages.rounded())) seconds between messages.")
        let trimmedAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAbout.isEmpty { lines.append("What the user uses Discord macros for: " + trimmedAbout) }
        let trimmedRules = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRules.isEmpty { lines.append("The user's own rules: " + trimmedRules) }
        return lines.joined(separator: "\n")
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Equatable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: return "Match the system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum RowDensity: String, Codable, CaseIterable, Equatable {
    case comfortable
    case compact

    public var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }
}

/// All persistent app configuration. Stored as JSON so it is easy to inspect and transfer.
/// Every field has a default and unknown/missing keys are tolerated, so settings files written
/// by older or newer versions still load.
public struct AppSettings: Codable, Equatable {
    public var formatVersion = 1

    // Recording
    public var recording = RecordingOptions()
    /// Seconds to wait after pressing "Start Recording" so you can switch to the target app.
    public var recordingCountdown = 3
    public var hideWindowWhileRecording = true

    // Playback defaults (new recordings start with these)
    public var defaultSpeed = 1.0
    /// 0 = loop until stopped.
    public var defaultRepeatCount = 1
    public var defaultLoopDelay = 0.0
    public var playbackCountdown = 3
    public var minActionDelay = 0.02
    public var typingCharDelay = 0.012
    public var emergencyStop = HotKey.defaultEmergencyStop
    public var verifyForeground = true
    public var confirmBeforePlay = false
    public var hideWindowDuringPlayback = true
    /// Bring the app a macro was recorded in (for example Discord) to the front before playing.
    public var bringTargetToFront = true
    /// Start the target app first if it is not running.
    public var launchTargetIfClosed = true
    /// If the target window has moved since recording, shift the recorded clicks to match.
    public var followTargetWindow = true
    /// Put the pointer back where it was when playback ends.
    public var restorePointerAfterPlayback = false
    /// Play a short sound when recording or playback starts, finishes or stops by itself.
    public var soundEffects = false
    public var inputTiming = InputTiming()
    /// Global shortcut that pauses and resumes playback.
    public var pauseHotKey = HotKey.defaultPause
    public var safety = SafetyOptions()

    // Discord
    public var discord = DiscordProfile()
    /// Use the Discord profile when asking the on-device AI for suggestions.
    public var aiUsesDiscordProfile = true

    // Appearance and editing
    public var appearance = AppearanceMode.system
    public var rowDensity = RowDensity.comfortable
    public var showDelaysInList = true
    public var confirmBeforeDelete = true
    /// Prefix for the names of new recordings.
    public var newMacroNamePrefix = "Recording"

    // Storage
    /// nil = the default folder inside Application Support.
    public var saveDirectoryPath: String?
    public var autoSave = true
    public var exportDirectoryPath: String?
    public var backupEnabled = true
    public var backupKeepCount = 5
    public var backupDirectoryPath: String?

    // Privacy
    public var acknowledgedRecordingWarning = false

    // Updates
    /// Look for a newer version on GitHub (a single read-only request, at most every few hours).
    public var checkForUpdates = true
    /// Download a newer version in the background (the key keeps its old name so saved settings
    /// still load). It is only installed when you choose Restart to Update.
    public var autoBuildUpdates = true

    // First run
    /// True once the Welcome screen has been closed with its Enter button.
    public var hasCompletedWelcome = false

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = c.value(.formatVersion, formatVersion)
        recording = c.value(.recording, recording)
        recordingCountdown = c.value(.recordingCountdown, recordingCountdown)
        hideWindowWhileRecording = c.value(.hideWindowWhileRecording, hideWindowWhileRecording)
        defaultSpeed = c.value(.defaultSpeed, defaultSpeed)
        defaultRepeatCount = c.value(.defaultRepeatCount, defaultRepeatCount)
        defaultLoopDelay = c.value(.defaultLoopDelay, defaultLoopDelay)
        playbackCountdown = c.value(.playbackCountdown, playbackCountdown)
        minActionDelay = c.value(.minActionDelay, minActionDelay)
        typingCharDelay = c.value(.typingCharDelay, typingCharDelay)
        emergencyStop = c.value(.emergencyStop, emergencyStop)
        verifyForeground = c.value(.verifyForeground, verifyForeground)
        confirmBeforePlay = c.value(.confirmBeforePlay, confirmBeforePlay)
        hideWindowDuringPlayback = c.value(.hideWindowDuringPlayback, hideWindowDuringPlayback)
        bringTargetToFront = c.value(.bringTargetToFront, bringTargetToFront)
        launchTargetIfClosed = c.value(.launchTargetIfClosed, launchTargetIfClosed)
        followTargetWindow = c.value(.followTargetWindow, followTargetWindow)
        restorePointerAfterPlayback = c.value(.restorePointerAfterPlayback, restorePointerAfterPlayback)
        soundEffects = c.value(.soundEffects, soundEffects)
        inputTiming = c.value(.inputTiming, inputTiming)
        pauseHotKey = c.value(.pauseHotKey, pauseHotKey)
        safety = c.value(.safety, safety)
        discord = c.value(.discord, discord)
        aiUsesDiscordProfile = c.value(.aiUsesDiscordProfile, aiUsesDiscordProfile)
        appearance = c.value(.appearance, appearance)
        rowDensity = c.value(.rowDensity, rowDensity)
        showDelaysInList = c.value(.showDelaysInList, showDelaysInList)
        confirmBeforeDelete = c.value(.confirmBeforeDelete, confirmBeforeDelete)
        newMacroNamePrefix = c.value(.newMacroNamePrefix, newMacroNamePrefix)
        saveDirectoryPath = c.optionalValue(.saveDirectoryPath, saveDirectoryPath)
        autoSave = c.value(.autoSave, autoSave)
        exportDirectoryPath = c.optionalValue(.exportDirectoryPath, exportDirectoryPath)
        backupEnabled = c.value(.backupEnabled, backupEnabled)
        backupKeepCount = c.value(.backupKeepCount, backupKeepCount)
        backupDirectoryPath = c.optionalValue(.backupDirectoryPath, backupDirectoryPath)
        acknowledgedRecordingWarning = c.value(.acknowledgedRecordingWarning, acknowledgedRecordingWarning)
        checkForUpdates = c.value(.checkForUpdates, checkForUpdates)
        autoBuildUpdates = c.value(.autoBuildUpdates, autoBuildUpdates)
        hasCompletedWelcome = c.value(.hasCompletedWelcome, hasCompletedWelcome)
    }

    /// Returns a copy with every value forced into a safe range.
    public func sanitized() -> AppSettings {
        var s = self
        s.recording.minEventInterval = Num.clamp(s.recording.minEventInterval, 0...1)
        s.recording.minMoveDistance = Num.clamp(s.recording.minMoveDistance, 0...100)
        s.recordingCountdown = Num.clamp(s.recordingCountdown, 0...60)
        s.defaultSpeed = PlaybackTiming.clampSpeed(s.defaultSpeed)
        s.defaultRepeatCount = Num.clamp(s.defaultRepeatCount, 0...100_000)
        s.defaultLoopDelay = Num.clamp(s.defaultLoopDelay, 0...3600)
        s.playbackCountdown = Num.clamp(s.playbackCountdown, 0...60)
        s.minActionDelay = Num.clamp(s.minActionDelay, 0...5)
        s.typingCharDelay = Num.clamp(s.typingCharDelay, 0...1)
        s.backupKeepCount = Num.clamp(s.backupKeepCount, 1...100)
        s.inputTiming = s.inputTiming.sanitized()
        s.discord = s.discord.sanitized()
        let prefix = s.newMacroNamePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        s.newMacroNamePrefix = prefix.isEmpty ? "Recording" : String(prefix.prefix(40))
        if s.pauseHotKey.keyCode < 0 || s.pauseHotKey.keyCode > RecordingValidator.maxKeyCode
            || s.pauseHotKey.modifiers.isEmpty || s.pauseHotKey == s.emergencyStop {
            s.pauseHotKey = HotKey.defaultPause
        }
        if s.emergencyStop.keyCode < 0 || s.emergencyStop.keyCode > RecordingValidator.maxKeyCode
            || s.emergencyStop.modifiers.isEmpty {
            s.emergencyStop = HotKey.defaultEmergencyStop
        }
        return s
    }
}

/// Loads and saves `AppSettings` as a JSON file.
public final class SettingsStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Returns saved settings, or defaults when the file is missing or unreadable.
    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return AppSettings()
        }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings.sanitized()
    }

    public func save(_ settings: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings.sanitized())
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
