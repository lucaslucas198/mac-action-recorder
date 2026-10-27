using System.Runtime.InteropServices;
using ActionRecorder.Core;

namespace ActionRecorder.Native;

/// <summary>Plays actions through the normal Windows input path (SendInput), as if typed and clicked by hand.</summary>
public sealed class SendInputPerformer : IActionPerformer
{
    private readonly HashSet<MouseButton> _heldButtons = new();
    private readonly HashSet<int> _heldKeys = new();
    private bool _timerRaised;
    private bool _checkedElevation;
    private double _lastX;
    private double _lastY;

    /// <summary>Set false in tests that run where no elevated program can be in front.</summary>
    public bool CheckElevation { get; set; } = true;

    public void Begin()
    {
        if (!Win32Info.IsWindows) throw new PlaybackException("Playback needs Windows.");
        _checkedElevation = false;
        // Ask Windows for 1 ms timer ticks while a macro plays, so fast mouse paths keep their speed.
        if (NativeMethods.timeBeginPeriod(1) == 0) _timerRaised = true;
    }

    public void Cleanup()
    {
        if (!Win32Info.IsWindows) return;
        try
        {
            // Never leave a button or key stuck down after a stop or an error.
            foreach (var button in _heldButtons.ToList()) SendMouse(ButtonFlag(button, up: true));
            foreach (var key in _heldKeys.ToList()) SendKey(key, up: true);
        }
        catch (Exception)
        {
            // best effort
        }
        finally
        {
            _heldButtons.Clear();
            _heldKeys.Clear();
            if (_timerRaised)
            {
                NativeMethods.timeEndPeriod(1);
                _timerRaised = false;
            }
        }
    }

    public void Perform(MacroAction action)
    {
        EnsureCanSendInput();
        switch (action.Kind)
        {
            case ActionKind.Move:
            case ActionKind.Drag:
                MoveTo(action.X ?? 0, action.Y ?? 0);
                break;

            case ActionKind.MouseDown:
                MoveTo(action.X ?? 0, action.Y ?? 0);
                var downButton = action.Button ?? MouseButton.Left;
                SendMouse(ButtonFlag(downButton, up: false));
                _heldButtons.Add(downButton);
                break;

            case ActionKind.MouseUp:
                MoveTo(action.X ?? 0, action.Y ?? 0);
                var upButton = action.Button ?? MouseButton.Left;
                SendMouse(ButtonFlag(upButton, up: true));
                _heldButtons.Remove(upButton);
                break;

            case ActionKind.Click:
                MoveTo(action.X ?? 0, action.Y ?? 0);
                var button = action.Button ?? MouseButton.Left;
                var count = Math.Clamp(action.ClickCount ?? 1, 1, 3);
                for (var i = 0; i < count; i++)
                {
                    SendMouse(ButtonFlag(button, up: false));
                    _heldButtons.Add(button);
                    Thread.Sleep(12);
                    SendMouse(ButtonFlag(button, up: true));
                    _heldButtons.Remove(button);
                    if (i < count - 1) Thread.Sleep(25);
                }
                break;

            case ActionKind.Scroll:
                if (action.X is double sx && action.Y is double sy) MoveTo(sx, sy);
                if ((action.ScrollY ?? 0) != 0) SendWheel(NativeMethods.MOUSEEVENTF_WHEEL, action.ScrollY!.Value);
                if ((action.ScrollX ?? 0) != 0) SendWheel(NativeMethods.MOUSEEVENTF_HWHEEL, action.ScrollX!.Value);
                break;

            case ActionKind.Key:
                PressKey(action.KeyCode ?? 0, action.Modifiers ?? KeyModifiers.None);
                break;

            case ActionKind.Text:
                TypeText(action.Text ?? "");
                break;

            case ActionKind.Wait:
                break;
        }
    }

    private void EnsureCanSendInput()
    {
        if (_checkedElevation || !CheckElevation) return;
        _checkedElevation = true;
        if (Win32Info.ForegroundIsMoreElevated())
        {
            throw new PlaybackException(
                "The program in front is running as administrator, so Windows blocks input from Action Recorder. " +
                "Start Action Recorder as administrator (right-click, Run as administrator) to control it.");
        }
    }

    // ------------------------------------------------------------------ mouse

    private void MoveTo(double x, double y)
    {
        _lastX = x;
        _lastY = y;
        NativeMethods.SetCursorPos((int)Math.Round(x), (int)Math.Round(y));
    }

