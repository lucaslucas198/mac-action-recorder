using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using ActionRecorder.Core;

namespace ActionRecorder.Native;

/// <summary>
/// Captures keyboard and mouse input while a recording is running, using Windows low-level hooks.
/// - The hooks exist only between <see cref="Start"/> and <see cref="Stop"/>. Nothing is captured before or after.
/// - Input produced by other programs through SendInput (including this app's own playback) is ignored.
/// - Clicks on this app's own windows, and keys typed into them, are ignored.
/// - The hook callbacks only note the event and return; turning events into actions happens afterwards.
/// </summary>
public sealed class InputRecorder : IInputCapture
{
    private readonly object _gate = new();
    private readonly List<RawEvent> _events = new();
    private readonly HashSet<int> _downKeys = new();
    private readonly HashSet<MouseButton> _heldButtons = new();
    private readonly HashSet<MouseButton> _ignoredButtons = new();
    private readonly Stopwatch _clock = new();

    private Thread? _thread;
    private uint _threadId;
    private IntPtr _keyboardHook;
    private IntPtr _mouseHook;
    private NativeMethods.HookProc? _keyboardProc;
    private NativeMethods.HookProc? _mouseProc;
    private readonly ManualResetEventSlim _ready = new(false);
    private string? _startError;
    private bool _running;

    private HotKey? _ignoredHotKey;
    private bool _includeInjected;

    // click counting
    private MouseButton _lastClickButton;
    private long _lastClickTicks;
    private NativeMethods.POINT _lastClickPoint;
    private int _clickCount;

    public bool IsRunning => _running;

    public int EventCount
    {
        get { lock (_gate) return _events.Count; }
    }

    public double ElapsedSeconds => _clock.Elapsed.TotalSeconds;

    /// <summary>Starts the hooks. Returns null on success, or a message that explains why capturing is not possible.</summary>
    public string? Start(HotKey? ignoredHotKey = null, bool includeInjected = false)
    {
        if (_running) return null;
        if (!Win32Info.IsWindows) return "Recording needs Windows.";

        lock (_gate)
        {
            _events.Clear();
            _downKeys.Clear();
            _heldButtons.Clear();
            _ignoredButtons.Clear();
        }
        _ignoredHotKey = ignoredHotKey;
        _includeInjected = includeInjected;
        _clickCount = 0;
        _lastClickTicks = 0;
        _startError = null;
        _ready.Reset();

        _thread = new Thread(HookLoop) { Name = "ActionRecorder.Hooks", IsBackground = true, Priority = ThreadPriority.Highest };
        _thread.Start();
        if (!_ready.Wait(3000))
        {
            return "Windows did not answer when installing the keyboard and mouse hooks.";
        }
        if (_startError != null)
        {
            _thread.Join(500);
            return _startError;
        }
        _clock.Restart();
        _running = true;
        return null;
    }

    /// <summary>Stops capturing and returns every event in the order it happened.</summary>
    public List<RawEvent> Stop()
    {
        if (_running)
        {
            _running = false;
            if (_threadId != 0)
            {
                NativeMethods.PostThreadMessage(_threadId, NativeMethods.WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
            }
            _thread?.Join(1500);
            _clock.Stop();
        }
        lock (_gate)
        {
            return new List<RawEvent>(_events);
        }
    }

    public void Dispose() => Stop();

    // ------------------------------------------------------------------ hook thread

    private void HookLoop()
    {
        _threadId = NativeMethods.GetCurrentThreadId();
        _keyboardProc = KeyboardHook;
        _mouseProc = MouseHook;
        var module = NativeMethods.GetModuleHandle(null);

        _keyboardHook = NativeMethods.SetWindowsHookEx(NativeMethods.WH_KEYBOARD_LL, _keyboardProc, module, 0);
        var keyboardError = Marshal.GetLastWin32Error();
        _mouseHook = NativeMethods.SetWindowsHookEx(NativeMethods.WH_MOUSE_LL, _mouseProc, module, 0);
        var mouseError = Marshal.GetLastWin32Error();

        if (_keyboardHook == IntPtr.Zero || _mouseHook == IntPtr.Zero)
        {
            _startError = $"Windows refused the input hooks (error {(_keyboardHook == IntPtr.Zero ? keyboardError : mouseError)}). " +
                          "Security software can block this; try allowing Action Recorder in it.";
            Unhook();
            _ready.Set();
            return;
        }
        _ready.Set();

        while (NativeMethods.GetMessage(out _, IntPtr.Zero, 0, 0) > 0)
        {
            // The hooks are called by Windows from inside GetMessage. Nothing else to do here.
        }
        Unhook();
    }

    private void Unhook()
    {
        if (_keyboardHook != IntPtr.Zero) NativeMethods.UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != IntPtr.Zero) NativeMethods.UnhookWindowsHookEx(_mouseHook);
        _keyboardHook = IntPtr.Zero;
        _mouseHook = IntPtr.Zero;
    }

