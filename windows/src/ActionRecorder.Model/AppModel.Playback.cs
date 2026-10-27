using ActionRecorder.Core;

namespace ActionRecorder.Model;

public sealed partial class AppModel
{
    private int _currentActionIndex = -1;
    private double _playbackFraction;
    private string _playbackText = "";
    private int _iteration;
    private int? _iterations;

    public int CurrentActionIndex
    {
        get => _currentActionIndex;
        private set => Set(ref _currentActionIndex, value);
    }

    public double PlaybackFraction
    {
        get => _playbackFraction;
        private set => Set(ref _playbackFraction, value);
    }

    public string PlaybackText
    {
        get => _playbackText;
        private set => Set(ref _playbackText, value);
    }

    public int Iteration
    {
        get => _iteration;
        private set => Set(ref _iteration, value);
    }

    public int? Iterations
    {
        get => _iterations;
        private set => Set(ref _iterations, value);
    }

    public string RepetitionText => Iterations is int total ? $"Run {Iteration} of {total}" : $"Run {Iteration} (until stopped)";

    public PlaybackConfig BuildConfig((int Start, int End)? range)
    {
        var config = new PlaybackConfig
        {
            Speed = _speed,
            RepeatCount = _repeatCount,
            Infinite = _infinite,
            LoopDelay = _loopDelay,
            Countdown = _countdown,
            MinActionDelay = _settings.MinActionDelay,
            TypingCharDelay = _settings.TypingCharDelay,
            Range = range,
        };
        if (_verifyForeground && _current?.TargetApp is { } target)
        {
            config.RequiredBundleId = target.BundleId;
            config.RequiredAppName = target.Name;
        }
        return config;
    }

    /// <summary>The text of a question to ask before playing, or null when no confirmation is needed.
    /// Looping until stopped always needs one; others only when the "confirm before playing" setting is on.</summary>
    public string? PlaybackConfirmation()
    {
        if (_current == null) return null;
        if (_infinite)
        {
            return "This macro will repeat until you stop it. It keeps clicking and typing in whichever program is in front.\n\n" +
                   $"Stop it at any time with {_settings.EmergencyStop.DisplayString}. Start it now?";
        }
        if (_settings.ConfirmBeforePlay)
        {
            return $"Play “{_current.Name}” now? It will control your mouse and keyboard. Stop it with {_settings.EmergencyStop.DisplayString}.";
        }
        return null;
    }

    /// <summary>Plays the current recording (or only the given section, as start-inclusive, end-exclusive action indices).</summary>
    public bool Play((int Start, int End)? section = null)
    {
        if (IsBusy || _current == null) return false;
        if (_current.Actions.Count == 0)
        {
            Show(NoticeKind.Info, "This macro has no actions yet. Record something or add steps first.");
            return false;
        }
        FlushSave();
        var config = BuildConfig(section);
        try
        {
            ResetPlaybackView();
            Iterations = PlaybackTiming.TotalIterations(config);
            Iteration = 1;
            Engine.Start(_current, config);
            return true;
        }
        catch (PlaybackException ex)
        {
            StatusDetail = ex.Message;
            Status = AppStatus.Error;
            Show(NoticeKind.Error, ex.Message);
            return false;
        }
    }

    public void Pause() => Engine.Pause();
    public void Resume() => Engine.Resume();

    public bool Restart()
    {
        if (_current == null) return false;
        try
        {
            ResetPlaybackView();
            Engine.Restart();
            return true;
        }
        catch (PlaybackException ex)
        {
            Show(NoticeKind.Error, ex.Message);
            return false;
        }
    }

    /// <summary>Stops playback. Safe to call at any time.</summary>
    public void StopPlayback() => Engine.Stop();

    /// <summary>Stops whatever is running: recording, the countdown before it, or playback.</summary>
    public void EmergencyStop()
    {
        if (_recordingActive) StopRecording();
        Engine.Stop();
    }

    private void ResetPlaybackView()
    {
        CurrentActionIndex = -1;
        PlaybackFraction = 0;
        PlaybackText = "";
        foreach (var row in Rows)
        {
            row.IsCurrent = false;
            row.IsDone = false;
        }
    }

    private void OnEngineEvent(PlaybackEvent e)
    {
        if (_disposed) return;
        switch (e.Kind)
        {
            case PlaybackEventKind.StateChanged:
                ApplyEngineState(e.State);
                break;

            case PlaybackEventKind.IterationStarted:
                Iteration = e.Iteration;
                Iterations = e.Total;
                RaiseAll(nameof(RepetitionText));
                if (e.Iteration > 1)
                {
                    foreach (var row in Rows) { row.IsDone = false; row.IsCurrent = false; }
                }
                break;

            case PlaybackEventKind.ActionStarted:
                SetCurrentRow(e.Index);
                break;

            case PlaybackEventKind.Progress when e.Progress is { } p:
                if (p.Fraction is double f) PlaybackFraction = f;
                else PlaybackFraction = (double)(p.ActionIndex + 1) / Math.Max(1, p.ActionCount);
                if (p.ActionIndex >= 0 && p.ActionIndex < Rows.Count) Rows[p.ActionIndex].IsDone = true;
                break;
        }
    }

    private void SetCurrentRow(int index)
    {
        CurrentActionIndex = index;
        for (var i = 0; i < Rows.Count; i++) Rows[i].IsCurrent = i == index;
        if (index >= 0 && index < Rows.Count)
        {
            PlaybackText = Rows[index].Title;
            CurrentRowChanged?.Invoke(Rows[index]);
        }
    }

    /// <summary>Raised when playback reaches a new action, so the list can scroll to it.</summary>
    public event Action<ActionRow>? CurrentRowChanged;

    private void ApplyEngineState(PlaybackState state)
    {
        switch (state.Phase)
        {
            case PlaybackPhase.Countdown:
                StatusDetail = $"Starting in {state.Seconds}…";
                Status = AppStatus.Preparing;
                RaiseAll(nameof(StatusText), nameof(IsPlayingOrPaused));
                break;
            case PlaybackPhase.Playing:
                StatusDetail = "";
                Status = AppStatus.Playing;
                RaiseAll(nameof(IsPlayingOrPaused));
                break;
            case PlaybackPhase.Paused:
                Status = AppStatus.Paused;
                break;
            case PlaybackPhase.Finished:
                FinishRun("Finished");
                Show(NoticeKind.Success, "Playback finished.");
                break;
            case PlaybackPhase.Stopped:
                FinishRun("Stopped");
                break;
            case PlaybackPhase.Failed:
                FinishRun(state.Message ?? "Playback failed");
                StatusDetail = state.Message ?? "Playback failed";
                Status = AppStatus.Error;
                Show(NoticeKind.Error, state.Message ?? "Playback failed.");
                break;
        }
    }

    private void FinishRun(string text)
    {
        foreach (var row in Rows) row.IsCurrent = false;
        StatusDetail = text;
        Status = AppStatus.Stopped;
        RaiseAll(nameof(IsPlayingOrPaused));
    }
}
