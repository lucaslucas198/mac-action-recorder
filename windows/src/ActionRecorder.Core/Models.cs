namespace ActionRecorder.Core;

public static class RecordingFormat
{
    /// <summary>The file-format version written by this build. See docs/RECORDING_FORMAT.md.</summary>
    public const int CurrentVersion = 1;

    /// <summary>Recordings are stored as <c>&lt;uuid&gt;.macro.json</c>.</summary>
    public const string FileExtension = "macro.json";

    /// <summary>Written into every recording made on Windows. Key codes are Windows virtual-key codes.</summary>
    public const string WindowsPlatform = "windows";

    /// <summary>Recordings from the Mac app carry no platform field; their key codes are macOS key codes.</summary>
    public const string MacPlatform = "macOS";
}

public enum MouseButton
{
    Left,
    Right,
    Other,
}

public enum ActionKind
{
    /// <summary>Move the pointer.</summary>
    Move,
    /// <summary>Move the pointer with a button held down.</summary>
    Drag,
    /// <summary>Press a mouse button and keep it down.</summary>
    MouseDown,
    /// <summary>Release a mouse button.</summary>
    MouseUp,
    /// <summary>Press and release a button (ClickCount 2 = double-click).</summary>
    Click,
    /// <summary>Mouse wheel. Units are wheel units: 120 is one notch.</summary>
    Scroll,
    /// <summary>Press and release one key, optionally with modifiers.</summary>
    Key,
    /// <summary>Type a string of text, independent of the keyboard layout.</summary>
    Text,
    /// <summary>Pause for <c>Duration</c> seconds.</summary>
    Wait,
}

public static class EnumNames
{
    public static string ToJson(this MouseButton button) => button switch
    {
        MouseButton.Left => "left",
        MouseButton.Right => "right",
        _ => "other",
    };

    public static bool TryParseButton(string? text, out MouseButton button)
    {
        switch (text)
        {
            case "left": button = MouseButton.Left; return true;
            case "right": button = MouseButton.Right; return true;
            case "other": button = MouseButton.Other; return true;
            default: button = MouseButton.Left; return false;
        }
    }

    public static string DisplayName(this MouseButton button) => button switch
    {
        MouseButton.Left => "Left",
        MouseButton.Right => "Right",
        _ => "Middle",
    };

    public static string ToJson(this ActionKind kind) => kind switch
    {
        ActionKind.Move => "move",
        ActionKind.Drag => "drag",
        ActionKind.MouseDown => "mouseDown",
        ActionKind.MouseUp => "mouseUp",
        ActionKind.Click => "click",
        ActionKind.Scroll => "scroll",
        ActionKind.Key => "key",
        ActionKind.Text => "text",
        _ => "wait",
    };

    public static bool TryParseKind(string? text, out ActionKind kind)
    {
        foreach (var candidate in Enum.GetValues<ActionKind>())
        {
            if (candidate.ToJson() == text)
            {
                kind = candidate;
                return true;
            }
        }
        kind = ActionKind.Move;
        return false;
    }

    public static string DisplayName(this ActionKind kind) => kind switch
    {
        ActionKind.Move => "Move",
        ActionKind.Drag => "Drag",
        ActionKind.MouseDown => "Mouse down",
        ActionKind.MouseUp => "Mouse up",
        ActionKind.Click => "Click",
        ActionKind.Scroll => "Scroll",
        ActionKind.Key => "Key",
        ActionKind.Text => "Type text",
        _ => "Wait",
    };
}

/// <summary>
/// One step of a macro. <c>Delay</c> is the time in seconds to wait <em>before</em> this action,
/// measured from the end of the previous action, at original (1x) speed. Relative delays keep
/// editing simple: reordering or deleting actions never leaves stale absolute timestamps.
/// </summary>
public sealed record MacroAction
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public ActionKind Kind { get; set; }
    public double Delay { get; set; }

    /// <summary>Pointer position in virtual-screen pixels (origin: top-left of the main display).</summary>
    public double? X { get; set; }
    public double? Y { get; set; }
    public MouseButton? Button { get; set; }
    public int? ClickCount { get; set; }

    public int? ScrollX { get; set; }
    public int? ScrollY { get; set; }

    /// <summary>A Windows virtual-key code (VK_*).</summary>
    public int? KeyCode { get; set; }
    public KeyModifiers? Modifiers { get; set; }
    public string? Text { get; set; }

    public double? Duration { get; set; }

    public MacroAction Copy(bool newId = false)
    {
        var copy = this with { };
        if (newId)
        {
            copy.Id = Guid.NewGuid();
        }
        return copy;
    }
}

