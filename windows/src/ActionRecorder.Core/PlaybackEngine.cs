using System.Diagnostics;

namespace ActionRecorder.Core;

/// <summary>Performs a single action on the system. The Windows app implements this with SendInput;
/// tests implement it with a recorder.</summary>
public interface IActionPerformer
{
    /// <summary>Called on the engine's playback thread once, before the first action of a run.</summary>
    void Begin() { }

    /// <summary>Called on the engine's playback thread. Throw to abort playback with an error.</summary>
    void Perform(MacroAction action);

    /// <summary>Called once when a run ends for any reason (finish, stop, failure) so the performer can
    /// release anything still held, such as a pressed mouse button.</summary>
    void Cleanup();
}

public sealed class PlaybackException : Exception
{
    public PlaybackException(string message) : base(message)
    {
    }
}

public enum PlaybackPhase
{
    Idle,
    Countdown,
    Playing,
    Paused,
    Finished,
    Stopped,
    Failed,
}

public readonly record struct PlaybackState(PlaybackPhase Phase, int Seconds = 0, string? Message = null)
{
    public static readonly PlaybackState Idle = new(PlaybackPhase.Idle);
    public static readonly PlaybackState Playing = new(PlaybackPhase.Playing);
    public static readonly PlaybackState Paused = new(PlaybackPhase.Paused);
    public static readonly PlaybackState Finished = new(PlaybackPhase.Finished);
    public static readonly PlaybackState Stopped = new(PlaybackPhase.Stopped);
    public static PlaybackState Countdown(int seconds) => new(PlaybackPhase.Countdown, seconds);
    public static PlaybackState Failed(string message) => new(PlaybackPhase.Failed, 0, message);

    public bool IsActive => Phase is PlaybackPhase.Countdown or PlaybackPhase.Playing or PlaybackPhase.Paused;
}

public sealed record PlaybackProgress(
    int Iteration,
    int? TotalIterations,
    int ActionIndex,
    int ActionCount,
    double? Fraction);

public enum PlaybackEventKind
{
    StateChanged,
    IterationStarted,
    ActionStarted,
    Progress,
}

public sealed record PlaybackEvent(
    PlaybackEventKind Kind,
    PlaybackState State = default,
    int Iteration = 0,
    int? Total = null,
    int Index = 0,
    PlaybackProgress? Progress = null);

/// <summary>
/// Runs a recording on a background thread.
/// Design notes:
/// - Every wait goes through <c>Run.Sleep</c>, which wakes immediately on stop/pause, so an emergency stop never
///   has to wait for a long delay to elapse.
/// - <see cref="Stop"/> marks the run cancelled before anything else; the thread re-checks that flag immediately
///   before every action, so no queued action fires after a stop.
/// - Events from a run that is no longer current are dropped.
/// - Callbacks are invoked on the playback thread (or the caller's thread for stop/pause/resume) and never while
///   an internal lock is held. Marshal to the UI thread in UI code.
/// </summary>
public sealed class PlaybackEngine
{
    private readonly IActionPerformer _performer;
    private readonly Func<string?> _foregroundProgram;
    private readonly object _lock = new();
    private Run? _currentRun;
    private PlaybackState _state = PlaybackState.Idle;
    private Action<PlaybackEvent>? _handler;
    private (Recording Recording, PlaybackConfig Config)? _lastStart;

    public PlaybackEngine(IActionPerformer performer, Func<string?>? foregroundProgram = null)
    {
        _performer = performer;
        _foregroundProgram = foregroundProgram ?? (() => null);
    }

    public Action<PlaybackEvent>? OnEvent
    {
        get { lock (_lock) return _handler; }
        set { lock (_lock) _handler = value; }
    }

    public PlaybackState State
    {
        get { lock (_lock) return _state; }
    }

