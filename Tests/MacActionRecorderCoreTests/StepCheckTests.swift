import XCTest
@testable import MacActionRecorderCore

/// Each recorded step knows which app received it (and, for clicks, which window), and playback
/// checks every step against that, so a macro that clicks into another app is not stopped by
/// mistake and one whose click would land on another app is.
final class StepCheckTests: XCTestCase {
    private let discord = "com.hnc.Discord"
    private let finder = "com.apple.finder"
    private let window = WindowFrame(x: 100, y: 100, width: 800, height: 600)

    private func down(_ t: Double, app: String?, window: WindowFrame?) -> RawEvent {
        RawEvent(time: t, x: 200, y: 200, kind: .mouseDown(.left, clickCount: 1), app: app, window: window)
    }

    private func up(_ t: Double, app: String?, window: WindowFrame?) -> RawEvent {
        RawEvent(time: t, x: 200, y: 200, kind: .mouseUp(.left, clickCount: 1), app: app, window: window)
    }

    private func key(_ t: Double, _ chars: String, app: String?) -> RawEvent {
        RawEvent(time: t, kind: .keyDown(keyCode: 4, modifiers: [], characters: chars, isRepeat: false), app: app)
    }

    // MARK: Recording

    func testStepsKeepTheirAppAndClicksTheirWindow() {
        let events = [
            down(0, app: discord, window: window), up(0.05, app: discord, window: window),
            key(0.5, "h", app: discord), key(0.6, "i", app: discord),
            RawEvent(time: 0.9, kind: .keyDown(keyCode: 36, modifiers: [], characters: "\r", isRepeat: false), app: discord)
        ]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertEqual(actions.map { $0.kind }, [.click, .text, .key])
        XCTAssertEqual(actions.map { $0.app }, [discord, discord, discord])
        XCTAssertEqual(actions[0].window, window)
        XCTAssertNil(actions[1].window, "typing has no window")
        XCTAssertTrue(Recording(name: "r", actions: actions).hasStepInfo)
    }

    func testTypingIntoAnotherAppStartsANewTextStep() {
        let events = [key(0, "a", app: discord), key(0.1, "b", app: finder)]
        let actions = RecordingBuilder.build(events: events, options: RecordingOptions())
        XCTAssertEqual(actions.map { $0.text }, ["a", "b"])
        XCTAssertEqual(actions.map { $0.app }, [discord, finder])
    }

    func testOldRecordingsHaveNoStepInfo() {
        XCTAssertFalse(Recording(name: "old", actions: [.click(x: 1, y: 1), .text("hi")]).hasStepInfo)
    }

