import XCTest
@testable import MacActionRecorderCore

final class RecordingEditingTests: XCTestCase {
    private func recording(_ count: Int = 5) -> Recording {
        let actions = (0..<count).map { MacroAction.click(x: Double($0), y: 0, delay: Double($0 + 1) * 0.1) }
        return Recording(name: "edit", actions: actions)
    }

    private func xs(_ r: Recording) -> [Double] {
        return r.actions.map { $0.x ?? -1 }
    }

    func testDeleteRemovesActionsAndKeepsOrder() {
        var r = recording()
        r.deleteActions(ids: [r.actions[1].id, r.actions[3].id])
        XCTAssertEqual(xs(r), [0, 2, 4])
    }

    func testDeleteFoldsRemovedDelaysIntoTheNextAction() {
        var r = recording()   // delays: 0.1, 0.2, 0.3, 0.4, 0.5
        let total = r.originalDuration
        r.deleteActions(ids: [r.actions[1].id, r.actions[2].id])
        // Action 3 (delay 0.4) inherits 0.2 + 0.3.
        XCTAssertEqual(r.actions[1].delay, 0.9, accuracy: 1e-9)
        XCTAssertEqual(r.originalDuration, total - 0.0, accuracy: 1e-9, "total timing is preserved")
    }

    func testDeletingTheLastActionDropsItsDelay() {
        var r = recording(3)   // 0.1, 0.2, 0.3
        r.deleteActions(ids: [r.actions[2].id])
        XCTAssertEqual(r.actions.count, 2)
        XCTAssertEqual(r.originalDuration, 0.3, accuracy: 1e-9)
    }

    func testDeleteWithUnknownIdsChangesNothing() {
        var r = recording()
        let before = r
        r.deleteActions(ids: [UUID()])
        XCTAssertEqual(r, before)
    }

    func testDuplicateInsertsCopiesAfterTheLastSelectedAction() {
        var r = recording()
        let ids = Set([r.actions[1].id, r.actions[2].id])
        let newIDs = r.duplicateActions(ids: ids)
        XCTAssertEqual(xs(r), [0, 1, 2, 1, 2, 3, 4])
        XCTAssertEqual(newIDs.count, 2)
        XCTAssertEqual(Set(r.actions.map { $0.id }).count, 7, "copies get fresh ids")
    }

    func testDuplicateWithNothingSelectedIsANoOp() {
        var r = recording()
        XCTAssertTrue(r.duplicateActions(ids: []).isEmpty)
        XCTAssertEqual(r.actions.count, 5)
    }

    func testMoveToLaterPosition() {
        var r = recording(4)   // 0 1 2 3
        r.moveActions(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(xs(r), [1, 2, 0, 3])
    }

    func testMoveToEarlierPosition() {
        var r = recording(4)
        r.moveActions(from: IndexSet(integer: 3), to: 1)
        XCTAssertEqual(xs(r), [0, 3, 1, 2])
    }

    func testMoveToEnd() {
        var r = recording(4)
        r.moveActions(from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(xs(r), [1, 2, 3, 0])
    }

    func testMoveSeveralActionsAtOnce() {
        var r = recording(5)
        r.moveActions(from: IndexSet([0, 1]), to: 4)
        XCTAssertEqual(xs(r), [2, 3, 0, 1, 4])
    }

    func testMoveWithOutOfRangeIndicesIsSafe() {
        var r = recording(3)
        r.moveActions(from: IndexSet(integer: 10), to: 0)
        XCTAssertEqual(xs(r), [0, 1, 2])
        r.moveActions(from: IndexSet(integer: 0), to: 99)
        XCTAssertEqual(xs(r), [1, 2, 0])
    }

    func testMoveUpAndDown() {
        var r = recording(4)
        let second = r.actions[1].id
        r.moveUp(ids: [second])
        XCTAssertEqual(xs(r), [1, 0, 2, 3])

        r.moveUp(ids: [second])   // already first: stays put
        XCTAssertEqual(xs(r), [1, 0, 2, 3])

        r.moveDown(ids: [second])
        XCTAssertEqual(xs(r), [0, 1, 2, 3])
    }

    func testMoveUpAndDownKeepSelectedBlocksTogether() {
        var r = recording(4)
        let block = Set([r.actions[2].id, r.actions[3].id])
        r.moveUp(ids: block)
        XCTAssertEqual(xs(r), [0, 2, 3, 1])
        r.moveDown(ids: block)
        XCTAssertEqual(xs(r), [0, 1, 2, 3])
    }

    func testInsertWaitAfterAnActionOrAtTheEnd() {
        var r = recording(3)
        let waitID = r.insertWait(seconds: 2.5, after: r.actions[0].id)
        XCTAssertEqual(r.actions[1].id, waitID)
        XCTAssertEqual(r.actions[1].kind, .wait)
        XCTAssertEqual(r.actions[1].duration, 2.5)
        XCTAssertEqual(r.actions.count, 4)

        r.insertWait(seconds: 1, after: nil)
        XCTAssertEqual(r.actions.last?.kind, .wait)
        XCTAssertEqual(r.actions.count, 5)
    }

    func testInsertedWaitsAffectOriginalDuration() {
        var r = recording(1)   // 0.1
        r.insertWait(seconds: 2, after: nil)
        XCTAssertEqual(r.originalDuration, 2.1, accuracy: 1e-9)
    }

    func testInsertActionsAfterOrAtEnd() {
        var r = recording(2)
        r.insertActions([.text("a"), .text("b")], after: r.actions[0].id)
        XCTAssertEqual(r.actions.map { $0.kind }, [.click, .text, .text, .click])
        r.insertActions([.key(36)], after: UUID())
        XCTAssertEqual(r.actions.last?.kind, .key)
    }

    func testReplaceActionAppliesEditsByIdAndSurvivesRoundTrip() throws {
        var r = recording(3)
        var edited = r.actions[1]
        edited.x = 420
        edited.y = 310
        edited.delay = 0.75
        XCTAssertTrue(r.replaceAction(edited))
        XCTAssertFalse(r.replaceAction(MacroAction.click(x: 1, y: 1)))

        let reloaded = try RecordingCodec.decode(try RecordingCodec.encode(r))
        XCTAssertEqual(reloaded.actions[1].x, 420)
        XCTAssertEqual(reloaded.actions[1].y, 310)
        XCTAssertEqual(reloaded.actions[1].delay, 0.75)
    }

    func testEditedRecordingPlaysWithTheEditedValues() throws {
        // Edits must be reflected in playback: change a click position and a delay, then play.
        var r = recording(2)
        var edited = r.actions[1]
        edited.x = 999
        edited.delay = 0.003
        r.replaceAction(edited)
        r.deleteActions(ids: [r.actions[0].id])

        let h = Harness()
        defer { h.engine.stop() }
        try h.engine.start(recording: r, config: PlaybackConfig())
        XCTAssertTrue(waitUntil { h.log.states.contains(.finished) })
        XCTAssertEqual(h.performer.performed.map { $0.x }, [999])
    }
}
