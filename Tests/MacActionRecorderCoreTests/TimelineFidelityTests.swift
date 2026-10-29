import XCTest
@testable import MacActionRecorderCore

/// Recorded click holds and typing pace are kept and replayed, so playback follows the recorded
/// timeline instead of shortening every click to a fixed tap.
final class TimelineFidelityTests: XCTestCase {
    private func down(_ t: Double, _ x: Double = 10, _ y: Double = 10, count: Int = 1) -> RawEvent {
        RawEvent(time: t, x: x, y: y, kind: .mouseDown(.left, clickCount: count))
    }

    private func up(_ t: Double, _ x: Double = 10, _ y: Double = 10, count: Int = 1) -> RawEvent {
        RawEvent(time: t, x: x, y: y, kind: .mouseUp(.left, clickCount: count))
    }

    private func key(_ t: Double, _ code: Int, _ chars: String) -> RawEvent {
        RawEvent(time: t, kind: .keyDown(keyCode: code, modifiers: [], characters: chars, isRepeat: false))
    }

    // MARK: Recording

    func testClickKeepsHowLongTheButtonWasHeld() {
        let actions = RecordingBuilder.build(events: [down(1.0), up(1.079)], options: RecordingOptions())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].duration ?? -1, 0.079, accuracy: 0.0001)
    }

    func testDoubleClickKeepsTheTimeFromFirstPressToLastRelease() {
        let events = [down(1.0), up(1.05), down(1.15, count: 2), up(1.20, count: 2)]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].clickCount, 2)
        XCTAssertEqual(actions[0].duration ?? -1, 0.20, accuracy: 0.0001)
    }

    func testTextKeepsTheTimeFromFirstToLastCharacter() {
        let events = [key(2.0, 4, "h"), key(2.25, 14, "e"), key(2.5, 37, "l")]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertEqual(actions.map { $0.text }, ["hel"])
        XCTAssertEqual(actions[0].duration ?? -1, 0.5, accuracy: 0.0001)
    }

    func testSingleCharacterTextHasZeroDuration() {
        let actions = RecordingBuilder.build(events: [key(2.0, 4, "h")], options: RecordingOptions())
        XCTAssertEqual(actions[0].duration ?? -1, 0, accuracy: 0.0001)
    }

    /// The recorded timeline (start of each action) can be rebuilt from delays and durations and
    /// matches the times the input happened.
    func testTimelineCanBeRebuiltExactly() {
        let events = [down(0.0), up(0.079), key(0.5522, 4, "h"), key(0.8164, 14, "e"), key(1.9690, 36, "\r")]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertEqual(actions.map { $0.kind }, [.click, .text, .key])
        var starts: [Double] = []
        var clock = 0.0
        for action in actions {
            clock += action.delay
            starts.append(clock)
            clock += action.duration ?? 0
        }
        XCTAssertEqual(starts[0], 0.0, accuracy: 0.002)
        XCTAssertEqual(starts[1], 0.5522, accuracy: 0.002)
        XCTAssertEqual(starts[2], 1.9690, accuracy: 0.002)
    }

    func testRecordingLengthIncludesHoldsAndTyping() {
        let events = [down(0.0), up(0.1), key(0.5, 4, "h"), key(0.9, 14, "e")]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        let recording = Recording(name: "r", actions: actions)
        XCTAssertEqual(recording.originalDuration, 0.9, accuracy: 0.002)
    }

    // MARK: Timing maths

    func testClickHoldScalesWithSpeedAndCanBeSwitchedOff() {
        var click = MacroAction.click(x: 1, y: 1)
        click.duration = 0.2
        var config = PlaybackConfig()
        XCTAssertEqual(PlaybackTiming.clickHold(for: click, config: config) ?? -1, 0.2, accuracy: 1e-9)
        config.speed = 2
        XCTAssertEqual(PlaybackTiming.clickHold(for: click, config: config) ?? -1, 0.1, accuracy: 1e-9)
        config.clickHoldAsRecorded = false
        XCTAssertNil(PlaybackTiming.clickHold(for: click, config: config))
        XCTAssertNil(PlaybackTiming.clickHold(for: .click(x: 1, y: 1), config: PlaybackConfig()), "no recorded hold")
    }

    func testTypingPaceFollowsTheRecordingAndKeepsTheFloor() {
        var text = MacroAction.text("hello")
        text.duration = 0.8 // 4 gaps of 0.2 s
        var config = PlaybackConfig()
        XCTAssertEqual(PlaybackTiming.typingDelay(for: text, config: config), 0.2, accuracy: 1e-9)
        config.speed = 4
        XCTAssertEqual(PlaybackTiming.typingDelay(for: text, config: config), 0.05, accuracy: 1e-9)
        config.speed = 20
        text.duration = 0.004
        XCTAssertEqual(PlaybackTiming.typingDelay(for: text, config: config), config.minTypingCharDelay, accuracy: 1e-9)
        config.typingAsRecorded = false
        XCTAssertEqual(PlaybackTiming.typingDelay(for: text, config: config), PlaybackTiming.typingDelay(config: config), accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.typingDelay(for: .text("abc"), config: PlaybackConfig()),
                       PlaybackTiming.typingDelay(config: PlaybackConfig()), accuracy: 1e-9, "no recorded pace")
    }

    func testEstimateIncludesHoldsAndRecordedTyping() {
        var click = MacroAction.click(x: 1, y: 1)
        click.duration = 0.5
        var text = MacroAction.text("abc", delay: 1)
        text.duration = 1.0
        let config = PlaybackConfig()
        // 0.5 hold + 1 delay + 2 gaps of 0.5
        XCTAssertEqual(PlaybackTiming.estimatedDuration(of: [click, text], config: config), 2.5, accuracy: 1e-9)
    }

    // MARK: Engine

    private func play(_ actions: [MacroAction], config: PlaybackConfig = PlaybackConfig(), timeout: Double = 5) -> (TestPerformer, Double) {
        let performer = TestPerformer()
        let engine = PlaybackEngine(performer: performer, frontmostBundleID: { nil })
        let started = Date()
        XCTAssertNoThrow(try engine.start(recording: Recording(name: "t", actions: actions), config: config))
        while Date().timeIntervalSince(started) < timeout {
            if case .finished = engine.state { break }
            if case .failed = engine.state { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(engine.state, .finished)
        return (performer, Date().timeIntervalSince(started))
    }

    /// A performer that presses `lead` seconds after it is handed a click is handed it that much
    /// earlier, so the press itself is on the timeline; other steps are not moved.
    func testClicksAreHandedOverEarlyByThePerformersPressLead() {
        final class LeadPerformer: ActionPerformer {
            let lock = NSLock()
            var times: [(ActionKind, Double)] = []
            func perform(_ action: MacroAction) throws {
                lock.lock()
                times.append((action.kind, ProcessInfo.processInfo.systemUptime))
                lock.unlock()
            }
            func cleanup() {}
            func pressLead(for action: MacroAction) -> Double { action.kind == .click ? 0.05 : 0 }
        }
        let performer = LeadPerformer()
        let engine = PlaybackEngine(performer: performer, frontmostBundleID: { nil })
        let actions: [MacroAction] = [
            .key(KeyCodes.returnKey, delay: 0),
            .click(x: 1, y: 1, delay: 0.3),
            .key(KeyCodes.returnKey, delay: 0.3)
        ]
        var config = PlaybackConfig()
        config.countdown = 0
        config.clickHoldAsRecorded = false
        XCTAssertNoThrow(try engine.start(recording: Recording(name: "lead", actions: actions), config: config))
        XCTAssertTrue(waitUntil(5) { engine.state == .finished })
        performer.lock.lock()
        let times = performer.times
        performer.lock.unlock()
        XCTAssertEqual(times.map { $0.0 }, [.key, .click, .key])
        // Generous bounds: a test machine can wake late, never early.
        let clickGap = times[1].1 - times[0].1
        XCTAssertGreaterThanOrEqual(clickGap, 0.245)
        XCTAssertLessThan(clickGap, 0.29, "the click is handed over about 0.05 s before its time")
        let total = times[2].1 - times[0].1
        XCTAssertGreaterThanOrEqual(total, 0.595, "the step after the click keeps its own time")
    }

    func testShortHoldIsPassedToThePerformerScaled() {
        var click = MacroAction.click(x: 5, y: 6)
        click.duration = 0.08
        var config = PlaybackConfig()
        config.speed = 2
        let (performer, _) = play([click], config: config)
        XCTAssertEqual(performer.performed.count, 1)
        XCTAssertEqual(performer.performed[0].kind, .click)
        XCTAssertEqual(performer.performed[0].duration ?? -1, 0.04, accuracy: 1e-9)
    }

    func testHoldIsRemovedWhenTheOptionIsOff() {
        var click = MacroAction.click(x: 5, y: 6)
        click.duration = 0.08
        var config = PlaybackConfig()
        config.clickHoldAsRecorded = false
        let (performer, _) = play([click], config: config)
        XCTAssertNil(performer.performed.first?.duration)
    }

    func testLongHoldBecomesPressWaitRelease() {
        var click = MacroAction.click(x: 5, y: 6, button: .right)
        click.duration = 0.4
        click.modifiers = [.shift]
        let (performer, took) = play([click])
        XCTAssertEqual(performer.performed.map { $0.kind }, [.mouseDown, .mouseUp])
        let expectedButtons: [MouseButton?] = [.right, .right]
        XCTAssertEqual(performer.performed.map { $0.button }, expectedButtons)
        let expectedModifiers: [KeyModifiers?] = [[.shift], [.shift]]
        XCTAssertEqual(performer.performed.map { $0.modifiers }, expectedModifiers)
        XCTAssertEqual(performer.performed[0].x, 5)
        XCTAssertGreaterThanOrEqual(took, 0.39)
    }

    func testStopDuringALongHoldDoesNotRelease_cleanupDoes() {
        var click = MacroAction.click(x: 5, y: 6)
        click.duration = 3
        let performer = TestPerformer()
        let engine = PlaybackEngine(performer: performer, frontmostBundleID: { nil })
        XCTAssertNoThrow(try engine.start(recording: Recording(name: "t", actions: [click]), config: PlaybackConfig()))
        let deadline = Date().addingTimeInterval(2)
        while performer.performed.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        engine.stop()
        let settle = Date().addingTimeInterval(1)
        while performer.cleanupCount == 0 && Date() < settle { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(performer.performed.map { $0.kind }, [.mouseDown], "no release after Stop")
        XCTAssertEqual(performer.cleanupCount, 1, "cleanup releases the held button")
    }

    func testRecordedTypingPaceSpacesTheCharacters() {
        var text = MacroAction.text("abc")
        text.duration = 0.3
        let (performer, took) = play([text])
        XCTAssertEqual(performer.performed.compactMap { $0.text }, ["a", "b", "c"])
        XCTAssertGreaterThanOrEqual(took, 0.29)
    }

    func testValidatorAcceptsDurationsOnClicksAndRejectsBadOnes() {
        var click = MacroAction.click(x: 1, y: 1)
        click.duration = 0.1
        XCTAssertTrue(RecordingValidator.errors(in: RecordingValidator.validate(action: click)).isEmpty)
        click.duration = -1
        XCTAssertFalse(RecordingValidator.errors(in: RecordingValidator.validate(action: click)).isEmpty)
        var text = MacroAction.text("a")
        text.duration = .infinity
        XCTAssertFalse(RecordingValidator.errors(in: RecordingValidator.validate(action: text)).isEmpty)
    }

    func testDurationsSurviveTheCodec() throws {
        var click = MacroAction.click(x: 1, y: 1)
        click.duration = 0.079
        let recording = Recording(name: "c", actions: [click])
        let back = try RecordingCodec.decode(RecordingCodec.encode(recording))
        XCTAssertEqual(back.actions.first?.duration ?? -1, 0.079, accuracy: 1e-9)
    }

    func testMergingTextKeepsBothTypingTimes() {
        var first = MacroAction.text("ab")
        first.duration = 0.2
        var second = MacroAction.text("cd", delay: 0.05)
        second.duration = 0.3
        var recording = Recording(name: "m", actions: [first, second])
        let applied = recording.applyEdits([MacroEdit(id: "x", source: .rule, operation: .mergeText([second.id]), title: "", reason: "")])
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(recording.actions.count, 1)
        XCTAssertEqual(recording.actions[0].text, "abcd")
        XCTAssertEqual(recording.actions[0].duration ?? -1, 0.5, accuracy: 1e-9)
    }

    func testDeletingAClickKeepsLaterActionsOnTheTimeline() {
        var click = MacroAction.click(x: 1, y: 1, delay: 0.2)
        click.duration = 0.1
        let key = MacroAction.key(36, delay: 0.3)
        var recording = Recording(name: "d", actions: [click, key])
        recording.deleteActions(ids: [click.id])
        XCTAssertEqual(recording.actions.count, 1)
        XCTAssertEqual(recording.actions[0].delay, 0.6, accuracy: 1e-9)
    }

    func testPressTimingForSingleAndDoubleClicks() {
        let none = PlaybackTiming.pressTiming(count: 1, recorded: nil, clickHold: 0.01, doubleClickGap: 0.03)
        XCTAssertEqual(none.hold, 0.01, accuracy: 1e-9)
        let single = PlaybackTiming.pressTiming(count: 1, recorded: 0.079, clickHold: 0.01, doubleClickGap: 0.03)
        XCTAssertEqual(single.hold, 0.079, accuracy: 1e-9)
        // Double click recorded over 0.2 s: two short presses, the rest is the gap, total kept.
        let double = PlaybackTiming.pressTiming(count: 2, recorded: 0.2, clickHold: 0.01, doubleClickGap: 0.03)
        XCTAssertEqual(double.hold, 0.01, accuracy: 1e-9)
        XCTAssertEqual(2 * double.hold + double.gap, 0.2, accuracy: 1e-9)
        // A very slow "double click" still keeps the gap inside the double-click time.
        let slow = PlaybackTiming.pressTiming(count: 2, recorded: 3, clickHold: 0.01, doubleClickGap: 0.03)
        XCTAssertLessThanOrEqual(slow.gap, 0.4)
    }

    /// A slow action is made up in the next gap: the next step still starts on the timeline.
    /// (If the test machine makes the slow step much slower than asked, past the catch-up limit,
    /// the engine correctly restarts the timeline instead; that case is checked too.)
    func testASlowActionDoesNotDelayTheNextOne() {
        let performer = TestPerformer()
        let lock = NSLock()
        var starts: [Double] = []
        var firstEnded = 0.0
        performer.onPerform = { _, count in
            lock.lock()
            starts.append(ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            if count == 1 {
                Thread.sleep(forTimeInterval: 0.08)
                lock.lock()
                firstEnded = ProcessInfo.processInfo.systemUptime
                lock.unlock()
            }
        }
        let engine = PlaybackEngine(performer: performer, frontmostBundleID: { nil })
        let actions: [MacroAction] = [.key(1), .key(2, delay: 1.0)]
        XCTAssertNoThrow(try engine.start(recording: Recording(name: "t", actions: actions), config: PlaybackConfig()))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .finished = engine.state { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        lock.lock()
        let seen = starts
        let ended = firstEnded
        lock.unlock()
        XCTAssertEqual(seen.count, 2)
        guard seen.count == 2 else { return }
        let slowTook = ended - seen[0]
        // Never earlier than the timeline allows.
        XCTAssertGreaterThanOrEqual(seen[1] - seen[0], 0.99)
        if slowTook < PlaybackSchedule.maxLag - 0.03 {
            // On the timeline: 1.0 s after the first started, not 1.0 s after it finished.
            // The margin allows for a busy test machine waking the thread late.
            XCTAssertLessThan(seen[1] - seen[0], 1.25, "a sanity bound only; the exact rule is tested without a clock below")
        } else if slowTook > PlaybackSchedule.maxLag + 0.03 {
            // Too far behind: the timeline restarts from the end of the slow step.
            XCTAssertGreaterThanOrEqual(seen[1] - ended, 0.99)
        }
        // In between, the busy test machine decides which rule applied; both are correct.
    }

    func testPlannedSpanCoversHoldsAndTyping() {
        var click = MacroAction.click(x: 1, y: 1)
        click.duration = 0.2
        var text = MacroAction.text("abcd")
        text.duration = 0.3
        let config = PlaybackConfig()
        XCTAssertEqual(PlaybackTiming.plannedSpan(of: click, config: config), 0.2, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.plannedSpan(of: text, config: config), 0.3, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.plannedSpan(of: .key(1), config: config), 0)
    }

    /// Rounding to milliseconds is done against the exact times, so it never adds up.
    func testRoundingDoesNotAccumulateOverALongMacro() {
        var events: [RawEvent] = []
        var t = 0.0
        for i in 0..<600 {
            events.append(down(t, Double(i % 50), 10))
            events.append(up(t + 0.0334, Double(i % 50), 10))
            t += 0.2337 // every interval has a fraction of a millisecond
        }
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertEqual(actions.count, 600)
        var clock = 0.0
        for action in actions.dropLast() {
            clock += action.delay + (action.duration ?? 0)
        }
        clock += actions.last?.delay ?? 0
        // The last click started at 599 * 0.2337 s.
        XCTAssertEqual(clock, 599 * 0.2337, accuracy: 0.001)
    }

    // MARK: Schedule arithmetic (no clock involved)

    func testASlowStepIsMadeUpInTheNextGap() {
        // Planned at 0, meant to be instant, really ended at 0.08: the timeline stays at 0 ...
        let due = PlaybackSchedule.dueAfterAction(due: 0, plannedSpan: 0, end: 0.08)
        XCTAssertEqual(due, 0, accuracy: 1e-12)
        // ... so the next step (1.0 s later on the timeline) is due at 1.0, not 1.08.
        XCTAssertEqual(PlaybackSchedule.waitTarget(due: due + 1.0, lastEnd: 0.08, floor: 0.01), 1.0, accuracy: 1e-12)
    }

    func testFarBehindRestartsTheTimelineInsteadOfRushing() {
        let due = PlaybackSchedule.dueAfterAction(due: 0, plannedSpan: 0, end: 0.4)
        XCTAssertEqual(due, 0.4, accuracy: 1e-12)
        XCTAssertEqual(PlaybackSchedule.waitTarget(due: due + 1.0, lastEnd: 0.4, floor: 0.01), 1.4, accuracy: 1e-12)
        XCTAssertEqual(PlaybackSchedule.resyncIfFarBehind(due: 1.0, now: 1.2), 1.2, accuracy: 1e-12)
        XCTAssertEqual(PlaybackSchedule.resyncIfFarBehind(due: 1.0, now: 1.1), 1.0, accuracy: 1e-12)
    }

    func testPlannedHoldMovesTheTimelineOn() {
        // A click held 0.2 s that ended at 0.205 keeps the timeline at 0.2.
        XCTAssertEqual(PlaybackSchedule.dueAfterAction(due: 0, plannedSpan: 0.2, end: 0.205), 0.2, accuracy: 1e-12)
    }

    func testCatchingUpNeverSkipsTheGapEntirely() {
        // Due long ago, but a click still waits the minimum gap after the previous step.
        XCTAssertEqual(PlaybackSchedule.waitTarget(due: 0.5, lastEnd: 0.6, floor: PlaybackSchedule.minimumGap), 0.61, accuracy: 1e-12)
    }
}
