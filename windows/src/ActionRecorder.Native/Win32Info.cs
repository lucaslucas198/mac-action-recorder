using System.Runtime.InteropServices;
using System.Text;
using ActionRecorder.Core;

namespace ActionRecorder.Native;

public sealed record ProgramInfo(string FileName, string DisplayName);

public readonly record struct MonitorBounds(int Left, int Top, int Width, int Height);

/// <summary>Small read-only questions about the desktop: which program is in front, how big is the screen.</summary>
public static class Win32Info
{
    public static bool IsWindows => OperatingSystem.IsWindows();

    /// <summary>Makes the process per-monitor DPI aware, so coordinates are real screen pixels everywhere.
    /// The app manifest does this too; this call is a fallback for tools that start the process without it.</summary>
    public static void EnsureDpiAware()
    {
        if (!IsWindows) return;
        try
        {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
            if (!NativeMethods.SetProcessDpiAwarenessContext(new IntPtr(-4)))
            {
                NativeMethods.SetProcessDPIAware();
            }
        }
        catch (Exception)
        {
            // Already set by the manifest, or not supported: nothing to do.
        }
    }

    /// <summary>Size of the main display in pixels (null if it cannot be read).</summary>
    public static ScreenSize? PrimaryScreen()
    {
        if (!IsWindows) return null;
        try
        {
            var w = NativeMethods.GetSystemMetrics(NativeMethods.SM_CXSCREEN);
            var h = NativeMethods.GetSystemMetrics(NativeMethods.SM_CYSCREEN);
            return w > 0 && h > 0 ? new ScreenSize(w, h) : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static MonitorBounds VirtualScreen()
    {
        if (!IsWindows) return new MonitorBounds(0, 0, 1920, 1080);
        return new MonitorBounds(
            NativeMethods.GetSystemMetrics(NativeMethods.SM_XVIRTUALSCREEN),
            NativeMethods.GetSystemMetrics(NativeMethods.SM_YVIRTUALSCREEN),
            Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SM_CXVIRTUALSCREEN)),
            Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SM_CYVIRTUALSCREEN)));
    }

    public static List<MonitorBounds> Monitors()
    {
        var list = new List<MonitorBounds>();
        if (!IsWindows) return list;
        NativeMethods.MonitorEnumProc callback = (IntPtr monitor, IntPtr hdc, ref NativeMethods.RECT rect, IntPtr data) =>
        {
            list.Add(new MonitorBounds(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top));
            return true;
        };
        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return list;
    }

    /// <summary>The program that owns the window in front, for example <c>Discord.exe</c>. Null if unknown.</summary>
    public static ProgramInfo? ForegroundProgram()
    {
        if (!IsWindows) return null;
        try
        {
            var window = NativeMethods.GetForegroundWindow();
            return window == IntPtr.Zero ? null : ProgramOfWindow(window);
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static string? ForegroundProgramFileName() => ForegroundProgram()?.FileName;

    public static ProgramInfo? ProgramOfWindow(IntPtr window)
    {
        NativeMethods.GetWindowThreadProcessId(window, out var pid);
        if (pid == 0) return null;
        var path = ImagePath(pid);
        if (path == null) return null;
        var file = Path.GetFileName(path);
        var name = Path.GetFileNameWithoutExtension(path);
        try
        {
            var description = System.Diagnostics.FileVersionInfo.GetVersionInfo(path).FileDescription;
            if (!string.IsNullOrWhiteSpace(description)) name = description!.Trim();
        }
        catch (Exception)
        {
            // keep the file name
        }
        return new ProgramInfo(file, name);
    }

    public static uint ProcessIdOfWindow(IntPtr window)
    {
        if (window == IntPtr.Zero) return 0;
        NativeMethods.GetWindowThreadProcessId(window, out var pid);
        return pid;
    }

    public static bool IsOwnProcess(uint pid) => pid != 0 && pid == NativeMethods.GetCurrentProcessId();

    private static string? ImagePath(uint pid)
    {
        var handle = NativeMethods.OpenProcess(NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (handle == IntPtr.Zero) return null;
        try
        {
            var builder = new StringBuilder(1024);
            var size = (uint)builder.Capacity;
            return NativeMethods.QueryFullProcessImageName(handle, 0, builder, ref size) ? builder.ToString() : null;
        }
        finally
        {
            NativeMethods.CloseHandle(handle);
        }
    }

    /// <summary>True when Action Recorder itself runs as administrator.</summary>
    public static bool IsSelfElevated()
    {
        if (!IsWindows) return false;
        try
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            return new System.Security.Principal.WindowsPrincipal(identity)
                .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>True when the program in front runs with higher rights than this app. Windows then silently blocks
    /// simulated input to it (and hides its keystrokes from recording).</summary>
    public static bool ForegroundIsMoreElevated()
    {
        if (!IsWindows || IsSelfElevated()) return false;
        try
        {
            var window = NativeMethods.GetForegroundWindow();
            var pid = ProcessIdOfWindow(window);
            if (pid == 0 || IsOwnProcess(pid)) return false;
            var process = NativeMethods.OpenProcess(NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (process == IntPtr.Zero) return false;
            try
            {
                if (!NativeMethods.OpenProcessToken(process, NativeMethods.TOKEN_QUERY, out var token))
                {
                    // Access denied on the token of a process we can otherwise see means it has higher rights.
                    return Marshal.GetLastWin32Error() == 5;
                }
                try
                {
                    return NativeMethods.GetTokenInformation(token, NativeMethods.TokenElevation, out var elevation,
                        Marshal.SizeOf<NativeMethods.TOKEN_ELEVATION>(), out _) && elevation.TokenIsElevated != 0;
                }
                finally
                {
                    NativeMethods.CloseHandle(token);
                }
            }
            finally
            {
                NativeMethods.CloseHandle(process);
            }
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static string WindowsDescription()
    {
        var version = Environment.OSVersion.Version;
        return $"Windows {(version.Build >= 22000 ? "11" : "10")} (build {version.Build})";
    }
}
