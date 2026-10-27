using System.Diagnostics;
using ActionRecorder.Core;

namespace ActionRecorder.Tests;

public static class EngineTests
{
    private static Recording Make(params MacroAction[] actions)
    {
        var r = new Recording("t");
        r.Actions.AddRange(actions);
        return r;
    }

    private static bool WaitFor(Func<bool> condition, double seconds = 5)
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed.TotalSeconds < seconds)
        {
            if (condition()) return true;
            Thread.Sleep(2);
        }
        return condition();
    }

    private static PlaybackEngine NewEngine(FakePerformer performer, Func<string?>? foreground = null) => new(performer, foreground);

    [Test]
    public static void PlaysEverythingInOrder()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        var states = new List<PlaybackPhase>();
        engine.OnEvent = e => { if (e.Kind == PlaybackEventKind.StateChanged) lock (states) states.Add(e.State.Phase); };
        engine.Start(Make(Act.Click(1, 1), Act.Key(KeyCodes.Return), Act.Move(5, 5), Act.Scroll(0, -120)), new PlaybackConfig());
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished), "should finish");
        Check.SequenceEqual(new[] { ActionKind.Click, ActionKind.Key, ActionKind.Move, ActionKind.Scroll }, performer.Performed.Select(a => a.Kind));
        Check.Equal(1, performer.Begins);
        Check.True(WaitFor(() => performer.Cleanups == 1), "cleanup runs once");
        Check.Equal(PlaybackPhase.Playing, states[0]);
        Check.Equal(PlaybackPhase.Finished, states[^1]);
    }

    [Test]
    public static void TextIsTypedOneCharacterAtATime()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Text("hi😀")), new PlaybackConfig { Speed = 20 });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.SequenceEqual(new[] { "h", "i", "😀" }, performer.Performed.Select(a => a.Text!));
    }

    [Test]
    public static void RepeatCountRunsThatManyPasses()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        var iterations = new List<int>();
        engine.OnEvent = e => { if (e.Kind == PlaybackEventKind.IterationStarted) lock (iterations) iterations.Add(e.Iteration); };
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2)), new PlaybackConfig { RepeatCount = 3 });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.Equal(6, performer.Count);
        Check.SequenceEqual(new[] { 1, 2, 3 }, iterations);
    }

    [Test]
    public static void ProgressReachesOne()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        var last = (PlaybackProgress?)null;
        engine.OnEvent = e => { if (e.Kind == PlaybackEventKind.Progress) last = e.Progress; };
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2)), new PlaybackConfig { RepeatCount = 2 });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.Near(1.0, last!.Fraction!.Value, 1e-9);
        Check.Equal(2, last.Iteration);
        Check.Equal(1, last.ActionIndex);
    }

    [Test]
    public static void LoopDelayIsAppliedBetweenRepetitions()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        var sw = Stopwatch.StartNew();
        engine.Start(Make(Act.Click(1, 1)), new PlaybackConfig { RepeatCount = 3, LoopDelay = 0.15 });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.True(sw.Elapsed.TotalSeconds >= 0.29, $"two loop delays expected, took {sw.Elapsed.TotalSeconds:0.000}");
    }

    [Test]
    public static void SpeedChangesTotalTime()
    {
        double Run(double speed)
        {
            var performer = new FakePerformer();
            var engine = NewEngine(performer);
            var sw = Stopwatch.StartNew();
            engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2, delay: 0.4)), new PlaybackConfig { Speed = speed, MinActionDelay = 0 });
            WaitFor(() => engine.State.Phase == PlaybackPhase.Finished);
            return sw.Elapsed.TotalSeconds;
        }
        var slow = Run(1);
        var fast = Run(4);
        Check.True(slow >= 0.38, $"1x took {slow:0.000}");
        Check.True(fast < slow * 0.6, $"4x ({fast:0.000}) should be much faster than 1x ({slow:0.000})");
    }

    [Test]
    public static void StopCancelsPendingActionsImmediately()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2, delay: 30), Act.Click(3, 3)), new PlaybackConfig());
        Check.True(WaitFor(() => performer.Count == 1));
        var sw = Stopwatch.StartNew();
        engine.Stop();
        Check.Equal(PlaybackPhase.Stopped, engine.State.Phase);
        Check.True(WaitFor(() => performer.Cleanups == 1, 1), "cleanup runs promptly after stop");
        Check.True(sw.Elapsed.TotalSeconds < 1, "stop must not wait for the 30 s delay");
        Thread.Sleep(50);
        Check.Equal(1, performer.Count);
    }

    [Test]
    public static void StopDuringATextRunStopsTyping()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        performer.OnPerform = a => { if (performer.Count == 3) engine.Stop(); };
        engine.Start(Make(Act.Text(new string('x', 200))), new PlaybackConfig { Speed = 1, MinTypingCharDelay = 0.001, TypingCharDelay = 0.001 });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Stopped));
        Thread.Sleep(100);
        Check.True(performer.Count <= 4, $"typed {performer.Count} characters after stop");
    }

    [Test]
    public static void InfiniteLoopRunsUntilStopped()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1, delay: 0.01)), new PlaybackConfig { Infinite = true, MinActionDelay = 0 });
        Check.True(WaitFor(() => performer.Count >= 5), "loops repeatedly");
        Check.True(engine.State.IsActive);
        engine.Stop();
        Thread.Sleep(50);
        var after = performer.Count;
        Thread.Sleep(100);
        Check.Equal(after, performer.Count);
    }

    [Test]
    public static void PauseHoldsActionsAndResumeContinues()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2, delay: 0.2), Act.Click(3, 3)), new PlaybackConfig());
        Check.True(WaitFor(() => performer.Count == 1));
        engine.Pause();
        Check.Equal(PlaybackPhase.Paused, engine.State.Phase);
        Thread.Sleep(400);
        Check.Equal(1, performer.Count);
        engine.Resume();
        Check.Equal(PlaybackPhase.Playing, engine.State.Phase);
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.Equal(3, performer.Count);
    }

    [Test]
    public static void PausedTimeDoesNotCountAgainstADelay()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2, delay: 0.3)), new PlaybackConfig());
        Check.True(WaitFor(() => performer.Count == 1));
        Thread.Sleep(100);
        engine.Pause();
        Thread.Sleep(500);
        var sw = Stopwatch.StartNew();
        engine.Resume();
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.True(sw.Elapsed.TotalSeconds >= 0.15, $"the rest of the delay should still be waited, only {sw.Elapsed.TotalSeconds:0.000}");
    }

    [Test]
    public static void StopWhilePausedWorks()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2, delay: 10)), new PlaybackConfig());
        Check.True(WaitFor(() => performer.Count == 1));
        engine.Pause();
        engine.Stop();
        Check.Equal(PlaybackPhase.Stopped, engine.State.Phase);
        Check.True(WaitFor(() => performer.Cleanups == 1, 1));
    }

    [Test]
    public static void CountdownRunsBeforeTheFirstAction()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        var countdowns = new List<int>();
        engine.OnEvent = e =>
        {
            if (e.Kind == PlaybackEventKind.StateChanged && e.State.Phase == PlaybackPhase.Countdown) lock (countdowns) countdowns.Add(e.State.Seconds);
        };
        var sw = Stopwatch.StartNew();
        engine.Start(Make(Act.Click(1, 1)), new PlaybackConfig { Countdown = 2 });
        Check.Equal(PlaybackPhase.Countdown, engine.State.Phase);
        Check.Equal(0, performer.Count);
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished, 6));
        Check.True(sw.Elapsed.TotalSeconds >= 1.9, $"countdown took {sw.Elapsed.TotalSeconds:0.00}");
        Check.SequenceEqual(new[] { 2, 1 }, countdowns);
    }

    [Test]
    public static void StopDuringCountdownPerformsNothing()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1)), new PlaybackConfig { Countdown = 5 });
        Thread.Sleep(50);
        engine.Stop();
        Thread.Sleep(100);
        Check.Equal(0, performer.Count);
        Check.Equal(PlaybackPhase.Stopped, engine.State.Phase);
    }

    [Test]
    public static void SelectedSectionPlaysOnly()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        var indices = new List<int>();
        engine.OnEvent = e => { if (e.Kind == PlaybackEventKind.ActionStarted) lock (indices) indices.Add(e.Index); };
        engine.Start(Make(Act.Text("a"), Act.Click(1, 1), Act.Click(2, 2), Act.Text("d")), new PlaybackConfig { Range = (1, 3) });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.SequenceEqual(new[] { 1, 2 }, indices);
        Check.Equal(2, performer.Count);
    }

    [Test]
    public static void InvalidInputIsRefused()
    {
        var engine = NewEngine(new FakePerformer());
        Check.Throws<PlaybackException>(() => engine.Start(Make(), new PlaybackConfig()));
        Check.Throws<PlaybackException>(() => engine.Start(Make(Act.Click(1, 1)), new PlaybackConfig { Range = (5, 9) }));
        Check.Throws<PlaybackException>(() => engine.Start(Make(new MacroAction { Kind = ActionKind.Key }), new PlaybackConfig()));
        Check.Throws<PlaybackException>(() => engine.Restart());
    }

    [Test]
    public static void ForegroundCheckStopsPlayback()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer, () => "notepad.exe");
        engine.Start(Make(Act.Click(1, 1)), new PlaybackConfig { RequiredBundleId = "discord.exe", RequiredAppName = "Discord" });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Failed));
        Check.True(engine.State.Message!.Contains("Discord"));
        Check.Equal(0, performer.Count);
    }

    [Test]
    public static void ForegroundCheckPassesWhenTheProgramMatches()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer, () => "Discord.exe");
        engine.Start(Make(Act.Click(1, 1)), new PlaybackConfig { RequiredBundleId = "discord.exe" });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.Equal(1, performer.Count);
    }

    [Test]
    public static void ForegroundLossMidRunStopsBeforeTheNextAction()
    {
        var performer = new FakePerformer();
        var current = "discord.exe";
        var engine = NewEngine(performer, () => current);
        performer.OnPerform = _ => current = "other.exe";
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2, delay: 0.05), Act.Click(3, 3)), new PlaybackConfig { RequiredBundleId = "discord.exe" });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Failed));
        Check.Equal(1, performer.Count);
    }

    [Test]
    public static void PerformerErrorsFailThePlayback()
    {
        var performer = new FakePerformer { OnPerform = _ => throw new InvalidOperationException("boom") };
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2)), new PlaybackConfig());
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Failed));
        Check.Equal("boom", engine.State.Message);
        Check.True(WaitFor(() => performer.Cleanups == 1));
    }

    [Test]
    public static void RestartRunsFromTheBeginning()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1), Act.Click(2, 2)), new PlaybackConfig());
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        engine.Restart();
        Check.True(WaitFor(() => performer.Count == 4 && engine.State.Phase == PlaybackPhase.Finished));
    }

    [Test]
    public static void StartingAgainCancelsTheOldRun()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        engine.Start(Make(Act.Click(1, 1), Act.Click(9, 9, delay: 30)), new PlaybackConfig());
        Check.True(WaitFor(() => performer.Count == 1));
        engine.Start(Make(Act.Key(KeyCodes.Return)), new PlaybackConfig());
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.Equal(2, performer.Count);
        Check.True(WaitFor(() => performer.Cleanups == 2));
    }

    [Test]
    public static void EditingTheRecordingWhilePlayingDoesNotChangeTheRun()
    {
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        var recording = Make(Act.Click(1, 1), Act.Text("x", delay: 0.2));
        engine.Start(recording, new PlaybackConfig());
        recording.Actions[1].Text = "CHANGED";
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.Equal("x", performer.Performed[^1].Text);
    }

    [Test]
    public static void MouseMovementKeepsUpWithSpeed()
    {
        // 50 moves, 10 ms apart at 1x = 0.5 s. At 5x it must take well under 0.3 s even with timer overshoot.
        var actions = new List<MacroAction>();
        for (var i = 0; i < 50; i++) actions.Add(Act.Move(i, i, delay: 0.01));
        var performer = new FakePerformer();
        var engine = NewEngine(performer);
        var sw = Stopwatch.StartNew();
        var r = new Recording("m");
        r.Actions.AddRange(actions);
        engine.Start(r, new PlaybackConfig { Speed = 5 });
        Check.True(WaitFor(() => engine.State.Phase == PlaybackPhase.Finished));
        Check.True(sw.Elapsed.TotalSeconds < 0.45, $"took {sw.Elapsed.TotalSeconds:0.000}");
        Check.Equal(50, performer.Count);
    }
}
