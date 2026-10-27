using System.Net;
using System.Text.Json;
using ActionRecorder.Core;
using ActionRecorder.Model;
using ActionRecorder.Native;

namespace ActionRecorder.Tests;

public sealed class FakeCapture : IInputCapture
{
    public string? StartError;
    public List<RawEvent> Events = new();
    public bool IsRunning { get; private set; }
    public int EventCount => Events.Count;
    public double ElapsedSeconds { get; set; }
    public int Starts;
    public int Stops;

    public string? Start(HotKey? ignoredHotKey = null, bool includeInjected = false)
    {
        Starts++;
        if (StartError != null) return StartError;
        IsRunning = true;
        return null;
    }

    public List<RawEvent> Stop()
    {
        Stops++;
        IsRunning = false;
        return Events;
    }

    public void Dispose()
    {
    }
}

public sealed class FakeHotKey : IHotKeyRegistrar
{
    public bool Accept = true;
    public HotKey? Last;
    public event Action? Pressed;
    public bool IsRegistered { get; private set; }

    public bool Set(HotKey hotKey)
    {
        Last = hotKey;
        IsRegistered = Accept;
        return Accept;
    }

    public void Press() => Pressed?.Invoke();
    public void Dispose()
    {
    }
}

public sealed class FakeProbe : ISystemProbe
{
    public ProgramInfo? Foreground = new("discord.exe", "Discord");
    public ScreenSize? Screen = new(1920, 1080);
    public bool MoreElevated;
    public int Build = 22631;
    public int Monitors = 1;

    public ProgramInfo? ForegroundProgram() => Foreground;
    public ScreenSize? PrimaryScreen() => Screen;
    public bool ForegroundIsMoreElevated() => MoreElevated;
    public string WindowsDescription() => "Windows 11 (build 22631)";
    public int WindowsBuild => Build;
    public int MonitorCount => Monitors;
}

public sealed class ModelRig : IDisposable
{
    public readonly string Root = Path.Combine(Path.GetTempPath(), "ar-model-" + Guid.NewGuid().ToString("N"));
    public readonly FakeCapture Capture = new();
    public readonly FakeHotKey HotKey = new();
    public readonly FakePerformer Performer = new();
    public readonly FakeProbe Probe = new();
    public AppModel Model = null!;
    public Func<AppSettings, AiAssistant>? AiFactory;
    public Func<UpdateService?>? UpdateFactory;

    public ModelRig(Action<AppSettings>? configure = null, bool acknowledged = true)
    {
        Directory.CreateDirectory(Root);
        AppPaths.RootOverride = Root;
        var store = new SettingsStore(AppPaths.SettingsFile);
        var settings = new AppSettings { RecordingCountdown = 0, PlaybackCountdown = 0, AcknowledgedRecordingWarning = acknowledged, BackupEnabled = false, HasCompletedWelcome = true };
        configure?.Invoke(settings);
        store.Save(settings);
        Model = Create();
    }

    public AppModel Create()
    {
        var model = new AppModel(new AppServices
        {
            Ui = new InlineUiThread(),
            Capture = Capture,
            HotKey = HotKey,
            Performer = Performer,
            Probe = Probe,
            SettingsStore = new SettingsStore(AppPaths.SettingsFile),
            InstalledVersion = "0.4.0",
            AiFactory = AiFactory,
            UpdateFactory = UpdateFactory,
            OwnProgramFileName = "ActionRecorder.exe",
        });
        model.Initialize();
        return model;
    }

    public static bool WaitFor(Func<bool> condition, double seconds = 5)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end)
        {
            if (condition()) return true;
            Thread.Sleep(5);
        }
        return condition();
    }

    public void Dispose()
    {
        try { Model.Dispose(); } catch (Exception) { }
        AppPaths.RootOverride = null;
        try { Directory.Delete(Root, true); } catch (Exception) { }
    }
}

public static class ModelTests
{
    private static List<RawEvent> ClickAndType() => new()
    {
        RawEvent.Move(0.10, 100, 100),
        RawEvent.Down(0.50, 300, 200),
        RawEvent.Up(0.58, 300, 200),
        RawEvent.KeyPress(1.00, 0x48, KeyModifiers.None, "h"),
        RawEvent.KeyRelease(1.05, 0x48, KeyModifiers.None),
        RawEvent.KeyPress(1.10, 0x49, KeyModifiers.None, "i"),
        RawEvent.KeyRelease(1.15, 0x49, KeyModifiers.None),
        RawEvent.Move(1.60, 900, 900),
    };

