using ActionRecorder.Core;

namespace ActionRecorder.Tests;

public static class TimingTests
{
    [Test]
    public static void SpeedIsClamped()
    {
        Check.Equal(1.0, PlaybackTiming.ClampSpeed(double.NaN));
        Check.Equal(1.0, PlaybackTiming.ClampSpeed(0));
        Check.Equal(1.0, PlaybackTiming.ClampSpeed(-3));
        Check.Equal(PlaybackTiming.MinSpeed, PlaybackTiming.ClampSpeed(0.0001));
        Check.Equal(PlaybackTiming.MaxSpeed, PlaybackTiming.ClampSpeed(1000));
        Check.Equal(2.5, PlaybackTiming.ClampSpeed(2.5));
    }

    [Test]
    public static void PresetsAndFormatting()
    {
        Check.Equal(6, SpeedPreset.All.Length);
        Check.Equal("2× — Double speed", SpeedPreset.Describe(2.0));
        Check.Equal("0.25× — Very slow", SpeedPreset.Describe(0.25));
        Check.Equal("3.25× (custom)", SpeedPreset.Describe(3.25));
        Check.Equal("5×", PlaybackTiming.FormatSpeed(5));
        Check.Equal("1.5×", PlaybackTiming.FormatSpeed(1.5));
        Check.Equal("0.33×", PlaybackTiming.FormatSpeed(1.0 / 3));
    }

    [Test]
    public static void DelaysScaleWithSpeed()
    {
        var config = new PlaybackConfig { Speed = 2 };
        Check.Near(0.5, PlaybackTiming.ScaledDelay(Act.Move(1, 1, delay: 1.0), config));
        config.Speed = 0.5;
        Check.Near(2.0, PlaybackTiming.ScaledDelay(Act.Move(1, 1, delay: 1.0), config));
        config.Speed = 1;
        Check.Near(1.0, PlaybackTiming.ScaledDelay(Act.Click(1, 1, delay: 1.0), config));
    }

    [Test]
    public static void WaitContributesItsDuration()
    {
        var config = new PlaybackConfig { Speed = 2 };
        Check.Near(1.25, PlaybackTiming.ScaledDelay(Act.Wait(2.0, delay: 0.5), config));
    }

    [Test]
    public static void MinimumDelayFloorAppliesOnlyAboveOneTimes()
    {
        var config = new PlaybackConfig { Speed = 20, MinActionDelay = 0.02 };
        // 0.1 s recorded at 20x would be 0.005 s; the floor lifts click gaps to 0.02 s.
        Check.Near(0.02, PlaybackTiming.ScaledDelay(Act.Click(1, 1, delay: 0.1), config));
        // ...but never above the recorded gap.
        Check.Near(0.01, PlaybackTiming.ScaledDelay(Act.Click(1, 1, delay: 0.01), config));
        // Movement and waits are not floored.
        Check.Near(0.005, PlaybackTiming.ScaledDelay(Act.Move(1, 1, delay: 0.1), config));
        Check.Near(0.005, PlaybackTiming.ScaledDelay(Act.Wait(0.1), config));
        // At or below 1x there is no floor.
        config.Speed = 1;
        Check.Near(0.01, PlaybackTiming.ScaledDelay(Act.Click(1, 1, delay: 0.01), config));
        config.Speed = 0.5;
        Check.Near(0.02, PlaybackTiming.ScaledDelay(Act.Click(1, 1, delay: 0.01), config));
    }

    [Test]
    public static void NegativeDelaysAreTreatedAsZero()
    {
        var config = new PlaybackConfig();
        Check.Equal(0.0, PlaybackTiming.ScaledDelay(Act.Click(1, 1, delay: -5), config));
    }

    [Test]
    public static void TypingDelayHasAFloor()
    {
        var config = new PlaybackConfig { Speed = 1, TypingCharDelay = 0.012, MinTypingCharDelay = 0.004 };
        Check.Near(0.012, PlaybackTiming.TypingDelay(config));
        config.Speed = 20;
        Check.Near(0.004, PlaybackTiming.TypingDelay(config));
        config.Speed = 0.25;
        Check.Near(0.048, PlaybackTiming.TypingDelay(config));
    }

    [Test]
    public static void EstimatesIncludeTypingAndRepeats()
    {
        var actions = new List<MacroAction> { Act.Click(1, 1, delay: 1), Act.Text("abcd", delay: 1) };
        var config = new PlaybackConfig { Speed = 1, TypingCharDelay = 0.1, MinTypingCharDelay = 0.0 };
        // 1 + 1 + 3 gaps * 0.1
        Check.Near(2.3, PlaybackTiming.EstimatedDuration(actions, config), 1e-9);
        config.RepeatCount = 3;
        config.LoopDelay = 2;
        config.Countdown = 5;
        Check.Near(2.3 * 3 + 4 + 5, PlaybackTiming.EstimatedTotal(actions, config)!.Value, 1e-9);
        config.Infinite = true;
        Check.True(PlaybackTiming.EstimatedTotal(actions, config) == null);
        Check.True(PlaybackTiming.TotalIterations(config) == null);
        config.Infinite = false;
        config.RepeatCount = 0;
        Check.Equal(1, PlaybackTiming.TotalIterations(config)!.Value);
    }

    [Test]
    public static void TypingEstimateCountsEmojiAsOneCharacter()
    {
        var actions = new List<MacroAction> { Act.Text("a😀") };
        var config = new PlaybackConfig { Speed = 1, TypingCharDelay = 0.1, MinTypingCharDelay = 0.0 };
        Check.Near(0.1, PlaybackTiming.EstimatedDuration(actions, config), 1e-9);
    }

    [Test]
    public static void OriginalDurationAddsDelaysAndWaits()
    {
        var r = new Recording("t");
        r.Actions.Add(Act.Click(1, 1, delay: 0.5));
        r.Actions.Add(Act.Wait(2, delay: 0.25));
        Check.Near(2.75, r.OriginalDuration);
    }
}
