using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Desktop;

/// <summary>
/// Real-input checks for CI (and for anyone who wants to confirm the app works on their PC):
/// `ActionRecorder.exe --selftest --out result.txt`.
/// It starts a small test window in a second process, drives it with the same SendInput code that playback uses,
/// records that input with the same hooks that recording uses, then replays the recording into a fresh window.
/// </summary>
internal static class SelfTest
{
    private sealed record TargetState(string Text, int Clicks, double BoxX, double BoxY, double BtnX, double BtnY);

    private sealed class TargetHandle : IDisposable
    {
        public required Process Process { get; init; }
        public required string StatePath { get; init; }

        public TargetState? Read()
        {
            try
            {
                using var stream = new FileStream(StatePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var doc = JsonDocument.Parse(stream);
                var root = doc.RootElement;
                if (!root.GetProperty("ready").GetBoolean()) return null;
                return new TargetState(
                    root.GetProperty("text").GetString() ?? "",
                    root.GetProperty("clicks").GetInt32(),
                    root.GetProperty("boxX").GetDouble(), root.GetProperty("boxY").GetDouble(),
                    root.GetProperty("btnX").GetDouble(), root.GetProperty("btnY").GetDouble());
            }
            catch (Exception)
            {
                return null;
            }
        }

        public async Task<TargetState?> WaitReadyAsync(int seconds)
        {
            var end = DateTime.UtcNow.AddSeconds(seconds);
            while (DateTime.UtcNow < end)
            {
                if (Process.HasExited) return null;
                var state = Read();
                if (state != null) return state;
                await Task.Delay(100);
            }
            return null;
        }

        public void Dispose()
        {
            try
            {
                if (!Process.HasExited) Process.Kill(true);
            }
            catch (Exception)
            {
            }
            Process.Dispose();
        }
    }

    public static async Task<int> RunAsync(string? outPath)
    {
        var report = new Report(outPath);
        try
        {
            await RunAllAsync(report);
        }
        catch (Exception ex)
        {
            report.Fail("The self-test itself crashed", ex.ToString());
        }
        report.Info($"{report.Passes} passed, {report.Failures} failed");
        return report.Failures == 0 ? 0 : 1;
    }

