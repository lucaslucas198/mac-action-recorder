namespace ActionRecorder.Core;

public enum EditSource
{
    /// <summary>A fixed rule in this app.</summary>
    Rule,
    /// <summary>A suggestion parsed from the local language model's reply.</summary>
    Ai,
}

public abstract record EditOperation
{
    /// <summary>Delete these actions. Their delays are added to the next surviving action.</summary>
    public sealed record Delete(IReadOnlyList<Guid> Ids) : EditOperation;
    /// <summary>Join each listed text action onto the text action directly before it.</summary>
    public sealed record MergeText(IReadOnlyList<Guid> Ids) : EditOperation;
    /// <summary>Raise the delay before each listed action to at least Seconds.</summary>
    public sealed record SetMinimumDelay(IReadOnlyList<Guid> Ids, double Seconds) : EditOperation;
    /// <summary>Shorten every delay or wait longer than Above seconds to To seconds.</summary>
    public sealed record CapPauses(double Above, double To) : EditOperation;
}

/// <summary>One proposed change to a macro. Nothing is applied until the user chooses it.</summary>
public sealed record MacroEdit(string Id, EditSource Source, EditOperation Operation, string Title, string Reason);

/// <summary>Fixed rules that tidy a macro and make common failures less likely. They run locally and
/// deterministically; no language model is involved.</summary>
public static class MacroOptimizer
{
    /// <summary>Shortest run of consecutive mouse moves that is worth removing.</summary>
    public const int MinMoveRun = 3;
    /// <summary>Typed chunks closer together than this (seconds) are joined into one.</summary>
    public const double MaxMergeGap = 1.0;
    /// <summary>Typing right after a click or shortcut waits at least this long (seconds).</summary>
    public const double SettleDelay = 0.35;

    public static List<MacroEdit> Plan(Recording recording)
    {
        var actions = recording.Actions;
        var edits = new List<MacroEdit>();
        if (actions.Count == 0) return edits;

        // 1. Mouse paths. A click already carries its position, so the path before it adds steps but no
        //    behaviour. Before anything else, the last position is kept.
        var moveIds = new List<Guid>();
        var index = 0;
        while (index < actions.Count)
        {
            if (actions[index].Kind != ActionKind.Move)
            {
                index++;
                continue;
            }
            var end = index;
            while (end + 1 < actions.Count && actions[end + 1].Kind == ActionKind.Move)
            {
                end++;
            }
            if (end - index + 1 >= MinMoveRun)
            {
                ActionKind? next = end + 1 < actions.Count ? actions[end + 1].Kind : null;
                var dropAll = next == ActionKind.Click || next == ActionKind.MouseDown;
                var last = dropAll ? end : end - 1;
                for (var position = index; position <= last; position++)
                {
                    moveIds.Add(actions[position].Id);
                }
            }
            index = end + 1;
        }
        if (moveIds.Count > 0)
        {
            edits.Add(new MacroEdit("rule-remove-moves", EditSource.Rule, new EditOperation.Delete(moveIds),
                $"Remove {moveIds.Count} mouse-movement steps",
                "A click already includes where to click, so the pointer jumps straight there. Keep the movements if something only appears when you hover."));
        }

        // 2. Typing split into several chunks in a row.
        var mergeIds = new List<Guid>();
        for (var p = 1; p < actions.Count; p++)
        {
            if (actions[p].Kind == ActionKind.Text && actions[p - 1].Kind == ActionKind.Text && actions[p].Delay <= MaxMergeGap)
            {
                mergeIds.Add(actions[p].Id);
            }
        }
        if (mergeIds.Count > 0)
        {
            edits.Add(new MacroEdit("rule-merge-text", EditSource.Rule, new EditOperation.MergeText(mergeIds),
                $"Combine consecutive typing steps ({mergeIds.Count} fewer)",
                "Text typed back to back is one step. The text and its order stay the same; only the short gaps between chunks are dropped."));
        }

        // 3. Typing right after a click or shortcut, before the app has caught up.
        var settleIds = new List<Guid>();
        const KeyModifiers shortcutKeys = KeyModifiers.Command | KeyModifiers.Control | KeyModifiers.Option;
        for (var p = 1; p < actions.Count; p++)
        {
            var action = actions[p];
            var previous = actions[p - 1];
            if (action.Kind != ActionKind.Text || action.Delay >= SettleDelay) continue;
            var afterClick = previous.Kind == ActionKind.Click;
            var afterShortcut = previous.Kind == ActionKind.Key && ((previous.Modifiers ?? KeyModifiers.None) & shortcutKeys) != 0;
            if (afterClick || afterShortcut)
            {
                settleIds.Add(action.Id);
            }
        }
        if (settleIds.Count > 0)
        {
            edits.Add(new MacroEdit("rule-settle-text", EditSource.Rule, new EditOperation.SetMinimumDelay(settleIds, SettleDelay),
                $"Wait a moment before {settleIds.Count} typing step(s)",
                $"Text typed immediately after a click or shortcut can be lost if the text field is not focused yet. This waits at least {ActionDescriber.FormatSeconds(SettleDelay)} first."));
        }

        // 4. Idle time from the recording session.
        var longPauses = 0;
        foreach (var action in actions)
        {
            if (action.Delay > MacroAnalyzer.LongPause) longPauses++;
            if (action.Kind == ActionKind.Wait && (action.Duration ?? 0) > MacroAnalyzer.LongPause) longPauses++;
        }
        if (longPauses > 0)
        {
            edits.Add(new MacroEdit("rule-cap-pauses", EditSource.Rule, new EditOperation.CapPauses(MacroAnalyzer.LongPause, MacroAnalyzer.PauseCap),
                $"Shorten {longPauses} long pause(s) to {(int)MacroAnalyzer.PauseCap} s",
                $"Pauses over {(int)MacroAnalyzer.LongPause} seconds are usually thinking time from recording. Keep them if the app really needs that long to load."));
        }

        return edits;
    }

