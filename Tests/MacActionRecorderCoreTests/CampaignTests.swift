import XCTest
@testable import MacActionRecorderCore

final class CampaignTests: XCTestCase {
    // A fixed calendar so the schedule tests do not depend on the machine's time zone.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 1
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return utc.date(from: parts)!
    }

    // MARK: Rotation order

    func testRotationSendsEachMessageToEveryChannelBeforeTheNextMessage() {
        let campaign = Campaign(messages: ["1", "2", "3"], channels: ["A", "B"])
        let order = (0..<7).map { campaign.step(at: $0) }.map { "\($0.message!)\($0.channel!)" }
        XCTAssertEqual(order, ["1A", "1B", "2A", "2B", "3A", "3B", "1A"])
        XCTAssertEqual(campaign.cycleLength, 6)
    }

    func testBlankEntriesAreSkipped() {
        let campaign = Campaign(messages: ["hi", "  ", "", "yo"], channels: [" general ", "\n"])
        XCTAssertEqual(campaign.activeMessages, ["hi", "yo"])
        XCTAssertEqual(campaign.activeChannels, ["general"])
        XCTAssertEqual(campaign.step(at: 1).message, "yo")
        XCTAssertEqual(campaign.step(at: 1).channel, "general")
    }

    func testMessagesOnlyAndChannelsOnly() {
        let messages = Campaign(messages: ["a", "b"])
        XCTAssertEqual((0..<3).map { messages.step(at: $0).message! }, ["a", "b", "a"])
        XCTAssertNil(messages.step(at: 0).channel)

        let channels = Campaign(channels: ["x", "y"])
        XCTAssertEqual((0..<3).map { channels.step(at: $0).channel! }, ["x", "y", "x"])
        XCTAssertNil(channels.step(at: 0).message)
    }

    func testPlaceholdersAreReplacedOnlyInTextSteps() {
        let step = Campaign(messages: ["hello"], channels: ["general"]).step(at: 0)
        let actions: [MacroAction] = [
            .text("{channel}"),
            .key(36),
            .text("Say: {message} in {channel}")
        ]
        let applied = step.apply(to: actions)
        XCTAssertEqual(applied[0].text, "general")
        XCTAssertEqual(applied[1], actions[1])
        XCTAssertEqual(applied[2].text, "Say: hello in general")
        XCTAssertEqual(applied.map { $0.id }, actions.map { $0.id }, "steps keep their ids")
    }

    func testPlaceholderWithoutValueIsLeftAlone() {
        let step = Campaign(channels: ["general"]).step(at: 0)
        XCTAssertEqual(step.apply(to: [.text("{message}")])[0].text, "{message}")
    }

    func testSummary() {
        XCTAssertEqual(Campaign(messages: ["a", "b"], channels: ["x"]).step(at: 1).summary, "Message 2 → x")
        XCTAssertEqual(Campaign().step(at: 4).summary, "Run 5")
    }

    // MARK: Schedule

    func testNoWindowsMeansAnyTime() {
        let now = date(5, 3)
        XCTAssertEqual(SendSchedule.nextAllowed(from: now, windows: [], calendar: utc), now)
    }

    func testInsideAndBeforeAWindow() {
        let windows = [SendWindow(start: 9 * 60, end: 17 * 60)]
        XCTAssertTrue(SendSchedule.isAllowed(date(5, 10), windows: windows, calendar: utc))
        XCTAssertEqual(SendSchedule.nextAllowed(from: date(5, 7), windows: windows, calendar: utc), date(5, 9))
        XCTAssertEqual(SendSchedule.nextAllowed(from: date(5, 17), windows: windows, calendar: utc), date(6, 9), "the end is exclusive")
    }

    func testWindowPastMidnight() {
        let windows = [SendWindow(start: 22 * 60, end: 2 * 60)]
        XCTAssertTrue(SendSchedule.isAllowed(date(5, 1), windows: windows, calendar: utc), "yesterday's window is still open")
        XCTAssertTrue(SendSchedule.isAllowed(date(5, 23), windows: windows, calendar: utc))
        XCTAssertEqual(SendSchedule.nextAllowed(from: date(5, 3), windows: windows, calendar: utc), date(5, 22))
    }

    func testSoonestOfSeveralWindowsWins() {
        let windows = [SendWindow(start: 18 * 60, end: 19 * 60), SendWindow(start: 12 * 60, end: 13 * 60)]
        XCTAssertEqual(SendSchedule.nextAllowed(from: date(5, 10), windows: windows, calendar: utc), date(5, 12))
        XCTAssertEqual(SendSchedule.nextAllowed(from: date(5, 14), windows: windows, calendar: utc), date(5, 18))
    }

    func testInvalidWindowsAreIgnored() {
        let now = date(5, 10)
        XCTAssertEqual(SendSchedule.nextAllowed(from: now, windows: [SendWindow(start: 600, end: 600)], calendar: utc), now)
        XCTAssertEqual(SendWindow(start: 22 * 60, end: 2 * 60).lengthInMinutes, 240)
        XCTAssertEqual(SendWindow(start: 9 * 60 + 5, end: 17 * 60 + 30).displayText, "09:05–17:30")
    }

    func testStartOfNextDay() {
        XCTAssertEqual(SendSchedule.startOfNextDay(after: date(5, 23, 59), calendar: utc), date(6, 0))
    }

    // MARK: Validation and file format

    func testValidationRejectsBadCampaigns() {
        XCTAssertFalse(RecordingValidator.validate(campaign: Campaign(sendWindows: [SendWindow(start: 60, end: 60)])).isEmpty)
        XCTAssertFalse(RecordingValidator.validate(campaign: Campaign(sendWindows: [SendWindow(start: -1, end: 60)])).isEmpty)
        XCTAssertFalse(RecordingValidator.validate(campaign: Campaign(dailyLimit: 0)).isEmpty)
        XCTAssertFalse(RecordingValidator.validate(campaign: Campaign(messages: Array(repeating: "m", count: 51))).isEmpty)
        XCTAssertTrue(RecordingValidator.validate(campaign: Campaign(messages: ["a"], channels: ["b"], sendWindows: [SendWindow(start: 0, end: 60)], dailyLimit: 5)).isEmpty)

        let recording = Recording(name: "r", campaign: Campaign(dailyLimit: -3), actions: [.key(36)])
        XCTAssertTrue(RecordingValidator.validate(recording).contains { $0.severity == .error })
    }

    func testCampaignSurvivesSaveAndLoad() throws {
        let campaign = Campaign(
            messages: ["WTS limiteds, DM me", "Trading, offers welcome"],
            channels: ["trading", "general"],
            sendWindows: [SendWindow(start: 9 * 60, end: 21 * 60)],
            dailyLimit: 20,
            position: 3
        )
        let recording = Recording(name: "r", campaign: campaign, actions: [.text("{message}"), .key(36)])
        let loaded = try RecordingCodec.decode(RecordingCodec.encode(recording))
        XCTAssertEqual(loaded.campaign, campaign)
    }

    func testOlderFilesHaveNoCampaign() throws {
        let recording = Recording(name: "r", actions: [.key(36)])
        let loaded = try RecordingCodec.decode(RecordingCodec.encode(recording))
        XCTAssertNil(loaded.campaign)
    }

    func testDamagedCampaignFieldsAreDroppedNotFatal() throws {
        let json = """
        {"formatVersion":1,"id":"\(UUID().uuidString)","name":"r","createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z",
         "campaign":{"messages":5,"channels":["general"],"sendWindows":"x","dailyLimit":"lots","position":-4},
         "actions":[{"kind":"key","keyCode":36}]}
        """
        let loaded = try RecordingCodec.decode(Data(json.utf8))
        XCTAssertEqual(loaded.campaign?.messages, [])
        XCTAssertEqual(loaded.campaign?.channels, ["general"])
        XCTAssertEqual(loaded.campaign?.sendWindows, [])
        XCTAssertNil(loaded.campaign?.dailyLimit)
        XCTAssertEqual(loaded.campaign?.position, 0)
    }

    func testDuplicateStartsTheRotationAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try RecordingStore(directory: folder)
        let recording = Recording(name: "r", campaign: Campaign(messages: ["a", "b"], position: 7), actions: [.key(36)])
        try store.save(recording)
        let copy = try store.duplicate(recording)
        XCTAssertEqual(copy.campaign?.position, 0)
        XCTAssertEqual(copy.campaign?.messages, ["a", "b"])
    }

    // MARK: Activity log

    func testActivityLogCountsTodaysFinishedRunsAndKeepsTheNewest() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let macro = UUID()
        let other = UUID()
        let now = date(5, 12)

        let log = ActivityLogStore(fileURL: file, limit: 4)
        log.append(ActivityEntry(date: date(4, 23), recordingID: macro, recordingName: "m", outcome: .sent))
        log.append(ActivityEntry(date: date(5, 8), recordingID: macro, recordingName: "m", outcome: .sent))
        log.append(ActivityEntry(date: date(5, 9), recordingID: macro, recordingName: "m", outcome: .failed, detail: "x"))
        log.append(ActivityEntry(date: date(5, 10), recordingID: other, recordingName: "o", outcome: .sent))
        XCTAssertEqual(log.sentToday(recordingID: macro, now: now, calendar: utc), 1, "yesterday, failures and other macros do not count")

        log.append(ActivityEntry(date: date(5, 11), recordingID: macro, recordingName: "m", outcome: .sent))
        XCTAssertEqual(log.entries.count, 4, "the oldest entry is dropped past the limit")

        let reopened = ActivityLogStore(fileURL: file, limit: 4)
        XCTAssertEqual(reopened.entries.count, 4)
        XCTAssertEqual(reopened.sentToday(recordingID: macro, now: now, calendar: utc), 2)

        reopened.clear()
        XCTAssertTrue(ActivityLogStore(fileURL: file).entries.isEmpty)
    }

    // MARK: Macro check

    private func findingIDs(_ recording: Recording, repeatCount: Int = 1) -> [String] {
        return MacroAnalyzer.analyze(
            recording: recording,
            playback: PlaybackDefaults(speed: 1, repeatCount: repeatCount, loopDelay: 60),
            verifyForeground: true,
            currentScreen: nil
        ).map { $0.id }
    }

    func testCheckFlagsMessagesThatAreNeverTyped() {
        let unused = Recording(name: "r", campaign: Campaign(messages: ["a"]), actions: [.text("hi"), .key(KeyCodes.returnKey)])
        XCTAssertTrue(findingIDs(unused).contains("campaign-unused-messages"))

        let used = Recording(name: "r", campaign: Campaign(messages: ["a"]), actions: [.text("{message}"), .key(KeyCodes.returnKey)])
        XCTAssertFalse(findingIDs(used).contains("campaign-unused-messages"))
    }

    func testCheckFlagsAPlaceholderWithNoMessages() {
        let noCampaign = Recording(name: "r", actions: [.text("{message}")])
        XCTAssertTrue(findingIDs(noCampaign).contains("campaign-empty-placeholder"))
        let emptyCampaign = Recording(name: "r", campaign: Campaign(channels: ["x"]), actions: [.text("{message}")])
        XCTAssertTrue(findingIDs(emptyCampaign).contains("campaign-empty-placeholder"))
    }

    func testCheckSuggestsADailyLimitForEndlessSendLoops() {
        let send: [MacroAction] = [.text("hi"), .key(KeyCodes.returnKey)]
        XCTAssertTrue(findingIDs(Recording(name: "r", actions: send), repeatCount: 0).contains("loop-no-daily-limit"))
        XCTAssertFalse(findingIDs(Recording(name: "r", campaign: Campaign(dailyLimit: 10), actions: send), repeatCount: 0).contains("loop-no-daily-limit"))
        XCTAssertFalse(findingIDs(Recording(name: "r", actions: send), repeatCount: 3).contains("loop-no-daily-limit"))
    }

    func testCampaignChannelsCountAsChoosingAChannel() {
        let send: [MacroAction] = [.text("hi"), .key(KeyCodes.returnKey)]
        XCTAssertTrue(findingIDs(Recording(name: "r", actions: send)).contains("no-channel"))
        XCTAssertFalse(findingIDs(Recording(name: "r", campaign: Campaign(channels: ["general"]), actions: send)).contains("no-channel"))
    }

    func testUnreadableLogStartsEmpty() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(ActivityLogStore(fileURL: file).entries.isEmpty)
    }
}

