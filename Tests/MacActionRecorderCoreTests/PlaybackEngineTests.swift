import XCTest
@testable import MacActionRecorderCore

// MARK: - Test doubles

/// Records everything the engine asks it to perform.
final class TestPerformer: ActionPerformer {
    private let lock = NSLock()
    private var actions: [MacroAction] = []
    private var cleanups = 0

    /// Called on the playback thread after each action is recorded; `count` is the running total.
    var onPerform: ((MacroAction, Int) -> Void)?
    /// If set, performing the Nth action throws.
    var failAtCount: Int?

    func perform(_ action: MacroAction) throws {
        lock.lock()
        actions.append(action)
        let count = actions.count
        lock.unlock()

        onPerform?(action, count)

        if let failAt = failAtCount, count == failAt {
            throw PlaybackError("boom")
        }
    }

    func cleanup() {
        lock.lock()
        cleanups += 1
        lock.unlock()
    }

    var performed: [MacroAction] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }

    var cleanupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cleanups
    }
}

/// Thread-safe log of engine events.
final class EventLog {
    private let lock = NSLock()
    private var events: [PlaybackEvent] = []

    func append(_ event: PlaybackEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var all: [PlaybackEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var states: [PlaybackState] {
        return all.compactMap { (event) -> PlaybackState? in
            if case .stateChanged(let state) = event { return state }
            return nil
        }
    }

    var startedIndices: [Int] {
        return all.compactMap { (event) -> Int? in
            if case .actionStarted(let index) = event { return index }
            return nil
        }
    }

    var iterations: [Int] {
        return all.compactMap { (event) -> Int? in
            if case .iterationStarted(let iteration, _) = event { return iteration }
            return nil
        }
    }
}

final class Harness {
    let performer: TestPerformer
    let log: EventLog
    let engine: PlaybackEngine

    init(frontmost: @escaping () -> String? = { nil }) {
        let performer = TestPerformer()
        let log = EventLog()
        let engine = PlaybackEngine(performer: performer, frontmostBundleID: frontmost)
        engine.onEvent = { event in log.append(event) }
        self.performer = performer
        self.log = log
        self.engine = engine
    }

    deinit {
        engine.stop()
    }
}

func waitUntil(_ timeout: TimeInterval = 5.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

/// N click actions at x = 0...N-1, each preceded by `delay` seconds.
func makeRecording(count: Int, delay: Double = 0.002) -> Recording {
    let actions = (0..<count).map { MacroAction.click(x: Double($0), y: 0, delay: delay) }
    return Recording(name: "test", actions: actions)
}

// MARK: - Tests

final class PlaybackEngineTests: XCTestCase {
    private func fastConfig() -> PlaybackConfig {
        var config = PlaybackConfig()
        config.countdown = 0
        return config
    }

    func testPlaysEveryActionInOrderThenFinishes() throws {
        let h = Harness()
        defer { h.engine.stop() }

        try h.engine.start(recording: makeRecording(count: 5), config: fastConfig())

        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        XCTAssertEqual(h.performer.performed.map { $0.x }, [0, 1, 2, 3, 4])
        XCTAssertEqual(h.log.states, [.playing, .finished])
        XCTAssertEqual(h.log.startedIndices, [0, 1, 2, 3, 4])
        XCTAssertEqual(h.engine.state, .finished)
        XCTAssertTrue(waitUntil { h.performer.cleanupCount == 1 }, "performer cleanup runs once at the end")
    }

    func testProgressReachesOneOnFiniteRuns() throws {
        let h = Harness()
        defer { h.engine.stop() }

        try h.engine.start(recording: makeRecording(count: 4), config: fastConfig())
        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })

        let fractions = h.log.all.compactMap { event -> Double? in
            if case .progress(let progress) = event { return progress.fraction }
            return nil
        }
        XCTAssertEqual(fractions.count, 4)
        XCTAssertEqual(fractions.last ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes backwards")
    }

    // MARK: Repeats and loops

    func testRepeatCountPlaysTheWholeSequenceThatManyTimes() throws {
        let h = Harness()
        defer { h.engine.stop() }

        var config = fastConfig()
        config.repeatCount = 3
        try h.engine.start(recording: makeRecording(count: 2), config: config)

        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        XCTAssertEqual(h.performer.performed.map { $0.x }, [0, 1, 0, 1, 0, 1])
        XCTAssertEqual(h.log.iterations, [1, 2, 3])

        let totals = h.log.all.compactMap { event -> Int? in
            if case .iterationStarted(_, let total) = event { return total }
            return nil
        }
        XCTAssertEqual(totals, [3, 3, 3])
    }

    func testLoopDelayIsAppliedBetweenRepetitionsButNotAfterTheLast() throws {
        let h = Harness()
        defer { h.engine.stop() }

        var config = fastConfig()
        config.repeatCount = 3
        config.loopDelay = 0.1
        let started = Date()
        try h.engine.start(recording: makeRecording(count: 1, delay: 0), config: config)

        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.19, "two gaps of 0.1s")
        XCTAssertLessThan(elapsed, 2.0, "no trailing delay after the final pass")
    }

    func testInfiniteLoopRunsUntilStoppedAndNothingRunsAfterStop() throws {
        let h = Harness()
        defer { h.engine.stop() }

        let engine = h.engine
        h.performer.onPerform = { _, count in
            if count == 7 { engine.stop() }
        }

        var config = fastConfig()
        config.infinite = true
        try h.engine.start(recording: makeRecording(count: 2, delay: 0.001), config: config)

        XCTAssertTrue(waitUntil { h.log.states.contains(.stopped) })
        Thread.sleep(forTimeInterval: 0.3)   // give any leaked action time to appear
        XCTAssertEqual(h.performer.performed.count, 7)
        XCTAssertEqual(h.engine.state, .stopped)
        XCTAssertFalse(h.log.states.contains(.finished))
        XCTAssertTrue(waitUntil { h.performer.cleanupCount == 1 })
    }

    func testInfiniteLoopOfInstantActionsDoesNotSpinTheCPU() throws {
        let h = Harness()
        defer { h.engine.stop() }

        var config = fastConfig()
        config.infinite = true
        try h.engine.start(recording: makeRecording(count: 1, delay: 0), config: config)

        Thread.sleep(forTimeInterval: 0.5)
        h.engine.stop()
        // With the 50 ms loop floor there can be at most ~11 passes in 0.5 s.
        XCTAssertLessThan(h.performer.performed.count, 40)
        XCTAssertGreaterThan(h.performer.performed.count, 0)
    }

    // MARK: Pause, resume, stop

    func testPauseHaltsExecutionAndResumeContinues() throws {
        let h = Harness()
        defer { h.engine.stop() }

        let engine = h.engine
        h.performer.onPerform = { _, count in
            if count == 2 { engine.pause() }
        }

        try h.engine.start(recording: makeRecording(count: 6, delay: 0.01), config: fastConfig())

        XCTAssertTrue(waitUntil { h.engine.state == .paused })
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(h.performer.performed.count, 2, "nothing runs while paused")
        XCTAssertEqual(h.engine.state, .paused)

        h.performer.onPerform = nil
        h.engine.resume()

        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        XCTAssertEqual(h.performer.performed.map { $0.x }, [0, 1, 2, 3, 4, 5], "order preserved across pause")
        XCTAssertEqual(h.log.states, [.playing, .paused, .playing, .finished])
    }

    func testPauseAndResumeAreNoOpsWhenNotApplicable() {
        let h = Harness()
        h.engine.pause()
        h.engine.resume()
        XCTAssertEqual(h.engine.state, .idle)
        XCTAssertTrue(h.log.all.isEmpty)
    }

    func testStopWhilePausedCancelsTheRun() throws {
        let h = Harness()
        defer { h.engine.stop() }

        let engine = h.engine
        h.performer.onPerform = { _, count in
            if count == 1 { engine.pause() }
        }
        try h.engine.start(recording: makeRecording(count: 5, delay: 0.01), config: fastConfig())

        XCTAssertTrue(waitUntil { h.engine.state == .paused })
        h.engine.stop()

        XCTAssertEqual(h.engine.state, .stopped)
        XCTAssertTrue(waitUntil { h.performer.cleanupCount == 1 })
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(h.performer.performed.count, 1)
    }

    func testStopInterruptsALongDelayImmediately() throws {
        let h = Harness()
        defer { h.engine.stop() }

        let recording = Recording(name: "slow", actions: [.wait(30), .click(x: 1, y: 1)])
        try h.engine.start(recording: recording, config: fastConfig())
        Thread.sleep(forTimeInterval: 0.1)

        let before = Date()
        h.engine.stop()
        XCTAssertEqual(h.engine.state, .stopped)
        XCTAssertTrue(waitUntil(2.0) { h.performer.cleanupCount == 1 }, "playback thread exits promptly")
        XCTAssertLessThan(Date().timeIntervalSince(before), 2.0)
        XCTAssertEqual(h.performer.performed.count, 0)
    }

    func testStopDuringCountdownPreventsAnyAction() throws {
        let h = Harness()
        defer { h.engine.stop() }

        var config = fastConfig()
        config.countdown = 5
        try h.engine.start(recording: makeRecording(count: 3), config: config)
        XCTAssertEqual(h.engine.state, .countdown(5))

        h.engine.stop()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(h.performer.performed.count, 0)
        XCTAssertEqual(h.log.states, [.countdown(5), .stopped])
    }

    func testCountdownDelaysTheFirstAction() throws {
        let h = Harness()
        defer { h.engine.stop() }

        var config = fastConfig()
        config.countdown = 1
        let started = Date()
        try h.engine.start(recording: makeRecording(count: 1, delay: 0), config: config)

        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.95)
        XCTAssertEqual(h.log.states.first, .countdown(1))
        XCTAssertEqual(h.log.states, [.countdown(1), .playing, .finished])
    }

