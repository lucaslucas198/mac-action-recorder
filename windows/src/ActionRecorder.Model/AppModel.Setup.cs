using System.Collections.ObjectModel;
using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Model;

/// <summary>The Welcome screen: four real checks, with a progress bar that moves as each one finishes.</summary>
public sealed partial class AppModel
{
    private double _setupFraction;
    private string _setupTitle = "";
    private string _setupStep = "";
    private bool _setupRunning;
    private bool _setupDone;

    public ObservableCollection<SetupCheck> SetupChecks { get; }

    /// <summary>Pause on each stage so the person can read it. Tests set this to 0.</summary>
    public int SetupStageDwellMilliseconds { get; set; } = 350;

    public bool ShowWelcome => !_settings.HasCompletedWelcome;

    public double SetupFraction
    {
        get => _setupFraction;
        private set => Set(ref _setupFraction, value);
    }

    public string SetupTitle
    {
        get => _setupTitle;
        private set => Set(ref _setupTitle, value);
    }

    public string SetupStep
    {
        get => _setupStep;
        private set => Set(ref _setupStep, value);
    }

    public bool SetupRunning
    {
        get => _setupRunning;
        private set => Set(ref _setupRunning, value);
    }

    public bool SetupDone
    {
        get => _setupDone;
        private set => Set(ref _setupDone, value);
    }

    public bool SetupHasWarnings => SetupChecks.Any(c => c.State == CheckState.Warning);

    private async Task Dwell()
    {
        if (SetupStageDwellMilliseconds > 0) await Task.Delay(SetupStageDwellMilliseconds);
    }

    /// <summary>Runs the four checks in order. Call from the UI thread. Safe to run again.</summary>
    public async Task RunSetupAsync()
    {
        if (SetupRunning) return;
        SetupRunning = true;
        SetupDone = false;
        SetupFraction = 0;
        SetupChecks.Clear();
        var system = new SetupCheck("Windows");
        var input = new SetupCheck("Keyboard and mouse access");
        var display = new SetupCheck("Display");
        var assistant = new SetupCheck("Local AI helper (optional)");
        foreach (var c in new[] { system, input, display, assistant }) SetupChecks.Add(c);

        try
        {
            // 1 — Windows
            Begin(SetupStage.System, system);
            var build = _s.Probe.WindowsBuild;
            var description = _s.Probe.WindowsDescription();
            if (build >= 17763)
            {
                system.State = CheckState.Ok;
                system.Detail = description;
            }
            else
            {
                system.State = CheckState.Warning;
                system.Detail = $"{description}. Windows 10 version 1809 or newer is recommended.";
            }
            await Dwell();

            // 2 — input hooks and emergency stop
            Begin(SetupStage.Input, input);
            string? hookError = null;
            if (!_s.Capture.IsRunning && !IsBusy)
            {
                hookError = await Task.Run(() =>
                {
                    var error = _s.Capture.Start(_settings.EmergencyStop);
                    if (error == null) _s.Capture.Stop();
                    return error;
                });
            }
            var hotkey = _s.HotKey.IsRegistered;
            if (hookError != null)
            {
                input.State = CheckState.Warning;
                input.Detail = hookError;
            }
            else if (!hotkey)
            {
                input.State = CheckState.Warning;
                input.Detail = $"Recording works, but {_settings.EmergencyStop.DisplayString} is used by another program. Pick another emergency-stop shortcut in Settings.";
            }
            else
            {
                input.State = CheckState.Ok;
                input.Detail = $"Recording and playback are available. Emergency stop: {_settings.EmergencyStop.DisplayString}.";
            }
            await Dwell();

            // 3 — display
            Begin(SetupStage.Display, display);
            var screen = _s.Probe.PrimaryScreen();
            var monitors = _s.Probe.MonitorCount;
            if (screen == null)
            {
                display.State = CheckState.Warning;
                display.Detail = "The screen size could not be read.";
            }
            else
            {
                display.State = CheckState.Ok;
                display.Detail = $"{screen.Width:0} × {screen.Height:0}" + (monitors > 1 ? $" · {monitors} monitors" : "");
            }
            await Dwell();

            // 4 — local AI helper (optional, so it only ever produces a hint)
            Begin(SetupStage.Assistant, assistant);
            await RefreshAiStatusAsync();
            switch (AiState)
            {
                case AiState.Ready:
                    assistant.State = CheckState.Ok;
                    assistant.Detail = "Ready. " + AiMessage;
                    break;
                case AiState.Disabled:
                    assistant.State = CheckState.Ok;
                    assistant.Detail = "Turned off. You can enable it in Settings.";
                    break;
                default:
                    assistant.State = CheckState.Warning;
                    assistant.Detail = "Not set up yet. The app works fully without it. You can install Ollama later from the AI panel.";
                    break;
            }
            await Dwell();

            SetupFraction = 1;
            SetupTitle = SetupHasWarnings ? "Ready, with a few notes" : "Everything looks good";
            SetupStep = "";
            SetupDone = true;
            RaiseAll(nameof(SetupHasWarnings));
        }
        finally
        {
            SetupRunning = false;
        }
    }

    private void Begin(SetupStage stage, SetupCheck check)
    {
        SetupFraction = stage.Fraction();
        SetupTitle = stage.Title();
        SetupStep = stage.StepText();
        check.State = CheckState.Working;
    }

    /// <summary>The Enter button on the Welcome screen.</summary>
    public void CompleteWelcome()
    {
        _settings.HasCompletedWelcome = true;
        TrySaveSettings();
        Raise(nameof(ShowWelcome));
    }

    /// <summary>Lets the person see the Welcome screen again (Settings → About).</summary>
    public void ResetWelcome()
    {
        _settings.HasCompletedWelcome = false;
        TrySaveSettings();
        SetupDone = false;
        SetupFraction = 0;
        Raise(nameof(ShowWelcome));
    }
}
