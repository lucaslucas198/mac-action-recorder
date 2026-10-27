import Foundation

// MARK: - Public types

/// Performs a single action on the system. The macOS app implements this with CGEvent;
/// tests implement it with a recorder.
public protocol ActionPerformer: AnyObject {
    /// Called on the engine's playback thread. Throw to abort playback with an error.
    ///
    /// For a `click`, `duration` is either nil (use the performer's own click timing) or the time,
    /// already scaled for the playback speed, from the first press to the last release. Long
    /// single-click holds arrive as a separate `mouseDown` and `mouseUp` instead, so a stop can
    /// interrupt them.
    func perform(_ action: MacroAction) throws
    /// Called once when a run ends for any reason (finish, stop, failure) so the performer
    /// can release anything still held, such as a pressed mouse button.
    func cleanup()
}

public struct PlaybackError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        return message
    }
}

public enum PlaybackState: Equatable {
    case idle
    /// Counting down; the payload is the seconds remaining.
    case countdown(Int)
    case playing
    case paused
    case finished
    case stopped
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .countdown, .playing, .paused: return true
        default: return false
        }
    }
}

public struct PlaybackProgress: Equatable {
    public var iteration: Int
    /// nil when looping until stopped.
    public var totalIterations: Int?
    /// Index in the recording of the action that just completed.
    public var actionIndex: Int
    /// Number of actions in the section being played.
    public var actionCount: Int
    /// 0...1 across all repetitions, or nil when looping until stopped.
    public var fraction: Double?
}

public enum PlaybackEvent: Equatable {
    case stateChanged(PlaybackState)
    case iterationStarted(iteration: Int, total: Int?)
    case actionStarted(index: Int)
    case progress(PlaybackProgress)
}

// MARK: - Engine

/// Runs a recording on a background thread.
///
/// Design notes:
/// - Every wait goes through `Run.sleep`, which wakes immediately on stop/pause, so an
///   emergency stop never has to wait for a long delay to elapse.
/// - `stop()` marks the run cancelled before anything else; the thread re-checks that flag
///   immediately before every action, so no queued action fires after a stop.
/// - Events from a run that is no longer current are dropped.
/// - Callbacks are invoked on the playback thread (or the caller's thread for stop/pause/resume)
///   and never while an internal lock is held. Marshal to the main thread in UI code.
public final class PlaybackEngine {
    private let performer: ActionPerformer
    private let frontmostBundleID: () -> String?
    private let safetyCheck: (ActionKind?) -> String?
    private let lock = NSLock()
    private var currentRun: Run?
    private var currentState: PlaybackState = .idle
    private var handler: ((PlaybackEvent) -> Void)?
    private var lastStart: (recording: Recording, config: PlaybackConfig)?

    /// - Parameter safetyCheck: called on the playback thread just before each action that sends
    ///   input (and once at the start of every repetition, with `nil`). Returning text stops the
    ///   run with that text as the failure message. It must only return a reason when the caller
    ///   is certain that continuing would be wrong.
    public init(
        performer: ActionPerformer,
        frontmostBundleID: @escaping () -> String? = { nil },
        safetyCheck: @escaping (ActionKind?) -> String? = { _ in nil }
    ) {
        self.performer = performer
        self.frontmostBundleID = frontmostBundleID
        self.safetyCheck = safetyCheck
    }

