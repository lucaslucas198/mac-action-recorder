namespace ActionRecorder.Core;

/// <summary>Controls what the recorder keeps. Stored in the app settings.</summary>
public sealed class RecordingOptions
{
    public bool IncludeMouseMove { get; set; } = true;
    public bool RecordScroll { get; set; } = true;
    /// <summary>Keyboard shortcuts (Ctrl/Alt/Win combinations) and special keys (Enter, arrows, Delete, ...).</summary>
    public bool RecordShortcuts { get; set; } = true;
    /// <summary>Ordinary typed characters.</summary>
    public bool RecordText { get; set; } = true;
    /// <summary>Minimum time between stored mouse-move samples, in seconds.</summary>
    public double MinEventInterval { get; set; } = 0.03;
    /// <summary>Minimum pointer travel between stored mouse-move samples, in pixels.</summary>
    public double MinMoveDistance { get; set; } = 3.0;
}

public enum RawEventKind
{
    MouseMove,
    MouseDrag,
    MouseDown,
    MouseUp,
    Scroll,
    KeyDown,
    KeyUp,
}

/// <summary>One captured input event. <c>Time</c> comes from a monotonic clock, in seconds.</summary>
public sealed record RawEvent
{
    public double Time { get; init; }
    public double X { get; init; }
    public double Y { get; init; }
    public RawEventKind Kind { get; init; }
    public MouseButton Button { get; init; } = MouseButton.Left;
    public int ClickCount { get; init; } = 1;
    public int ScrollX { get; init; }
    public int ScrollY { get; init; }
    public int KeyCode { get; init; }
    public KeyModifiers Modifiers { get; init; }
    public string Characters { get; init; } = "";
    public bool IsRepeat { get; init; }

    public static RawEvent Move(double time, double x, double y) => new() { Time = time, X = x, Y = y, Kind = RawEventKind.MouseMove };
    public static RawEvent Drag(double time, double x, double y, MouseButton b = MouseButton.Left) => new() { Time = time, X = x, Y = y, Kind = RawEventKind.MouseDrag, Button = b };
    public static RawEvent Down(double time, double x, double y, MouseButton b = MouseButton.Left, int count = 1) => new() { Time = time, X = x, Y = y, Kind = RawEventKind.MouseDown, Button = b, ClickCount = count };
    public static RawEvent Up(double time, double x, double y, MouseButton b = MouseButton.Left, int count = 1) => new() { Time = time, X = x, Y = y, Kind = RawEventKind.MouseUp, Button = b, ClickCount = count };
    public static RawEvent Wheel(double time, double x, double y, int dx, int dy) => new() { Time = time, X = x, Y = y, Kind = RawEventKind.Scroll, ScrollX = dx, ScrollY = dy };
    public static RawEvent KeyPress(double time, int keyCode, KeyModifiers modifiers, string characters, bool isRepeat = false) =>
        new() { Time = time, Kind = RawEventKind.KeyDown, KeyCode = keyCode, Modifiers = modifiers, Characters = characters, IsRepeat = isRepeat };
    public static RawEvent KeyRelease(double time, int keyCode, KeyModifiers modifiers) =>
        new() { Time = time, Kind = RawEventKind.KeyUp, KeyCode = keyCode, Modifiers = modifiers };
}

/// <summary>Decides which mouse-move samples to keep so high-frequency tracking stays cheap.</summary>
public sealed class MoveThrottle
{
    public double MinInterval { get; set; }
    public double MinDistance { get; set; }
    private double? _lastTime;
    private double _lastX;
    private double _lastY;

    public MoveThrottle(double minInterval, double minDistance)
    {
        MinInterval = minInterval;
        MinDistance = minDistance;
    }

    /// <summary>Returns true if the sample should be kept. Both the time and distance thresholds
    /// must be met relative to the last kept sample; the first sample is always kept.</summary>
    public bool ShouldAccept(double time, double x, double y)
    {
        if (_lastTime is not double previous)
        {
            Remember(time, x, y);
            return true;
        }
        var elapsed = time - previous;
        var distance = Math.Sqrt((x - _lastX) * (x - _lastX) + (y - _lastY) * (y - _lastY));
        if (elapsed >= MinInterval && distance >= MinDistance)
        {
            Remember(time, x, y);
            return true;
        }
        return false;
    }