    func testRestartPlaysFromTheBeginningAgain() throws {
        let h = Harness()
        defer { h.engine.stop() }

        try h.engine.start(recording: makeRecording(count: 3), config: fastConfig())
        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })

        try h.engine.restart()
        XCTAssertTrue(waitUntil { h.performer.performed.count == 6 })
        XCTAssertEqual(h.performer.performed.map { $0.x }, [0, 1, 2, 0, 1, 2])
    }

    func testRestartWithoutAPreviousRunThrows() {
        let h = Harness()
        XCTAssertThrowsError(try h.engine.restart())
    }

    // MARK: Speed

    func testHigherSpeedFinishesSooner() throws {
        let slowHarness = Harness()
        let fastHarness = Harness()
        defer {
            slowHarness.engine.stop()
            fastHarness.engine.stop()
        }

        // 20 pointer moves, 30 ms apart at 1x => about 0.6 s; at 4x about 0.15 s.
        let actions = (0..<20).map { MacroAction.move(x: Double($0), y: 0, delay: 0.03) }
        let recording = Recording(name: "moves", actions: actions)

        var slow = fastConfig()
        slow.speed = 1
        var fast = fastConfig()
        fast.speed = 4

        let slowStart = Date()
        try slowHarness.engine.start(recording: recording, config: slow)
        XCTAssertTrue(waitUntil { slowHarness.log.states.contains(.finished) })
        let slowElapsed = Date().timeIntervalSince(slowStart)

        let fastStart = Date()
        try fastHarness.engine.start(recording: recording, config: fast)
        XCTAssertTrue(waitUntil { fastHarness.log.states.contains(.finished) })
        let fastElapsed = Date().timeIntervalSince(fastStart)

        XCTAssertGreaterThanOrEqual(slowElapsed, 0.5, "cannot finish faster than the recorded timing")
        XCTAssertGreaterThanOrEqual(fastElapsed, 0.1)
        XCTAssertLessThan(fastElapsed, slowElapsed)
        XCTAssertEqual(slowHarness.performer.performed.count, 20)
        XCTAssertEqual(fastHarness.performer.performed.count, 20, "speed never drops actions")
    }

    // MARK: Sections, text, safety

    func testSelectedSectionPlaysOnlyThoseActionsWithOriginalIndices() throws {
        let h = Harness()
        defer { h.engine.stop() }

        var config = fastConfig()
        config.range = 1..<4
        try h.engine.start(recording: makeRecording(count: 5), config: config)

        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        XCTAssertEqual(h.performer.performed.map { $0.x }, [1, 2, 3])
        XCTAssertEqual(h.log.startedIndices, [1, 2, 3])
    }

    func testEmptyOrInvalidSectionThrows() {
        let h = Harness()
        var config = fastConfig()
        config.range = 3..<3
        XCTAssertThrowsError(try h.engine.start(recording: makeRecording(count: 5), config: config))

        config.range = 10..<20
        XCTAssertThrowsError(try h.engine.start(recording: makeRecording(count: 5), config: config))
    }

    func testTextIsTypedOneCharacterAtATime() throws {
        let h = Harness()
        defer { h.engine.stop() }

        let recording = Recording(name: "typing", actions: [.text("hi!"), .key(KeyCodes.returnKey)])
        try h.engine.start(recording: recording, config: fastConfig())

        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        let performed = h.performer.performed
        XCTAssertEqual(performed.map { $0.kind }, [.text, .text, .text, .key])
        XCTAssertEqual(performed.compactMap { $0.text }, ["h", "i", "!"])
    }

    func testStopMidTextStopsTyping() throws {
        let h = Harness()
        defer { h.engine.stop() }

        let engine = h.engine
        h.performer.onPerform = { _, count in
            if count == 3 { engine.stop() }
        }
        let recording = Recording(name: "typing", actions: [.text("abcdefghij")])
        try h.engine.start(recording: recording, config: fastConfig())

        XCTAssertTrue(waitUntil { h.log.states.contains(.stopped) })
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(h.performer.performed.count, 3)
    }

    func testInvalidRecordingIsRejectedBeforeAnythingRuns() {
        let h = Harness()
        let broken = Recording(name: "broken", actions: [MacroAction(kind: .click, x: 1, y: 1)])  // no button/count
        XCTAssertThrowsError(try h.engine.start(recording: broken, config: fastConfig()))
        XCTAssertEqual(h.performer.performed.count, 0)
        XCTAssertEqual(h.engine.state, .idle)
    }

    func testEmptyRecordingIsRejected() {
        let h = Harness()
        XCTAssertThrowsError(try h.engine.start(recording: Recording(name: "empty"), config: fastConfig()))
    }

    func testPerformerErrorFailsTheRunAndStillCleansUp() throws {
        let h = Harness()
        defer { h.engine.stop() }

        h.performer.failAtCount = 2
        try h.engine.start(recording: makeRecording(count: 5), config: fastConfig())

        XCTAssertTrue(waitUntil { h.engine.state == .failed("boom") })
        XCTAssertEqual(h.performer.performed.count, 2)
        XCTAssertTrue(waitUntil { h.performer.cleanupCount == 1 })
    }

    // MARK: Foreground verification

    func testForegroundMismatchStopsPlaybackBeforeAnyInput() throws {
        let h = Harness(frontmost: { "com.example.other" })
        defer { h.engine.stop() }

        var config = fastConfig()
        config.requiredBundleID = "com.example.expected"
        config.requiredAppName = "Expected"
        try h.engine.start(recording: makeRecording(count: 3), config: config)

        XCTAssertTrue(waitUntil {
            if case .failed = h.engine.state { return true }
            return false
        })
        XCTAssertEqual(h.performer.performed.count, 0)
        if case .failed(let message) = h.engine.state {
            XCTAssertTrue(message.contains("Expected"))
            XCTAssertTrue(message.contains("frontmost"))
        }
    }

    func testForegroundMatchPlaysNormally() throws {
        let h = Harness(frontmost: { "com.example.expected" })
        defer { h.engine.stop() }

        var config = fastConfig()
        config.requiredBundleID = "com.example.expected"
        try h.engine.start(recording: makeRecording(count: 3), config: config)

        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        XCTAssertEqual(h.performer.performed.count, 3)
    }

    func testForegroundLossMidRunStopsPlayback() throws {
        var frontmost = "com.example.expected"
        let lock = NSLock()
        let h = Harness(frontmost: {
            lock.lock()
            defer { lock.unlock() }
            return frontmost
        })
        defer { h.engine.stop() }

        h.performer.onPerform = { _, count in
            if count == 2 {
                lock.lock()
                frontmost = "com.example.other"
                lock.unlock()
            }
        }

        var config = fastConfig()
        config.requiredBundleID = "com.example.expected"
        try h.engine.start(recording: makeRecording(count: 6, delay: 0.005), config: config)

        XCTAssertTrue(waitUntil {
            if case .failed = h.engine.state { return true }
            return false
        })
        XCTAssertEqual(h.performer.performed.count, 2, "no input is sent once the app loses focus")
    }
}