    private static uint ButtonFlag(MouseButton button, bool up) => (button, up) switch
    {
        (MouseButton.Left, false) => NativeMethods.MOUSEEVENTF_LEFTDOWN,
        (MouseButton.Left, true) => NativeMethods.MOUSEEVENTF_LEFTUP,
        (MouseButton.Right, false) => NativeMethods.MOUSEEVENTF_RIGHTDOWN,
        (MouseButton.Right, true) => NativeMethods.MOUSEEVENTF_RIGHTUP,
        (_, false) => NativeMethods.MOUSEEVENTF_MIDDLEDOWN,
        _ => NativeMethods.MOUSEEVENTF_MIDDLEUP,
    };

    private static void SendMouse(uint flags, int data = 0)
    {
        var input = new NativeMethods.INPUT { type = NativeMethods.INPUT_MOUSE };
        input.U.mi = new NativeMethods.MOUSEINPUT { dwFlags = flags, mouseData = unchecked((uint)data) };
        Send(input);
    }

    private static void SendWheel(uint flag, int amount)
    {
        // Wheel amounts are in wheel units (120 = one notch). Large amounts are sent in notch-sized steps.
        var remaining = amount;
        var steps = 0;
        while (remaining != 0 && steps < 2000)
        {
            var chunk = Math.Clamp(remaining, -120 * 5, 120 * 5);
            SendMouse(flag, chunk);
            remaining -= chunk;
            steps++;
            if (remaining != 0) Thread.Sleep(2);
        }
    }

    // ------------------------------------------------------------------ keyboard

    private void PressKey(int vk, KeyModifiers modifiers)
    {
        var order = new List<int>();
        if (modifiers.Has(KeyModifiers.Control)) order.Add(KeyCodes.Control);
        if (modifiers.Has(KeyModifiers.Option)) order.Add(KeyCodes.Menu);
        if (modifiers.Has(KeyModifiers.Shift)) order.Add(KeyCodes.Shift);
        if (modifiers.Has(KeyModifiers.Command)) order.Add(KeyCodes.LWin);

        foreach (var modifier in order)
        {
            SendKey(modifier, up: false);
            _heldKeys.Add(modifier);
        }
        if (order.Count > 0) Thread.Sleep(8);

        SendKey(vk, up: false);
        _heldKeys.Add(vk);
        Thread.Sleep(6);
        SendKey(vk, up: true);
        _heldKeys.Remove(vk);

        if (order.Count > 0) Thread.Sleep(8);
        for (var i = order.Count - 1; i >= 0; i--)
        {
            SendKey(order[i], up: true);
            _heldKeys.Remove(order[i]);
        }
    }

    private static void SendKey(int vk, bool up)
    {
        var flags = up ? NativeMethods.KEYEVENTF_KEYUP : 0u;
        if (KeyCodes.IsExtendedKey(vk)) flags |= NativeMethods.KEYEVENTF_EXTENDEDKEY;
        var scan = (ushort)NativeMethods.MapVirtualKey((uint)vk, NativeMethods.MAPVK_VK_TO_VSC);
        var input = new NativeMethods.INPUT { type = NativeMethods.INPUT_KEYBOARD };
        input.U.ki = new NativeMethods.KEYBDINPUT { wVk = (ushort)vk, wScan = scan, dwFlags = flags };
        Send(input);
    }

    private void TypeText(string text)
    {
        foreach (var ch in text)
        {
            switch (ch)
            {
                case '\r':
                    break;
                case '\n':
                    PressKey(KeyCodes.Return, KeyModifiers.None);
                    break;
                case '\t':
                    PressKey(KeyCodes.Tab, KeyModifiers.None);
                    break;
                default:
                    SendUnicode(ch);
                    break;
            }
        }
    }

    /// <summary>Types one UTF-16 unit as a Unicode keystroke, so it works on any keyboard layout (and for emoji, in pairs).</summary>
    private static void SendUnicode(char ch)
    {
        var inputs = new NativeMethods.INPUT[2];
        for (var i = 0; i < 2; i++)
        {
            inputs[i].type = NativeMethods.INPUT_KEYBOARD;
            inputs[i].U.ki = new NativeMethods.KEYBDINPUT
            {
                wVk = 0,
                wScan = ch,
                dwFlags = NativeMethods.KEYEVENTF_UNICODE | (i == 1 ? NativeMethods.KEYEVENTF_KEYUP : 0u),
            };
        }
        SendMany(inputs);
    }

    // ------------------------------------------------------------------ plumbing

    private static void Send(NativeMethods.INPUT input) => SendMany(new[] { input });

    private static void SendMany(NativeMethods.INPUT[] inputs)
    {
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.INPUT>());
        if (sent != inputs.Length)
        {
            var error = Marshal.GetLastWin32Error();
            throw new PlaybackException($"Windows did not accept the simulated input (error {error}).");
        }
    }
}
