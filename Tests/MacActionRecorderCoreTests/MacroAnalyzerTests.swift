import XCTest
@testable import MacActionRecorderCore

final class MacroAnalyzerTests: XCTestCase {
    private let screen = ScreenSize(width: 1512, height: 982)
    private let once = PlaybackDefaults(speed: 1, repeatCount: 1, loopDelay: 0)

    private func analyze(
        _ recording: Recording,
        playback: PlaybackDefaults? = nil,
        verify: Bool = false,
        screen current: ScreenSize? = nil
    ) -> [MacroFinding] {
        return MacroAnalyzer.analyze(
            recording: recording,
            playback: playback ?? once,
            verifyForeground: verify,
            currentScreen: current ?? screen
        )
    }

    private func ids(_ findings: [MacroFinding]) -> [String] {
        return findings.map { $0.id }
    }

    private let discord = TargetApp(bundleID: "com.example.app", name: "Example")

    func testEmptyRecordingHasNoFindings() {
        XCTAssertTrue(analyze(Recording(name: "empty")).isEmpty)
    }

    func testKeyboardOnlyMacroWithATargetAppIsClean() {
        let r = Recording(
            name: "kb",
            targetApp: discord,
            actions: [.key(KeyCodes.ansiK, modifiers: [.command]), .text("general"), .key(KeyCodes.returnKey)]
        )
        XCTAssertTrue(analyze(r, verify: true).isEmpty)
    }

    func testClicksAreFlaggedAsFragile() {
        let r = Recording(name: "c", targetApp: discord, actions: [.click(x: 10, y: 10)])
        let found = ids(analyze(r, verify: true))
        XCTAssertTrue(found.contains("click-based"))
        XCTAssertFalse(found.contains("foreground-off"))
    }

    func testForegroundCheckSuggestedWhenOffAndAppKnown() {
        let r = Recording(name: "c", targetApp: discord, actions: [.click(x: 10, y: 10)])
        let finding = analyze(r, verify: false).first { $0.id == "foreground-off" }
        XCTAssertEqual(finding?.fix, .enableForegroundCheck)
        XCTAssertEqual(finding?.severity, .warning)
    }

    func testMissingTargetAppIsInformational() {
        let r = Recording(name: "c", actions: [.text("hello")])
        let finding = analyze(r).first { $0.id == "no-target-app" }
        XCTAssertEqual(finding?.severity, .info)
        XCTAssertNil(finding?.fix)
    }

    func testManyMovesOfferRemovalOnlyAboveTheThresholds() {
        var actions = (0..<30).map { MacroAction.move(x: Double($0), y: 0) }
        actions.append(.click(x: 5, y: 5))
        let many = analyze(Recording(name: "m", targetApp: discord, actions: actions), verify: true)
        XCTAssertEqual(many.first { $0.id == "many-moves" }?.fix, .removeMouseMoves)

        let few = (0..<5).map { MacroAction.move(x: Double($0), y: 0) } + [.click(x: 5, y: 5)]
        XCTAssertFalse(ids(analyze(Recording(name: "f", targetApp: discord, actions: few), verify: true)).contains("many-moves"))

        // Many moves, but a small share of a large macro: not flagged.
        let mixed = (0..<20).map { MacroAction.move(x: Double($0), y: 0) }
            + (0..<30).map { MacroAction.key($0 % 10) }
        XCTAssertFalse(ids(analyze(Recording(name: "x", targetApp: discord, actions: mixed), verify: true)).contains("many-moves"))
    }

    func testLongPausesOfferACap() {
        let r = Recording(name: "p", targetApp: discord, actions: [.key(1, delay: 30), .wait(12)])
        let finding = analyze(r, verify: true).first { $0.id == "long-pauses" }
        XCTAssertEqual(finding?.fix, .capLongPauses(maxSeconds: MacroAnalyzer.pauseCap))
        XCTAssertTrue(finding?.title.hasPrefix("2 pause") ?? false)
    }

    func testRapidMessagingNeedsTextReturnAndFastRepeats() {
        let send = Recording(
            name: "s", targetApp: discord,
            actions: [.text("hi"), .key(KeyCodes.returnKey)]
        )
        let fast = PlaybackDefaults(speed: 1, repeatCount: 0, loopDelay: 0)
        XCTAssertEqual(analyze(send, playback: fast, verify: true).first { $0.id == "rapid-messages" }?.fix,
                       .setLoopDelay(seconds: MacroAnalyzer.suggestedLoopDelay))

        let slow = PlaybackDefaults(speed: 1, repeatCount: 0, loopDelay: 10)
        XCTAssertFalse(ids(analyze(send, playback: slow, verify: true)).contains("rapid-messages"))
        XCTAssertFalse(ids(analyze(send, playback: once, verify: true)).contains("rapid-messages"))

        let fewTimes = PlaybackDefaults(speed: 1, repeatCount: 4, loopDelay: 0)
        XCTAssertFalse(ids(analyze(send, playback: fewTimes, verify: true)).contains("rapid-messages"))

        let noReturn = Recording(name: "n", targetApp: discord, actions: [.text("hi")])
        XCTAssertFalse(ids(analyze(noReturn, playback: fast, verify: true)).contains("rapid-messages"))
    }

