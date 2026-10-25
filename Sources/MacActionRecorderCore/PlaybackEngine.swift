import Foundation

// MARK: - Public types

/// Performs a single action on the system. The macOS app implements this with CGEvent;
/// tests implement it with a recorder.
public protocol ActionPerformer: AnyObject {
    /// Called on the engine's playback thread. Throw to abort playback with an error.
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
    private let lock = NSLock()
    private var currentRun: Run?
    private var currentState: PlaybackState = .idle
    private var handler: ((PlaybackEvent) -> Void)?
    private var lastStart: (recording: Recording, config: PlaybackConfig)?

    public init(performer: ActionPerformer, frontmostBundleID: @escaping () -> String? = { nil }) {
        self.performer = performer
        self.frontmostBundleID = frontmostBundleID
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
        thread.qualityOfService = .userInitiated
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

            // `due` is the ideal wall-clock time of the next movement sample. Scheduling
            // movement against it (instead of sleeping fixed gaps) stops sleep overshoot from
            // accumulating, so fast mouse paths stay on speed.
            var due = Run.now()

            for (offset, action) in actions.enumerated() {
                let index = firstIndex + offset
                let isMovement = (action.kind == .move || action.kind == .drag)

                if action.kind == .wait {
                    emit(run, .actionStarted(index: index))
                    if !run.sleep(PlaybackTiming.scaledDelay(for: action, config: config)) { return }
                    due = Run.now()
                } else {
                    let delay = PlaybackTiming.scaledDelay(for: action, config: config)
                    if isMovement {
                        due += delay
                        let remaining = due - Run.now()
                        if remaining > 0 {
                            if !run.sleep(remaining) { return }
                        } else {
                            if !run.sleep(0) { return }
                            if remaining < -0.1 { due = Run.now() }
                        }
                        if run.takePausedTime() > 0 { due = Run.now() }
                    } else {
                        if !run.sleep(delay) { return }
                        due = Run.now()
                    }

                    if let required = config.requiredBundleID,
                       PlaybackTiming.requiresForeground(action.kind),
                       frontmostBundleID() != required {
                        fail(run, foregroundMessage(config))
                        return
                    }

                    emit(run, .actionStarted(index: index))

                    do {
                        if action.kind == .text {
                            if !(try typeOut(text: action.text ?? "", run: run, config: config)) { return }
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

                    if !isMovement { due = Run.now() }
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

    /// Types text one character at a time with interruptible gaps.
    /// Returns false if playback was cancelled part-way.
    private func typeOut(text: String, run: Run, config: PlaybackConfig) throws -> Bool {
        let characters = Array(text)
        let gap = PlaybackTiming.typingDelay(config: config)
        for (offset, character) in characters.enumerated() {
            if !run.sleep(0) { return false }
            try performer.perform(MacroAction.text(String(character)))
            if offset < characters.count - 1 {
                if !run.sleep(gap) { return false }
            }
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