    /// <summary>Starts playback. Any run already in progress is cancelled first.
    /// Throws if the recording fails validation or the selected range is empty.</summary>
    public void Start(Recording recording, PlaybackConfig config)
    {
        var errors = RecordingValidator.Errors(RecordingValidator.Validate(recording));
        if (errors.Count > 0)
        {
            throw new PlaybackException($"The recording is invalid. {errors[0]}");
        }

        var all = recording.Actions;
        if (all.Count == 0)
        {
            throw new PlaybackException("The recording has no actions.");
        }

        var lower = 0;
        var upper = all.Count;
        if (config.Range is { } range)
        {
            lower = Math.Max(0, range.Start);
            upper = Math.Min(all.Count, range.End);
        }
        if (lower >= upper)
        {
            throw new PlaybackException("The selected section is empty.");
        }

        var effective = new PlaybackConfig
        {
            Speed = PlaybackTiming.ClampSpeed(config.Speed),
            RepeatCount = Math.Max(1, config.RepeatCount),
            Infinite = config.Infinite,
            LoopDelay = double.IsFinite(config.LoopDelay) ? Math.Max(0, config.LoopDelay) : 0,
            Countdown = Math.Max(0, config.Countdown),
            MinActionDelay = config.MinActionDelay,
            TypingCharDelay = config.TypingCharDelay,
            MinTypingCharDelay = config.MinTypingCharDelay,
            RequiredBundleId = config.RequiredBundleId,
            RequiredAppName = config.RequiredAppName,
            Range = config.Range,
        };

        // A snapshot, so editing the recording while it plays cannot change the run.
        var slice = all.Skip(lower).Take(upper - lower).Select(a => a.Copy()).ToList();
        var run = new Run();
        var initial = effective.Countdown > 0 ? PlaybackState.Countdown(effective.Countdown) : PlaybackState.Playing;

        Run? previous;
        Action<PlaybackEvent>? callback;
        lock (_lock)
        {
            previous = _currentRun;
            _currentRun = run;
            _state = initial;
            _lastStart = (recording.Clone(), config);
            callback = _handler;
        }

        previous?.Cancel();
        callback?.Invoke(new PlaybackEvent(PlaybackEventKind.StateChanged, initial));

        var thread = new Thread(() => Execute(run, slice, lower, effective))
        {
            Name = "ActionRecorder.Playback",
            IsBackground = true,
            Priority = ThreadPriority.AboveNormal,
        };
        thread.Start();
    }

    /// <summary>Restarts the last started playback from the beginning.</summary>
    public void Restart()
    {
        (Recording Recording, PlaybackConfig Config)? last;
        lock (_lock) last = _lastStart;
        if (last is not { } value)
        {
            throw new PlaybackException("There is nothing to restart.");
        }
        Start(value.Recording, value.Config);
    }

    public void Pause()
    {
        Run run;
        Action<PlaybackEvent>? callback;
        lock (_lock)
        {
            if (_currentRun == null || !_state.IsActive || _state.Phase == PlaybackPhase.Paused) return;
            run = _currentRun;
            _state = PlaybackState.Paused;
            callback = _handler;
        }
        run.SetPaused(true);
        callback?.Invoke(new PlaybackEvent(PlaybackEventKind.StateChanged, PlaybackState.Paused));
    }

    public void Resume()
    {
        Run run;
        Action<PlaybackEvent>? callback;
        lock (_lock)
        {
            if (_currentRun == null || _state.Phase != PlaybackPhase.Paused) return;
            run = _currentRun;
            _state = PlaybackState.Playing;
            callback = _handler;
        }
        run.SetPaused(false);
        callback?.Invoke(new PlaybackEvent(PlaybackEventKind.StateChanged, PlaybackState.Playing));
    }

    /// <summary>Stops immediately. Safe to call from any thread, including from inside the performer.</summary>
    public void Stop()
    {
        Run run;
        Action<PlaybackEvent>? callback;
        lock (_lock)
        {
            if (_currentRun == null) return;
            run = _currentRun;
            _currentRun = null;
            _state = PlaybackState.Stopped;
            callback = _handler;
        }
        run.Cancel();
        callback?.Invoke(new PlaybackEvent(PlaybackEventKind.StateChanged, PlaybackState.Stopped));
    }

    // ------------------------------------------------------------------ run loop

