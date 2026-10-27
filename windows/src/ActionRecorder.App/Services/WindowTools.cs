using ActionRecorder.Core;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace ActionRecorder.Desktop;

/// <summary>Small Win32 helpers for overlay windows that must not take focus or block clicks.</summary>
public static class WindowTools
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TRANSPARENT = 0x20;
    private const int WS_EX_TOOLWINDOW = 0x80;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

    /// <summary>Makes the window never take keyboard focus, hide from Alt+Tab, and optionally let clicks pass through.</summary>
    public static void MakeOverlay(Window window, bool clickThrough)
    {
        var handle = new WindowInteropHelper(window).EnsureHandle();
        var style = GetWindowLongPtr(handle, GWL_EXSTYLE).ToInt64();
        style |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        if (clickThrough) style |= WS_EX_TRANSPARENT;
        SetWindowLongPtr(handle, GWL_EXSTYLE, new IntPtr(style));
    }

    /// <summary>Places the window at a rectangle given in physical screen pixels, above other windows, without activating it.</summary>
    public static void PlaceTopmost(Window window, int left, int top, int width, int height)
    {
        var handle = new WindowInteropHelper(window).EnsureHandle();
        SetWindowPos(handle, HWND_TOPMOST, left, top, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}