    private double Now => _clock.Elapsed.TotalSeconds;

    private void Add(RawEvent ev)
    {
        lock (_gate)
        {
            _events.Add(ev);
        }
    }

    // ------------------------------------------------------------------ mouse

    private IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && _running)
        {
            try
            {
                HandleMouse((int)wParam, Marshal.PtrToStructure<NativeMethods.MSLLHOOKSTRUCT>(lParam));
            }
            catch (Exception)
            {
                // A hook must never throw; dropping one event is better than breaking the user's input.
            }
        }
        return NativeMethods.CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    private void HandleMouse(int message, NativeMethods.MSLLHOOKSTRUCT data)
    {
        if (!_includeInjected && (data.flags & NativeMethods.LLMHF_INJECTED) != 0) return;
        var time = Now;
        double x = data.pt.X;
        double y = data.pt.Y;

        switch (message)
        {
            case NativeMethods.WM_MOUSEMOVE:
                if (_ignoredButtons.Count > 0) return;
                Add(_heldButtons.Count > 0
                    ? RawEvent.Drag(time, x, y, _heldButtons.First())
                    : RawEvent.Move(time, x, y));
                break;

            case NativeMethods.WM_LBUTTONDOWN: Down(MouseButton.Left, data, time); break;
            case NativeMethods.WM_RBUTTONDOWN: Down(MouseButton.Right, data, time); break;
            case NativeMethods.WM_MBUTTONDOWN: Down(MouseButton.Other, data, time); break;
            case NativeMethods.WM_XBUTTONDOWN: Down(MouseButton.Other, data, time); break;

            case NativeMethods.WM_LBUTTONUP: Up(MouseButton.Left, data, time); break;
            case NativeMethods.WM_RBUTTONUP: Up(MouseButton.Right, data, time); break;
            case NativeMethods.WM_MBUTTONUP: Up(MouseButton.Other, data, time); break;
            case NativeMethods.WM_XBUTTONUP: Up(MouseButton.Other, data, time); break;

            case NativeMethods.WM_MOUSEWHEEL:
            case NativeMethods.WM_MOUSEHWHEEL:
                if (IsOverOwnWindow(data.pt)) return;
                var delta = (short)((data.mouseData >> 16) & 0xFFFF);
                Add(message == NativeMethods.WM_MOUSEWHEEL
                    ? RawEvent.Wheel(time, x, y, 0, delta)
                    : RawEvent.Wheel(time, x, y, delta, 0));
                break;
        }
    }

    private void Down(MouseButton button, NativeMethods.MSLLHOOKSTRUCT data, double time)
    {
        if (IsOverOwnWindow(data.pt))
        {
            _ignoredButtons.Add(button);
            return;
        }
        _heldButtons.Add(button);
        var count = ClickCountFor(button, data.pt);
        Add(RawEvent.Down(time, data.pt.X, data.pt.Y, button, count));
    }

    private void Up(MouseButton button, NativeMethods.MSLLHOOKSTRUCT data, double time)
    {
        if (_ignoredButtons.Remove(button)) return;
        if (!_heldButtons.Remove(button)) return;
        Add(RawEvent.Up(time, data.pt.X, data.pt.Y, button, Math.Max(1, _clickCount)));
    }

    private int ClickCountFor(MouseButton button, NativeMethods.POINT point)
    {
        var now = Stopwatch.GetTimestamp();
        var elapsedMs = (now - _lastClickTicks) * 1000.0 / Stopwatch.Frequency;
        var halfW = Math.Max(2, NativeMethods.GetSystemMetrics(NativeMethods.SM_CXDOUBLECLK) / 2);
        var halfH = Math.Max(2, NativeMethods.GetSystemMetrics(NativeMethods.SM_CYDOUBLECLK) / 2);
        var near = Math.Abs(point.X - _lastClickPoint.X) <= halfW && Math.Abs(point.Y - _lastClickPoint.Y) <= halfH;
        if (_clickCount > 0 && button == _lastClickButton && near && elapsedMs <= NativeMethods.GetDoubleClickTime())
        {
            _clickCount = Math.Min(3, _clickCount + 1);
        }
        else
        {
            _clickCount = 1;
        }
        _lastClickButton = button;
        _lastClickTicks = now;
        _lastClickPoint = point;
        return _clickCount;
    }

    private static bool IsOverOwnWindow(NativeMethods.POINT point)
    {
        try
        {
            var window = NativeMethods.WindowFromPoint(point);
            return window != IntPtr.Zero && Win32Info.IsOwnProcess(Win32Info.ProcessIdOfWindow(window));
        }
        catch (Exception)
        {
            return false;
        }
    }

    // ------------------------------------------------------------------ keyboard

    private IntPtr KeyboardHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && _running)
        {
            try
            {
                HandleKey((int)wParam, Marshal.PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam));
            }
            catch (Exception)
            {
                // see MouseHook
            }
        }
        return NativeMethods.CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    private void HandleKey(int message, NativeMethods.KBDLLHOOKSTRUCT data)
    {
        var injected = (data.flags & NativeMethods.LLKHF_INJECTED) != 0;
        if (injected && !_includeInjected) return;

        var isDown = message == NativeMethods.WM_KEYDOWN || message == NativeMethods.WM_SYSKEYDOWN;
        var vk = (int)data.vkCode;
        var time = Now;

        // Keep track of which keys are down, so modifiers are right and auto-repeat is known.
        bool isRepeat;
        lock (_gate)
        {
            if (isDown)
            {
                isRepeat = !_downKeys.Add(vk);
            }
            else
            {
                _downKeys.Remove(vk);
                isRepeat = false;
            }
        }

        if (KeyCodes.IsModifierKey(vk)) return;

        // Typing into Action Recorder itself (for example a macro name) is not part of the macro.
        if (!injected && Win32Info.IsOwnProcess(Win32Info.ProcessIdOfWindow(NativeMethods.GetForegroundWindow()))) return;

        var modifiers = CurrentModifiers();

        if (_ignoredHotKey is { } hot && hot.Matches(vk, modifiers)) return;

        if (!isDown)
        {
            Add(RawEvent.KeyRelease(time, vk, modifiers));
            return;
        }

        var characters = CharactersFor(vk, (int)data.scanCode, ref modifiers);
        Add(RawEvent.KeyPress(time, vk, modifiers, characters, isRepeat));
    }

    private KeyModifiers CurrentModifiers()
    {
        var result = KeyModifiers.None;
        lock (_gate)
        {
            if (_downKeys.Contains(0x10) || _downKeys.Contains(0xA0) || _downKeys.Contains(0xA1)) result |= KeyModifiers.Shift;
            if (_downKeys.Contains(0x11) || _downKeys.Contains(0xA2) || _downKeys.Contains(0xA3)) result |= KeyModifiers.Control;
            if (_downKeys.Contains(0x12) || _downKeys.Contains(0xA4) || _downKeys.Contains(0xA5)) result |= KeyModifiers.Option;
            if (_downKeys.Contains(0x5B) || _downKeys.Contains(0x5C)) result |= KeyModifiers.Command;
        }
        return result;
    }

    /// <summary>The text the key would produce with the current modifiers and keyboard layout ("" for keys that produce none).
    /// On layouts that use AltGr (Ctrl+Alt) for characters, such a character counts as typing, not as a shortcut.</summary>
    private string CharactersFor(int vk, int scan, ref KeyModifiers modifiers)
    {
        var state = new byte[256];
        void Press(int key) => state[key] = 0x80;
        if (modifiers.Has(KeyModifiers.Shift)) { Press(0x10); Press(0xA0); }
        if (modifiers.Has(KeyModifiers.Control)) { Press(0x11); Press(0xA2); }
        if (modifiers.Has(KeyModifiers.Option)) { Press(0x12); Press(0xA4); }
        if ((NativeMethods.GetKeyState(0x14) & 1) != 0) state[0x14] = 0x01;

        var layout = CurrentLayout();
        var text = Translate(vk, scan, state, layout);

        if (modifiers.Has(KeyModifiers.Control) && modifiers.Has(KeyModifiers.Option)
            && text.Length > 0 && RecordingBuilder.IsPrintable(text))
        {
            // AltGr: Windows reports it as Ctrl+Alt. The character is typed text.
            modifiers &= ~(KeyModifiers.Control | KeyModifiers.Option);
            return text;
        }
        if (modifiers.IntersectsWith(KeyModifiers.Control | KeyModifiers.Option | KeyModifiers.Command))
        {
            return ""; // a shortcut; the builder records it as a key press
        }
        return text;
    }

    private static IntPtr CurrentLayout()
    {
        var window = NativeMethods.GetForegroundWindow();
        var thread = NativeMethods.GetWindowThreadProcessId(window, out _);
        return NativeMethods.GetKeyboardLayout(thread);
    }

    private static string Translate(int vk, int scan, byte[] state, IntPtr layout)
    {
        var buffer = new StringBuilder(8);
        // Flag 0x4 (Windows 10 1607+): do not change the keyboard state, so recording never disturbs dead-key typing.
        var result = NativeMethods.ToUnicodeEx((uint)vk, (uint)scan, state, buffer, buffer.Capacity, 0x4, layout);
        return result > 0 ? buffer.ToString(0, Math.Min(result, buffer.Length)) : "";
    }
}