    private static AppModel Recorded(ModelRig rig)
    {
        rig.Capture.Events = ClickAndType();
        Check.True(rig.Model.StartRecording());
        Check.True(ModelRig.WaitFor(() => rig.Model.Status == AppStatus.Recording), "recording should begin");
        rig.Model.StopRecording();
        return rig.Model;
    }

    private static string Chat(string content) => JsonSerializer.Serialize(new { model = "m", message = new { role = "assistant", content }, done = true });
    private const string Tags = """{"models":[{"name":"llama3.2:3b","size":2019393189}]}""";

    /// <summary>The engine types text one character at a time, so each character is one performed call.</summary>
    private static int ExpectedPerformed(Recording r) =>
        r.Actions.Sum(a => a.Kind == ActionKind.Text ? TextUnits.Count(a.Text ?? "") : 1);

    // ------------------------------------------------------------------ recording

    [Test]
    public static void RecordingProducesASelectedMacroWithoutTheTrailingMove()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        Check.Equal(AppStatus.Idle, model.Status);
        Check.Equal(1, model.Recordings.Count);
        Check.True(model.HasActions);
        Check.True(model.Current!.Actions.Last().Kind != ActionKind.Move, "the pointer drifting to Stop must be dropped");
        Check.Equal("discord.exe", model.Current.TargetApp?.BundleId);
        Check.Equal(1, rig.Capture.Stops);
        Check.True(File.Exists(Directory.GetFiles(model.RecordingsFolder, "*.macro.json").FirstOrDefault() ?? ""), "recording is saved right away");
    }

    [Test]
    public static void RecordingNeedsTheWarningToBeAcknowledged()
    {
        using var rig = new ModelRig(acknowledged: false);
        Check.True(rig.Model.NeedsRecordingAcknowledgement);
        Check.False(rig.Model.StartRecording());
        Check.Equal(0, rig.Capture.Starts);
        rig.Model.AcknowledgeRecordingWarning();
        Check.False(rig.Model.NeedsRecordingAcknowledgement);
        Check.True(rig.Model.StartRecording());
        rig.Model.StopRecording();
        // the acknowledgement is remembered
        using var again = rig.Create();
        Check.False(again.NeedsRecordingAcknowledgement);
    }

    [Test]
    public static void RecordingIgnoresItsOwnWindowAsTarget()
    {
        using var rig = new ModelRig();
        rig.Probe.Foreground = new ProgramInfo("ActionRecorder.exe", "Action Recorder");
        var model = Recorded(rig);
        Check.True(model.Current!.TargetApp == null);
    }

    [Test]
    public static void CaptureFailureShowsAnErrorAndAllowsRetry()
    {
        using var rig = new ModelRig();
        rig.Capture.StartError = "Windows refused the keyboard hook.";
        var seen = new List<string>();
        rig.Model.NoticeShown += (_, m) => seen.Add(m);
        Check.True(rig.Model.StartRecording());
        Check.True(ModelRig.WaitFor(() => rig.Model.Status == AppStatus.Error));
        Check.True(ModelRig.WaitFor(() => { lock (seen) return seen.Any(m => m.Contains("refused")); }), "the reason is shown");
        Check.False(rig.Model.IsRecordingOrPreparing);
        rig.Capture.StartError = null;
        Check.True(rig.Model.CanRecord, "an error must not lock the app");
    }

    [Test]
    public static void EmptyRecordingIsNotSaved()
    {
        using var rig = new ModelRig();
        rig.Capture.Events = new();
        rig.Model.StartRecording();
        Check.True(ModelRig.WaitFor(() => rig.Model.Status == AppStatus.Recording));
        rig.Model.StopRecording();
        Check.Equal(0, rig.Model.Recordings.Count);
        Check.Equal(AppStatus.Idle, rig.Model.Status);
    }

    [Test]
    public static void ElevatedForegroundWindowGetsAWarning()
    {
        using var rig = new ModelRig();
        rig.Probe.MoreElevated = true;
        var seen = new List<string>();
        rig.Model.NoticeShown += (_, m) => seen.Add(m);
        rig.Model.StartRecording();
        Check.True(ModelRig.WaitFor(() => rig.Model.Status == AppStatus.Recording));
        rig.Model.StopRecording();
        Check.True(seen.Any(m => m.Contains("administrator")));
    }

    [Test]
    public static void CountdownBeforeRecordingCanBeCancelled()
    {
        using var rig = new ModelRig(s => s.RecordingCountdown = 5);
        Check.True(rig.Model.StartRecording());
        Check.Equal(AppStatus.Preparing, rig.Model.Status);
        rig.Model.StopRecording();
        Check.Equal(AppStatus.Idle, rig.Model.Status);
        Thread.Sleep(150);
        Check.Equal(0, rig.Capture.Starts);
    }

    // ------------------------------------------------------------------ playback

    [Test]
    public static void PlaybackRunsEveryActionAndMarksRows()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Speed = 20;
        model.Countdown = 0;
        Check.True(model.Play());
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Stopped && model.StatusText == "Finished"), "playback should finish");
        Check.Equal(ExpectedPerformed(model.Current!), rig.Performer.Count);
        Check.True(model.Rows.All(r => r.IsDone));
        Check.True(model.Rows.All(r => !r.IsCurrent));
        Check.Near(1.0, model.PlaybackFraction, 1e-9);
        Check.True(rig.Performer.Cleanups >= 1);
    }

    [Test]
    public static void RepeatCountRunsTheMacroThatManyTimes()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Speed = 20;
        model.Countdown = 0;
        model.RepeatCount = 3;
        var perRun = ExpectedPerformed(model.Current!);
        model.Play();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Stopped));
        Check.Equal(perRun * 3, rig.Performer.Count);
        Check.Equal(3, model.Iteration);
        Check.Equal("Run 3 of 3", model.RepetitionText);
    }

    [Test]
    public static void InfiniteLoopNeedsConfirmationAndStopsImmediately()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Infinite = true;
        model.Speed = 20;
        model.Countdown = 0;
        var question = model.PlaybackConfirmation();
        Check.True(question != null && question.Contains("until you stop"), "looping forever must ask first");
        Check.True(question!.Contains(model.EmergencyStopText));
        model.Play();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Playing && rig.Performer.Count > 3));
        model.StopPlayback();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Stopped));
        var count = rig.Performer.Count;
        Thread.Sleep(120);
        Check.Equal(count, rig.Performer.Count, "nothing may run after stop");
    }

    [Test]
    public static void ConfirmBeforePlaySettingAsksForFiniteRunsToo()
    {
        using var rig = new ModelRig(s => s.ConfirmBeforePlay = true);
        var model = Recorded(rig);
        Check.True(model.PlaybackConfirmation() != null);
        using var plain = new ModelRig();
        Recorded(plain);
        Check.True(plain.Model.PlaybackConfirmation() == null);
    }

    [Test]
    public static void PauseAndResumeHoldAndContinue()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Speed = 1;
        model.Countdown = 0;
        model.Play();
        Check.True(ModelRig.WaitFor(() => rig.Performer.Count >= 1));
        model.Pause();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Paused));
        Check.True(model.CanResume);
        Thread.Sleep(80);
        var held = rig.Performer.Count;
        Thread.Sleep(250);
        Check.Equal(held, rig.Performer.Count, "paused playback must not act");
        model.Resume();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Playing || model.Status == AppStatus.Stopped));
        model.StopPlayback();
    }

    [Test]
    public static void EmergencyHotKeyStopsPlayback()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Infinite = true;
        model.Speed = 1;
        model.Countdown = 0;
        model.Play();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Playing));
        rig.HotKey.Press();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Stopped));
    }

    [Test]
    public static void EmergencyHotKeyEndsARecording()
    {
        using var rig = new ModelRig();
        rig.Capture.Events = ClickAndType();
        rig.Model.StartRecording();
        Check.True(ModelRig.WaitFor(() => rig.Model.Status == AppStatus.Recording));
        rig.HotKey.Press();
        Check.Equal(AppStatus.Idle, rig.Model.Status);
        Check.Equal(1, rig.Model.Recordings.Count);
    }

    [Test]
    public static void ForegroundVerificationBlocksPlaybackInTheWrongProgram()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.VerifyForeground = true;
        model.Countdown = 0;
        model.Speed = 20;
        rig.Probe.Foreground = new ProgramInfo("notepad.exe", "Notepad");
        model.Play();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Error), "wrong program must fail playback");
        Check.True(model.StatusDetail.Length > 0);
        Check.Equal(0, rig.Performer.Count);
    }

    [Test]
    public static void SectionPlaybackOnlyRunsTheSelectedActions()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Speed = 20;
        model.Countdown = 0;
        model.Play((0, 1));
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Stopped));
        Check.Equal(1, rig.Performer.Count);
    }

    [Test]
    public static void PerformerFailureBecomesAVisibleError()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Speed = 20;
        model.Countdown = 0;
        rig.Performer.OnPerform = _ => throw new PlaybackException("Blocked by an administrator window.");
        model.Play();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Error));
        Check.True(model.StatusDetail.Contains("administrator"));
        Check.True(model.CanRecord && model.CanPlay, "the app must recover from a failed run");
    }

    [Test]
    public static void OptionsArePerMacroAndPersist()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Speed = 2;
        model.RepeatCount = 4;
        model.LoopDelay = 1.5;
        model.FlushSave();
        Check.Equal(2.0, model.Current!.PlaybackDefaults!.Speed);
        Check.Equal(4, model.Current.PlaybackDefaults.RepeatCount);
        var second = model.NewEmptyRecording("Second");
        model.Speed = 0.5;
        model.SelectedEntry = model.Recordings.Last();
        Check.Equal(2.0, model.Speed);
        Check.Equal(4, model.RepeatCount);
        Check.Equal("2× — Double speed", model.SpeedText);
    }

    [Test]
    public static void SpeedIsClampedAndDescribed()
    {
        using var rig = new ModelRig();
        rig.Model.Speed = 9999;
        Check.Equal(PlaybackTiming.MaxSpeed, rig.Model.Speed);
        rig.Model.Speed = 0.001;
        Check.Equal(PlaybackTiming.MinSpeed, rig.Model.Speed);
        rig.Model.Speed = -3;
        Check.Equal(1.0, rig.Model.Speed, "a nonsense speed falls back to original timing");
        rig.Model.Speed = 3.25;
        Check.True(rig.Model.SpeedText.Contains("custom"));
    }

    // ------------------------------------------------------------------ editing

    [Test]
    public static void DeleteUndoRedoRoundTrip()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        var before = model.Current!.Actions.Select(a => a.Id).ToList();
        Check.True(model.DeleteActions(new[] { before[0] }));
        Check.Equal(before.Count - 1, model.ActionCount);
        Check.True(model.CanUndo);
        model.Undo();
        Check.SequenceEqual(before, model.Current!.Actions.Select(a => a.Id));
        Check.Equal(before.Count, model.Rows.Count);
        model.Redo();
        Check.Equal(before.Count - 1, model.ActionCount);
        Check.False(model.CanRedo);
    }

    [Test]
    public static void EditsAreSavedAndSurviveARestart()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.RenameCurrent("My macro");
        model.InsertWait(2.5, null);
        model.FlushSave();
        var id = model.Current!.Id;
        var count = model.ActionCount;
        model.Dispose();
        rig.Model = rig.Create();
        var again = rig.Model;
        Check.Equal(1, again.Recordings.Count);
        Check.Equal(id, again.Current!.Id);
        Check.Equal("My macro", again.CurrentName);
        Check.Equal(count, again.ActionCount);
        Check.Equal(ActionKind.Wait, again.Current.Actions.Last().Kind);
    }

    [Test]
    public static void InvalidEditsAreRejectedAndLeaveTheMacroUntouched()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        var click = model.Current!.Actions.First(a => a.Kind == ActionKind.Click);
        Check.False(model.EditAction(click.Id, a => a.X = double.NaN, out var error));
        Check.True(!string.IsNullOrEmpty(error));
        Check.False(model.EditAction(click.Id, a => a.Delay = -5, out _));
        Check.Near(300, model.Current.Actions.First(a => a.Id == click.Id).X!.Value);
        Check.True(model.EditAction(click.Id, a => { a.X = 640; a.Y = 480; }, out _));
        Check.Near(640, model.Current.Actions.First(a => a.Id == click.Id).X!.Value);
        Check.True(model.CanUndo);
    }

    [Test]
    public static void DuplicateAndMoveKeepOrderConsistent()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        var first = model.Current!.Actions[0].Id;
        var copies = model.DuplicateActions(new[] { first });
        Check.Equal(1, copies.Count);
        Check.Equal(copies[0], model.Current.Actions[1].Id);
        Check.True(model.MoveDown(copies));
        Check.Equal(copies[0], model.Current.Actions[2].Id);
        Check.True(model.MoveUp(copies));
        Check.Equal(copies[0], model.Current.Actions[1].Id);
        Check.True(model.Rows.Select((r, i) => r.Index == i).All(x => x));
    }

    [Test]
    public static void PresetsInsertKeyboardSteps()
    {
        using var rig = new ModelRig();
        var model = model0(rig);
        var before = model.ActionCount;
        Check.True(model.InsertPreset("open-channel", "general", "", null));
        Check.True(model.ActionCount > before);
        var key = model.Current!.Actions.First(a => a.Kind == ActionKind.Key && a.KeyCode == 75);
        Check.True(key.Modifiers!.Value.Has(KeyModifiers.Control), "Quick Switcher is Ctrl+K on Windows");
        Check.True(model.Current.Actions.Any(a => a.Text == "general"));

        static AppModel model0(ModelRig r)
        {
            r.Model.NewEmptyRecording("Blank");
            return r.Model;
        }
    }

    [Test]
    public static void EditingIsBlockedWhileBusy()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.Infinite = true;
        model.Countdown = 0;
        model.Speed = 1;
        model.Play();
        Check.True(ModelRig.WaitFor(() => model.Status == AppStatus.Playing));
        Check.False(model.DeleteActions(new[] { model.Current!.Actions[0].Id }));
        Check.False(model.CanEdit);
        model.StopPlayback();
    }

    [Test]
    public static void ClickMarkersAreNumberedInOrder()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        model.InsertActions(new[] { Act.Click(10, 20), Act.Click(30, 40, MouseButton.Right) }, null);
        var markers = model.ClickMarkers();
        Check.Equal(3, markers.Count);
        Check.SequenceEqual(new[] { 1, 2, 3 }, markers.Select(m => m.Number));
        Check.Equal(MouseButton.Right, markers[2].Button);
    }

    // ------------------------------------------------------------------ list actions / import / export

    [Test]
    public static void DuplicateDeleteAndRenameWork()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        var original = model.SelectedEntry!;
        model.DuplicateRecording(original);
        Check.Equal(2, model.Recordings.Count);
        Check.True(model.Current!.Id != original.Id);
        model.DeleteRecording(model.SelectedEntry!);
        Check.Equal(1, model.Recordings.Count);
        Check.Equal(original.Id, model.Current!.Id);
        Check.Equal(1, Directory.GetFiles(model.RecordingsFolder, "*.macro.json").Length);
    }

    [Test]
    public static void ExportThenImportRoundTrips()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        var path = Path.Combine(rig.Root, model.SuggestedExportFileName());
        Check.True(model.ExportCurrent(path));
        var outcome = model.ImportFile(path);
        Check.True(outcome.Error == null, outcome.Error ?? "");
        Check.Equal(2, model.Recordings.Count);
        Check.Equal(model.Recordings[1].Recording.Actions.Count, outcome.Recording!.Actions.Count);
        Check.True(outcome.Recording.Id != model.Recordings[1].Id, "an imported copy gets its own id");
    }

    [Test]
    public static void ImportingAMacFileConvertsKeysAndTellsTheUser()
    {
        using var rig = new ModelRig();
        var mac = new Recording("From Mac") { Platform = null, TargetApp = new TargetApp("com.hnc.Discord", "Discord"), RecordedScreen = new ScreenSize(1440, 900) };
        mac.Actions.Add(Act.Key(40, KeyModifiers.Command));
        mac.Actions.Add(Act.Text("general"));
        mac.Actions.Add(Act.Key(36));
        var path = Path.Combine(rig.Root, "mac.macro.json");
        File.WriteAllBytes(path, RecordingCodec.Encode(mac));
        var outcome = rig.Model.ImportFile(path);
        Check.True(outcome.Error == null, outcome.Error ?? "");
        Check.True(outcome.Recording!.IsFromWindows);
        var key = outcome.Recording.Actions[0];
        Check.Equal(75, key.KeyCode!.Value);
        Check.True(key.Modifiers!.Value.Has(KeyModifiers.Control));
        Check.False(key.Modifiers.Value.Has(KeyModifiers.Command));
        Check.Equal(13, outcome.Recording.Actions[2].KeyCode!.Value);
        Check.True(outcome.Recording.TargetApp == null, "a Mac app id means nothing on Windows");
        Check.True(outcome.Notes.Count > 0);
    }

    [Test]
    public static void BrokenFilesNeverCrashImport()
    {
        using var rig = new ModelRig();
        var path = Path.Combine(rig.Root, "bad.macro.json");
        File.WriteAllText(path, "{ not json");
        var outcome = rig.Model.ImportFile(path);
        Check.True(outcome.Recording == null && !string.IsNullOrEmpty(outcome.Error));
        var missing = rig.Model.ImportFile(Path.Combine(rig.Root, "nope.macro.json"));
        Check.True(missing.Recording == null && !string.IsNullOrEmpty(missing.Error));
        Check.Equal(0, rig.Model.Recordings.Count);
    }

    [Test]
    public static void UnreadableFilesInTheFolderAreSkippedWithAWarning()
    {
        using var rig = new ModelRig();
        var model = Recorded(rig);
        File.WriteAllText(Path.Combine(model.RecordingsFolder, "corrupt.macro.json"), "garbage");
        var seen = new List<string>();
        model.NoticeShown += (_, m) => seen.Add(m);
        model.ReloadRecordings();
        Check.Equal(1, model.Recordings.Count);
        Check.True(seen.Any(m => m.Contains("could not be read")));
    }

    // ------------------------------------------------------------------ analysis

    [Test]
    public static void FindingsAppearAndOneClickFixesWork()
    {
        using var rig = new ModelRig();
        var model = rig.Model;
        model.NewEmptyRecording("Noisy");
        var actions = new List<MacroAction>();
        for (var i = 0; i < 30; i++) actions.Add(Act.Move(i * 5, i * 5, 0.01));
        actions.Add(Act.Click(10, 10, delay: 0.1));
        actions.Add(Act.Text("Zx9$kq2!mPw7#vL", delay: 12));
        model.InsertActions(actions, null);
        Check.True(model.HasFindings);
        var moves = model.Findings.First(f => f.Fix?.Kind == FixKind.RemoveMouseMoves);
        Check.True(model.ApplyFix(moves));
        Check.False(model.Current!.Actions.Any(a => a.Kind == ActionKind.Move));
        model.Undo();
        Check.True(model.Current!.Actions.Count(a => a.Kind == ActionKind.Move) == 30);
        Check.True(model.Findings.Any(f => f.Id == "secret-text"));
    }

    [Test]
    public static void BuiltInImproveListsAndAppliesTickedChanges()
    {
        using var rig = new ModelRig();
        var model = rig.Model;
        model.NewEmptyRecording("Moves");
        var actions = new List<MacroAction> { Act.Click(5, 5) };
        for (var i = 0; i < 12; i++) actions.Add(Act.Move(i * 4, i * 4, 0.01));
        actions.Add(Act.Click(200, 200, delay: 0.1));
        model.InsertActions(actions, null);
        var count = model.PlanImprovements();
        Check.True(count > 0);
        var before = model.ActionCount;
        var applied = model.ApplySelectedProposals();
        Check.True(applied > 0);
        Check.True(model.ActionCount < before);
        Check.True(model.CanUndo);
    }

    // ------------------------------------------------------------------ AI

    private static ModelRig AiRig(Func<string, string> chatReply, FakeHandler? handler = null, Action<AppSettings>? configure = null)
    {
        var h = handler ?? new FakeHandler(r => r.RequestUri!.AbsolutePath.EndsWith("/api/tags")
            ? (HttpStatusCode.OK, Tags)
            : (HttpStatusCode.OK, Chat(chatReply(r.RequestUri!.AbsolutePath))));
        var rig = new ModelRig(configure);
        rig.AiFactory = s => new AiAssistant(() => rig.Model.Settings, _ => h);
        rig.Model.Dispose();
        rig.Model = rig.Create();
        return rig;
    }

    [Test]
    public static async Task AiStatusReadyNeedsModelAndNotRunning()
    {
        using (var rig = AiRig(_ => ""))
        {
            await rig.Model.RefreshAiStatusAsync();
            Check.Equal(AiState.Ready, rig.Model.AiState);
        }
        using (var rig = AiRig(_ => "", new FakeHandler(r => (HttpStatusCode.OK, """{"models":[]}"""))))
        {
            await rig.Model.RefreshAiStatusAsync();
            Check.Equal(AiState.NoModel, rig.Model.AiState);
            Check.True(rig.Model.AiNeedsModel);
        }
        using (var rig = new ModelRig())
        {
            rig.AiFactory = s => new AiAssistant(() => rig.Model.Settings, _ => new ThrowingHandler());
            rig.Model.Dispose();
            rig.Model = rig.Create();
            await rig.Model.RefreshAiStatusAsync();
            Check.Equal(AiState.NotRunning, rig.Model.AiState);
        }
        using (var rig = AiRig(_ => "", configure: s => s.AiEnabled = false))
        {
            await rig.Model.RefreshAiStatusAsync();
            Check.Equal(AiState.Disabled, rig.Model.AiState);
        }
    }

    [Test]
    public static async Task AiReviewIsShownAsText()
    {
        using var rig = AiRig(_ => "- Wait after Ctrl+K");
        var model = Recorded(rig);
        await model.ReviewWithAiAsync();
        Check.Equal("- Wait after Ctrl+K", model.AiReview);
        Check.False(model.AiBusy);
    }

    [Test]
    public static async Task AiEditsOnlyBecomeCheckedProposalsNeverApplyThemselves()
    {
        using var rig = AiRig(_ => "DELETE 1 | stray\nPAUSE 2 1.5 | let it open\nRUN powershell calc.exe\nDELETE 99 | nonsense");
        var model = Recorded(rig);
        var before = model.ActionCount;
        await model.SuggestEditsWithAiAsync();
        Check.Equal(before, model.ActionCount, "suggestions must not change the macro");
        Check.True(model.Proposals.Count > 0 && model.Proposals.Count <= 2, "only the two valid lines survive");
        Check.True(model.Proposals.All(p => p.FromAi));
        var applied = model.ApplySelectedProposals();
        Check.True(applied > 0);
    }

    [Test]
    public static async Task AiDraftIsPreviewedThenInserted()
    {
        using var rig = AiRig(_ => "KEY ctrl+k\nWAIT 0.5\nTYPE general\nKEY return\nRUN calc.exe");
        var model = rig.Model;
        model.NewEmptyRecording("Blank");
        await model.DraftWithAiAsync("open the general channel");
        Check.True(model.HasDraft);
        Check.Equal(0, model.ActionCount);
        Check.True(model.InsertDraft(null));
        Check.Equal(4, model.ActionCount);
        Check.False(model.HasDraft);
        Check.True(model.Current!.Actions.All(a => a.Kind is ActionKind.Key or ActionKind.Wait or ActionKind.Text));
    }

    [Test]
    public static async Task AiNameIsOnlyAppliedWhenAccepted()
    {
        using var rig = AiRig(_ => "\"Open general channel.\"");
        var model = Recorded(rig);
        var old = model.CurrentName;
        await model.SuggestNameWithAiAsync();
        Check.Equal("Open general channel", model.SuggestedName);
        Check.Equal(old, model.CurrentName);
        model.AcceptSuggestedName();
        Check.Equal("Open general channel", model.CurrentName);
        Check.Equal("", model.SuggestedName);
    }

    [Test]
    public static async Task AiFailureIsReportedWithoutBreakingTheApp()
    {
        using var rig = new ModelRig();
        rig.AiFactory = s => new AiAssistant(() => rig.Model.Settings, _ => new ThrowingHandler());
        rig.Model.Dispose();
        rig.Model = rig.Create();
        var model = Recorded(rig);
        var seen = new List<NoticeKind>();
        model.NoticeShown += (k, _) => seen.Add(k);
        await model.ReviewWithAiAsync();
        Check.True(seen.Contains(NoticeKind.Warning));
        Check.False(model.AiBusy);
        Check.True(model.CanPlay);
    }

    [Test]
    public static void AiEndpointMustStayOnThisComputer()
    {
        var s = new AppSettings { AiEndpoint = "https://evil.example.com" }.Sanitized();
        Check.Equal(AiDefaults.Endpoint, s.AiEndpoint);
    }

    // ------------------------------------------------------------------ updates

    private static string ReleaseJson(string tag, string installer, string sums) => JsonSerializer.Serialize(new
    {
        tag_name = tag,
        draft = false,
        prerelease = false,
        assets = new object[]
        {
            new { name = UpdateConfig.InstallerAssetName, browser_download_url = installer },
            new { name = UpdateConfig.ChecksumAssetName, browser_download_url = sums },
        },
    });

    [Test]
    public static async Task UpdateCheckReportsANewerVersion()
    {
        var installer = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.InstallerAssetName;
        var sums = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.ChecksumAssetName;
        using var rig = new ModelRig(s => s.AutoDownloadUpdates = false);
        rig.UpdateFactory = () => new UpdateService("0.4.0", new FakeHandler(r => (HttpStatusCode.OK, ReleaseJson("v0.5.0", installer, sums))));
        rig.Model.Dispose();
        rig.Model = rig.Create();
        await rig.Model.CheckForUpdatesAsync(true);
        Check.True(rig.Model.UpdateAvailable);
        Check.True(rig.Model.ShowUpdateBanner);
        Check.False(rig.Model.InstallUpdate(), "nothing installs before it is downloaded");
    }

    [Test]
    public static async Task UpdatesCanBeTurnedOffAndFailuresAreQuiet()
    {
        using var rig = new ModelRig(s => s.CheckForUpdates = false);
        var handler = new FakeHandler(r => (HttpStatusCode.OK, "{}"));
        rig.UpdateFactory = () => new UpdateService("0.4.0", handler);
        rig.Model.Dispose();
        rig.Model = rig.Create();
        await rig.Model.StartBackgroundUpdateCheckAsync(0);
        Check.Equal(0, handler.Requests.Count);

        using var offline = new ModelRig();
        offline.UpdateFactory = () => new UpdateService("0.4.0", new ThrowingHandler());
        offline.Model.Dispose();
        offline.Model = offline.Create();
        await offline.Model.CheckForUpdatesAsync(true);
        Check.False(offline.Model.UpdateAvailable);
        Check.True(offline.Model.UpdateState.Phase == UpdatePhase.Failed);
    }

    // ------------------------------------------------------------------ welcome / setup

    [Test]
    public static async Task SetupRunsFourChecksAndTheBarOnlyMovesForward()
    {
        using var rig = new ModelRig(s => s.HasCompletedWelcome = false);
        rig.AiFactory = s => new AiAssistant(() => rig.Model.Settings, _ => new FakeHandler(r => (HttpStatusCode.OK, Tags)));
        rig.Model.Dispose();
        rig.Model = rig.Create();
        var model = rig.Model;
        model.SetupStageDwellMilliseconds = 0;
        Check.True(model.ShowWelcome);
        var seen = new List<double>();
        model.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppModel.SetupFraction)) seen.Add(model.SetupFraction); };
        await model.RunSetupAsync();
        Check.Equal(4, model.SetupChecks.Count);
        Check.True(model.SetupDone);
        Check.Equal(1.0, model.SetupFraction);
        Check.True(seen.Zip(seen.Skip(1), (a, b) => b >= a).All(x => x), "progress never goes backwards");
        Check.True(seen.Take(seen.Count - 1).All(f => f < 1.0), "the bar is full only after every check");
        Check.True(model.SetupChecks.All(c => c.State == CheckState.Ok), string.Join("; ", model.SetupChecks.Select(c => c.Title + "=" + c.State)));
        model.CompleteWelcome();
        Check.False(model.ShowWelcome);
        using var again = rig.Create();
        Check.False(again.ShowWelcome, "completing the welcome is remembered");
    }

    [Test]
    public static async Task SetupReportsProblemsAsWarningsNotCrashes()
    {
        using var rig = new ModelRig(s => s.HasCompletedWelcome = false);
        rig.Capture.StartError = "hook refused";
        rig.Probe.Build = 10240;
        rig.Probe.Screen = null;
        rig.AiFactory = s => new AiAssistant(() => rig.Model.Settings, _ => new ThrowingHandler());
        rig.Model.Dispose();
        rig.Model = rig.Create();
        rig.Model.SetupStageDwellMilliseconds = 0;
        await rig.Model.RunSetupAsync();
        Check.True(rig.Model.SetupDone);
        Check.True(rig.Model.SetupHasWarnings);
        Check.Equal(4, rig.Model.SetupChecks.Count(c => c.State == CheckState.Warning));
        Check.True(rig.Model.SetupChecks[1].Detail.Contains("hook refused"));
    }

    // ------------------------------------------------------------------ settings

    [Test]
    public static void ChangingTheEmergencyShortcutReRegistersIt()
    {
        using var rig = new ModelRig();
        var s = rig.Model.Settings;
        s.EmergencyStop = new HotKey(0x51, KeyModifiers.Control | KeyModifiers.Shift);
        rig.Model.ApplySettings(s);
        Check.Equal(0x51, rig.HotKey.Last!.KeyCode);
        Check.True(rig.Model.EmergencyStopText.Contains("Q"));
        using var again = rig.Create();
        Check.Equal(0x51, again.Settings.EmergencyStop.KeyCode);
    }

    [Test]
    public static void ShortcutConflictIsReported()
    {
        using var rig = new ModelRig();
        rig.HotKey.Accept = false;
        using var model = rig.Create();
        Check.True(model.Notice.Contains("used by another program"), "Notice was: " + model.Notice);
        Check.Equal(NoticeKind.Warning, model.NoticeKind);
    }

    [Test]
    public static void MovingTheSaveFolderReloadsTheList()
    {
        using var rig = new ModelRig();
        Recorded(rig);
        var other = Path.Combine(rig.Root, "elsewhere");
        var s = rig.Model.Settings;
        s.SaveDirectoryPath = other;
        rig.Model.ApplySettings(s);
        Check.Equal(0, rig.Model.Recordings.Count);
        Check.Equal(other, rig.Model.RecordingsFolder);
    }
}
