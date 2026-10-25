import XCTest
@testable import MacActionRecorderCore

final class PlaybackTimingTests: XCTestCase {
    private func config(speed: Double) -> PlaybackConfig {
        var c = PlaybackConfig()
        c.speed = speed
        return c
    }

    // MARK: Speed clamping and presets

    func testClampSpeed() {
        XCTAssertEqual(PlaybackTiming.clampSpeed(2), 2)
        XCTAssertEqual(PlaybackTiming.clampSpeed(0), 1)
        XCTAssertEqual(PlaybackTiming.clampSpeed(-3), 1)
        XCTAssertEqual(PlaybackTiming.clampSpeed(.nan), 1)
        XCTAssertEqual(PlaybackTiming.clampSpeed(0.01), PlaybackTiming.minSpeed)
        XCTAssertEqual(PlaybackTiming.clampSpeed(1000), PlaybackTiming.maxSpeed)
    }

    func testPresetsMatchTheRequestedSet() {
        XCTAssertEqual(SpeedPreset.all.map { $0.value }, [0.25, 0.5, 1, 1.5, 2, 5])
        XCTAssertEqual(SpeedPreset.describe(2), "2× — Double speed")
        XCTAssertEqual(SpeedPreset.describe(0.25), "0.25× — Very slow")
        XCTAssertEqual(SpeedPreset.describe(3.5), "3.5× (custom)")
    }

    func testFormatSpeed() {
        XCTAssertEqual(PlaybackTiming.formatSpeed(1.5), "1.5×")
        XCTAssertEqual(PlaybackTiming.formatSpeed(2), "2×")
    }

    // MARK: Delay scaling

    func testRecordedDelaysScaleInverselyWithSpeed() {
        let action = MacroAction.click(x: 1, y: 1, delay: 1.0)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 0.25)), 4.0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 0.5)), 2.0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 1)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 1.5)), 1.0 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 2)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 5)), 0.2, accuracy: 1e-9)
    }

    func testMovementScalesWithoutAMinimumFloor() {
        let action = MacroAction.move(x: 1, y: 1, delay: 0.01)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 5)), 0.002, accuracy: 1e-9)
    }

    func testMinimumDelayProtectsFastClicksButNeverExceedsTheOriginal() {
        var c = config(speed: 5)
        c.minActionDelay = 0.02

        // 0.04 / 5 = 0.008, below the floor -> raised to the floor (0.02).
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: .click(x: 1, y: 1, delay: 0.04), config: c), 0.02, accuracy: 1e-9)

        // A recorded gap already shorter than the floor is kept, not stretched.
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: .click(x: 1, y: 1, delay: 0.01), config: c), 0.01, accuracy: 1e-9)

        // A zero delay stays zero.
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: .click(x: 1, y: 1, delay: 0), config: c), 0, accuracy: 1e-9)
    }

    func testMinimumDelayDoesNotApplyAtOrBelowOriginalSpeed() {
        var c = config(speed: 1)
        c.minActionDelay = 0.5
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: .click(x: 1, y: 1, delay: 0.01), config: c), 0.01, accuracy: 1e-9)
    }

    func testWaitContributesItsDurationAndScales() {
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: .wait(2.0), config: config(speed: 2)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: .wait(2.0, delay: 1.0), config: config(speed: 1)), 3.0, accuracy: 1e-9)
    }

    func testOutOfRangeSpeedIsClampedInsideScaling() {
        let action = MacroAction.click(x: 1, y: 1, delay: 1.0)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 0)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackTiming.scaledDelay(for: action, config: config(speed: 10_000)), 1.0 / PlaybackTiming.maxSpeed, accuracy: 1e-9)
    }

    func testTypingDelay() {
        var c = config(speed: 1)
        c.typingCharDelay = 0.012
        c.minTypingCharDelay = 0.004
        XCTAssertEqual(PlaybackTiming.typingDelay(config: c), 0.012, accuracy: 1e-9)

        c.speed = 0.25
        XCTAssertEqual(PlaybackTiming.typingDelay(config: c), 0.048, accuracy: 1e-9)

        c.speed = 5   // 0.0024 would be too fast -> floored
        XCTAssertEqual(PlaybackTiming.typingDelay(config: c), 0.004, accuracy: 1e-9)
    }

    // MARK: Totals and repeats

    func testEstimatedDuration() {
        let actions: [MacroAction] = [
            .click(x: 1, y: 1, delay: 1.0),
            .text("abc", delay: 0.5),
            .wait(1.0)
        ]
        var c = config(speed: 2)
        c.typingCharDelay = 0.012
        // click 0.5 + text delay 0.25 + 2 gaps * 0.006 + wait 0.5
        XCTAssertEqual(PlaybackTiming.estimatedDuration(of: actions, config: c), 1.262, accuracy: 1e-9)
    }

    func testIterationCounts() {
        var c = PlaybackConfig()
        XCTAssertEqual(PlaybackTiming.totalIterations(config: c), 1)

        c.repeatCount = 5
        XCTAssertEqual(PlaybackTiming.totalIterations(config: c), 5)

        c.repeatCount = 0
        XCTAssertEqual(PlaybackTiming.totalIterations(config: c), 1)

        c.repeatCount = -4
        XCTAssertEqual(PlaybackTiming.totalIterations(config: c), 1)

        c.repeatCount = 3
        c.infinite = true
        XCTAssertNil(PlaybackTiming.totalIterations(config: c))
    }

    func testEstimatedTotalIncludesRepeatsLoopDelaysAndCountdown() {
        let actions: [MacroAction] = [.wait(1.0)]
        var c = config(speed: 1)
        c.repeatCount = 3
        c.loopDelay = 2
        c.countdown = 3
        // 3 passes of 1s + 2 gaps of 2s + 3s countdown
        XCTAssertEqual(PlaybackTiming.estimatedTotal(of: actions, config: c) ?? -1, 10, accuracy: 1e-9)

        c.infinite = true
        XCTAssertNil(PlaybackTiming.estimatedTotal(of: actions, config: c))
    }

    func testOnlyMovementAndWaitsSkipTheForegroundCheck() {
        XCTAssertFalse(PlaybackTiming.requiresForeground(.move))
        XCTAssertFalse(PlaybackTiming.requiresForeground(.wait))
        for kind in [ActionKind.click, .key, .text, .scroll, .drag, .mouseDown, .mouseUp] {
            XCTAssertTrue(PlaybackTiming.requiresForeground(kind))
        }
    }
}