/// <summary>Convenient constructors for actions.</summary>
public static class Act
{
    public static MacroAction Move(double x, double y, double delay = 0) =>
        new() { Kind = ActionKind.Move, Delay = delay, X = x, Y = y };

    public static MacroAction Drag(double x, double y, MouseButton button = MouseButton.Left, double delay = 0) =>
        new() { Kind = ActionKind.Drag, Delay = delay, X = x, Y = y, Button = button };

    public static MacroAction MouseDown(double x, double y, MouseButton button = MouseButton.Left, double delay = 0) =>
        new() { Kind = ActionKind.MouseDown, Delay = delay, X = x, Y = y, Button = button };

    public static MacroAction MouseUp(double x, double y, MouseButton button = MouseButton.Left, double delay = 0) =>
        new() { Kind = ActionKind.MouseUp, Delay = delay, X = x, Y = y, Button = button };

    public static MacroAction Click(double x, double y, MouseButton button = MouseButton.Left, int count = 1, double delay = 0) =>
        new() { Kind = ActionKind.Click, Delay = delay, X = x, Y = y, Button = button, ClickCount = count };

    public static MacroAction Scroll(int dx = 0, int dy = 0, double? x = null, double? y = null, double delay = 0) =>
        new() { Kind = ActionKind.Scroll, Delay = delay, X = x, Y = y, ScrollX = dx, ScrollY = dy };

    public static MacroAction Key(int keyCode, KeyModifiers modifiers = KeyModifiers.None, double delay = 0) =>
        new() { Kind = ActionKind.Key, Delay = delay, KeyCode = keyCode, Modifiers = modifiers };

    public static MacroAction Text(string text, double delay = 0) =>
        new() { Kind = ActionKind.Text, Delay = delay, Text = text };

    public static MacroAction Wait(double seconds, double delay = 0) =>
        new() { Kind = ActionKind.Wait, Delay = delay, Duration = seconds };
}

public sealed record ScreenSize(double Width, double Height);

/// <summary>The application a recording was made against (used for the optional foreground check).
/// <c>BundleId</c> holds the program's file name on Windows, for example <c>discord.exe</c>.</summary>
public sealed record TargetApp(string BundleId, string Name);

/// <summary>Playback settings stored with a recording so they travel with the file.</summary>
public sealed record PlaybackDefaults(double Speed = 1.0, int RepeatCount = 1, double LoopDelay = 0);

public sealed class Recording
{
    public int FormatVersion { get; set; } = RecordingFormat.CurrentVersion;
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime ModifiedAt { get; set; } = DateTime.UtcNow;
    public TargetApp? TargetApp { get; set; }
    public ScreenSize? RecordedScreen { get; set; }
    public PlaybackDefaults? PlaybackDefaults { get; set; }
    public string? Notes { get; set; }

    /// <summary>"windows" for recordings made by this app, "macOS" (or null) for the Mac app's files.</summary>
    public string? Platform { get; set; } = RecordingFormat.WindowsPlatform;

    public List<MacroAction> Actions { get; set; } = new();

    public Recording()
    {
    }

    public Recording(string name)
    {
        Name = name;
    }

    /// <summary>True when the key codes in this file are Windows key codes.</summary>
    public bool IsFromWindows => string.Equals(Platform, RecordingFormat.WindowsPlatform, StringComparison.OrdinalIgnoreCase);

    /// <summary>Total recorded time at 1x: all delays plus explicit waits (typing time not included).</summary>
    public double OriginalDuration
    {
        get
        {
            var total = 0.0;
            foreach (var action in Actions)
            {
                total += action.Delay;
                if (action.Kind == ActionKind.Wait)
                {
                    total += action.Duration ?? 0;
                }
            }
            return total;
        }
    }

    /// <summary>A copy that shares nothing with the original (used for undo and for playback snapshots).</summary>
    public Recording Clone()
    {
        return new Recording
        {
            FormatVersion = FormatVersion,
            Id = Id,
            Name = Name,
            CreatedAt = CreatedAt,
            ModifiedAt = ModifiedAt,
            TargetApp = TargetApp,
            RecordedScreen = RecordedScreen,
            PlaybackDefaults = PlaybackDefaults,
            Notes = Notes,
            Platform = Platform,
            Actions = Actions.Select(a => a.Copy()).ToList(),
        };
    }
}
