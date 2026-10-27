using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Model;

public sealed partial class AppModel
{
    private bool _recordingActive;
    private CancellationTokenSource? _recordingLoop;
    private TargetApp? _pendingTarget;
    private double _recordingElapsed;
    private int _recordedEvents;

    public bool PlaybackEnabled { get; }

    /// <summary>True until the user has read the warning about recorded text (passwords) once.</summary>
    public bool NeedsRecordingAcknowledgement => !_settings.AcknowledgedRecordingWarning;

    public void AcknowledgeRecordingWarning()
    {
        _settings.AcknowledgedRecordingWarning = true;
        TrySaveSettings();
        Raise(nameof(NeedsRecordingAcknowledgement));
    }

    public double RecordingElapsed
    {
        get => _recordingElapsed;
        private set
        {
            if (Set(ref _recordingElapsed, value)) Raise(nameof(RecordingElapsedText));
        }
    }

    public string RecordingElapsedText
    {
        get
        {
            var total = (int)_recordingElapsed;
            return $"{total / 60}:{total % 60:00}";
        }
    }

    public int RecordedEventCount
    {
        get => _recordedEvents;
        private set => Set(ref _recordedEvents, value);
    }

    /// <summary>Starts a recording after the configured countdown. Returns false if it cannot start right now.</summary>
    public bool StartRecording()
    {
        if (IsBusy) return false;
        if (NeedsRecordingAcknowledgement)
        {
            Show(NoticeKind.Warning, "Please read and accept the recording notice first.");
            return false;
        }

        FlushSave();
        _recordingActive = true;
        RaiseAll(nameof(IsRecordingOrPreparing));
        var cancel = new CancellationTokenSource();
        _recordingLoop = cancel;
        var countdown = _settings.RecordingCountdown;

        if (countdown > 0)
        {
            StatusDetail = $"Recording starts in {countdown}…";
            Status = AppStatus.Preparing;
        }
        var ui = _s.Ui;
        Task.Run(async () =>
        {
            try
            {
                for (var remaining = countdown; remaining > 0; remaining--)
                {
                    var shown = remaining;
                    ui.Post(() => { if (!cancel.IsCancellationRequested) StatusDetail = $"Recording starts in {shown}…"; RaiseAll(nameof(StatusText)); });
                    await Task.Delay(1000, cancel.Token).ConfigureAwait(false);
                }
                ui.Post(() => { if (!cancel.IsCancellationRequested) BeginCapture(cancel); });
            }
            catch (OperationCanceledException)
            {
            }
        });
        return true;
    }

    private void BeginCapture(CancellationTokenSource cancel)
    {
        var program = _s.Probe.ForegroundProgram();
        _pendingTarget = program != null && !string.Equals(program.FileName, _s.OwnProgramFileName, StringComparison.OrdinalIgnoreCase)
            ? new TargetApp(program.FileName, program.DisplayName)
            : null;

        var error = _s.Capture.Start(_settings.EmergencyStop);
        if (error != null)
        {
            _recordingActive = false;
            RaiseAll(nameof(IsRecordingOrPreparing));
            StatusDetail = error;
            Status = AppStatus.Error;
            Show(NoticeKind.Error, error);
            return;
        }

        RecordingElapsed = 0;
        RecordedEventCount = 0;
        StatusDetail = "";
        Status = AppStatus.Recording;
        if (_s.Probe.ForegroundIsMoreElevated())
        {
            Show(NoticeKind.Warning, "The program in front runs as administrator, so Windows hides its keys and clicks from recording. Start Action Recorder as administrator to record it.");
        }

        // Keep the on-screen timer and counter fresh while recording.
        var ui = _s.Ui;
        Task.Run(async () =>
        {
            try
            {
                while (!cancel.IsCancellationRequested)
                {
                    await Task.Delay(250, cancel.Token).ConfigureAwait(false);
                    var elapsed = _s.Capture.ElapsedSeconds;
                    var count = _s.Capture.EventCount;
                    ui.Post(() =>
                    {
                        if (cancel.IsCancellationRequested) return;
                        RecordingElapsed = elapsed;
                        RecordedEventCount = count;
                    });
                }
            }
            catch (OperationCanceledException)
            {
            }
        });
    }

    /// <summary>Stops a recording (or cancels the countdown before it) and keeps what was captured.</summary>
    public void StopRecording()
    {
        if (!_recordingActive) return;
        _recordingActive = false;
        _recordingLoop?.Cancel();
        _recordingLoop = null;
        RaiseAll(nameof(IsRecordingOrPreparing));

        if (Status == AppStatus.Preparing)
        {
            StatusDetail = "";
            Status = AppStatus.Idle;
            Show(NoticeKind.Info, "Recording cancelled.");
            return;
        }

        var events = _s.Capture.Stop();
        var actions = RecordingBuilder.Build(events, _settings.Recording);
        // The pointer drifting to the Stop button at the end says nothing about the macro.
        while (actions.Count > 0 && actions[^1].Kind is ActionKind.Move or ActionKind.Drag)
        {
            actions.RemoveAt(actions.Count - 1);
        }

        StatusDetail = "";
        Status = AppStatus.Idle;
        if (actions.Count == 0)
        {
            Show(NoticeKind.Info, "Nothing was recorded. Click or type in another program while recording.");
            return;
        }

        var now = _s.Now();
        var recording = new Recording($"Recording {now:yyyy-MM-dd HH:mm}")
        {
            TargetApp = _pendingTarget,
            RecordedScreen = _s.Probe.PrimaryScreen(),
            PlaybackDefaults = CurrentDefaults(),
        };
        recording.Actions.AddRange(actions);
        AddAndSelect(recording);
        Show(NoticeKind.Success, $"Recorded {actions.Count} action{(actions.Count == 1 ? "" : "s")}. Review them below, then press Play.");
    }
}
