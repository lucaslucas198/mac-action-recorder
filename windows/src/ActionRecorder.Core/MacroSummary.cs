using System.Text;

namespace ActionRecorder.Core;

/// <summary>A compact plain-text description of a macro, small enough for a language model with a
/// short context window. Long mouse paths are collapsed into one line.</summary>
public static class MacroSummary
{
    public static string Text(Recording recording, int maxLines = 60)
    {
        var lines = new List<string>();
        var pointerSteps = 0;

        void FlushPointer()
        {
            if (pointerSteps > 0)
            {
                lines.Add($"Move the mouse ({pointerSteps} steps)");
                pointerSteps = 0;
            }
        }

        foreach (var action in recording.Actions)
        {
            if (action.Kind == ActionKind.Move || action.Kind == ActionKind.Drag)
            {
                pointerSteps++;
                continue;
            }
            FlushPointer();
            var line = ActionDescriber.Describe(action);
            if (action.Delay >= 1)
            {
                line += $" (after a {ActionDescriber.FormatSeconds(action.Delay)} pause)";
            }
            lines.Add(line);
        }
        FlushPointer();

        lines = Trim(lines, maxLines, "steps");

        var output = new StringBuilder();
        output.Append($"Macro: {recording.Name}\n");
        if (recording.TargetApp is { } app) output.Append($"Recorded in: {app.Name}\n");
        output.Append($"Total actions: {recording.Actions.Count}\nSteps:\n");
        for (var i = 0; i < lines.Count; i++)
        {
            output.Append($"{i + 1}. {lines[i]}\n");
        }
        return output.ToString();
    }

    /// <summary>A numbered list for asking a language model to suggest edits. Each line is labelled with the
    /// action's real position in the macro (#7 is the 7th action), so a reply that refers to "step 7" can be
    /// mapped back to the right action. Mouse movements are collapsed into one unnumbered line.</summary>
    public static string NumberedText(Recording recording, int maxLines = 60)
    {
        var lines = new List<string>();
        var pointerSteps = 0;

        void FlushPointer()
        {
            if (pointerSteps > 0)
            {
                lines.Add($"(mouse movements: {pointerSteps}, not editable)");
                pointerSteps = 0;
            }
        }

        for (var index = 0; index < recording.Actions.Count; index++)
        {
            var action = recording.Actions[index];
            if (action.Kind == ActionKind.Move || action.Kind == ActionKind.Drag)
            {
                pointerSteps++;
                continue;
            }
            FlushPointer();
            var line = $"#{index + 1} " + ActionDescriber.Describe(action);
            if (action.Delay >= 0.05)
            {
                line += $" (after {ActionDescriber.FormatSeconds(action.Delay)})";
            }
            lines.Add(line);
        }
        FlushPointer();

        lines = Trim(lines, maxLines, "lines");

        var output = new StringBuilder();
        output.Append($"Macro: {recording.Name}\n");
        if (recording.TargetApp is { } app) output.Append($"Recorded in: {app.Name}\n");
        output.Append($"Total actions: {recording.Actions.Count}\nSteps:\n");
        foreach (var line in lines) output.Append(line).Append('\n');
        return output.ToString();
    }

    private static List<string> Trim(List<string> lines, int maxLines, string noun)
    {
        var limit = Math.Max(4, maxLines);
        if (lines.Count <= limit) return lines;
        var head = limit * 2 / 3;
        var tail = limit - head;
        var omitted = lines.Count - head - tail;
        var kept = new List<string>(lines.Take(head)) { $"… {omitted} {noun} omitted …" };
        kept.AddRange(lines.Skip(lines.Count - tail));
        return kept;
    }
}