// MARK: - Engine

final class CampaignPlaybackTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 1
        parts.day = day
        parts.hour = hour
        return utc.date(from: parts)!
    }

    private func harness(now: Date? = nil) -> (TestPerformer, EventLog, PlaybackEngine) {
        let performer = TestPerformer()
        let log = EventLog()
        let fixed = now
        let engine = PlaybackEngine(
            performer: performer,
            clock: { fixed ?? Date() },
            calendar: utc
        )
        engine.onEvent = { log.append($0) }
        return (performer, log, engine)
    }

    /// The typed text, one string per repetition (the engine types one character at a time).
    private func typed(_ performer: TestPerformer) -> String {
        return performer.performed.compactMap { $0.kind == .text ? $0.text : nil }.joined()
    }

    private func waits(_ log: EventLog) -> [PlaybackWait?] {
        return log.all.compactMap { event -> PlaybackWait?? in
            if case .waiting(let wait) = event { return .some(wait) }
            return nil
        }
    }

    func testEachRepetitionUsesTheNextMessageAndChannel() throws {
        let (performer, log, engine) = harness()
        defer { engine.stop() }
        let recording = Recording(name: "r", actions: [.text("{channel}"), .text("{message}")])
        var config = PlaybackConfig()
        config.repeatCount = 4
        config.campaign = Campaign(messages: ["A", "B"], channels: ["x", "y"])

        try engine.start(recording: recording, config: config)
        XCTAssertTrue(waitUntil { log.states.contains(.finished) })
        XCTAssertEqual(typed(performer), "xAyAxByB")

        let steps = log.all.compactMap { event -> Int? in
            if case .campaignStep(let step) = event { return step.position }
            return nil
        }
        XCTAssertEqual(steps, [0, 1, 2, 3])
        let completed = log.all.compactMap { event -> Int? in
            if case .runCompleted(let iteration) = event { return iteration }
            return nil
        }
        XCTAssertEqual(completed, [1, 2, 3, 4])
    }

    func testRotationContinuesFromTheSavedPosition() throws {
        let (performer, log, engine) = harness()
        defer { engine.stop() }
        var config = PlaybackConfig()
        config.repeatCount = 2
        config.campaign = Campaign(messages: ["A", "B"], channels: ["x", "y"], position: 3)

        try engine.start(recording: Recording(name: "r", actions: [.text("{channel}{message}")]), config: config)
        XCTAssertTrue(waitUntil { log.states.contains(.finished) })
        XCTAssertEqual(typed(performer), "yBxA")
    }

    func testOutsideTheSendWindowNothingRunsUntilItOpens() throws {
        let (performer, log, engine) = harness(now: date(5, 10))
        defer { engine.stop() }
        var config = PlaybackConfig()
        config.campaign = Campaign(sendWindows: [SendWindow(start: 12 * 60, end: 13 * 60)])

        try engine.start(recording: Recording(name: "r", actions: [.key(36)]), config: config)
        XCTAssertTrue(waitUntil { !self.waits(log).isEmpty })
        XCTAssertEqual(waits(log).first ?? nil, PlaybackWait(until: date(5, 12), reason: .sendWindow))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(performer.performed.isEmpty)
        XCTAssertEqual(engine.state, .playing)

        engine.stop()
        XCTAssertEqual(engine.state, .stopped)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(performer.performed.isEmpty, "nothing runs after Stop during a wait")
    }

    func testInsideTheSendWindowItRunsAtOnce() throws {
        let (performer, log, engine) = harness(now: date(5, 10))
        defer { engine.stop() }
        var config = PlaybackConfig()
        config.campaign = Campaign(sendWindows: [SendWindow(start: 9 * 60, end: 11 * 60)])

        try engine.start(recording: Recording(name: "r", actions: [.key(36)]), config: config)
        XCTAssertTrue(waitUntil { log.states.contains(.finished) })
        XCTAssertEqual(performer.performed.count, 1)
        XCTAssertTrue(waits(log).isEmpty)
    }

    func testDailyLimitStopsSendingUntilTomorrow() throws {
        let (performer, log, engine) = harness(now: date(5, 10))
        defer { engine.stop() }
        var config = PlaybackConfig()
        config.repeatCount = 5
        config.campaign = Campaign(dailyLimit: 3)
        config.sentToday = 1

        try engine.start(recording: Recording(name: "r", actions: [.key(36)]), config: config)
        XCTAssertTrue(waitUntil { self.waits(log).contains(PlaybackWait(until: self.date(6, 0), reason: .dailyLimit)) })
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(performer.performed.count, 2, "1 already sent today + 2 more = the limit of 3")
        engine.stop()
    }

    func testPauseWorksWhileWaiting() throws {
        let (performer, log, engine) = harness(now: date(5, 10))
        defer { engine.stop() }
        var config = PlaybackConfig()
        config.campaign = Campaign(dailyLimit: 1)
        config.sentToday = 1

        try engine.start(recording: Recording(name: "r", actions: [.key(36)]), config: config)
        XCTAssertTrue(waitUntil { !self.waits(log).isEmpty })
        engine.pause()
        XCTAssertEqual(engine.state, .paused)
        engine.resume()
        XCTAssertEqual(engine.state, .playing)
        engine.stop()
        XCTAssertTrue(performer.performed.isEmpty)
    }

    func testLongDelayBetweenRepetitionsIsAnnounced() throws {
        let (_, log, engine) = harness()
        defer { engine.stop() }
        var config = PlaybackConfig()
        config.repeatCount = 2
        config.loopDelay = 1.0

        try engine.start(recording: Recording(name: "r", actions: [.key(36)]), config: config)
        XCTAssertTrue(waitUntil { log.states.contains(.finished) })
        let reasons = waits(log).map { $0?.reason }
        XCTAssertEqual(reasons, [.loopDelay, nil])
    }

    func testInvalidCampaignIsRejectedAtStart() {
        let (_, _, engine) = harness()
        var config = PlaybackConfig()
        config.campaign = Campaign(dailyLimit: 0)
        XCTAssertThrowsError(try engine.start(recording: Recording(name: "r", actions: [.key(36)]), config: config))
    }
}