    private void Execute(Run run, List<MacroAction> actions, int firstIndex, PlaybackConfig config)
    {
        try
        {
            try
            {
                _performer.Begin();
            }
            catch (Exception ex)
            {
                Fail(run, ex.Message);
                return;
            }

            // Countdown before the first action.
            if (config.Countdown > 0)
            {
                var remaining = config.Countdown;
                while (remaining > 0)
                {
                    if (remaining < config.Countdown)
                    {
                        Transition(run, PlaybackState.Countdown(remaining));
                    }
                    if (!run.Sleep(1.0)) return;
                    remaining--;
                }
                Transition(run, PlaybackState.Playing);
            }

            var total = PlaybackTiming.TotalIterations(config);
            var estimate = PlaybackTiming.EstimatedDuration(actions, config);
            // Guard against a zero-length recording spinning the CPU when looping.
            var loopFloor = ((total ?? 2) > 1 && estimate < 0.01) ? 0.05 : 0.0;
            var iteration = 1;

            while (true)
            {
                Emit(run, new PlaybackEvent(PlaybackEventKind.IterationStarted, Iteration: iteration, Total: total));

                if (config.RequiredBundleId is { } required && !ProgramMatches(required))
                {
                    Fail(run, ForegroundMessage(config));
                    return;
                }

                // "due" is the ideal time of the next movement sample. Scheduling movement against it (instead of
                // sleeping fixed gaps) stops sleep overshoot from accumulating, so fast mouse paths stay on speed.
                var due = Run.Now();

                for (var offset = 0; offset < actions.Count; offset++)
                {
                    var action = actions[offset];
                    var index = firstIndex + offset;
                    var isMovement = action.Kind == ActionKind.Move || action.Kind == ActionKind.Drag;

                    if (action.Kind == ActionKind.Wait)
                    {
                        Emit(run, new PlaybackEvent(PlaybackEventKind.ActionStarted, Index: index));
                        if (!run.Sleep(PlaybackTiming.ScaledDelay(action, config))) return;
                        due = Run.Now();
                    }
                    else
                    {
                        var delay = PlaybackTiming.ScaledDelay(action, config);
                        if (isMovement)
                        {
                            due += delay;
                            var remaining = due - Run.Now();
                            if (remaining > 0)
                            {
                                if (!run.Sleep(remaining)) return;
                            }
                            else
                            {
                                if (!run.Sleep(0)) return;
                                if (remaining < -0.1) due = Run.Now();
                            }
                            if (run.TakePausedTime() > 0) due = Run.Now();
                        }
                        else
                        {
                            if (!run.Sleep(delay)) return;
                            due = Run.Now();
                        }

                        if (config.RequiredBundleId is { } needed
                            && PlaybackTiming.RequiresForeground(action.Kind)
                            && !ProgramMatches(needed))
                        {
                            Fail(run, ForegroundMessage(config));
                            return;
                        }

                        Emit(run, new PlaybackEvent(PlaybackEventKind.ActionStarted, Index: index));

                        try
                        {
                            if (action.Kind == ActionKind.Text)
                            {
                                if (!TypeOut(action.Text ?? "", run, config)) return;
                            }
                            else
                            {
                                // Last check before touching the system: a stop that arrived while we were
                                // asleep must not let this action through.
                                if (!run.Sleep(0)) return;
                                _performer.Perform(action);
                            }
                        }
                        catch (Exception ex)
                        {
                            Fail(run, ex.Message);
                            return;
                        }

                        if (!isMovement) due = Run.Now();
                    }

                    double? fraction = null;
                    if (total is int t)
                    {
                        var completed = (double)((iteration - 1) * actions.Count + offset + 1);
                        fraction = completed / ((double)t * actions.Count);
                    }
                    Emit(run, new PlaybackEvent(PlaybackEventKind.Progress,
                        Progress: new PlaybackProgress(iteration, total, index, actions.Count, fraction)));
                }

                if (total is int limit && iteration >= limit) break;
                iteration++;

                var pause = Math.Max(config.LoopDelay, loopFloor);
                if (!run.Sleep(pause)) return;
            }

            Finish(run, PlaybackState.Finished);
        }
        finally
        {
            try
            {
                _performer.Cleanup();
            }
            catch (Exception)
            {
                // Cleanup must never throw out of the playback thread.
            }
        }
    }