    public void Reset() => _lastTime = null;

    private void Remember(double time, double x, double y)
    {
        _lastTime = time;
        _lastX = x;
        _lastY = y;
    }
}

/// <summary>
/// Turns the raw event stream into an editable list of actions:
/// mouse down + up at the same spot become one click (double/triple clicks are merged);
/// consecutive typed characters become one text action;
/// shortcuts and special keys become key actions (key-down + key-up = one press);
/// delays are the gaps between the end of one action and the start of the next.
/// </summary>
public static class RecordingBuilder
{
    /// <summary>A pause longer than this starts a new text action instead of extending the last one.</summary>
    public const double TextRunGap = 2.0;
    /// <summary>Scroll events closer together than this are combined.</summary>
    public const double ScrollCoalesceGap = 0.08;
    /// <summary>Down/up positions closer than this (pixels) still count as a click.</summary>
    public const double ClickSlop = 4.0;

    private static double Dist(double ax, double ay, double bx, double by) =>
        Math.Sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

    public static List<MacroAction> Build(IReadOnlyList<RawEvent> events, RecordingOptions options)
    {
        var assembler = new Assembler();
        var throttle = new MoveThrottle(options.MinEventInterval, options.MinMoveDistance);
        var openButtons = new List<MouseButton>();
        double lastX = 0, lastY = 0;
        var index = 0;

        while (index < events.Count)
        {
            var ev = events[index];
            lastX = ev.X;
            lastY = ev.Y;

            switch (ev.Kind)
            {
                case RawEventKind.MouseMove:
                    if (options.IncludeMouseMove && throttle.ShouldAccept(ev.Time, ev.X, ev.Y))
                    {
                        assembler.Append(Round(Act.Move(ev.X, ev.Y)), ev.Time, ev.Time);
                    }
                    break;

                case RawEventKind.MouseDrag:
                    if (options.IncludeMouseMove && throttle.ShouldAccept(ev.Time, ev.X, ev.Y))
                    {
                        assembler.Append(Round(Act.Drag(ev.X, ev.Y, ev.Button)), ev.Time, ev.Time);
                    }
                    break;

                case RawEventKind.MouseDown:
                    if (index + 1 < events.Count
                        && events[index + 1] is { Kind: RawEventKind.MouseUp } up
                        && up.Button == ev.Button
                        && Dist(up.X, up.Y, ev.X, ev.Y) <= ClickSlop)
                    {
                        var count = Math.Max(1, Math.Max(ev.ClickCount, up.ClickCount));
                        var last = assembler.Actions.Count > 0 ? assembler.Actions[^1] : null;
                        if (count >= 2 && last != null
                            && last.Kind == ActionKind.Click && last.Button == ev.Button
                            && last.ClickCount == count - 1
                            && last.X is double lx && last.Y is double ly
                            && Dist(lx, ly, ev.X, ev.Y) <= ClickSlop)
                        {
                            // Second (or third) click of a multi-click: upgrade the previous click.
                            last.ClickCount = count;
                            assembler.ExtendLast(up.Time);
                        }
                        else
                        {
                            assembler.Append(Round(Act.Click(ev.X, ev.Y, ev.Button, Math.Min(count, 3))), ev.Time, up.Time);
                        }
                        lastX = up.X;
                        lastY = up.Y;
                        index++; // the matching mouse-up has been consumed
                    }
                    else
                    {
                        assembler.Append(Round(Act.MouseDown(ev.X, ev.Y, ev.Button)), ev.Time, ev.Time);
                        openButtons.Add(ev.Button);
                    }
                    break;

                case RawEventKind.MouseUp:
                    // A release without a recorded press (the press happened in the app's own window)
                    // is dropped rather than replayed.
                    var position = openButtons.IndexOf(ev.Button);
                    if (position >= 0)
                    {
                        openButtons.RemoveAt(position);
                        assembler.Append(Round(Act.MouseUp(ev.X, ev.Y, ev.Button)), ev.Time, ev.Time);
                    }
                    break;

                case RawEventKind.Scroll:
                    if (!options.RecordScroll) break;
                    if (assembler.Actions.Count > 0 && assembler.Actions[^1].Kind == ActionKind.Scroll
                        && assembler.LastEnd is double end && ev.Time - end < ScrollCoalesceGap)
                    {
                        var target = assembler.Actions[^1];
                        target.ScrollX = (target.ScrollX ?? 0) + ev.ScrollX;
                        target.ScrollY = (target.ScrollY ?? 0) + ev.ScrollY;
                        target.X = RoundPosition(ev.X);
                        target.Y = RoundPosition(ev.Y);
                        assembler.ExtendLast(ev.Time);
                    }
                    else
                    {
                        assembler.Append(Round(Act.Scroll(ev.ScrollX, ev.ScrollY, ev.X, ev.Y)), ev.Time, ev.Time);
                    }
                    break;

                case RawEventKind.KeyDown:
                    // Alt counts as a shortcut modifier on Windows (Alt+F4, Alt+Left, menus).
                    var isShortcut = ev.Modifiers.IntersectsWith(KeyModifiers.Command | KeyModifiers.Control | KeyModifiers.Option);
                    if (isShortcut)
                    {
                        if (!options.RecordShortcuts) break;
                        assembler.Append(Act.Key(ev.KeyCode, ev.Modifiers), ev.Time, ev.Time);
                    }
                    else if (IsPrintable(ev.Characters))
                    {
                        if (!options.RecordText) break;
                        if (assembler.Actions.Count > 0 && assembler.Actions[^1].Kind == ActionKind.Text
                            && assembler.LastEnd is double textEnd && ev.Time - textEnd <= TextRunGap)
                        {
                            var lastText = assembler.Actions[^1];
                            lastText.Text = (lastText.Text ?? "") + ev.Characters;
                            assembler.ExtendLast(ev.Time);
                        }
                        else
                        {
                            assembler.Append(Act.Text(ev.Characters), ev.Time, ev.Time);
                        }
                    }
                    else
                    {
                        if (!options.RecordShortcuts) break;
                        assembler.Append(Act.Key(ev.KeyCode, ev.Modifiers), ev.Time, ev.Time);
                    }
                    break;

                case RawEventKind.KeyUp:
                    // A key action already represents press + release.
                    break;
            }

            index++;
        }

        // If recording stopped while a button was held, release it so replay can't leave it stuck.
        foreach (var button in openButtons)
        {
            var at = assembler.LastEnd ?? 0;
            assembler.Append(Round(Act.MouseUp(lastX, lastY, button)), at, at);
        }

        return assembler.Actions;
    }

    /// <summary>True for ordinary text: not empty and without control characters.</summary>
    public static bool IsPrintable(string characters)
    {
        if (string.IsNullOrEmpty(characters)) return false;
        foreach (var ch in characters)
        {
            if (char.IsControl(ch)) return false;
            if (ch >= 0xF700 && ch <= 0xF8FF) return false;
        }
        return true;
    }

    public static double RoundMilliseconds(double value) => Math.Round(value * 1000, MidpointRounding.AwayFromZero) / 1000;

    public static double RoundPosition(double value) => Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100;

    private static MacroAction Round(MacroAction action)
    {
        if (action.X is double x) action.X = RoundPosition(x);
        if (action.Y is double y) action.Y = RoundPosition(y);
        return action;
    }

    private sealed class Assembler
    {
        public List<MacroAction> Actions { get; } = new();
        public double? LastEnd { get; private set; }

        public void Append(MacroAction action, double start, double end)
        {
            action.Delay = LastEnd is double previousEnd ? RoundMilliseconds(Math.Max(0, start - previousEnd)) : 0;
            Actions.Add(action);
            LastEnd = end;
        }

        public void ExtendLast(double time) => LastEnd = time;
    }
}
