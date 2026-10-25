import XCTest
@testable import MacActionRecorderCore

final class RecordingBuilderTests: XCTestCase {
    private let options = RecordingOptions()

    // Event helpers
    private func move(_ t: Double, _ x: Double, _ y: Double) -> RawEvent {
        RawEvent(time: t, x: x, y: y, kind: .mouseMove)
    }

    private func down(_ t: Double, _ x: Double, _ y: Double, _ button: MouseButton = .left, count: Int = 1) -> RawEvent {
        RawEvent(time: t, x: x, y: y, kind: .mouseDown(button, clickCount: count))
    }

    private func up(_ t: Double, _ x: Double, _ y: Double, _ button: MouseButton = .left, count: Int = 1) -> RawEvent {
        RawEvent(time: t, x: x, y: y, kind: .mouseUp(button, clickCount: count))
    }

    private func key(_ t: Double, _ code: Int, _ chars: String, _ mods: KeyModifiers = []) -> RawEvent {
        RawEvent(time: t, kind: .keyDown(keyCode: code, modifiers: mods, characters: chars, isRepeat: false))
    }

    private func keyUp(_ t: Double, _ code: Int) -> RawEvent {
        RawEvent(time: t, kind: .keyUp(keyCode: code, modifiers: []))
    }

    private func scroll(_ t: Double, dx: Int = 0, dy: Int) -> RawEvent {
        RawEvent(time: t, x: 50, y: 60, kind: .scroll(dx: dx, dy: dy))
    }

    // MARK: Ordering and timing

    func testClickAndTypingKeepOrderAndRelativeDelays() {
        let events = [
            move(0.00, 100, 100),
            down(0.50, 100, 100), up(0.58, 100, 100),
            key(1.00, 4, "h"), keyUp(1.04, 4),
            key(1.10, 34, "i"), keyUp(1.14, 34),
            key(1.30, 36, "\r")
        ]
        let actions = RecordingBuilder.build(events: events, options: options)

        XCTAssertEqual(actions.map { $0.kind }, [.move, .click, .text, .key])
        XCTAssertEqual(actions[0].delay, 0, accuracy: 0.0001)
        XCTAssertEqual(actions[1].delay, 0.5, accuracy: 0.0001)   // 0.50 - 0.00
        XCTAssertEqual(actions[2].delay, 0.42, accuracy: 0.0001)  // 1.00 - end of click (0.58)
        XCTAssertEqual(actions[2].text, "hi")
        XCTAssertEqual(actions[3].delay, 0.2, accuracy: 0.0001)   // 1.30 - last typed char (1.10)
        XCTAssertEqual(actions[3].keyCode, 36)
    }

