namespace ActionRecorder.Core;

/// <summary>Everything the playback engine needs to know about how to run a recording.</summary>
public sealed class PlaybackConfig
{
    /// <summary>1.0 = original timing. Clamped to MinSpeed..MaxSpeed.</summary>
    public double Speed { get; set; } = 1.0;
    /// <summary>Number of times to play (ignored when Infinite). Values below 1 are treated as 1.</summary>
    public int RepeatCount { get; set; } = 1;
    /// <summary>Loop until stopped.</summary>
    public bool Infinite { get; set; }
    /// <summary>Pause between repetitions, in seconds (not scaled by speed).</summary>
    public double LoopDelay { get; set; }
    /// <summary>Seconds to count down before the first action.</summary>
    public int Countdown { get; set; }
    /// <summary>Lower bound for gaps between non-movement actions when playing faster than 1x,
    /// so the UI has time to react. It never makes a gap longer than the recorded one.</summary>
    public double MinActionDelay { get; set; } = 0.02;
    /// <summary>Time between typed characters at 1x.</summary>
    public double TypingCharDelay { get; set; } = 0.012;
    /// <summary>Fastest allowed typing, regardless of speed.</summary>
    public double MinTypingCharDelay { get; set; } = 0.004;
    /// <summary>If set, playback fails unless this program (file name, e.g. discord.exe) is in front.</summary>
    public string? RequiredBundleId { get; set; }
    public string? RequiredAppName { get; set; }
    /// <summary>Replay only these action indices (a "selected section"): Start inclusive, End exclusive.</summary>
    public (int Start, int End)? Range { get; set; }
}

public sealed record SpeedPreset(double Value, string Label, string Detail)
{
    public static readonly SpeedPreset[] All =
    {
        new(0.25, "0.25×", "Very slow"),
        new(0.5, "0.5×", "Slow"),
        new(1.0, "1×", "Original timing"),
        new(1.5, "1.5×", "Faster"),
        new(2.0, "2×", "Double speed"),
        new(5.0, "5×", "Very fast"),
    };

    /// <summary>"2× — Double speed" for presets, "3.25× (custom)" otherwise.</summary>
    public static string Describe(double speed)
    {
        var preset = All.FirstOrDefault(p => Math.Abs(p.Value - speed) < 0.0001);
        return preset != null ? $"{preset.Label} — {preset.Detail}" : PlaybackTiming.FormatSpeed(speed) + " (custom)";
    }
}

public static class PlaybackTiming
{
    public const double MinSpeed = 0.05;
    public const double MaxSpeed = 20.0;

    public static double ClampSpeed(double speed)
    {
        if (double.IsNaN(speed) || speed <= 0) return 1.0;
        return Math.Min(Math.Max(speed, MinSpeed), MaxSpeed);
    }

    public static string FormatSpeed(double speed)
    {
        var rounded = Math.Round(speed * 100, MidpointRounding.AwayFromZero) / 100;
        if (rounded == Math.Round(rounded))
        {
            return $"{(int)rounded}×";
        }
        return rounded.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture) + "×";
    }

    /// <summary>Kinds that need the target app to be in front (pointer moves and waits do not).</summary>
    public static bool RequiresForeground(ActionKind kind) => kind != ActionKind.Move && kind != ActionKind.Wait;

    /// <summary>Seconds to wait before performing the action at the configured speed.</summary>
    /// <remarks>
    /// Recorded delays are divided by the speed, so order is preserved and all gaps scale consistently
    /// (movement included). Above 1x, gaps before clicks/keys/text/scrolls are never shorter than
    /// min(recorded gap, MinActionDelay) so slow-reacting UI stays reliable. A wait action contributes
    /// its duration, scaled the same way.
    /// </remarks>
    public static double ScaledDelay(MacroAction action, PlaybackConfig config)
    {
        var speed = ClampSpeed(config.Speed);
        var baseDelay = Math.Max(0, action.Delay);
        if (action.Kind == ActionKind.Wait)
        {
            baseDelay += Math.Max(0, action.Duration ?? 0);
        }
        var scaled = baseDelay / speed;

        switch (action.Kind)
        {
            case ActionKind.Move:
            case ActionKind.Drag:
            case ActionKind.Wait:
                break;
            default:
                if (speed > 1.0 && baseDelay > 0)
                {
                    var floor = Math.Min(baseDelay, Math.Max(0, config.MinActionDelay));
                    scaled = Math.Max(scaled, floor);
                }
                break;
        }
        return scaled;
    }

    /// <summary>Seconds between typed characters at the configured speed.</summary>
    public static double TypingDelay(PlaybackConfig config)
    {
        var speed = ClampSpeed(config.Speed);
        var scaled = Math.Max(0, config.TypingCharDelay) / speed;
        return Math.Max(scaled, Math.Max(0, config.MinTypingCharDelay));
    }

    /// <summary>Estimated duration of one pass over the actions (excludes time the system takes to post events).</summary>
    public static double EstimatedDuration(IEnumerable<MacroAction> actions, PlaybackConfig config)
    {
        var total = 0.0;
        foreach (var action in actions)
        {
            total += ScaledDelay(action, config);
            if (action.Kind == ActionKind.Text)
            {
                var count = Math.Max(0, TextUnits.Count(action.Text ?? "") - 1);
                total += count * TypingDelay(config);
            }
        }
        return total;
    }

    /// <summary>Number of passes, or null for "until stopped".</summary>
    public static int? TotalIterations(PlaybackConfig config) => config.Infinite ? null : Math.Max(1, config.RepeatCount);

    /// <summary>Estimated total time for the whole run, or null when looping forever.</summary>
    public static double? EstimatedTotal(IEnumerable<MacroAction> actions, PlaybackConfig config)
    {
        if (TotalIterations(config) is not int iterations) return null;
        var single = EstimatedDuration(actions, config);
        var gaps = Math.Max(0, iterations - 1) * Math.Max(0, config.LoopDelay);
        return single * iterations + gaps + Math.Max(0, config.Countdown);
    }
}

/// <summary>Text helpers that count what a person sees as characters (text elements), not UTF-16 units.</summary>
public static class TextUnits
{
    public static List<string> Split(string text)
    {
        var result = new List<string>();
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            result.Add((string)enumerator.Current);
        }
        return result;
    }

    public static int Count(string text) => new System.Globalization.StringInfo(text).LengthInTextElements;
}
