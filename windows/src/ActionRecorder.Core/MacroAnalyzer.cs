namespace ActionRecorder.Core;

public enum FixKind
{
    None,
    RemoveMouseMoves,
    CapLongPauses,
    SetLoopDelay,
    EnableForegroundCheck,
}

/// <summary>A one-click change that resolves a finding.</summary>
public sealed record MacroFix(FixKind Kind, double Seconds = 0)
{
    public static MacroFix RemoveMouseMoves() => new(FixKind.RemoveMouseMoves);
    public static MacroFix CapLongPauses(double maxSeconds) => new(FixKind.CapLongPauses, maxSeconds);
    public static MacroFix SetLoopDelay(double seconds) => new(FixKind.SetLoopDelay, seconds);
    public static MacroFix EnableForegroundCheck() => new(FixKind.EnableForegroundCheck);
}

public enum FindingSeverity
{
    Info,
    Warning,
}

public sealed record MacroFinding(string Id, FindingSeverity Severity, string Title, string Detail, MacroFix? Fix = null, string? FixLabel = null);

/// <summary>Fixed rules that look for things that commonly make macros unreliable or risky.
/// Everything here runs locally and deterministically; there is no model involved.</summary>
public static class MacroAnalyzer
{
    public const double LongPause = 10.0;
    public const double PauseCap = 2.0;
    public const double MinLoopDelay = 3.0;
    public const double SuggestedLoopDelay = 5.0;
    /// <summary>Mouse moves must be at least this many, and this share of all actions, to be flagged.</summary>
    public const int ManyMovesCount = 20;
    public const double ManyMovesShare = 0.5;

    public static List<MacroFinding> Analyze(Recording recording, PlaybackDefaults playback, bool verifyForeground, ScreenSize? currentScreen)
    {
        var actions = recording.Actions;
        var findings = new List<MacroFinding>();
        if (actions.Count == 0) return findings;

        var moveCount = actions.Count(a => a.Kind == ActionKind.Move);
        var hasClicks = actions.Any(a => a.Kind == ActionKind.Click || a.Kind == ActionKind.MouseDown);
        var hasText = actions.Any(a => a.Kind == ActionKind.Text);

        var secretCount = actions.Count(a => a.Kind == ActionKind.Text && LooksLikeSecret(a.Text ?? ""));
        if (secretCount > 0)
        {
            findings.Add(new MacroFinding("secret-text", FindingSeverity.Warning,
                "Typed text may contain a password",
                $"{secretCount} text action(s) look like a password or key (a single long word mixing letters, digits and symbols). Saved macros and exported files store typed text in plain, readable form. Delete those actions if they are secrets."));
        }

        if (recording.RecordedScreen is { } recorded && currentScreen is { } now && hasClicks
            && (Math.Abs(recorded.Width - now.Width) > 1 || Math.Abs(recorded.Height - now.Height) > 1))
        {
            findings.Add(new MacroFinding("screen-changed", FindingSeverity.Warning,
                "The display size changed",
                $"Recorded on {(int)recorded.Width}×{(int)recorded.Height}; the main display is now {(int)now.Width}×{(int)now.Height}. Recorded click positions may land in the wrong place."));
        }

        var hasPlainReturn = actions.Any(a => a.Kind == ActionKind.Key && a.KeyCode == KeyCodes.Return
                                              && (a.Modifiers ?? KeyModifiers.None) == KeyModifiers.None);
        var repeatsALot = playback.RepeatCount == 0 || playback.RepeatCount >= 5;
        if (hasText && hasPlainReturn && repeatsALot && playback.LoopDelay < MinLoopDelay)
        {
            var times = playback.RepeatCount == 0 ? "until stopped" : $"{playback.RepeatCount} times";
            findings.Add(new MacroFinding("rapid-messages", FindingSeverity.Warning,
                "This may send messages very quickly",
                $"The macro types text and presses Enter, and repeats {times} with less than {(int)MinLoopDelay} seconds between repetitions. Sending many messages fast can be treated as spam, and Discord may rate-limit or restrict the account. Add a longer delay between repetitions.",
                MacroFix.SetLoopDelay(SuggestedLoopDelay), $"Set {(int)SuggestedLoopDelay} s between repeats"));
        }

        if (hasClicks || hasText)
        {
            if (recording.TargetApp != null && !verifyForeground)
            {
                findings.Add(new MacroFinding("foreground-off", FindingSeverity.Warning,
                    "Nothing checks which app is in front",
                    "If another window is in front when playback starts, the clicks and typing go there. Turning on the foreground check makes playback stop instead.",
                    MacroFix.EnableForegroundCheck(), "Turn on foreground check"));
            }
            else if (recording.TargetApp == null)
            {
                findings.Add(new MacroFinding("no-target-app", FindingSeverity.Info,
                    "No target app was recorded",
                    "The foreground check needs to know which app this macro belongs to. Record it again with the target app in front to enable that check."));
            }
        }

        if (moveCount >= ManyMovesCount && (double)moveCount / actions.Count >= ManyMovesShare)
        {
            findings.Add(new MacroFinding("many-moves", FindingSeverity.Info,
                $"{moveCount} of {actions.Count} actions are mouse movements",
                "Long movement paths make a macro slow to edit and add little. Removing them makes the pointer jump straight to each click. Keep them if something only appears when you hover.",
                MacroFix.RemoveMouseMoves(), "Remove mouse movements"));
        }

        var longPauses = 0;
        foreach (var action in actions)
        {
            if (action.Delay > LongPause) longPauses++;
            if (action.Kind == ActionKind.Wait && (action.Duration ?? 0) > LongPause) longPauses++;
        }
        if (longPauses > 0)
        {
            findings.Add(new MacroFinding("long-pauses", FindingSeverity.Info,
                $"{longPauses} pause(s) longer than {(int)LongPause} seconds",
                "These are usually idle time while you were thinking during recording, not time the app needs. Shortening them speeds up the macro. Keep them if the app really needs that long to load.",
                MacroFix.CapLongPauses(PauseCap), $"Shorten to {(int)PauseCap} s"));
        }

        if (hasClicks)
        {
            findings.Add(new MacroFinding("click-based", FindingSeverity.Info,
                "This macro clicks at fixed screen positions",
                "It breaks if the window moves or resizes, the display changes, or the app's layout changes. Where an app has a keyboard shortcut for the same step (for example Discord's Quick Switcher, Ctrl+K), a shortcut is more reliable than a click. Test at a slow speed first."));
        }

        // Stable sort: warnings first, original order kept inside each group.
        return findings.OrderBy(f => f.Severity == FindingSeverity.Warning ? 0 : 1).ToList();
    }

    /// <summary>Heuristic: one long word with at least three of: lowercase, uppercase, digits, symbols.
    /// Web addresses are excluded. It can be wrong in both directions; callers say "may".</summary>
    public static bool LooksLikeSecret(string text)
    {
        var chars = TextUnits.Split(text);
        if (chars.Count < 8 || chars.Count > 64) return false;
        if (text.Any(char.IsWhiteSpace)) return false;
        if (text.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return false;

        var classes = 0;
        if (text.Any(char.IsLower)) classes++;
        if (text.Any(char.IsUpper)) classes++;
        if (text.Any(char.IsDigit)) classes++;
        if (text.Any(c => !char.IsLetter(c) && !char.IsDigit(c))) classes++;
        return classes >= 3;
    }
}