    /// <summary>Applies the edits in order. An edit that no longer matches anything (for example an action that an
    /// earlier edit already removed) is skipped. Returns how many edits changed something.</summary>
    public static int ApplyEdits(this Recording recording, IEnumerable<MacroEdit> edits)
    {
        var applied = 0;
        foreach (var edit in edits)
        {
            if (ApplyOperation(recording, edit.Operation)) applied++;
        }
        return applied;
    }

    private static bool ApplyOperation(Recording recording, EditOperation operation)
    {
        var actions = recording.Actions;
        switch (operation)
        {
            case EditOperation.Delete del:
            {
                var existing = new HashSet<Guid>(actions.Select(a => a.Id));
                existing.IntersectWith(del.Ids);
                if (existing.Count == 0) return false;
                recording.DeleteActions(existing);
                return true;
            }
            case EditOperation.MergeText merge:
            {
                var changed = false;
                foreach (var id in merge.Ids)
                {
                    var index = actions.FindIndex(a => a.Id == id);
                    if (index <= 0 || actions[index].Kind != ActionKind.Text || actions[index - 1].Kind != ActionKind.Text) continue;
                    var first = actions[index - 1].Text;
                    var second = actions[index].Text;
                    if (first == null || second == null || first.Length + second.Length > RecordingValidator.MaxText) continue;
                    actions[index - 1].Text = first + second;
                    actions.RemoveAt(index);
                    changed = true;
                }
                return changed;
            }
            case EditOperation.SetMinimumDelay setMin:
            {
                if (double.IsNaN(setMin.Seconds) || double.IsInfinity(setMin.Seconds) || setMin.Seconds < 0) return false;
                var target = Math.Min(setMin.Seconds, RecordingValidator.MaxDelay);
                var ids = new HashSet<Guid>(setMin.Ids);
                var changed = false;
                foreach (var action in actions)
                {
                    if (ids.Contains(action.Id) && action.Delay < target)
                    {
                        action.Delay = target;
                        changed = true;
                    }
                }
                return changed;
            }
            case EditOperation.CapPauses cap:
            {
                if (double.IsNaN(cap.Above) || double.IsInfinity(cap.Above) || double.IsNaN(cap.To) || double.IsInfinity(cap.To)
                    || cap.To < 0 || cap.To > cap.Above) return false;
                var changed = false;
                foreach (var action in actions)
                {
                    if (action.Delay > cap.Above)
                    {
                        action.Delay = cap.To;
                        changed = true;
                    }
                    if (action.Kind == ActionKind.Wait && action.Duration is double d && d > cap.Above)
                    {
                        action.Duration = cap.To;
                        changed = true;
                    }
                }
                return changed;
            }
            default:
                return false;
        }
    }
}

