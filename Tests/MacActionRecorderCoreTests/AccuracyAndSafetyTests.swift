import XCTest
@testable import MacActionRecorderCore

/// Modifier keys on mouse events, following a moved window, the safety watchdog, and the
/// Discord-aware settings and checks.
final class AccuracyAndSafetyTests: XCTestCase {
    // MARK: Modifier keys on clicks

    func testShiftClickKeepsItsModifier() {
        let events = [
            RawEvent(time: 0, x: 10, y: 20, kind: .mouseDown(.left, clickCount: 1), modifiers: [.shift]),
            RawEvent(time: 0.05, x: 10, y: 20, kind: .mouseUp(.left, clickCount: 1), modifiers: [.shift])
        ]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].kind, .click)
        XCTAssertEqual(actions[0].modifiers, [.shift])
    }

    func testPlainClickHasNoModifiers() {
        let events = [
            RawEvent(time: 0, x: 10, y: 20, kind: .mouseDown(.left, clickCount: 1)),
            RawEvent(time: 0.05, x: 10, y: 20, kind: .mouseUp(.left, clickCount: 1))
        ]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertNil(actions[0].modifiers, "a plain click must not gain an empty modifier list")
    }

    func testHeldButtonActionsAndScrollKeepModifiers() {
        let events = [
            RawEvent(time: 0, x: 1, y: 1, kind: .mouseDown(.left, clickCount: 1), modifiers: [.command]),
            RawEvent(time: 0.1, x: 50, y: 50, kind: .mouseDrag(.left), modifiers: [.command]),
            RawEvent(time: 0.3, x: 90, y: 90, kind: .mouseUp(.left, clickCount: 1), modifiers: [.command]),
            RawEvent(time: 1.0, x: 90, y: 90, kind: .scroll(dx: 0, dy: -5), modifiers: [.option])
        ]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertEqual(actions.map { $0.kind }, [.mouseDown, .drag, .mouseUp, .scroll])
        let expected: [KeyModifiers?] = [[.command], [.command], [.command], [.option]]
        XCTAssertEqual(actions.map { $0.modifiers }, expected)
    }

    func testModifiersSurviveSaveAndLoad() throws {
        var click = MacroAction.click(x: 5, y: 6)
        click.modifiers = [.shift, .command]
        let recording = Recording(name: "m", actions: [click])
        let loaded = try RecordingCodec.decode(try RecordingCodec.encode(recording))
        XCTAssertEqual(loaded.actions[0].modifiers, [.shift, .command])
    }

    func testDescriptionShowsModifiersOnMouseActionsOnly() {
        var click = MacroAction.click(x: 10, y: 20)
        XCTAssertEqual(ActionDescriber.describe(click), "Left click at (10, 20)")
        click.modifiers = [.shift]
        XCTAssertEqual(ActionDescriber.describe(click), "⇧ Left click at (10, 20)")
        // Key actions already show their modifiers in the key name.
        XCTAssertEqual(ActionDescriber.describe(.key(KeyCodes.ansiK, modifiers: [.command])), "Press ⌘K")
    }

    // MARK: Following a moved window

    private let recordedWindow = WindowFrame(x: 100, y: 50, width: 800, height: 600)

    func testWindowAssessment() {
        XCTAssertEqual(WindowRelocation.assess(recorded: recordedWindow, current: recordedWindow), .same)
        XCTAssertEqual(
            WindowRelocation.assess(recorded: recordedWindow, current: WindowFrame(x: 100.5, y: 50.5, width: 800, height: 600)),
            .same
        )
        XCTAssertEqual(
            WindowRelocation.assess(recorded: recordedWindow, current: WindowFrame(x: 300, y: 80, width: 800, height: 600)),
            .moved(dx: 200, dy: 30)
        )
        XCTAssertEqual(
            WindowRelocation.assess(recorded: recordedWindow, current: WindowFrame(x: 100, y: 50, width: 900, height: 600)),
            .resized
        )
    }

    func testTranslateShiftsOnlyPointsInsideTheRecordedWindow() {
        let inside = MacroAction.click(x: 200, y: 100)
        let outsideMenuBar = MacroAction.click(x: 200, y: 10)
        let key = MacroAction.key(KeyCodes.returnKey)
        let text = MacroAction.text("hi")
        let scrollInside = MacroAction.scroll(dx: 0, dy: -3, x: 400, y: 300)
        let scrollNoPoint = MacroAction.scroll(dx: 0, dy: -3)

        let moved = WindowRelocation.translate(
            [inside, outsideMenuBar, key, text, scrollInside, scrollNoPoint],
            recorded: recordedWindow, dx: 40, dy: -10
        )
        XCTAssertEqual(moved[0].x, 240)
        XCTAssertEqual(moved[0].y, 90)
        XCTAssertEqual(moved[1].x, 200, "a click on the menu bar is not part of the window")
        XCTAssertEqual(moved[1].y, 10)
        XCTAssertEqual(moved[2], key)
        XCTAssertEqual(moved[3], text)
        XCTAssertEqual(moved[4].x, 440)
        XCTAssertEqual(moved[4].y, 290)
        XCTAssertEqual(moved[5], scrollNoPoint)
        XCTAssertEqual(moved[0].id, inside.id, "translating keeps each action's identity")
    }

    func testHasPositions() {
        XCTAssertFalse(WindowRelocation.hasPositions([.key(1), .text("a"), .wait(1)]))
        XCTAssertTrue(WindowRelocation.hasPositions([.click(x: 1, y: 1)]))
        XCTAssertFalse(WindowRelocation.hasPositions([.click(x: 5000, y: 5000)], inside: recordedWindow))
    }

    func testRecordingKeepsWindowAndChannelThroughSaveAndLoad() throws {
        let recording = Recording(name: "w", targetWindow: recordedWindow, startChannel: "general", actions: [.click(x: 1, y: 1)])
        let loaded = try RecordingCodec.decode(try RecordingCodec.encode(recording))
        XCTAssertEqual(loaded.targetWindow, recordedWindow)
        XCTAssertEqual(loaded.startChannel, "general")
    }

    func testOlderFilesWithoutTheNewFieldsStillLoad() throws {
        let json = """
        {"formatVersion":1,"id":"6F2B1C0E-3D4A-4B7B-9A55-2F0C8E71D6A4","name":"old",
         "createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z",
         "actions":[{"kind":"click","delay":0,"x":1,"y":2,"button":"left","clickCount":1}]}
        """
        let loaded = try RecordingCodec.decode(Data(json.utf8))
        XCTAssertNil(loaded.targetWindow)
        XCTAssertNil(loaded.startChannel)
        XCTAssertNil(loaded.actions[0].modifiers)
    }

    // MARK: Safety watchdog

    private let discord = TargetApp(bundleID: "com.example.chat", name: "Chat")
    private func context(follow: Bool = true, window: WindowFrame? = nil, screen: ScreenSize? = nil) -> SafetyContext {
        SafetyContext(target: discord, recordedWindow: window ?? recordedWindow, recordedScreen: screen, followWindow: follow)
    }
    private func evaluate(
        _ snapshot: SafetySnapshot,
        kind: ActionKind = .click,
        options: SafetyOptions = SafetyOptions(),
        context ctx: SafetyContext? = nil
    ) -> String? {
        SafetyWatchdog.evaluate(options: options, context: ctx ?? context(), snapshot: snapshot, actionKind: kind)
    }

    func testNothingStopsWhenEverythingMatches() {
        let snapshot = SafetySnapshot(targetRunning: true, window: recordedWindow, windowKnown: true,
                                      screen: ScreenSize(width: 1512, height: 982), pointerDrift: 0)
        XCTAssertNil(evaluate(snapshot, context: context(screen: ScreenSize(width: 1512, height: 982))))
    }

    func testUnreadableValuesNeverStopPlayback() {
        XCTAssertNil(evaluate(SafetySnapshot()), "unknown is not the same as broken")
    }

    func testStopsWhenTheTargetAppQuit() {
        let reason = evaluate(SafetySnapshot(targetRunning: false))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.hasPrefix(SafetyWatchdog.messagePrefix) ?? false)
        XCTAssertTrue(reason?.contains("Chat") ?? false)
    }

    func testStopsWhenTheWindowIsGoneButOnlyIfTheWindowListWasReadable() {
        XCTAssertNotNil(evaluate(SafetySnapshot(targetRunning: true, window: nil, windowKnown: true)))
        XCTAssertNil(evaluate(SafetySnapshot(targetRunning: true, window: nil, windowKnown: false)))
    }

    func testStopsWhenTheWindowChangedSize() {
        let resized = WindowFrame(x: 100, y: 50, width: 640, height: 480)
        let reason = evaluate(SafetySnapshot(targetRunning: true, window: resized, windowKnown: true))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("changed size") ?? false)
    }

    func testWindowResizeIsIgnoredForKeyboardOnlyActions() {
        let resized = WindowFrame(x: 100, y: 50, width: 640, height: 480)
        XCTAssertNil(evaluate(SafetySnapshot(targetRunning: true, window: resized, windowKnown: true), kind: .key))
        XCTAssertNil(evaluate(SafetySnapshot(targetRunning: true, window: resized, windowKnown: true), kind: .text))
    }

    func testMovedWindowIsFineWhenFollowingAndAStopWhenNot() {
        let moved = WindowFrame(x: 400, y: 200, width: 800, height: 600)
        let snapshot = SafetySnapshot(targetRunning: true, window: moved, windowKnown: true)
        XCTAssertNil(evaluate(snapshot, context: context(follow: true)))
        let reason = evaluate(snapshot, context: context(follow: false))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("moved") ?? false)
    }

    func testDisplayChangeStopsOnlyWhenTheWindowDoesNotAlreadyPinThePositions() {
        let recordedScreen = ScreenSize(width: 1920, height: 1080)
        let newScreen = ScreenSize(width: 1512, height: 982)
        // Window still matches exactly: positions are relative to it, so the display size is irrelevant.
        XCTAssertNil(evaluate(
            SafetySnapshot(targetRunning: true, window: recordedWindow, windowKnown: true, screen: newScreen),
            context: context(screen: recordedScreen)
        ))
        // No window information at all: the display change is the only signal.
        let noWindow = SafetyContext(target: nil, recordedWindow: nil, recordedScreen: recordedScreen, followWindow: true)
        XCTAssertNotNil(evaluate(SafetySnapshot(screen: newScreen), context: noWindow))
        XCTAssertNil(evaluate(SafetySnapshot(screen: newScreen), kind: .key, context: noWindow))
    }

    func testPointerDriftStopsOnlyWhenEnabled() {
        let drifted = SafetySnapshot(pointerDrift: 200)
        XCTAssertNil(evaluate(drifted))
        var options = SafetyOptions()
        options.stopIfUserMovesMouse = true
        XCTAssertNotNil(evaluate(drifted, options: options))
        XCTAssertNil(evaluate(SafetySnapshot(pointerDrift: 3), options: options))
    }

    func testMasterSwitchAndIndividualSwitchesTurnChecksOff() {
        var off = SafetyOptions()
        off.enabled = false
        XCTAssertNil(evaluate(SafetySnapshot(targetRunning: false), options: off))

        var noGone = SafetyOptions()
        noGone.stopIfTargetGone = false
        XCTAssertNil(evaluate(SafetySnapshot(targetRunning: false), options: noGone))

        var noWindow = SafetyOptions()
        noWindow.stopIfWindowChanged = false
        let resized = WindowFrame(x: 0, y: 0, width: 10, height: 10)
        XCTAssertNil(evaluate(SafetySnapshot(targetRunning: true, window: resized, windowKnown: true), options: noWindow))
    }

    // MARK: Engine: safety hook and run-once prefix

    private func runToEnd(
        _ recording: Recording,
        config: PlaybackConfig = PlaybackConfig(),
        safety: @escaping (MacroAction?) -> String? = { _ in nil }
    ) throws -> (performer: TestPerformer, state: PlaybackState) {
        let performer = TestPerformer()
        let engine = PlaybackEngine(performer: performer, safetyCheck: safety)
        defer { engine.stop() }
        var cfg = config
        cfg.countdown = 0
        try engine.start(recording: recording, config: cfg)
        XCTAssertTrue(waitUntil { !engine.state.isActive })
        return (performer, engine.state)
    }

    func testSafetyStopHappensBeforeTheActionThatWouldBreak() throws {
        let recording = Recording(name: "s", actions: [
            .click(x: 1, y: 0, delay: 0.001), .click(x: 2, y: 0, delay: 0.001), .click(x: 3, y: 0, delay: 0.001)
        ])
        var clicks = 0
        let result = try runToEnd(recording) { action in
            guard action?.kind == .click else { return nil }
            clicks += 1
            return clicks == 2 ? SafetyWatchdog.messagePrefix + "window gone" : nil
        }
        XCTAssertEqual(result.performer.performed.map { $0.x }, [1], "the second click must never be sent")
        XCTAssertEqual(result.state, .failed(SafetyWatchdog.messagePrefix + "window gone"))
        XCTAssertEqual(result.performer.cleanupCount, 1)
    }

    func testSafetyIsAskedAtTheStartOfEveryRepetitionAndNotForMouseMoves() throws {
        let recording = Recording(name: "s", actions: [.move(x: 1, y: 1, delay: 0.001), .click(x: 2, y: 2, delay: 0.001)])
        var config = PlaybackConfig()
        config.repeatCount = 2
        var kinds: [ActionKind?] = []
        _ = try runToEnd(recording, config: config) { action in
            kinds.append(action?.kind)
            return nil
        }
        XCTAssertEqual(kinds.count, 4)
        XCTAssertNil(kinds[0])
        XCTAssertEqual(kinds[1], .click)
        XCTAssertNil(kinds[2])
        XCTAssertEqual(kinds[3], .click)
    }

    func testPrefixActionsRunInTheFirstRepetitionOnly() throws {
        let recording = Recording(name: "p", actions: [
            .key(KeyCodes.ansiK, modifiers: [.command], delay: 0.001),
            .click(x: 1, y: 1, delay: 0.001)
        ])
        var config = PlaybackConfig()
        config.repeatCount = 3
        config.prefixCount = 1
        let result = try runToEnd(recording, config: config)
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.performer.performed.map { $0.kind }, [.key, .click, .click, .click])
    }

    func testPrefixCountIsClampedToTheSection() throws {
        let recording = Recording(name: "p", actions: [.click(x: 1, y: 1, delay: 0.001)])
        var config = PlaybackConfig()
        config.repeatCount = 2
        config.prefixCount = 99
        let result = try runToEnd(recording, config: config)
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.performer.performed.count, 1, "everything was prefix, so it ran once")
    }

    // MARK: Settings

    func testNewSettingsDefaults() {
        let s = AppSettings()
        XCTAssertTrue(s.bringTargetToFront)
        XCTAssertTrue(s.followTargetWindow)
        XCTAssertTrue(s.launchTargetIfClosed)
        XCTAssertFalse(s.restorePointerAfterPlayback)
        XCTAssertFalse(s.soundEffects)
        XCTAssertTrue(s.safety.enabled)
        XCTAssertFalse(s.safety.stopIfUserMovesMouse)
        XCTAssertTrue(s.recording.preciseTiming)
        XCTAssertEqual(s.pauseHotKey, HotKey.defaultPause)
        XCTAssertEqual(s.pauseHotKey.displayString, "⌃⌥⌘P")
        XCTAssertNotEqual(s.pauseHotKey, s.emergencyStop)
    }

    func testNewSettingsRoundTrip() throws {
        var s = AppSettings()
        s.bringTargetToFront = false
        s.followTargetWindow = false
        s.soundEffects = true
        s.inputTiming.settleBeforeClick = 0.2
        s.inputTiming.keyHold = 0.05
        s.safety.stopIfUserMovesMouse = true
        s.safety.stopIfDisplayChanged = false
        s.discord.favoriteChannels = ["general", "mods"]
        s.discord.messageTemplates = ["Welcome!"]
        s.discord.minSecondsBetweenMessages = 9
        s.discord.about = "moderation"
        s.appearance = .dark
        s.rowDensity = .compact
        s.newMacroNamePrefix = "Discord"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try SettingsStore(fileURL: url).save(s)
        XCTAssertEqual(SettingsStore(fileURL: url).load(), s)
    }

    func testOldSettingsFileGetsDefaultsForNewKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data("{\"defaultSpeed\": 2, \"verifyForeground\": false, \"recording\": {\"includeMouseMove\": false}}".utf8).write(to: url)
        let loaded = SettingsStore(fileURL: url).load()
        XCTAssertEqual(loaded.defaultSpeed, 2)
        XCTAssertFalse(loaded.verifyForeground, "an explicit old choice is kept")
        XCTAssertFalse(loaded.recording.includeMouseMove)
        XCTAssertTrue(loaded.recording.preciseTiming)
        XCTAssertTrue(loaded.bringTargetToFront)
        XCTAssertEqual(loaded.discord, DiscordProfile())
    }

    func testSanitizingClampsTheNewSettings() {
        var s = AppSettings()
        s.inputTiming.settleBeforeClick = 99
        s.inputTiming.clickHold = -5
        s.discord.minSecondsBetweenMessages = -3
        s.discord.favoriteChannels = ["  general  ", "", "   "]
        s.discord.about = String(repeating: "x", count: 5000)
        s.newMacroNamePrefix = "   "
        s.pauseHotKey = s.emergencyStop
        let clean = s.sanitized()
        XCTAssertEqual(clean.inputTiming.settleBeforeClick, 1)
        XCTAssertEqual(clean.inputTiming.clickHold, 0.001)
        XCTAssertEqual(clean.discord.minSecondsBetweenMessages, 0)
        XCTAssertEqual(clean.discord.favoriteChannels, ["general"])
        XCTAssertEqual(clean.discord.about.count, 600)
        XCTAssertEqual(clean.newMacroNamePrefix, "Recording")
        XCTAssertEqual(clean.pauseHotKey, HotKey.defaultPause, "the pause shortcut may not equal the emergency stop")
    }

    func testDiscordPromptContextOnlyMentionsWhatWasFilledIn() {
        var profile = DiscordProfile()
        XCTAssertFalse(profile.promptContext.contains("opens often"))
        profile.favoriteChannels = ["general", "mods"]
        profile.messageTemplates = ["Welcome!"]
        profile.rules = "never use @everyone"
        let text = profile.promptContext
        XCTAssertTrue(text.contains("general, mods"))
        XCTAssertTrue(text.contains("\"Welcome!\""))
        XCTAssertTrue(text.contains("never use @everyone"))
        XCTAssertTrue(text.contains("at least 4 seconds"))
    }

    // MARK: Discord-aware checks

    private func findings(_ recording: Recording, discord profile: DiscordProfile? = nil, playback: PlaybackDefaults? = nil) -> [MacroFinding] {
        MacroAnalyzer.analyze(
            recording: recording,
            playback: playback ?? PlaybackDefaults(speed: 1, repeatCount: 1, loopDelay: 0),
            verifyForeground: true,
            currentScreen: nil,
            discord: profile
        )
    }

    func testMessagesCloserThanTheUsersMinimumAreFlagged() {
        let recording = Recording(name: "m", targetApp: discord, actions: [
            .key(KeyCodes.ansiK, modifiers: [.command]),
            .text("one", delay: 0.2), .key(KeyCodes.returnKey, delay: 0.1),
            .text("two", delay: 0.3), .key(KeyCodes.returnKey, delay: 0.1),
            .wait(10),
            .text("three"), .key(KeyCodes.returnKey)
        ])
        var profile = DiscordProfile()
        profile.minSecondsBetweenMessages = 4
        let found = findings(recording, discord: profile).first { $0.id == "messages-too-close" }
        XCTAssertNotNil(found)
        XCTAssertTrue(found?.detail.hasPrefix("1 message(s)") ?? false, "only the second message is too close")
        XCTAssertNil(findings(recording, discord: nil).first { $0.id == "messages-too-close" })
        profile.minSecondsBetweenMessages = 0
        XCTAssertNil(findings(recording, discord: profile).first { $0.id == "messages-too-close" })
    }

    func testRapidMessagesUsesThePersonalMinimum() {
        let recording = Recording(name: "r", targetApp: discord, actions: [.text("hi"), .key(KeyCodes.returnKey)])
        let loop = PlaybackDefaults(speed: 1, repeatCount: 0, loopDelay: 5)
        XCTAssertNil(findings(recording, playback: loop).first { $0.id == "rapid-messages" }, "5 s is above the built-in 3 s")
        var strict = DiscordProfile()
        strict.minSecondsBetweenMessages = 12
        let found = findings(recording, discord: strict, playback: loop).first { $0.id == "rapid-messages" }
        XCTAssertEqual(found?.fix, .setLoopDelay(seconds: 12))
    }

    func testMassMentionIsFlagged() {
        let recording = Recording(name: "p", targetApp: discord, actions: [.text("hello @Everyone!")])
        XCTAssertEqual(findings(recording).first { $0.id == "mass-mention" }?.severity, .warning)
        XCTAssertNil(findings(Recording(name: "q", targetApp: discord, actions: [.text("hello all")])).first { $0.id == "mass-mention" })
    }

    func testNoChannelHintListsTheUsersChannelsAndIsSilencedByAStartChannel() {
        var recording = Recording(name: "c", targetApp: discord, actions: [.text("hi"), .key(KeyCodes.returnKey)])
        var profile = DiscordProfile()
        profile.favoriteChannels = ["general", "mods"]
        let hint = findings(recording, discord: profile).first { $0.id == "no-channel" }
        XCTAssertTrue(hint?.detail.contains("general, mods") ?? false)
        recording.startChannel = "general"
        XCTAssertNil(findings(recording, discord: profile).first { $0.id == "no-channel" })
    }

    func testQuickSwitcherInTheMacroCountsAsChoosingAChannel() {
        let recording = Recording(name: "c", targetApp: discord, actions: Presets.actions(for: "open-and-send", input: "general", secondInput: "hi"))
        XCTAssertNil(findings(recording).first { $0.id == "no-channel" })
    }

    // MARK: Discord detection and start channel

    func testDiscordDetectionCoversReleaseChannelsAndRenamedCopies() {
        XCTAssertTrue(DiscordProfile.isDiscord(bundleID: "com.hnc.Discord", name: "Discord"))
        XCTAssertTrue(DiscordProfile.isDiscord(bundleID: "com.hnc.DiscordPTB", name: "Discord PTB"))
        XCTAssertTrue(DiscordProfile.isDiscord(bundleID: "com.hnc.DiscordCanary", name: "Discord Canary"))
        XCTAssertTrue(DiscordProfile.isDiscord(bundleID: "com.example.copy", name: "My Discord"))
        XCTAssertFalse(DiscordProfile.isDiscord(bundleID: "com.apple.finder", name: "Finder"))
    }

    func testStartChannelSurvivesTheCodec() throws {
        var recording = Recording(name: "c", actions: [.key(KeyCodes.returnKey)])
        recording.startChannel = "general"
        recording.targetWindow = WindowFrame(x: 10, y: 20, width: 800, height: 600)
        let data = try RecordingCodec.encode(recording)
        let back = try RecordingCodec.decode(data)
        XCTAssertEqual(back.startChannel, "general")
        XCTAssertEqual(back.targetWindow, WindowFrame(x: 10, y: 20, width: 800, height: 600))
    }

    func testPrefixStepsOpenTheChannelWithTheQuickSwitcher() {
        let steps = Presets.openChannel("general")
        XCTAssertEqual(steps.first?.kind, .key)
        XCTAssertEqual(steps.first?.keyCode, KeyCodes.ansiK)
        XCTAssertEqual(steps.first?.modifiers, [.command])
        XCTAssertTrue(steps.contains { $0.kind == .text && $0.text == "general" })
        XCTAssertEqual(steps.last?.keyCode, KeyCodes.returnKey)
    }
}
