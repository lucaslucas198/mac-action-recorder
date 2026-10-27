using ActionRecorder.Core;

namespace ActionRecorder.Model;

public enum AppStatus
{
    Idle,
    Preparing,
    Recording,
    Playing,
    Paused,
    Stopped,
    Error,
}

public enum NoticeKind
{
    Info,
    Success,
    Warning,
    Error,
}

/// <summary>One line in the list of actions.</summary>
public sealed class ActionRow : ObservableObject
{
    private int _index;
    private bool _isCurrent;
    private bool _isDone;

    public ActionRow(MacroAction action, int index)
    {
        Action = action;
        _index = index;
    }

    public MacroAction Action { get; }
    public Guid Id => Action.Id;

    public int Index
    {
        get => _index;
        set { if (Set(ref _index, value)) Raise(nameof(Number)); }
    }

    public int Number => _index + 1;

    public ActionKind Kind => Action.Kind;
    public string Title => ActionDescriber.Describe(Action);

    /// <summary>"after 0.40 s" or empty when there is no pause before the action.</summary>
    public string DelayText => Action.Delay >= 0.005 ? "after " + ActionDescriber.FormatSeconds(Action.Delay) : "";

    public string KindName => Action.Kind.DisplayName();

    /// <summary>A short symbol for the kind. Segoe Fluent Icons / plain text, so no image files are needed.</summary>
    public string Glyph => Action.Kind switch
    {
        ActionKind.Move => "↗",
        ActionKind.Drag => "⤨",
        ActionKind.MouseDown => "▼",
        ActionKind.MouseUp => "▲",
        ActionKind.Click => "◉",
        ActionKind.Scroll => "↕",
        ActionKind.Key => "⌨",
        ActionKind.Text => "Aa",
        _ => "⏱",
    };

    public bool IsCurrent
    {
        get => _isCurrent;
        set => Set(ref _isCurrent, value);
    }

    public bool IsDone
    {
        get => _isDone;
        set => Set(ref _isDone, value);
    }

    public void Refresh() => RaiseAll(nameof(Title), nameof(DelayText), nameof(KindName), nameof(Glyph), nameof(Kind));
}

/// <summary>One saved recording in the sidebar.</summary>
public sealed class RecordingEntry : ObservableObject
{
    private string _name;
    private string _subtitle = "";

    public RecordingEntry(Recording recording)
    {
        Recording = recording;
        _name = recording.Name;
        UpdateSubtitle();
    }

    public Recording Recording { get; set; }
    public Guid Id => Recording.Id;

    public string Name
    {
        get => _name;
        private set => Set(ref _name, value);
    }

    public string Subtitle
    {
        get => _subtitle;
        private set => Set(ref _subtitle, value);
    }

    public void UpdateSubtitle()
    {
        Name = Recording.Name;
        var count = Recording.Actions.Count;
        Subtitle = $"{count} action{(count == 1 ? "" : "s")} · {FormatDuration(Recording.OriginalDuration)}";
    }

    public static string FormatDuration(double seconds)
    {
        if (seconds < 60) return seconds.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " s";
        var total = (int)Math.Round(seconds);
        return $"{total / 60}:{total % 60:00} min";
    }
}

/// <summary>One check in the Welcome screen.</summary>
public sealed class SetupCheck : ObservableObject
{
    private string _detail = "";
    private CheckState _state = CheckState.Waiting;

    public SetupCheck(string title) => Title = title;

    public string Title { get; }

    public CheckState State
    {
        get => _state;
        set { if (Set(ref _state, value)) Raise(nameof(Symbol)); }
    }

    public string Detail
    {
        get => _detail;
        set => Set(ref _detail, value);
    }

    public string Symbol => State switch
    {
        CheckState.Ok => "✓",
        CheckState.Warning => "!",
        CheckState.Working => "…",
        _ => "·",
    };
}

public enum CheckState
{
    Waiting,
    Working,
    Ok,
    Warning,
}
