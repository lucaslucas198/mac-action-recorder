import XCTest
@testable import MacActionRecorderCore

final class ValidationTests: XCTestCase {
    private func errors(_ action: MacroAction) -> [ValidationIssue] {
        return RecordingValidator.errors(in: RecordingValidator.validate(action: action, index: 0))
    }

    func testWellFormedActionsHaveNoErrors() {
        let actions: [MacroAction] = [
            .move(x: 0, y: 0),
            .move(x: -1500, y: 40),          // secondary displays can be at negative coordinates
            .click(x: 10, y: 10, button: .left, count: 3),
            .drag(x: 5, y: 5),
            .mouseDown(x: 1, y: 1),
            .mouseUp(x: 1, y: 1),
            .scroll(dx: 0, dy: -50),
            .key(36),
            .key(40, modifiers: [.command]),
            .text("hello"),
            .wait(0)
        ]
        for action in actions {
            XCTAssertTrue(errors(action).isEmpty, "\(action.kind) should be valid")
        }
    }

    func testNegativeAndNonFiniteDelaysAreErrors() {
        XCTAssertFalse(errors(.move(x: 0, y: 0, delay: -1)).isEmpty)
        XCTAssertFalse(errors(.move(x: 0, y: 0, delay: .nan)).isEmpty)
        XCTAssertFalse(errors(.move(x: 0, y: 0, delay: .infinity)).isEmpty)
        XCTAssertFalse(errors(.move(x: 0, y: 0, delay: RecordingValidator.maxDelay + 1)).isEmpty)
    }

    func testCoordinatesMustBeFiniteAndInRange() {
        XCTAssertFalse(errors(.move(x: .nan, y: 0)).isEmpty)
        XCTAssertFalse(errors(.move(x: 0, y: .infinity)).isEmpty)
        XCTAssertFalse(errors(.move(x: 1e9, y: 0)).isEmpty)
        XCTAssertFalse(errors(MacroAction(kind: .move)).isEmpty)
    }

    func testClickRules() {
        XCTAssertFalse(errors(.click(x: 1, y: 1, count: 0)).isEmpty)
        XCTAssertFalse(errors(.click(x: 1, y: 1, count: 4)).isEmpty)
        XCTAssertFalse(errors(MacroAction(kind: .click, x: 1, y: 1, clickCount: 1)).isEmpty, "missing button")
        XCTAssertFalse(errors(MacroAction(kind: .click, x: 1, y: 1, button: .left)).isEmpty, "missing click count")
    }

    func testKeyRules() {
        XCTAssertFalse(errors(.key(-1)).isEmpty)
        XCTAssertFalse(errors(.key(256)).isEmpty)
        XCTAssertFalse(errors(MacroAction(kind: .key)).isEmpty)
    }

    func testTextRules() {
        XCTAssertFalse(errors(.text("")).isEmpty)
        XCTAssertFalse(errors(MacroAction(kind: .text)).isEmpty)
        XCTAssertFalse(errors(.text(String(repeating: "a", count: RecordingValidator.maxText + 1))).isEmpty)
    }

    func testWaitAndScrollRules() {
        XCTAssertFalse(errors(.wait(-0.1)).isEmpty)
        XCTAssertFalse(errors(MacroAction(kind: .wait)).isEmpty)
        XCTAssertFalse(errors(MacroAction(kind: .scroll)).isEmpty)
        XCTAssertFalse(errors(.scroll(dx: 0, dy: 10_000_000)).isEmpty)
    }

    func testRecordingLevelChecks() {
        var recording = Recording(name: "ok", actions: [.click(x: 1, y: 1)])
        XCTAssertTrue(RecordingValidator.errors(in: RecordingValidator.validate(recording)).isEmpty)

        recording.formatVersion = 7
        XCTAssertFalse(RecordingValidator.errors(in: RecordingValidator.validate(recording)).isEmpty)
    }

    func testEmptyNameAndEmptyActionsAreOnlyWarnings() {
        let recording = Recording(name: "  ", actions: [])
        let issues = RecordingValidator.validate(recording)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertTrue(RecordingValidator.errors(in: issues).isEmpty)
    }

    func testTooManyActionsIsAnError() {
        let actions = (0..<5).map { _ in MacroAction.click(x: 1, y: 1) }
        let recording = Recording(name: "big", actions: actions)
        let issues = RecordingValidator.validate(recording, maxActions: 3)
        XCTAssertFalse(RecordingValidator.errors(in: issues).isEmpty)
    }

    func testIssuesCarryTheActionIndex() {
        let recording = Recording(name: "r", actions: [.click(x: 1, y: 1), .click(x: 1, y: 1, count: 9)])
        let issues = RecordingValidator.errors(in: RecordingValidator.validate(recording))
        XCTAssertEqual(issues.first?.actionIndex, 1)
    }
}