    private static async Task RunAllAsync(Report report)
    {
        // 1 — Windows queries
        var screen = Win32Info.PrimaryScreen();
        var monitors = Win32Info.Monitors();
        report.Check(screen != null && monitors.Count > 0, "Display and system queries work",
            "No screen was reported.",
            $"{Win32Info.WindowsDescription()}; {screen?.Width}×{screen?.Height}; {monitors.Count} monitor(s); elevated={Win32Info.IsSelfElevated()}");

        // 2 — emergency stop hotkey, triggered by real key input
        using (var hotKey = new HotKeyService())
        {
            var pressed = new ManualResetEventSlim();
            hotKey.Pressed += () => pressed.Set();
            var combo = new HotKey(0x7A, KeyModifiers.Control | KeyModifiers.Option | KeyModifiers.Shift);
            var registered = hotKey.Set(combo);
            report.Check(registered, "Emergency-stop shortcut registers", $"RegisterHotKey failed (Windows error {hotKey.LastError}).");
            if (registered)
            {
                var performer = new SendInputPerformer();
                performer.Begin();
                try
                {
                    performer.Perform(Act.Key(combo.KeyCode, combo.Modifiers));
                }
                finally
                {
                    performer.Cleanup();
                }
                report.Check(pressed.Wait(4000), "Emergency-stop shortcut fires from real key input", "The shortcut did not fire within 4 seconds.");
            }
        }

        // 3 — live input into a test window, recorded at the same time
        List<MacroAction>? recorded = null;
        using (var target = await LaunchAsync(report, "test window 1"))
        {
            if (target != null)
            {
                var state = await target.WaitReadyAsync(25);
                if (state == null)
                {
                    report.Fail("Test window opens", "The test window did not become ready.");
                }
                else
                {
                    report.Pass("Test window opens", $"text box at ({state.BoxX:0},{state.BoxY:0}), button at ({state.BtnX:0},{state.BtnY:0})");
                    using var recorder = new InputRecorder();
                    var startError = recorder.Start(null, includeInjected: true);
                    report.Check(startError == null, "Recording hooks install", startError ?? "");

                    var macro = TypeAndClick(state, "hello 42");
                    var result = await RunMacroAsync(macro, 1.0, 40);
                    report.Check(result.Phase == PlaybackPhase.Finished, "Playback of a click-and-type macro finishes", $"Ended as {result.Phase}: {result.Message}");

                    await Task.Delay(400);
                    var events = startError == null ? recorder.Stop() : new List<RawEvent>();
                    var after = target.Read();
                    report.Check(after != null && after.Text == "hello 42", "Typed text reached the window",
                        $"The window contains “{after?.Text}”.", "hello 42");
                    report.Check(after != null && after.Clicks == 1, "Button click reached the window", $"Click count was {after?.Clicks}.");

                    recorded = RecordingBuilder.Build(events, new RecordingOptions());
                    var clickNearBox = recorded.Any(a => a.Kind == ActionKind.Click && Near(a, state.BoxX, state.BoxY));
                    var clickNearButton = recorded.Any(a => a.Kind == ActionKind.Click && Near(a, state.BtnX, state.BtnY));
                    var typed = recorded.Where(a => a.Kind == ActionKind.Text).Select(a => a.Text).FirstOrDefault(t => t != null && t.Contains("hello 42"));
                    report.Check(clickNearBox, "Recorder captured the click in the text box", Describe(recorded));
                    report.Check(typed != null, "Recorder captured the typed text", Describe(recorded));
                    report.Check(clickNearButton, "Recorder captured the button click", Describe(recorded));
                }
            }
        }

        // 4 — replay what was recorded into a fresh window, at 1× and at 5×
        if (recorded != null && recorded.Count > 0)
        {
            foreach (var speed in new[] { 1.0, 5.0 })
            {
                using var target = await LaunchAsync(report, $"replay window ({speed:0.#}×)");
                if (target == null) continue;
                var state = await target.WaitReadyAsync(25);
                if (state == null)
                {
                    report.Fail($"Replay window opens ({speed:0.#}×)", "The window did not become ready.");
                    continue;
                }
                var replay = new Recording("replay");
                replay.Actions.AddRange(recorded.Select(a => a.Copy(newId: true)));
                var result = await RunMacroAsync(replay, speed, 40);
                await Task.Delay(300);
                var after = target.Read();
                report.Check(result.Phase == PlaybackPhase.Finished && after != null && after.Text == "hello 42" && after.Clicks == 1,
                    $"Replaying the recording reproduces the result at {speed:0.#}×",
                    $"phase={result.Phase} {result.Message}; text=“{after?.Text}” clicks={after?.Clicks}");
            }
        }
        else
        {
            report.Fail("Replay of the recording", "Nothing was recorded, so there was nothing to replay.");
        }

        // 5 — Unicode text (accents, symbols, emoji) typed without a matching key on the keyboard
        using (var target = await LaunchAsync(report, "unicode window"))
        {
            var state = target == null ? null : await target.WaitReadyAsync(25);
            if (target != null && state != null)
            {
                const string text = "Héllo ✓ 😀 ñ";
                var macro = new Recording("unicode");
                macro.Actions.Add(Act.Click(state.BoxX, state.BoxY, delay: 0.4));
                macro.Actions.Add(Act.Text(text, delay: 0.2));
                var result = await RunMacroAsync(macro, 1.0, 30);
                await Task.Delay(300);
                var after = target.Read();
                report.Check(result.Phase == PlaybackPhase.Finished && after?.Text == text, "Unicode text types correctly",
                    $"phase={result.Phase}; window contains “{after?.Text}”.", text);
            }
            else
            {
                report.Fail("Unicode text types correctly", "The test window did not start.");
            }
        }

        // 6 — stop is immediate
        {
            var performed = 0;
            var counting = new CountingPerformer(new SendInputPerformer(), () => Interlocked.Increment(ref performed));
            var engine = new PlaybackEngine(counting, Win32Info.ForegroundProgramFileName);
            var stopped = new TaskCompletionSource<DateTime>();
            engine.OnEvent = e =>
            {
                if (e.Kind == PlaybackEventKind.StateChanged && e.State.Phase is PlaybackPhase.Stopped or PlaybackPhase.Finished or PlaybackPhase.Failed)
                {
                    stopped.TrySetResult(DateTime.UtcNow);
                }
            };
            var longWait = new Recording("long wait");
            longWait.Actions.Add(Act.Wait(60));
            longWait.Actions.Add(Act.Key(KeyCodes.F1)); // must never run
            engine.Start(longWait, new PlaybackConfig());
            await Task.Delay(400);
            var asked = DateTime.UtcNow;
            engine.Stop();
            var done = await Task.WhenAny(stopped.Task, Task.Delay(2000));
            var elapsed = done == stopped.Task ? (stopped.Task.Result - asked).TotalMilliseconds : double.PositiveInfinity;
            await Task.Delay(300);
            report.Check(elapsed < 1000 && performed == 0, "Stop ends a 60-second wait at once and nothing runs afterwards",
                $"stopped after {elapsed:0} ms; {performed} action(s) ran after the stop.", $"{elapsed:0} ms");
        }
    }

    private static bool Near(MacroAction action, double x, double y) =>
        action.X is double ax && action.Y is double ay && Math.Abs(ax - x) <= 3 && Math.Abs(ay - y) <= 3;

    private static string Describe(List<MacroAction> actions) =>
        "Recorded: " + (actions.Count == 0 ? "(nothing)" : string.Join(" | ", actions.Take(14).Select(ActionDescriber.Describe)));

