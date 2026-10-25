import XCTest
@testable import MacActionRecorderCore

final class MacroOptimizerTests: XCTestCase {
    private func moves(_ count: Int) -> [MacroAction] {
        return (0..<count).map { MacroAction.move(x: Double($0), y: 10, delay: 0.01) }
    }

    private func ids(_ edits: [MacroEdit]) -> [String] {
        return edits.map { $0.id }
    }

    // MARK: Planning

    func testEmptyRecordingHasNoPlan() {
        XCTAssertTrue(MacroOptimizer.plan(for: Recording(name: "e")).isEmpty)
    }

    func testCleanMacroHasNoPlan() {
        let r = Recording(name: "clean", actions: [
            .key(KeyCodes.ansiK, modifiers: [.command]),
            .text("general", delay: 0.5),
            .key(KeyCodes.returnKey, delay: 0.2)
        ])
        XCTAssertTrue(MacroOptimizer.plan(for: r).isEmpty)
    }

    func testMovesBeforeAClickAreAllRemoved() {
        let path = moves(5)
        let r = Recording(name: "m", actions: path + [.click(x: 5, y: 10)])
        let plan = MacroOptimizer.plan(for: r)
        XCTAssertEqual(ids(plan), ["rule-remove-moves"])
        guard case .delete(let removed) = plan[0].operation else { return XCTFail("expected delete") }
        XCTAssertEqual(Set(removed), Set(path.map { $0.id }))
    }

    func testTheLastMoveIsKeptWhenNoClickFollows() {
        let path = moves(4)
        let r = Recording(name: "m", actions: path + [.key(KeyCodes.returnKey)])
        let plan = MacroOptimizer.plan(for: r)
        guard case .delete(let removed) = plan[0].operation else { return XCTFail("expected delete") }
        XCTAssertEqual(removed.count, 3)
        XCTAssertFalse(removed.contains(path[3].id))
    }

    func testShortMoveRunsAreLeftAlone() {
        let r = Recording(name: "m", actions: moves(2) + [.click(x: 1, y: 1)])
        XCTAssertTrue(MacroOptimizer.plan(for: r).isEmpty)
    }

    func testAdjacentTextIsMergedOnlyWhenClose() {
        let a = MacroAction.text("Hel")
        let b = MacroAction.text("lo", delay: 0.4)
        let c = MacroAction.text("!", delay: 3)
        let plan = MacroOptimizer.plan(for: Recording(name: "t", actions: [a, b, c]))
        XCTAssertEqual(ids(plan), ["rule-merge-text"])
        guard case .mergeText(let merged) = plan[0].operation else { return XCTFail("expected merge") }
        XCTAssertEqual(merged, [b.id])
    }

    func testTextAfterClickOrShortcutGetsASettleDelay() {
        let afterClick = MacroAction.text("a", delay: 0.05)
        let afterShortcut = MacroAction.text("b", delay: 0.0)
        let afterPlainKey = MacroAction.text("c", delay: 0.0)
        let r = Recording(name: "s", actions: [
            .click(x: 1, y: 1), afterClick,
            .key(KeyCodes.ansiK, modifiers: [.command]), afterShortcut,
            .key(KeyCodes.tab), afterPlainKey
        ])
        let plan = MacroOptimizer.plan(for: r)
        guard let edit = plan.first(where: { $0.id == "rule-settle-text" }),
              case .setMinimumDelay(let targets, let seconds) = edit.operation else {
            return XCTFail("expected a settle edit")
        }
        XCTAssertEqual(Set(targets), [afterClick.id, afterShortcut.id])
        XCTAssertEqual(seconds, MacroOptimizer.settleDelay)
    }

    func testLongPausesAreCounted() {
        let r = Recording(name: "p", actions: [.key(36, delay: 30), .wait(20), .wait(1)])
        let plan = MacroOptimizer.plan(for: r)
        XCTAssertEqual(ids(plan), ["rule-cap-pauses"])
        XCTAssertTrue(plan[0].title.contains("2 long pause"))
    }

    // MARK: Applying

    func testApplyingTheWholePlanKeepsTheRecordingValidAndShorter() {
        let r = Recording(name: "all", actions:
            moves(6) + [.click(x: 5, y: 10, delay: 1)]
            + [.text("Hel", delay: 0.02), .text("lo", delay: 0.1), .key(KeyCodes.returnKey, delay: 40)]
        )
        var copy = r
        let applied = copy.applyEdits(MacroOptimizer.plan(for: r))
        XCTAssertEqual(applied, 4)
        XCTAssertTrue(RecordingValidator.errors(in: RecordingValidator.validate(copy)).isEmpty)
        XCTAssertEqual(copy.actions.map { $0.kind }, [.click, .text, .key])
        XCTAssertEqual(copy.actions[1].text, "Hello")
        XCTAssertGreaterThanOrEqual(copy.actions[1].delay, MacroOptimizer.settleDelay)
        XCTAssertEqual(copy.actions[2].delay, MacroAnalyzer.pauseCap)
    }