    func testStepInfoSurvivesTheCodecAndOldFilesStillLoad() throws {
        var click = MacroAction.click(x: 1, y: 1)
        click.app = discord
        click.window = window
        let back = try RecordingCodec.decode(RecordingCodec.encode(Recording(name: "c", actions: [click])))
        XCTAssertEqual(back.actions.first?.app, discord)
        XCTAssertEqual(back.actions.first?.window, window)

        // A window that makes no sense (zero size) is dropped when loading; the app is kept.
        let data = try RecordingCodec.encode(Recording(name: "c", actions: [click]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var actions = try XCTUnwrap(json["actions"] as? [[String: Any]])
        actions[0]["window"] = ["x": 0, "y": 0, "width": 0, "height": 0]
        json["actions"] = actions
        let edited = try RecordingCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(edited.actions.first?.app, discord)
        XCTAssertNil(edited.actions.first?.window)
    }

    // MARK: Step checks

    private func check(
        _ action: MacroAction,
        _ snapshot: StepSnapshot,
        options: SafetyOptions = SafetyOptions(),
        verify: Bool = true,
        follow: Bool = true
    ) -> String? {
        return SafetyWatchdog.evaluate(
            step: action, options: options, verifyForeground: verify, followWindow: follow,
            recordedScreen: ScreenSize(width: 1512, height: 982), snapshot: snapshot,
            names: { $0 == "com.hnc.Discord" ? "Discord" : $0 }
        )
    }

    private var click: MacroAction {
        var action = MacroAction.click(x: 200, y: 200)
        action.app = discord
        action.window = window
        return action
    }

    func testAClickIntoAnAppThatIsNotInFrontYetIsFine() {
        // Recorded: Finder in front, the click went to Discord's window. Playing it back with
        // Finder in front must not stop: the click itself brings Discord forward.
        let snapshot = StepSnapshot(frontmost: finder, appRunning: true, appWindows: [window], regularAppAtPoint: discord)
        XCTAssertNil(check(click, snapshot))
    }

    func testKeysGoingToAnotherAppStop() {
        var text = MacroAction.text("hi")
        text.app = discord
        let reason = check(text, StepSnapshot(frontmost: finder, appRunning: true))
        XCTAssertTrue(reason?.hasPrefix(SafetyWatchdog.messagePrefix) ?? false)
        XCTAssertTrue(reason?.contains("Discord") ?? false)
        XCTAssertNil(check(text, StepSnapshot(frontmost: discord, appRunning: true)))
        XCTAssertNil(check(text, StepSnapshot(frontmost: finder, appRunning: true), verify: false))
    }

    func testAClickCoveredByAnotherAppStops() {
        let snapshot = StepSnapshot(frontmost: finder, appRunning: true, appWindows: [window], regularAppAtPoint: finder)
        XCTAssertTrue(check(click, snapshot)?.contains("covered") ?? false)
    }

    func testABackgroundHelperOnTopNeverStops() {
        // regularAppAtPoint is nil when the window on top belongs to a helper or menu bar tool.
        let snapshot = StepSnapshot(frontmost: discord, appRunning: true, appWindows: [window], regularAppAtPoint: nil)
        XCTAssertNil(check(click, snapshot))
    }

    func testAnotherWindowOfTheSameAppInFrontIsFine() {
        // A dialog of the same app opened in front: the recorded window is still there.
        let dialog = WindowFrame(x: 300, y: 300, width: 400, height: 200)
        let snapshot = StepSnapshot(frontmost: discord, appRunning: true, appWindows: [dialog, window], regularAppAtPoint: discord)
        XCTAssertNil(check(click, snapshot))
    }

    func testTheRecordedWindowMissingOrResizedStops() {
        let other = WindowFrame(x: 100, y: 100, width: 1000, height: 700)
        XCTAssertTrue(check(click, StepSnapshot(appRunning: true, appWindows: [other]))?.contains("not on screen at that size") ?? false)
        XCTAssertTrue(check(click, StepSnapshot(appRunning: true, appWindows: []))?.contains("no window") ?? false)
        var off = SafetyOptions()
        off.stopIfWindowChanged = false
        XCTAssertNil(check(click, StepSnapshot(appRunning: true, appWindows: [other]), options: off))
    }

    func testAMovedWindowStopsOnlyWhenNotFollowing() {
        let moved = WindowFrame(x: 150, y: 120, width: 800, height: 600)
        let snapshot = StepSnapshot(appRunning: true, appWindows: [moved])
        XCTAssertNil(check(click, snapshot, follow: true))
        XCTAssertTrue(check(click, snapshot, follow: false)?.contains("moved") ?? false)
    }

    func testTheMatchingWindowIsTheNearestOfTheSameSize() {
        let far = WindowFrame(x: 900, y: 500, width: 800, height: 600)
        let near = WindowFrame(x: 110, y: 100, width: 800, height: 600)
        XCTAssertEqual(SafetyWatchdog.matchingWindow(window, in: [far, near]), near)
        XCTAssertNil(SafetyWatchdog.matchingWindow(window, in: [WindowFrame(x: 0, y: 0, width: 10, height: 10)]))
    }

    func testAQuitAppStops() {
        XCTAssertTrue(check(click, StepSnapshot(appRunning: false))?.contains("not running") ?? false)
    }

    func testUnreadableValuesNeverStop() {
        XCTAssertNil(check(click, StepSnapshot()))
    }

    func testReleaseOfADragIsNotWindowChecked() {
        var release = MacroAction.mouseUp(x: 200, y: 200)
        release.app = discord
        release.window = WindowFrame(x: 190, y: 190, width: 40, height: 40) // the drag picture
        let snapshot = StepSnapshot(appRunning: true, appWindows: [window], regularAppAtPoint: finder)
        XCTAssertNil(check(release, snapshot))
    }

    func testStepsWithoutAnAppAreNotChecked() {
        XCTAssertNil(check(.click(x: 1, y: 1), StepSnapshot(appRunning: false)))
    }
}
