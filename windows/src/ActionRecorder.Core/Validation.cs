namespace ActionRecorder.Core;

public enum Severity
{
    Error,
    Warning,
}

public sealed record ValidationIssue(Severity Severity, int? ActionIndex, string Message)
{
    public ValidationIssue(Severity severity, string message) : this(severity, null, message)
    {
    }

    public override string ToString() => ActionIndex is int index ? $"Action {index + 1}: {Message}" : Message;
}

public static class RecordingValidator
{
    public const int DefaultMaxActions = 500_000;
    /// <summary>Longest single delay or wait accepted (24 hours).</summary>
    public const double MaxDelay = 86_400.0;
    public const int MaxText = 100_000;
    public const double MaxCoordinate = 100_000.0;
    public const int MaxScroll = 100_000;
    public const int MaxKeyCode = 255;

    /// <summary>Checks a whole recording. Errors block playback; warnings are informational.</summary>
    public static List<ValidationIssue> Validate(Recording recording, int maxActions = DefaultMaxActions)
    {
        var issues = new List<ValidationIssue>();

        if (recording.FormatVersion < 1 || recording.FormatVersion > RecordingFormat.CurrentVersion)
        {
            issues.Add(new ValidationIssue(Severity.Error, $"Unsupported format version {recording.FormatVersion}."));
        }

        if (string.IsNullOrWhiteSpace(recording.Name))
        {
            issues.Add(new ValidationIssue(Severity.Warning, "The recording has no name."));
        }

        if (recording.Actions.Count > maxActions)
        {
            issues.Add(new ValidationIssue(Severity.Error,
                $"Too many actions ({recording.Actions.Count}); the limit is {maxActions}."));
            // Don't walk an enormous list just to produce more errors.
            return issues;
        }

        if (recording.Actions.Count == 0)
        {
            issues.Add(new ValidationIssue(Severity.Warning, "The recording has no actions."));
        }

        for (var index = 0; index < recording.Actions.Count; index++)
        {
            issues.AddRange(Validate(recording.Actions[index], index));
        }
        return issues;
    }

    /// <summary>Checks a single action. Used by the editor before accepting changes.</summary>
    public static List<ValidationIssue> Validate(MacroAction action, int? index = null)
    {
        var issues = new List<ValidationIssue>();

        void Fail(string message) => issues.Add(new ValidationIssue(Severity.Error, index, message));

        static bool Finite(double value) => !double.IsNaN(value) && !double.IsInfinity(value);

        if (!Finite(action.Delay) || action.Delay < 0 || action.Delay > MaxDelay)
        {
            Fail($"Delay must be between 0 and {(int)MaxDelay} seconds.");
        }

        void CheckPoint()
        {
            if (action.X is not double x || action.Y is not double y)
            {
                Fail($"{action.Kind.DisplayName()} needs x and y coordinates.");
                return;
            }
            if (!Finite(x) || !Finite(y) || Math.Abs(x) > MaxCoordinate || Math.Abs(y) > MaxCoordinate)
            {
                Fail("Coordinates are out of range.");
            }
        }

        switch (action.Kind)
        {
            case ActionKind.Move:
                CheckPoint();
                break;

            case ActionKind.Drag:
            case ActionKind.MouseDown:
            case ActionKind.MouseUp:
                CheckPoint();
                if (action.Button == null)
                {
                    Fail($"{action.Kind.DisplayName()} needs a mouse button.");
                }
                break;

            case ActionKind.Click:
                CheckPoint();
                if (action.Button == null)
                {
                    Fail("Click needs a mouse button.");
                }
                if (action.ClickCount is int count)
                {
                    if (count < 1 || count > 3)
                    {
                        Fail("Click count must be 1, 2 or 3.");
                    }
                }
                else
                {
                    Fail("Click needs a click count.");
                }
                break;

            case ActionKind.Scroll:
                if (action.ScrollX == null && action.ScrollY == null)
                {
                    Fail("Scroll needs a horizontal or vertical amount.");
                }
                if (action.ScrollX is int dx && Math.Abs((long)dx) > MaxScroll) Fail("Scroll amount is out of range.");
                if (action.ScrollY is int dy && Math.Abs((long)dy) > MaxScroll) Fail("Scroll amount is out of range.");
                if (action.X != null || action.Y != null)
                {
                    CheckPoint();
                }
                break;

            case ActionKind.Key:
                if (action.KeyCode is int code)
                {
                    if (code < 0 || code > MaxKeyCode)
                    {
                        Fail($"Key code must be between 0 and {MaxKeyCode}.");
                    }
                }
                else
                {
                    Fail("Key press needs a key code.");
                }
                break;

            case ActionKind.Text:
                if (action.Text is string text)
                {
                    if (text.Length == 0) Fail("Text must not be empty.");
                    if (text.Length > MaxText) Fail("Text is too long.");
                }
                else
                {
                    Fail("Text action needs text.");
                }
                break;

            case ActionKind.Wait:
                if (action.Duration is double duration)
                {
                    if (!Finite(duration) || duration < 0 || duration > MaxDelay)
                    {
                        Fail($"Wait must be between 0 and {(int)MaxDelay} seconds.");
                    }
                }
                else
                {
                    Fail("Wait needs a duration.");
                }
                break;
        }

        return issues;
    }

    public static List<ValidationIssue> Errors(IEnumerable<ValidationIssue> issues) =>
        issues.Where(i => i.Severity == Severity.Error).ToList();
}

public static class Num
{
    /// <summary>Clamps to a range; NaN becomes the lower bound.</summary>
    public static double Clamp(double value, double min, double max)
    {
        if (double.IsNaN(value)) return min;
        return Math.Min(Math.Max(value, min), max);
    }

    public static int Clamp(int value, int min, int max) => Math.Min(Math.Max(value, min), max);
}
