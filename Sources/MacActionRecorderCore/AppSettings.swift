import Foundation

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
    public var verifyForeground = false
    public var confirmBeforePlay = false
    public var hideWindowDuringPlayback = true

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
        saveDirectoryPath = c.optionalValue(.saveDirectoryPath, saveDirectoryPath)
        autoSave = c.value(.autoSave, autoSave)
        exportDirectoryPath = c.optionalValue(.exportDirectoryPath, exportDirectoryPath)
        backupEnabled = c.value(.backupEnabled, backupEnabled)
        backupKeepCount = c.value(.backupKeepCount, backupKeepCount)
        backupDirectoryPath = c.optionalValue(.backupDirectoryPath, backupDirectoryPath)
        acknowledgedRecordingWarning = c.value(.acknowledgedRecordingWarning, acknowledgedRecordingWarning)
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