    public var onEvent: ((PlaybackEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
        set {
            lock.lock()
            handler = newValue
            lock.unlock()
        }
    }

    public var state: PlaybackState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// Starts playback. Any run already in progress is cancelled first.
    /// Throws if the recording fails validation or the selected range is empty.
    public func start(recording: Recording, config: PlaybackConfig) throws {
        let errors = RecordingValidator.errors(in: RecordingValidator.validate(recording))
        if let first = errors.first {
            throw PlaybackError("The recording is invalid. \(first.description)")
        }

        let all = recording.actions
        guard !all.isEmpty else {
            throw PlaybackError("The recording has no actions.")
        }

        var lower = 0
        var upper = all.count
        if let range = config.range {
            lower = max(0, range.lowerBound)
            upper = min(all.count, range.upperBound)
        }
        guard lower < upper else {
            throw PlaybackError("The selected section is empty.")
        }

        var effective = config
        effective.speed = PlaybackTiming.clampSpeed(config.speed)
        effective.repeatCount = max(1, config.repeatCount)
        effective.loopDelay = max(0, config.loopDelay.isFinite ? config.loopDelay : 0)
        effective.countdown = max(0, config.countdown)

        let slice = Array(all[lower..<upper])
        effective.prefixCount = max(0, min(config.prefixCount, slice.count))
        let run = Run()
        let initialState: PlaybackState = effective.countdown > 0 ? .countdown(effective.countdown) : .playing

        lock.lock()
        let previous = currentRun
        currentRun = run
        currentState = initialState
        lastStart = (recording, config)
        let callback = handler
        lock.unlock()

        previous?.cancel()
        callback?(.stateChanged(initialState))

        let thread = Thread { [weak self] in
            self?.execute(run: run, actions: slice, firstIndex: lower, config: effective)
        }
        thread.name = "MacActionRecorder.Playback"
        // The highest priority keeps macOS from batching this thread's timers, which would make
        // every wait a little late.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Restarts the last started playback from the beginning.
    public func restart() throws {
        lock.lock()
        let last = lastStart
        lock.unlock()
        guard let last = last else {
            throw PlaybackError("There is nothing to restart.")
        }
        try start(recording: last.recording, config: last.config)
    }

    public func pause() {
        lock.lock()
        guard let run = currentRun, currentState.isActive, currentState != .paused else {
            lock.unlock()
            return
        }
        currentState = .paused
        let callback = handler
        lock.unlock()

        run.setPaused(true)
        callback?(.stateChanged(.paused))
    }

    public func resume() {
        lock.lock()
        guard let run = currentRun, currentState == .paused else {
            lock.unlock()
            return
        }
        currentState = .playing
        let callback = handler
        lock.unlock()

        run.setPaused(false)
        callback?(.stateChanged(.playing))
    }

    /// Stops immediately. Safe to call from any thread, including from inside the performer.
    public func stop() {
        lock.lock()
        guard let run = currentRun else {
            lock.unlock()
            return
        }
        currentRun = nil
        currentState = .stopped
        let callback = handler
        lock.unlock()

        run.cancel()
        callback?(.stateChanged(.stopped))
    }

    // MARK: Run loop

    private func execute(run: Run, actions: [MacroAction], firstIndex: Int, config: PlaybackConfig) {
        defer { performer.cleanup() }

        // Countdown before the first action.
        if config.countdown > 0 {
            var remaining = config.countdown
            while remaining > 0 {
                if remaining < config.countdown {
                    transition(run, to: .countdown(remaining))
                }
                if !run.sleep(1.0) { return }
                remaining -= 1
            }
            transition(run, to: .playing)
        }

        let total = PlaybackTiming.totalIterations(config: config)
        let estimate = PlaybackTiming.estimatedDuration(of: actions, config: config)
        // Guard against a zero-length recording spinning the CPU when looping.
        let loopFloor: Double = ((total ?? 2) > 1 && estimate < 0.01) ? 0.05 : 0
        var iteration = 1

        while true {
            emit(run, .iterationStarted(iteration: iteration, total: total))

            if let required = config.requiredBundleID, frontmostBundleID() != required {
                fail(run, foregroundMessage(config))
                return
            }
            if let reason = safetyCheck(nil) {
                fail(run, reason)
                return
            }

            // `due` is when the next action should start on the recorded timeline (divided by
            // the speed). Every action is scheduled against it instead of sleeping a fixed gap,
            // so waking up late, or an action that took a little longer, is made up in the next
            // gap instead of pushing everything after it later. A pause moves the timeline on by
            // the paused time. If playback falls far behind (a busy Mac), the timeline restarts
            // from now rather than rushing through the following steps.
            var due = Run.now()
            var lastEnd = due

            /// Sleeps until `target`. Time spent paused moves the timeline on; the amount is
            /// returned (nil if the run was cancelled).
            func sleep(until target: Double) -> Double? {
                if !run.sleep(max(0, target - Run.now())) { return nil }
                let paused = run.takePausedTime()
                due += paused
                return paused
            }

            /// Sleeps until `due`, but never less than `floor` after the previous action ended.
            func waitForDue(floor: Double) -> Bool {
                let target = PlaybackSchedule.waitTarget(due: due, lastEnd: lastEnd, floor: floor)
                guard sleep(until: target) != nil else { return false }
                due = PlaybackSchedule.resyncIfFarBehind(due: due, now: Run.now())
                return true
            }

            for (offset, action) in actions.enumerated() {
                // The first `prefixCount` actions (opening a channel, say) run only once.
                if iteration > 1 && offset < config.prefixCount { continue }
                let index = firstIndex + offset
                let isMovement = (action.kind == .move || action.kind == .drag)
                let delay = PlaybackTiming.scaledDelay(for: action, config: config)
                due += delay

                if action.kind == .wait {
                    emit(run, .actionStarted(index: index))
                    if !waitForDue(floor: 0) { return }
                    lastEnd = Run.now()
                } else {
                    // Clicks, keys and text never follow the previous step with no gap at all,
                    // even when catching up.
                    let floor = isMovement ? 0 : min(delay, PlaybackSchedule.minimumGap)
                    if PlaybackTiming.requiresForeground(action.kind) {
                        // Wake a moment early for the checks (they ask macOS which app is in front
                        // and where its window is), so the time they take does not make the step
                        // late; then wait out the rest.
                        var target = PlaybackSchedule.waitTarget(due: due, lastEnd: lastEnd, floor: floor)
                        guard let pausedEarly = sleep(until: target - PlaybackSchedule.checkLead) else { return }
                        target += pausedEarly

                        if let required = config.requiredBundleID, frontmostBundleID() != required {
                            fail(run, foregroundMessage(config))
                            return
                        }
                        if let reason = safetyCheck(action.kind) {
                            fail(run, reason)
                            return
                        }

                        guard sleep(until: target) != nil else { return }
                        due = PlaybackSchedule.resyncIfFarBehind(due: due, now: Run.now())
                    } else if !waitForDue(floor: floor) {
                        return
                    }

                    emit(run, .actionStarted(index: index))

                    var pausedWhileTyping = 0.0
                    do {
                        if action.kind == .text {
                            if !(try typeOut(action: action, run: run, config: config, plannedStart: due, paused: &pausedWhileTyping)) { return }
                        } else if action.kind == .click {
                            if !(try performClick(action, run: run, config: config)) { return }
                        } else {
                            // Last check before touching the system: a stop that arrived while
                            // we were asleep must not let this action through.
                            if !run.sleep(0) { return }
                            try performer.perform(action)
                        }
                    } catch {
                        fail(run, error.localizedDescription)
                        return
                    }

                    // The time this action was meant to take: the click's hold, the typing.
                    due += pausedWhileTyping + run.takePausedTime()
                    lastEnd = Run.now()
                    due = PlaybackSchedule.dueAfterAction(due: due, plannedSpan: PlaybackTiming.plannedSpan(of: action, config: config), end: lastEnd)
                }

                let completed = Double((iteration - 1) * actions.count + offset + 1)
                var fraction: Double?
                if let total = total {
                    fraction = completed / Double(total * actions.count)
                }
                emit(run, .progress(PlaybackProgress(
                    iteration: iteration,
                    totalIterations: total,
                    actionIndex: index,
                    actionCount: actions.count,
                    fraction: fraction
                )))
            }

            if let total = total, iteration >= total {
                break
            }
            iteration += 1

            let pause = max(config.loopDelay, loopFloor)
            if !run.sleep(pause) { return }
        }

        finish(run, with: .finished)
    }

    /// Single-click holds longer than this are played as press, interruptible wait, release.
    static let splitHoldAbove = 0.25

    /// Plays a click with the hold time it was recorded with (when known and switched on).
    /// Returns false if playback was cancelled part-way.
    private func performClick(_ action: MacroAction, run: Run, config: PlaybackConfig) throws -> Bool {
        var click = action
        guard let hold = PlaybackTiming.clickHold(for: action, config: config) else {
            click.duration = nil
            if !run.sleep(0) { return false }
            try performer.perform(click)
            return true
        }
        let count = max(1, min(3, action.clickCount ?? 1))
        if count == 1 && hold > PlaybackEngine.splitHoldAbove {
            let button = action.button ?? .left
            var press = MacroAction(kind: .mouseDown, x: action.x, y: action.y, button: button)
            press.modifiers = action.modifiers
            var release = MacroAction(kind: .mouseUp, x: action.x, y: action.y, button: button)
            release.modifiers = action.modifiers
            if !run.sleep(0) { return false }
            try performer.perform(press)
            // If this wait is cut short by Stop, the performer's cleanup releases the button.
            if !run.sleep(hold) { return false }
            try performer.perform(release)
            return true
        }
        click.duration = hold
        if !run.sleep(0) { return false }
        try performer.perform(click)
        return true
    }

    /// Types text one character at a time. Each character is scheduled from the text's planned
    /// start on the timeline, so a late start or a late wake-up is made up over the following
    /// characters (never faster than `minTypingCharDelay`) instead of adding up. Time spent paused
    /// is added to `paused`. Returns false if playback was cancelled part-way.
    private func typeOut(action: MacroAction, run: Run, config: PlaybackConfig, plannedStart: Double, paused: inout Double) throws -> Bool {
        let characters = Array(action.text ?? "")
        let gap = PlaybackTiming.typingDelay(for: action, config: config)
        let minimumGap = max(0, config.minTypingCharDelay)
        var start = plannedStart
        var last = Run.now()
        for (offset, character) in characters.enumerated() {
            if offset > 0 {
                var target = start + Double(offset) * gap
                if Run.now() - target > PlaybackSchedule.maxLag {
                    // Far behind: carry on from here at the normal pace instead of rushing.
                    start = Run.now() - Double(offset) * gap
                    target = Run.now()
                }
                target = max(target, last + minimumGap)
                if !run.sleep(max(0, target - Run.now())) { return false }
                let pausedNow = run.takePausedTime()
                start += pausedNow
                paused += pausedNow
            } else if !run.sleep(0) {
                return false
            }
            try performer.perform(MacroAction.text(String(character)))
            last = Run.now()
        }
        return true
    }

    private func foregroundMessage(_ config: PlaybackConfig) -> String {
        let name = config.requiredAppName ?? config.requiredBundleID ?? "the target app"
        return "Playback stopped because \(name) is not the frontmost app."
    }

    // MARK: State helpers

    private func emit(_ run: Run, _ event: PlaybackEvent) {
        lock.lock()
        let isCurrent = (currentRun === run)
        let callback = handler
        lock.unlock()
        if isCurrent {
            callback?(event)
        }
    }

    private func transition(_ run: Run, to state: PlaybackState) {
        lock.lock()
        let isCurrent = (currentRun === run)
        if isCurrent {
            currentState = state
        }
        let callback = handler
        lock.unlock()
        if isCurrent {
            callback?(.stateChanged(state))
        }
    }

    private func finish(_ run: Run, with state: PlaybackState) {
        lock.lock()
        guard currentRun === run else {
            lock.unlock()
            return
        }
        currentRun = nil
        currentState = state
        let callback = handler
        lock.unlock()
        callback?(.stateChanged(state))
    }

    private func fail(_ run: Run, _ message: String) {
        finish(run, with: .failed(message))
    }

    // MARK: Run

    /// Cancellation / pause state for one playback thread, plus an interruptible sleep.
    private final class Run {
        private let condition = NSCondition()
        private var paused = false
        private var cancelled = false
        private var pausedSince: Double?
        private var pausedTotal = 0.0

        static func now() -> Double {
            return ProcessInfo.processInfo.systemUptime
        }

        func cancel() {
            condition.lock()
            cancelled = true
            paused = false
            condition.broadcast()
            condition.unlock()
        }

        func setPaused(_ value: Bool) {
            condition.lock()
            defer { condition.unlock() }
            if cancelled { return }
            if value && !paused {
                paused = true
                pausedSince = Run.now()
            } else if !value && paused {
                paused = false
                if let since = pausedSince {
                    pausedTotal += Run.now() - since
                }
                pausedSince = nil
            }
            condition.broadcast()
        }

        /// Time spent paused since the last call.
        func takePausedTime() -> Double {
            condition.lock()
            defer { condition.unlock() }
            let value = pausedTotal
            pausedTotal = 0
            return value
        }

        /// Sleeps for `seconds` of un-paused time. Returns false if the run was cancelled.
        /// With `seconds <= 0` it is a pure checkpoint: it blocks while paused and reports
        /// cancellation, which is how the engine guards every action.
        func sleep(_ seconds: Double) -> Bool {
            var remaining = seconds < 0.0005 ? 0.0 : seconds
            condition.lock()
            defer { condition.unlock() }
            while true {
                if cancelled { return false }
                if paused {
                    condition.wait()
                    continue
                }
                if remaining <= 0 { return true }
                let started = Run.now()
                _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
                remaining -= Run.now() - started
            }
        }
    }
}