    private bool ProgramMatches(string required)
    {
        var current = _foregroundProgram();
        return current != null && string.Equals(current, required, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Types text one character at a time with interruptible gaps. Returns false if playback was cancelled part-way.</summary>
    private bool TypeOut(string text, Run run, PlaybackConfig config)
    {
        var characters = TextUnits.Split(text);
        var gap = PlaybackTiming.TypingDelay(config);
        for (var offset = 0; offset < characters.Count; offset++)
        {
            if (!run.Sleep(0)) return false;
            _performer.Perform(Act.Text(characters[offset]));
            if (offset < characters.Count - 1)
            {
                if (!run.Sleep(gap)) return false;
            }
        }
        return true;
    }

    private static string ForegroundMessage(PlaybackConfig config)
    {
        var name = config.RequiredAppName ?? config.RequiredBundleId ?? "the target app";
        return $"Playback stopped because {name} is not the program in front.";
    }

    // ------------------------------------------------------------------ state helpers

    private void Emit(Run run, PlaybackEvent ev)
    {
        Action<PlaybackEvent>? callback;
        bool current;
        lock (_lock)
        {
            current = ReferenceEquals(_currentRun, run);
            callback = _handler;
        }
        if (current) callback?.Invoke(ev);
    }

    private void Transition(Run run, PlaybackState state)
    {
        Action<PlaybackEvent>? callback;
        bool current;
        lock (_lock)
        {
            current = ReferenceEquals(_currentRun, run);
            if (current) _state = state;
            callback = _handler;
        }
        if (current) callback?.Invoke(new PlaybackEvent(PlaybackEventKind.StateChanged, state));
    }

    private void Finish(Run run, PlaybackState state)
    {
        Action<PlaybackEvent>? callback;
        lock (_lock)
        {
            if (!ReferenceEquals(_currentRun, run)) return;
            _currentRun = null;
            _state = state;
            callback = _handler;
        }
        callback?.Invoke(new PlaybackEvent(PlaybackEventKind.StateChanged, state));
    }

    private void Fail(Run run, string message) => Finish(run, PlaybackState.Failed(message));

    // ------------------------------------------------------------------ run

    /// <summary>Cancellation / pause state for one playback thread, plus an interruptible sleep.</summary>
    private sealed class Run
    {
        private readonly object _gate = new();
        private bool _paused;
        private bool _cancelled;
        private double? _pausedSince;
        private double _pausedTotal;

        public static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

        public void Cancel()
        {
            lock (_gate)
            {
                _cancelled = true;
                _paused = false;
                Monitor.PulseAll(_gate);
            }
        }

        public void SetPaused(bool value)
        {
            lock (_gate)
            {
                if (_cancelled) return;
                if (value && !_paused)
                {
                    _paused = true;
                    _pausedSince = Now();
                }
                else if (!value && _paused)
                {
                    _paused = false;
                    if (_pausedSince is double since) _pausedTotal += Now() - since;
                    _pausedSince = null;
                }
                Monitor.PulseAll(_gate);
            }
        }

        /// <summary>Time spent paused since the last call.</summary>
        public double TakePausedTime()
        {
            lock (_gate)
            {
                var value = _pausedTotal;
                _pausedTotal = 0;
                return value;
            }
        }

        /// <summary>Sleeps for <paramref name="seconds"/> of un-paused time. Returns false if the run was cancelled.
        /// With seconds &lt;= 0 it is a pure checkpoint: it blocks while paused and reports cancellation,
        /// which is how the engine guards every action.</summary>
        public bool Sleep(double seconds)
        {
            var remaining = seconds < 0.0005 ? 0.0 : seconds;
            lock (_gate)
            {
                while (true)
                {
                    if (_cancelled) return false;
                    if (_paused)
                    {
                        Monitor.Wait(_gate);
                        continue;
                    }
                    if (remaining <= 0) return true;
                    var started = Now();
                    Monitor.Wait(_gate, TimeSpan.FromSeconds(remaining));
                    remaining -= Now() - started;
                }
            }
        }
    }
}
