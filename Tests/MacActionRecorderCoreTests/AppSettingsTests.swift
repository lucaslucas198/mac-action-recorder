import XCTest
@testable import MacActionRecorderCore

final class AppSettingsTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacActionRecorderSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.defaultSpeed, 1.0)
        XCTAssertEqual(settings.defaultRepeatCount, 1)
        XCTAssertEqual(settings.defaultLoopDelay, 0)
        XCTAssertTrue(settings.autoSave)
        XCTAssertTrue(settings.verifyForeground)
        XCTAssertEqual(settings.emergencyStop, HotKey.defaultEmergencyStop)
        XCTAssertEqual(settings.emergencyStop.displayString, "⌃⌥⌘S")
        XCTAssertTrue(settings.recording.includeMouseMove)
        XCTAssertFalse(settings.acknowledgedRecordingWarning)
    }

    func testSettingsPersistAcrossStoreInstances() throws {
        var settings = AppSettings()
        settings.defaultSpeed = 2.5
        settings.defaultRepeatCount = 4
        settings.defaultLoopDelay = 1.5
        settings.playbackCountdown = 7
        settings.minActionDelay = 0.05
        settings.verifyForeground = true
        settings.confirmBeforePlay = true
        settings.hideWindowDuringPlayback = false
        settings.emergencyStop = HotKey(keyCode: 11, modifiers: [.control, .shift])
        settings.recording.includeMouseMove = false
        settings.recording.recordScroll = false
        settings.recording.minEventInterval = 0.1
        settings.recording.minMoveDistance = 8
        settings.saveDirectoryPath = "/tmp/my-recordings"
        settings.autoSave = false
        settings.backupKeepCount = 9
        settings.acknowledgedRecordingWarning = true

        try SettingsStore(fileURL: fileURL).save(settings)
        let loaded = SettingsStore(fileURL: fileURL).load()   // a fresh instance, like a relaunch

        XCTAssertEqual(loaded, settings)
    }

    func testMissingFileGivesDefaults() {
        XCTAssertEqual(SettingsStore(fileURL: fileURL).load(), AppSettings())
    }

    func testCorruptFileGivesDefaultsInsteadOfCrashing() throws {
        try Data("{{{ not json".utf8).write(to: fileURL)
        XCTAssertEqual(SettingsStore(fileURL: fileURL).load(), AppSettings())
    }

    func testPartialFileKeepsDefaultsForMissingKeys() throws {
        try Data("{\"defaultSpeed\": 3, \"autoSave\": false}".utf8).write(to: fileURL)
        let loaded = SettingsStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.defaultSpeed, 3)
        XCTAssertFalse(loaded.autoSave)
        XCTAssertEqual(loaded.defaultRepeatCount, 1)
        XCTAssertEqual(loaded.emergencyStop, HotKey.defaultEmergencyStop)
    }

    func testUnknownKeysAndWrongTypesAreTolerated() throws {
        try Data("{\"defaultSpeed\": \"fast\", \"autoSave\": false, \"someFutureSetting\": [1,2,3]}".utf8).write(to: fileURL)
        let loaded = SettingsStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.defaultSpeed, 1.0, "unreadable value falls back to the default")
        XCTAssertFalse(loaded.autoSave, "readable values are still applied")
    }

    func testLoadedValuesAreClampedToSafeRanges() throws {
        try Data("{\"defaultSpeed\": 999, \"playbackCountdown\": -4, \"backupKeepCount\": 0, \"defaultRepeatCount\": -2}".utf8)
            .write(to: fileURL)
        let loaded = SettingsStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.defaultSpeed, PlaybackTiming.maxSpeed)
        XCTAssertEqual(loaded.playbackCountdown, 0)
        XCTAssertEqual(loaded.backupKeepCount, 1)
        XCTAssertEqual(loaded.defaultRepeatCount, 0)
    }

    func testSanitizeHandlesNaNAndBadHotKey() {
        var settings = AppSettings()
        settings.defaultSpeed = .nan
        settings.defaultLoopDelay = .nan
        settings.emergencyStop = HotKey(keyCode: 12, modifiers: [])   // a bare key would hijack typing
        let clean = settings.sanitized()
        XCTAssertEqual(clean.defaultSpeed, 1.0)
        XCTAssertEqual(clean.defaultLoopDelay, 0)
        XCTAssertEqual(clean.emergencyStop, HotKey.defaultEmergencyStop)
    }

    func testSaveCreatesMissingDirectories() throws {
        let nested = directory.appendingPathComponent("deep/er/settings.json")
        try SettingsStore(fileURL: nested).save(AppSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testHotKeyMatchingIsExact() {
        let hotKey = HotKey(keyCode: 1, modifiers: [.control, .option, .command])
        XCTAssertTrue(hotKey.matches(keyCode: 1, modifiers: [.control, .option, .command]))
        XCTAssertFalse(hotKey.matches(keyCode: 1, modifiers: [.control, .option]))
        XCTAssertFalse(hotKey.matches(keyCode: 1, modifiers: [.control, .option, .command, .shift]))
        XCTAssertFalse(hotKey.matches(keyCode: 2, modifiers: [.control, .option, .command]))
    }
}