/// <summary>Turns the local model's text reply into edits the app is willing to apply.
/// The model may only ask for two things, in a fixed line format:
///     DELETE &lt;step&gt; | &lt;reason&gt;
///     PAUSE &lt;step&gt; &lt;seconds&gt; | &lt;reason&gt;
/// Anything else is ignored: unknown words, step numbers that do not exist, mouse-movement steps (the rules
/// handle those), wild values, and more than a few deletions. The model can never write text, coordinates or
/// key codes into a macro, and the user still has to choose each change.</summary>
public static class AIEditParser
{
    public const int MaxEdits = 12;
    public const double MaxPause = 5.0;

    public static List<MacroEdit> Parse(string reply, Recording recording)
    {
        var actions = recording.Actions;
        var edits = new List<MacroEdit>();
        if (actions.Count == 0) return edits;

        var editableCount = actions.Count(a => a.Kind != ActionKind.Move && a.Kind != ActionKind.Drag);
        var maxDeletes = Math.Max(1, editableCount / 2);
        var seen = new HashSet<string>();
        var deletes = 0;

        foreach (var rawLine in SplitLines(reply))
        {
            if (edits.Count >= MaxEdits) break;
            var line = Clean(rawLine);
            if (line.Length == 0) continue;

            var bar = line.IndexOf('|');
            var command = bar >= 0 ? line[..bar] : line;
            var reason = bar >= 0 ? line[(bar + 1)..].Trim() : "";
            if (reason.Length == 0) reason = "Suggested by the local AI.";
            if (reason.Length > 160) reason = reason[..157] + "…";

            var words = command.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0) continue;
            var verb = words[0].ToUpperInvariant();
            var tokens = new List<string> { verb };
            tokens.AddRange(words.Skip(1).Where(w => !string.Equals(w, "step", StringComparison.OrdinalIgnoreCase)));
            if (tokens.Count < 2 || StepNumber(tokens[1]) is not int step || step < 1 || step > actions.Count) continue;

            var action = actions[step - 1];
            if (action.Kind == ActionKind.Move || action.Kind == ActionKind.Drag) continue;
            var described = ActionDescriber.Describe(action);

            switch (verb)
            {
                case "DELETE":
                case "REMOVE":
                {
                    var key = "delete-" + action.Id;
                    if (seen.Contains(key) || deletes >= maxDeletes) continue;
                    seen.Add(key);
                    deletes++;
                    edits.Add(new MacroEdit("ai-" + key, EditSource.Ai, new EditOperation.Delete(new[] { action.Id }),
                        $"Delete step {step}: {described}", reason));
                    break;
                }
                case "PAUSE":
                case "WAIT":
                {
                    if (tokens.Count < 3 || Number(tokens[2]) is not double seconds || double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds <= 0) continue;
                    var clamped = Math.Min(seconds, MaxPause);
                    var key = "pause-" + action.Id;
                    if (seen.Contains(key)) continue;
                    seen.Add(key);
                    edits.Add(new MacroEdit("ai-" + key, EditSource.Ai, new EditOperation.SetMinimumDelay(new[] { action.Id }, clamped),
                        $"Wait at least {ActionDescriber.FormatSeconds(clamped)} before step {step}: {described}", reason));
                    break;
                }
            }
        }
        return edits;
    }

    internal static IEnumerable<string> SplitLines(string text) => text.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.None);

    /// <summary>Removes list bullets, numbering and markdown emphasis from the start of a line.</summary>
    public static string Clean(string line)
    {
        var text = line.Replace("*", "").Replace("`", "").Trim();
        while (text.Length > 0 && (text[0] == '-' || text[0] == '•' || text[0] == '>'))
        {
            text = text[1..].Trim();
        }
        // "1. DELETE 3" or "2) DELETE 3"
        var digits = 0;
        while (digits < text.Length && char.IsDigit(text[digits])) digits++;
        if (digits > 0 && digits < text.Length && (text[digits] == '.' || text[digits] == ')'))
        {
            text = text[(digits + 1)..].Trim();
        }
        return text;
    }

    private static int? StepNumber(string token)
    {
        var trimmed = token.Trim('#', ':', ',', '.');
        return int.TryParse(trimmed, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    private static double? Number(string token)
    {
        var trimmed = token.ToLowerInvariant().Trim(Enumerable.Range('a', 26).Select(c => (char)c).Append(',').ToArray());
        return double.TryParse(trimmed, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value) ? value : null;
    }
}