    private static Recording TypeAndClick(TargetState state, string text)
    {
        var macro = new Recording("selftest");
        macro.Actions.Add(Act.Click(state.BoxX, state.BoxY, delay: 0.5));
        foreach (var c in text)
        {
            var vk = c == ' ' ? KeyCodes.Space : char.ToUpperInvariant(c);
            macro.Actions.Add(Act.Key(vk, delay: 0.06));
        }
        macro.Actions.Add(Act.Key(KeyCodes.Tab, delay: 0.15));
        macro.Actions.Add(Act.Click(state.BtnX, state.BtnY, delay: 0.25));
        return macro;
    }

    private static async Task<PlaybackState> RunMacroAsync(Recording recording, double speed, int timeoutSeconds)
    {
        var engine = new PlaybackEngine(new SendInputPerformer(), Win32Info.ForegroundProgramFileName);
        var done = new TaskCompletionSource<PlaybackState>();
        engine.OnEvent = e =>
        {
            if (e.Kind == PlaybackEventKind.StateChanged && e.State.Phase is PlaybackPhase.Finished or PlaybackPhase.Stopped or PlaybackPhase.Failed)
            {
                done.TrySetResult(e.State);
            }
        };
        try
        {
            engine.Start(recording, new PlaybackConfig { Speed = speed });
        }
        catch (PlaybackException ex)
        {
            return PlaybackState.Failed(ex.Message);
        }
        var finished = await Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromSeconds(timeoutSeconds)));
        if (finished != done.Task)
        {
            engine.Stop();
            return PlaybackState.Failed("Timed out.");
        }
        return done.Task.Result;
    }

    private static async Task<TargetHandle?> LaunchAsync(Report report, string name)
    {
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "ar-selftest-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            var statePath = Path.Combine(dir, "state.json");
            var exe = Environment.ProcessPath ?? "ActionRecorder.exe";
            var arguments = $"--selftest-target \"{statePath}\"";
            if (Path.GetFileNameWithoutExtension(exe).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            {
                arguments = $"\"{Assembly.GetEntryAssembly()?.Location}\" " + arguments;
            }
            var info = new ProcessStartInfo(exe, arguments) { UseShellExecute = false };
            info.Environment["ACTION_RECORDER_DATA"] = dir;
            var process = Process.Start(info);
            if (process == null)
            {
                report.Fail($"Start {name}", "The process did not start.");
                return null;
            }
            await Task.Yield();
            return new TargetHandle { Process = process, StatePath = statePath };
        }
        catch (Exception ex)
        {
            report.Fail($"Start {name}", ex.Message);
            return null;
        }
    }

    private sealed class CountingPerformer : IActionPerformer
    {
        private readonly IActionPerformer _inner;
        private readonly Action _onPerform;

        public CountingPerformer(IActionPerformer inner, Action onPerform)
        {
            _inner = inner;
            _onPerform = onPerform;
        }

        public void Begin() => _inner.Begin();

        public void Perform(MacroAction action)
        {
            _onPerform();
            _inner.Perform(action);
        }

        public void Cleanup() => _inner.Cleanup();
    }
}

/// <summary>The window that the self-test types and clicks into. Runs in its own process so the recorder does not ignore it as "our own window".</summary>
internal sealed class SelfTestTarget : Window
{
    private readonly string _statePath;
    private readonly TextBox _box = new() { FontSize = 26, Height = 64, Margin = new Thickness(24, 24, 24, 12), VerticalContentAlignment = VerticalAlignment.Center };
    private readonly Button _button = new() { Content = "Click me", FontSize = 22, Height = 64, Margin = new Thickness(24, 0, 24, 24) };
    private int _clicks;

    public SelfTestTarget(string statePath)
    {
        _statePath = statePath;
        Title = "Action Recorder self-test window";
        Width = 560;
        Height = 300;
        Left = 40;
        Top = 40;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        var panel = new StackPanel();
        panel.Children.Add(_box);
        panel.Children.Add(_button);
        Content = panel;
        _box.TextChanged += (_, _) => Write();
        _button.Click += (_, _) =>
        {
            _clicks++;
            Write();
        };
        ContentRendered += (_, _) =>
        {
            Activate();
            _box.Focus();
            Write();
        };
        LocationChanged += (_, _) => Write();
    }

    private void Write()
    {
        try
        {
            UpdateLayout();
            var box = _box.PointToScreen(new Point(_box.ActualWidth / 2, _box.ActualHeight / 2));
            var button = _button.PointToScreen(new Point(_button.ActualWidth / 2, _button.ActualHeight / 2));
            var json = JsonSerializer.Serialize(new
            {
                ready = true,
                text = _box.Text,
                clicks = _clicks,
                boxX = box.X,
                boxY = box.Y,
                btnX = button.X,
                btnY = button.Y,
            });
            var temp = _statePath + ".tmp";
            File.WriteAllText(temp, json);
            File.Move(temp, _statePath, true);
        }
        catch (Exception)
        {
            // The test reads the file again on its next poll.
        }
    }
}