    func testShiftReturnDoesNotCountAsSending() {
        let r = Recording(
            name: "s", targetApp: discord,
            actions: [.text("hi"), .key(KeyCodes.returnKey, modifiers: [.shift])]
        )
        let fast = PlaybackDefaults(speed: 1, repeatCount: 0, loopDelay: 0)
        XCTAssertFalse(ids(analyze(r, playback: fast, verify: true)).contains("rapid-messages"))
    }

    func testScreenChangeIsFlaggedOnlyForClicks() {
        let clicky = Recording(
            name: "c", targetApp: discord,
            recordedScreen: ScreenSize(width: 1920, height: 1080),
            actions: [.click(x: 1, y: 1)]
        )
        XCTAssertTrue(ids(analyze(clicky, verify: true)).contains("screen-changed"))

        let typing = Recording(
            name: "t", targetApp: discord,
            recordedScreen: ScreenSize(width: 1920, height: 1080),
            actions: [.text("hello")]
        )
        XCTAssertFalse(ids(analyze(typing, verify: true)).contains("screen-changed"))

        let same = Recording(name: "s", targetApp: discord, recordedScreen: screen, actions: [.click(x: 1, y: 1)])
        XCTAssertFalse(ids(analyze(same, verify: true)).contains("screen-changed"))
    }

    func testSecretLookingTextIsFlagged() {
        XCTAssertTrue(MacroAnalyzer.looksLikeSecret("Hunter2!xyz"))
        XCTAssertTrue(MacroAnalyzer.looksLikeSecret("aB3$kLm9"))
        XCTAssertFalse(MacroAnalyzer.looksLikeSecret("general"))
        XCTAssertFalse(MacroAnalyzer.looksLikeSecret("Hello from Mac Action Recorder"))
        XCTAssertFalse(MacroAnalyzer.looksLikeSecret("short1!"))
        XCTAssertFalse(MacroAnalyzer.looksLikeSecret("https://example.com/path/123"))
        XCTAssertFalse(MacroAnalyzer.looksLikeSecret(String(repeating: "aB3$", count: 20)))

        let r = Recording(name: "p", targetApp: discord, actions: [.text("Hunter2!xyz")])
        XCTAssertEqual(analyze(r, verify: true).first?.id, "secret-text")
    }

    func testWarningsComeBeforeInfo() {
        var actions = (0..<30).map { MacroAction.move(x: Double($0), y: 0) }
        actions.append(.click(x: 5, y: 5))
        let r = Recording(name: "m", targetApp: discord, actions: actions)
        let found = analyze(r, verify: false)
        let severities = found.map { $0.severity }
        if let firstInfo = severities.firstIndex(of: .info) {
            XCTAssertFalse(severities[firstInfo...].contains(.warning))
        }
        XCTAssertEqual(found.first?.severity, .warning)
    }

    // MARK: Summary

    func testSummaryCollapsesMouseMovesAndNumbersSteps() {
        var actions: [MacroAction] = [.key(KeyCodes.ansiK, modifiers: [.command])]
        actions += (0..<50).map { MacroAction.move(x: Double($0), y: 0) }
        actions.append(.text("general", delay: 2))
        let text = MacroSummary.text(for: Recording(name: "Demo", targetApp: discord, actions: actions))
        XCTAssertTrue(text.contains("Macro: Demo"))
        XCTAssertTrue(text.contains("Recorded in: Example"))
        XCTAssertTrue(text.contains("Total actions: 52"))
        XCTAssertTrue(text.contains("Move the mouse (50 steps)"))
        XCTAssertTrue(text.contains("2. Move the mouse"))
        XCTAssertTrue(text.contains("after a 2.00 s pause"))
        XCTAssertFalse(text.contains("(10, 0)"), "individual moves must not be listed")
    }

    func testSummaryIsCappedForLongMacros() {
        let actions = (0..<500).map { MacroAction.key($0 % 100) }
        let text = MacroSummary.text(for: Recording(name: "Long", actions: actions), maxLines: 30)
        let numbered = text.split(separator: "\n").filter { line in
            guard let first = line.first else { return false }
            return first.isNumber
        }
        XCTAssertLessThanOrEqual(numbered.count, 31)
        XCTAssertTrue(text.contains("steps omitted"))
    }
}
