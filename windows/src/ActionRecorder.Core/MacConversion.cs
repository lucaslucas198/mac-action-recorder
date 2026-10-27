namespace ActionRecorder.Core;

/// <summary>Converts a recording made with the Mac app so it can run on Windows.
/// Key codes are translated (macOS key code to Windows virtual-key code) and the Command modifier becomes Ctrl,
/// the Windows equivalent for shortcuts such as Quick Switcher (Cmd+K on a Mac, Ctrl+K on Windows).
/// Keys with no Windows equivalent are reported, never guessed.</summary>
public static class MacConversion
{
    public sealed record Result(Recording Recording, int Converted, List<string> Problems);

    private static readonly Dictionary<int, int> MacToWindows = Build();

    private static Dictionary<int, int> Build()
    {
        var map = new Dictionary<int, int>
        {
            // letters (ANSI layout)
            [0] = 0x41, [11] = 0x42, [8] = 0x43, [2] = 0x44, [14] = 0x45, [3] = 0x46, [5] = 0x47, [4] = 0x48,
            [34] = 0x49, [38] = 0x4A, [40] = 0x4B, [37] = 0x4C, [46] = 0x4D, [45] = 0x4E, [31] = 0x4F, [35] = 0x50,
            [12] = 0x51, [15] = 0x52, [1] = 0x53, [17] = 0x54, [32] = 0x55, [9] = 0x56, [13] = 0x57, [7] = 0x58,
            [16] = 0x59, [6] = 0x5A,
            // digits
            [29] = 0x30, [18] = 0x31, [19] = 0x32, [20] = 0x33, [21] = 0x34, [23] = 0x35, [22] = 0x36, [26] = 0x37, [28] = 0x38, [25] = 0x39,
            // punctuation
            [27] = 0xBD, [24] = 0xBB, [33] = 0xDB, [30] = 0xDD, [39] = 0xDE, [41] = 0xBA, [42] = 0xDC, [43] = 0xBC, [44] = 0xBF, [47] = 0xBE, [50] = 0xC0,
            // editing and navigation
            [36] = KeyCodes.Return, [76] = KeyCodes.Return, [48] = KeyCodes.Tab, [49] = KeyCodes.Space,
            [51] = KeyCodes.Backspace, [117] = KeyCodes.Delete, [53] = KeyCodes.Escape,
            [115] = KeyCodes.Home, [119] = KeyCodes.End, [116] = KeyCodes.PageUp, [121] = KeyCodes.PageDown,
            [123] = KeyCodes.Left, [124] = KeyCodes.Right, [125] = KeyCodes.Down, [126] = KeyCodes.Up,
            // function keys
            [122] = 0x70, [120] = 0x71, [99] = 0x72, [118] = 0x73, [96] = 0x74, [97] = 0x75,
            [98] = 0x76, [100] = 0x77, [101] = 0x78, [109] = 0x79, [103] = 0x7A, [111] = 0x7B,
        };
        return map;
    }

    public static bool CanConvertKey(int macKeyCode) => MacToWindows.ContainsKey(macKeyCode);

    public static Result FromMac(Recording source)
    {
        var recording = source.Clone();
        var problems = new List<string>();
        var converted = 0;
        var remove = new HashSet<Guid>();

        for (var i = 0; i < recording.Actions.Count; i++)
        {
            var action = recording.Actions[i];
            if (action.Kind != ActionKind.Key) continue;

            if (action.KeyCode is int mac && MacToWindows.TryGetValue(mac, out var vk))
            {
                action.KeyCode = vk;
                var modifiers = action.Modifiers ?? KeyModifiers.None;
                if (modifiers.Has(KeyModifiers.Command))
                {
                    modifiers = (modifiers & ~KeyModifiers.Command) | KeyModifiers.Control;
                }
                action.Modifiers = modifiers;
                converted++;
            }
            else
            {
                problems.Add($"Step {i + 1}: Mac key code {action.KeyCode} has no Windows equivalent, so it was removed.");
                remove.Add(action.Id);
            }
        }

        if (remove.Count > 0)
        {
            recording.DeleteActions(remove);
        }

        recording.Platform = RecordingFormat.WindowsPlatform;
        if (recording.TargetApp is { } app)
        {
            // A Mac bundle id such as com.hnc.Discord does not identify a Windows program.
            recording.TargetApp = null;
            problems.Add($"The target app “{app.Name}” was cleared. Record the target again on Windows to use the foreground check.");
        }
        if (recording.RecordedScreen != null)
        {
            recording.RecordedScreen = null;
            if (recording.Actions.Any(a => a.Kind is ActionKind.Click or ActionKind.MouseDown))
            {
                problems.Add("Clicks use screen positions from the Mac and will land in the wrong place. Re-record clicks on this PC.");
            }
        }
        return new Result(recording, converted, problems);
    }
}
