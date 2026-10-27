namespace ActionRecorder.Core;

/// <summary>The result of reading a language model's drafted steps.</summary>
public sealed record MacroDraft(List<MacroAction> Actions, int SkippedLines, bool Unsupported);

/// <summary>Turns the local model's reply to "describe what the macro should do" into real actions.
/// The model may only use three line formats:
///     KEY &lt;shortcut&gt;     for example KEY ctrl+k, KEY enter, KEY shift+enter
///     TYPE &lt;text&gt;        the exact text to type
///     WAIT &lt;seconds&gt;     0.1 to 10
/// Everything else is ignored. The result is a list of ordinary keyboard actions with no screen coordinates,
/// and the app shows it to the user before anything is added to a macro.</summary>
public static class AIMacroDrafter
{
    public const int MaxActions = 30;
    public const int MaxTextLength = 500;
    public const double MinWait = 0.1;
    public const double MaxWait = 10.0;

    /// <summary>Delay before a step that follows a shortcut such as Ctrl+K, which opens a panel.</summary>
    private const double AfterShortcutDelay = 0.5;
    /// <summary>Delay before pressing Enter after typing, so suggestion lists can update.</summary>
    private const double BeforeReturnDelay = 0.4;
    private const double DefaultDelay = 0.2;

    public static MacroDraft Parse(string reply)
    {
        var actions = new List<MacroAction>();
        var skipped = 0;
        var unsupported = false;
        MacroAction? previous = null;

        foreach (var rawLine in AIEditParser.SplitLines(reply))
        {
            if (actions.Count >= MaxActions) break;
            var line = AIEditParser.Clean(rawLine);
            if (line.Length == 0) continue;
            if (string.Equals(line, "UNSUPPORTED", StringComparison.OrdinalIgnoreCase))
            {
                unsupported = true;
                continue;
            }

            var verbEnd = 0;
            while (verbEnd < line.Length && !char.IsWhiteSpace(line[verbEnd])) verbEnd++;
            var verb = line[..verbEnd].ToUpperInvariant();
            var rest = line[verbEnd..].Trim();

            MacroAction? action = null;
            switch (verb)
            {
                case "KEY":
                    if (ParseKey(rest) is { } parsed)
                    {
                        action = Act.Key(parsed.KeyCode, parsed.Modifiers);
                    }
                    break;
                case "TYPE":
                    var text = Unquote(rest);
                    if (text.Length > 0 && TextUnits.Count(text) <= MaxTextLength)
                    {
                        action = Act.Text(text);
                    }
                    break;
                case "WAIT":
                    var number = rest.ToLowerInvariant().Trim(Enumerable.Range('a', 26).Select(c => (char)c).Append(' ').ToArray());
                    if (double.TryParse(number, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds)
                        && !double.IsNaN(seconds) && !double.IsInfinity(seconds))
                    {
                        action = Act.Wait(Math.Min(MaxWait, Math.Max(MinWait, seconds)));
                    }
                    break;
            }

            if (action == null)
            {
                // Prose, code fences and blank markdown are expected; count only real attempts.
                if (verb is "KEY" or "TYPE" or "WAIT") skipped++;
                continue;
            }

            if (previous != null && action.Kind != ActionKind.Wait)
            {
                action.Delay = DelayBetween(previous, action);
            }
            actions.Add(action);
            previous = action;
        }
        return new MacroDraft(actions, skipped, unsupported && actions.Count == 0);
    }

    private static double DelayBetween(MacroAction previous, MacroAction next)
    {
        const KeyModifiers shortcut = KeyModifiers.Command | KeyModifiers.Control | KeyModifiers.Option;
        if (previous.Kind == ActionKind.Key && ((previous.Modifiers ?? KeyModifiers.None) & shortcut) != 0)
        {
            return AfterShortcutDelay;
        }
        if (previous.Kind == ActionKind.Text && next.Kind == ActionKind.Key && next.KeyCode == KeyCodes.Return
            && (next.Modifiers ?? KeyModifiers.None) == KeyModifiers.None)
        {
            return BeforeReturnDelay;
        }
        return DefaultDelay;
    }

    private static string Unquote(string text)
    {
        var pairs = new[] { ('"', '"'), ('“', '”'), ('\'', '\'') };
        foreach (var (open, close) in pairs)
        {
            if (text.Length >= 2 && text[0] == open && text[^1] == close)
            {
                return text[1..^1];
            }
        }
        return text;
    }

    /// <summary>Parses a shortcut such as "ctrl+k", "shift+enter" or "tab".</summary>
    public static (int KeyCode, KeyModifiers Modifiers)? ParseKey(string text)
    {
        var parts = text.ToLowerInvariant().Split('+', StringSplitOptions.RemoveEmptyEntries).Select(p => p.Trim()).ToList();
        if (parts.Count == 0 || parts[^1].Length == 0) return null;

        var modifiers = KeyModifiers.None;
        foreach (var name in parts.Take(parts.Count - 1))
        {
            switch (name)
            {
                // The model may think in Mac terms; "cmd" maps to Ctrl, which is Windows' equivalent.
                case "ctrl": case "control": case "cmd": case "command": case "⌘": case "⌃":
                    modifiers |= KeyModifiers.Control; break;
                case "alt": case "opt": case "option": case "⌥":
                    modifiers |= KeyModifiers.Option; break;
                case "shift": case "⇧":
                    modifiers |= KeyModifiers.Shift; break;
                case "win": case "windows": case "super": case "meta":
                    modifiers |= KeyModifiers.Command; break;
                default:
                    return null;
            }
        }
        return KeyCodesByName.TryGetValue(parts[^1], out var code) ? (code, modifiers) : null;
    }

    /// <summary>Names the model may use, mapped to Windows virtual-key codes.</summary>
    public static readonly IReadOnlyDictionary<string, int> KeyCodesByName = BuildNames();

    private static Dictionary<string, int> BuildNames()
    {
        var map = new Dictionary<string, int>
        {
            ["return"] = KeyCodes.Return, ["enter"] = KeyCodes.Return,
            ["tab"] = KeyCodes.Tab, ["space"] = KeyCodes.Space,
            ["delete"] = KeyCodes.Backspace, ["backspace"] = KeyCodes.Backspace,
            ["escape"] = KeyCodes.Escape, ["esc"] = KeyCodes.Escape,
            ["left"] = KeyCodes.Left, ["right"] = KeyCodes.Right, ["down"] = KeyCodes.Down, ["up"] = KeyCodes.Up,
            ["home"] = KeyCodes.Home, ["end"] = KeyCodes.End,
            ["pageup"] = KeyCodes.PageUp, ["pagedown"] = KeyCodes.PageDown,
        };
        for (var letter = 0; letter < 26; letter++) map[((char)('a' + letter)).ToString()] = 0x41 + letter;
        for (var digit = 0; digit <= 9; digit++) map[digit.ToString()] = 0x30 + digit;
        for (var f = 1; f <= 12; f++) map["f" + f] = 0x6F + f;
        return map;
    }
}
