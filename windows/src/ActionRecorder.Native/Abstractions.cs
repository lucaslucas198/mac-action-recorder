using ActionRecorder.Core;

namespace ActionRecorder.Native;

/// <summary>Captures raw input while a recording runs. The real one uses Windows hooks; tests use a fake.</summary>
public interface IInputCapture : IDisposable
{
    bool IsRunning { get; }
    int EventCount { get; }
    double ElapsedSeconds { get; }

    /// <summary>Starts capturing. Returns null on success, otherwise a message that explains why not.</summary>
    string? Start(HotKey? ignoredHotKey = null, bool includeInjected = false);

    /// <summary>Stops capturing and returns every event in the order it happened.</summary>
    List<RawEvent> Stop();
}

/// <summary>Owns the global emergency-stop shortcut.</summary>
public interface IHotKeyRegistrar : IDisposable
{
    event Action? Pressed;
    bool IsRegistered { get; }
    bool Set(HotKey hotKey);
}

/// <summary>Read-only questions about the desktop.</summary>
public interface ISystemProbe
{
    ProgramInfo? ForegroundProgram();
    ScreenSize? PrimaryScreen();
    bool ForegroundIsMoreElevated();
    string WindowsDescription();
    int WindowsBuild { get; }
    int MonitorCount { get; }
}

public sealed class WindowsSystemProbe : ISystemProbe
{
    public ProgramInfo? ForegroundProgram() => Win32Info.ForegroundProgram();
    public ScreenSize? PrimaryScreen() => Win32Info.PrimaryScreen();
    public bool ForegroundIsMoreElevated() => Win32Info.ForegroundIsMoreElevated();
    public string WindowsDescription() => Win32Info.WindowsDescription();
    public int WindowsBuild => Environment.OSVersion.Version.Build;
    public int MonitorCount => Math.Max(1, Win32Info.Monitors().Count);
}
