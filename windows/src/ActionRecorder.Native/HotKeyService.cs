using ActionRecorder.Core;

namespace ActionRecorder.Native;

/// <summary>Registers one global shortcut (the emergency stop) with Windows. Only the shortcut is delivered to the app;
/// no other keystroke is seen. The shortcut works whichever program is in front, as long as it is not running as administrator
/// while this app is not.</summary>
public sealed class HotKeyService : IHotKeyRegistrar
{
    private const int HotKeyId = 0x4152; // "AR"
    private const int ApplyMessage = NativeMethods.WM_APP + 1;

    private readonly Thread _thread;
    private readonly ManualResetEventSlim _ready = new(false);
    private uint _threadId;
    private volatile HotKey? _pending;
    private bool _disposed;
    private volatile bool _registered;
    private volatile int _lastError;

    /// <summary>Raised on a background thread when the shortcut is pressed.</summary>
    public event Action? Pressed;

    public HotKeyService()
    {
        _thread = new Thread(Loop) { Name = "ActionRecorder.HotKey", IsBackground = true };
        if (Win32Info.IsWindows)
        {
            _thread.Start();
            _ready.Wait(2000);
        }
    }

    /// <summary>True when Windows accepted the shortcut. False if another program already uses it.</summary>
    public bool IsRegistered => _registered;

    public int LastError => _lastError;

    /// <summary>Changes the shortcut and waits briefly for the result.</summary>
    public bool Set(HotKey hotKey)
    {
        if (!Win32Info.IsWindows || _disposed || _threadId == 0) return false;
        _pending = hotKey;
        using var done = new ManualResetEventSlim(false);
        _applied = done;
        NativeMethods.PostThreadMessage(_threadId, ApplyMessage, UIntPtr.Zero, IntPtr.Zero);
        done.Wait(1500);
        _applied = null;
        return _registered;
    }

    private volatile ManualResetEventSlim? _applied;

    private void Loop()
    {
        _threadId = NativeMethods.GetCurrentThreadId();
        // Force creation of this thread's message queue before anyone posts to it.
        NativeMethods.GetCursorPos(out _);
        _ready.Set();

        while (NativeMethods.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            if (msg.message == NativeMethods.WM_HOTKEY && (int)msg.wParam == HotKeyId)
            {
                try { Pressed?.Invoke(); } catch (Exception) { /* a handler must not kill the loop */ }
            }
            else if (msg.message == ApplyMessage)
            {
                Apply();
            }
        }
        NativeMethods.UnregisterHotKey(IntPtr.Zero, HotKeyId);
    }

    private void Apply()
    {
        NativeMethods.UnregisterHotKey(IntPtr.Zero, HotKeyId);
        _registered = false;
        var hotKey = _pending;
        if (hotKey != null && hotKey.IsValid)
        {
            uint mods = NativeMethods.MOD_NOREPEAT;
            if (hotKey.Modifiers.Has(KeyModifiers.Control)) mods |= NativeMethods.MOD_CONTROL;
            if (hotKey.Modifiers.Has(KeyModifiers.Option)) mods |= NativeMethods.MOD_ALT;
            if (hotKey.Modifiers.Has(KeyModifiers.Shift)) mods |= NativeMethods.MOD_SHIFT;
            if (hotKey.Modifiers.Has(KeyModifiers.Command)) mods |= NativeMethods.MOD_WIN;
            _registered = NativeMethods.RegisterHotKey(IntPtr.Zero, HotKeyId, mods, (uint)hotKey.KeyCode);
            _lastError = _registered ? 0 : System.Runtime.InteropServices.Marshal.GetLastWin32Error();
        }
        _applied?.Set();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (Win32Info.IsWindows && _threadId != 0)
        {
            NativeMethods.PostThreadMessage(_threadId, NativeMethods.WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
            _thread.Join(1000);
        }
    }
}