    func testFirstActionAlwaysHasZeroDelay() {
        let actions = RecordingBuilder.build(events: [down(5.0, 1, 1), up(5.1, 1, 1)], options: options)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].delay, 0)
    }

    func testDelaysAreRoundedToMilliseconds() {
        let events = [down(0, 1, 1), up(0, 1, 1), down(0.123456, 1, 1), up(0.123456, 1, 1)]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[1].delay, 0.123, accuracy: 0.00001)
    }

    func testTimestampsNeverProduceNegativeDelays() {
        // Out-of-order timestamps must not yield negative delays.
        let events = [down(2.0, 1, 1), up(2.1, 1, 1), key(1.0, 4, "a")]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertTrue(actions.allSatisfy { $0.delay >= 0 })
    }

    // MARK: Clicks

    func testDoubleClickIsMergedIntoOneAction() {
        let events = [
            down(0.00, 50, 50, count: 1), up(0.05, 50, 50, count: 1),
            down(0.12, 50, 50, count: 2), up(0.17, 50, 50, count: 2)
        ]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].kind, .click)
        XCTAssertEqual(actions[0].clickCount, 2)
    }

    func testTripleClickIsMerged() {
        let events = [
            down(0.00, 50, 50, count: 1), up(0.04, 50, 50, count: 1),
            down(0.10, 50, 50, count: 2), up(0.14, 50, 50, count: 2),
            down(0.20, 50, 50, count: 3), up(0.24, 50, 50, count: 3)
        ]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].clickCount, 3)
    }

    func testSeparateClicksStaySeparate() {
        let events = [
            down(0.0, 50, 50, count: 1), up(0.05, 50, 50, count: 1),
            down(2.0, 300, 300, count: 1), up(2.05, 300, 300, count: 1)
        ]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertEqual(actions.map { $0.kind }, [.click, .click])
        XCTAssertEqual(actions[1].delay, 1.95, accuracy: 0.0001)
    }

    func testRightClickKeepsButton() {
        let actions = RecordingBuilder.build(events: [down(0, 9, 9, .right), up(0.05, 9, 9, .right)], options: options)
        XCTAssertEqual(actions.first?.button, .right)
    }

    func testDragIsPressMovesRelease() {
        let events = [
            down(0.0, 10, 10),
            RawEvent(time: 0.10, x: 40, y: 10, kind: .mouseDrag(.left)),
            RawEvent(time: 0.20, x: 80, y: 10, kind: .mouseDrag(.left)),
            up(0.30, 80, 10)
        ]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertEqual(actions.map { $0.kind }, [.mouseDown, .drag, .drag, .mouseUp])
    }

    func testButtonHeldAtStopIsReleased() {
        let actions = RecordingBuilder.build(events: [down(0, 10, 10)], options: options)
        XCTAssertEqual(actions.map { $0.kind }, [.mouseDown, .mouseUp])
    }

    func testReleaseWithoutPressIsDropped() {
        // E.g. the press happened inside the app's own window and was filtered out.
        let actions = RecordingBuilder.build(events: [up(0, 10, 10)], options: options)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: Keyboard

    func testShortcutBecomesKeyActionNotText() {
        let actions = RecordingBuilder.build(events: [key(0, 40, "k", [.command])], options: options)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].kind, .key)
        XCTAssertEqual(actions[0].keyCode, 40)
        XCTAssertEqual(actions[0].modifiers, [.command])
    }

    func testShiftedCharactersStayText() {
        let actions = RecordingBuilder.build(
            events: [key(0, 4, "H", [.shift]), key(0.05, 34, "i")],
            options: options
        )
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].text, "Hi")
    }

    func testSpecialKeysBreakTextRuns() {
        let events = [
            key(0.00, 0, "a"),
            key(0.10, 123, "\u{F702}"),       // left arrow
            key(0.20, 11, "b")
        ]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertEqual(actions.map { $0.kind }, [.text, .key, .text])
        XCTAssertEqual(actions[1].keyCode, 123)
    }

    func testLongPauseStartsNewTextAction() {
        let events = [key(0, 0, "a"), key(3.0, 11, "b")]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[1].delay, 3.0, accuracy: 0.0001)
    }

    func testKeyUpAloneRecordsNothing() {
        XCTAssertTrue(RecordingBuilder.build(events: [keyUp(0, 4)], options: options).isEmpty)
    }

    func testIsPrintable() {
        XCTAssertTrue(RecordingBuilder.isPrintable("a"))
        XCTAssertTrue(RecordingBuilder.isPrintable(" "))
        XCTAssertTrue(RecordingBuilder.isPrintable("é"))
        XCTAssertTrue(RecordingBuilder.isPrintable("👋"))
        XCTAssertFalse(RecordingBuilder.isPrintable(""))
        XCTAssertFalse(RecordingBuilder.isPrintable("\r"))
        XCTAssertFalse(RecordingBuilder.isPrintable("\t"))
        XCTAssertFalse(RecordingBuilder.isPrintable("\u{7F}"))
        XCTAssertFalse(RecordingBuilder.isPrintable("\u{F702}"))
    }

    // MARK: Options

    func testMouseMoveCanBeExcluded() {
        var custom = options
        custom.includeMouseMove = false
        let events = [move(0, 1, 1), move(0.1, 50, 50), down(0.2, 50, 50), up(0.25, 50, 50)]
        let actions = RecordingBuilder.build(events: events, options: custom)
        XCTAssertEqual(actions.map { $0.kind }, [.click])
    }

    func testScrollCanBeExcluded() {
        var custom = options
        custom.recordScroll = false
        XCTAssertTrue(RecordingBuilder.build(events: [scroll(0, dy: -10)], options: custom).isEmpty)
    }

    func testTextCanBeExcludedWhileShortcutsStay() {
        var custom = options
        custom.recordText = false
        let events = [key(0, 40, "k", [.command]), key(0.1, 4, "h"), key(0.2, 36, "\r")]
        let actions = RecordingBuilder.build(events: events, options: custom)
        XCTAssertEqual(actions.map { $0.kind }, [.key, .key])
        XCTAssertEqual(actions.map { $0.keyCode }, [40, 36])
    }

    func testShortcutsCanBeExcludedWhileTextStays() {
        var custom = options
        custom.recordShortcuts = false
        let events = [key(0, 40, "k", [.command]), key(0.1, 4, "h"), key(0.2, 36, "\r")]
        let actions = RecordingBuilder.build(events: events, options: custom)
        XCTAssertEqual(actions.map { $0.kind }, [.text])
        XCTAssertEqual(actions.first?.text, "h")
    }

    // MARK: Throttling / scroll coalescing

    func testMoveThrottleKeepsFirstAndRespectsBothThresholds() {
        var throttle = MoveThrottle(minInterval: 0.03, minDistance: 3)
        XCTAssertTrue(throttle.shouldAccept(time: 0.000, x: 0, y: 0))     // first
        XCTAssertFalse(throttle.shouldAccept(time: 0.010, x: 1, y: 0))    // too soon, too close
        XCTAssertFalse(throttle.shouldAccept(time: 0.040, x: 1, y: 0))    // late enough but too close
        XCTAssertFalse(throttle.shouldAccept(time: 0.020, x: 50, y: 0))   // far enough but too soon
        XCTAssertTrue(throttle.shouldAccept(time: 0.050, x: 20, y: 0))    // both thresholds met
        XCTAssertFalse(throttle.shouldAccept(time: 0.060, x: 40, y: 0))   // only 0.010 after the last kept sample
    }

    func testHighFrequencyMovesAreThinnedWhenBuilding() {
        var events: [RawEvent] = []
        for i in 0..<500 {
            events.append(move(Double(i) * 0.002, Double(i), 0))   // 500 Hz, 1 px steps
        }
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertGreaterThan(actions.count, 1)
        XCTAssertLessThan(actions.count, 60)
        XCTAssertTrue(actions.allSatisfy { $0.kind == .move })
    }

    func testRapidScrollEventsAreCoalesced() {
        let events = [scroll(0.00, dy: -5), scroll(0.01, dy: -5), scroll(0.02, dy: -5), scroll(1.0, dy: 8)]
        let actions = RecordingBuilder.build(events: events, options: options)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].scrollY, -15)
        XCTAssertEqual(actions[1].scrollY, 8)
        XCTAssertEqual(actions[1].delay, 0.98, accuracy: 0.0001)
    }

    func testBuiltActionsPassValidation() {
        let events = [
            move(0, 10, 10), down(0.2, 10, 10), up(0.25, 10, 10),
            key(0.5, 4, "a"), key(0.6, 36, "\r"), scroll(0.9, dy: 20), key(1.0, 40, "k", [.command])
        ]
        let recording = Recording(name: "built", actions: RecordingBuilder.build(events: events, options: options))
        XCTAssertTrue(RecordingValidator.errors(in: RecordingValidator.validate(recording)).isEmpty)
    }

    func testEmptyInputGivesEmptyOutput() {
        XCTAssertTrue(RecordingBuilder.build(events: [], options: options).isEmpty)
    }
}