    func testDeletedMovesPassTheirDelayToTheNextAction() {
        let path = moves(3)
        let click = MacroAction.click(x: 1, y: 1, delay: 0.5)
        var r = Recording(name: "d", actions: path + [click])
        r.applyEdits(MacroOptimizer.plan(for: r))
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.actions[0].delay, 0.5 + 0.03, accuracy: 1e-9)
    }

    func testEditsThatNoLongerMatchAreSkipped() {
        let a = MacroAction.text("a")
        var r = Recording(name: "x", actions: [a])
        let edit = MacroEdit(id: "x", source: .ai, operation: .delete([UUID()]), title: "", reason: "")
        XCTAssertEqual(r.applyEdits([edit]), 0)
        XCTAssertEqual(r.actions.count, 1)
    }

    func testMergeRefusesToExceedTheTextLimit() {
        let big = String(repeating: "a", count: RecordingValidator.maxText)
        let first = MacroAction.text(big)
        let second = MacroAction.text("b")
        var r = Recording(name: "big", actions: [first, second])
        let edit = MacroEdit(id: "m", source: .rule, operation: .mergeText([second.id]), title: "", reason: "")
        XCTAssertEqual(r.applyEdits([edit]), 0)
        XCTAssertEqual(r.actions.count, 2)
    }

    func testMinimumDelayNeverLowersADelay() {
        let a = MacroAction.text("a", delay: 2)
        var r = Recording(name: "d", actions: [a])
        let edit = MacroEdit(id: "d", source: .ai, operation: .setMinimumDelay([a.id], seconds: 0.5), title: "", reason: "")
        XCTAssertEqual(r.applyEdits([edit]), 0)
        XCTAssertEqual(r.actions[0].delay, 2)
    }

    func testBadCapParametersDoNothing() {
        var r = Recording(name: "c", actions: [.wait(50)])
        let edit = MacroEdit(id: "c", source: .rule, operation: .capPauses(above: 10, to: 20), title: "", reason: "")
        XCTAssertEqual(r.applyEdits([edit]), 0)
        XCTAssertEqual(r.actions[0].duration, 50)
    }

    // MARK: AI reply parsing

    private func sample() -> Recording {
        return Recording(name: "ai", actions: [
            .key(KeyCodes.ansiK, modifiers: [.command]),   // 1
            .text("general"),                              // 2
            .move(x: 1, y: 1),                             // 3
            .key(KeyCodes.returnKey),                      // 4
            .key(KeyCodes.returnKey),                      // 5
            .click(x: 9, y: 9),                            // 6
            .text("hi")                                    // 7
        ])
    }

    func testParsesTheTwoCommands() {
        let r = sample()
        let edits = AIEditParser.parse("DELETE 5 | Repeated Return\nPAUSE 2 0.5 | Let the menu open", recording: r)
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0].operation, .delete([r.actions[4].id]))
        XCTAssertEqual(edits[1].operation, .setMinimumDelay([r.actions[1].id], seconds: 0.5))
        XCTAssertEqual(edits[0].reason, "Repeated Return")
        XCTAssertTrue(edits.allSatisfy { $0.source == .ai })
    }

    func testToleratesBulletsNumberingMarkdownAndUnits() {
        let r = sample()
        let reply = """
        Here are my suggestions:
        - **DELETE** #5 | duplicate
        2. pause step 2 1.5s | slow
        `WAIT 7 0.25 sec | focus`
        """
        let edits = AIEditParser.parse(reply, recording: r)
        XCTAssertEqual(edits.count, 3)
    }

    func testIgnoresJunkNoneAndUnknownVerbs() {
        let r = sample()
        XCTAssertTrue(AIEditParser.parse("NONE", recording: r).isEmpty)
        XCTAssertTrue(AIEditParser.parse("", recording: r).isEmpty)
        XCTAssertTrue(AIEditParser.parse("TYPE 2 rm -rf /", recording: r).isEmpty)
        XCTAssertTrue(AIEditParser.parse("DELETE banana", recording: r).isEmpty)
        XCTAssertTrue(AIEditParser.parse("DELETE", recording: r).isEmpty)
        XCTAssertTrue(AIEditParser.parse("PAUSE 2", recording: r).isEmpty)
    }

    func testRejectsStepsThatDoNotExistOrAreMouseMoves() {
        let r = sample()
        XCTAssertTrue(AIEditParser.parse("DELETE 0\nDELETE 8\nDELETE -1\nDELETE 3", recording: r).isEmpty)
    }

    func testClampsAndRejectsBadPauseValues() {
        let r = sample()
        let edits = AIEditParser.parse("PAUSE 2 9999\nPAUSE 4 -3\nPAUSE 5 nan\nPAUSE 6 0", recording: r)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].operation, .setMinimumDelay([r.actions[1].id], seconds: AIEditParser.maxPause))
    }

    func testDuplicateLinesAreCollapsed() {
        let r = sample()
        XCTAssertEqual(AIEditParser.parse("DELETE 5\nDELETE 5\nDELETE 5", recording: r).count, 1)
    }

    func testTooManyDeletionsAreRefused() {
        // 6 editable steps -> at most 3 deletions.
        let r = sample()
        let edits = AIEditParser.parse("DELETE 1\nDELETE 2\nDELETE 4\nDELETE 5\nDELETE 6\nDELETE 7", recording: r)
        XCTAssertEqual(edits.count, 3)
    }

    func testLongReasonsAreTruncated() {
        let r = sample()
        let reason = String(repeating: "x", count: 500)
        let edits = AIEditParser.parse("DELETE 5 | \(reason)", recording: r)
        XCTAssertLessThanOrEqual(edits[0].reason.count, 160)
    }

    func testEditCountIsCapped() {
        var actions: [MacroAction] = []
        for _ in 0..<60 { actions.append(.text("x")) }
        let r = Recording(name: "many", actions: actions)
        let reply = (1...40).map { "PAUSE \($0) 1" }.joined(separator: "\n")
        XCTAssertEqual(AIEditParser.parse(reply, recording: r).count, AIEditParser.maxEdits)
    }

    // MARK: Numbered summary

    func testNumberedSummaryUsesRealActionPositions() {
        let text = MacroSummary.numberedText(for: sample())
        XCTAssertTrue(text.contains("#1 "))
        XCTAssertTrue(text.contains("#4 "))
        XCTAssertTrue(text.contains("#7 "))
        XCTAssertFalse(text.contains("#3 "), "mouse movements are not numbered")
        XCTAssertTrue(text.contains("mouse movements: 1"))
    }

    func testNumberedSummaryKeepsNumbersWhenTrimmed() {
        let actions = (0..<200).map { _ in MacroAction.text("x") }
        let text = MacroSummary.numberedText(for: Recording(name: "long", actions: actions), maxLines: 12)
        XCTAssertTrue(text.contains("#200 "))
        XCTAssertTrue(text.contains("lines omitted"))
        XCTAssertFalse(text.contains("#100 "))
    }

    // MARK: Drafting steps from a description

    func testDraftsQuickSwitcherSteps() {
        let draft = AIMacroDrafter.parse("""
        KEY cmd+k
        TYPE general
        KEY return
        TYPE Hello everyone!
        KEY return
        """)
        XCTAssertEqual(draft.actions.map { $0.kind }, [.key, .text, .key, .text, .key])
        XCTAssertEqual(draft.actions[0].keyCode, KeyCodes.ansiK)
        XCTAssertEqual(draft.actions[0].modifiers, KeyModifiers.command)
        XCTAssertEqual(draft.actions[3].text, "Hello everyone!")
        XCTAssertEqual(draft.actions[0].delay, 0)
        XCTAssertEqual(draft.actions[1].delay, AIMacroDrafter.afterShortcutDelay)
        XCTAssertEqual(draft.actions[2].delay, AIMacroDrafter.beforeReturnDelay)
        XCTAssertEqual(draft.skippedLines, 0)
        XCTAssertFalse(draft.unsupported)
    }

    func testDraftedActionsPassValidation() {
        let draft = AIMacroDrafter.parse("KEY cmd+k\nTYPE hi\nWAIT 99\nKEY shift+return")
        let r = Recording(name: "d", actions: draft.actions)
        XCTAssertTrue(RecordingValidator.errors(in: RecordingValidator.validate(r)).isEmpty)
        XCTAssertEqual(draft.actions[2].duration, AIMacroDrafter.maxWait)
    }

    func testDraftIgnoresProseFencesAndBulletsButCountsBrokenSteps() {
        let draft = AIMacroDrafter.parse("""
        Sure! Here you go:
        ```
        - KEY ctrl+opt+tab
        - **TYPE** "quoted text"
        KEY florp
        WAIT soon
        ```
        """)
        XCTAssertEqual(draft.actions.count, 2)
        XCTAssertEqual(draft.actions[0].modifiers, KeyModifiers([.control, .option]))
        XCTAssertEqual(draft.actions[1].text, "quoted text")
        XCTAssertEqual(draft.skippedLines, 2)
    }

    func testDraftUnsupportedAndEmpty() {
        XCTAssertTrue(AIMacroDrafter.parse("UNSUPPORTED").unsupported)
        XCTAssertTrue(AIMacroDrafter.parse("").actions.isEmpty)
        XCTAssertFalse(AIMacroDrafter.parse("").unsupported)
    }

    func testDraftRejectsUnknownModifiersAndOversizedText() {
        XCTAssertTrue(AIMacroDrafter.parse("KEY hyper+k").actions.isEmpty)
        let long = String(repeating: "a", count: AIMacroDrafter.maxTextLength + 1)
        XCTAssertTrue(AIMacroDrafter.parse("TYPE \(long)").actions.isEmpty)
    }

    func testDraftIsCapped() {
        let reply = (0..<100).map { _ in "KEY tab" }.joined(separator: "\n")
        XCTAssertEqual(AIMacroDrafter.parse(reply).actions.count, AIMacroDrafter.maxActions)
    }

    func testDraftKeepsTextExactlyIncludingInnerSpacesAndCase() {
        let draft = AIMacroDrafter.parse("type   Hello   World ")
        XCTAssertEqual(draft.actions.first?.text, "Hello   World")
    }
}
