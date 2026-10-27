using System.Text.Json.Serialization;

namespace ActionRecorder.Core;

/// <summary>Keyboard modifiers. <c>Option</c> is the Alt key and <c>Command</c> is the Windows key,
/// so the names in recording files match the Mac app's.</summary>
[Flags]
[JsonConverter(typeof(KeyModifiersJsonConverter))]
public enum KeyModifiers
{
    None = 0,
    Shift = 1 << 0,
    Control = 1 << 1,
    Option = 1 << 2,
    Command = 1 << 3,
}

public static class KeyModifiersExt
{
    /// <summary>Stable names used in the recording file, in display order.</summary>
    public static readonly (string Name, KeyModifiers Value)[] Named =
    {
        ("control", KeyModifiers.Control),
        ("option", KeyModifiers.Option),
        ("shift", KeyModifiers.Shift),
        ("command", KeyModifiers.Command),
    };

    public static bool Has(this KeyModifiers value, KeyModifiers flag) => (value & flag) == flag && flag != KeyModifiers.None;

    public static bool IsEmpty(this KeyModifiers value) => value == KeyModifiers.None;

    public static bool IntersectsWith(this KeyModifiers value, KeyModifiers other) => (value & other) != KeyModifiers.None;

    public static List<string> ToNames(this KeyModifiers value)
    {
        var names = new List<string>();
        foreach (var (name, flag) in Named)
        {
            if (value.Has(flag))
            {
                names.Add(name);
            }
        }
        return names;
    }

    /// <summary>Returns null if a name is not a known modifier.</summary>
    public static KeyModifiers? FromNames(IEnumerable<string> names)
    {
        var result = KeyModifiers.None;
        foreach (var name in names)
        {
            var match = Named.FirstOrDefault(n => n.Name == name);
            if (match.Name == null)
            {
                return null;
            }
            result |= match.Value;
        }
        return result;
    }

    /// <summary>Display text such as "Ctrl+Alt+Shift+Win+" (empty for none).</summary>
    public static string Prefix(this KeyModifiers value)
    {
        var text = "";
        if (value.Has(KeyModifiers.Control)) text += "Ctrl+";
        if (value.Has(KeyModifiers.Option)) text += "Alt+";
        if (value.Has(KeyModifiers.Shift)) text += "Shift+";
        if (value.Has(KeyModifiers.Command)) text += "Win+";
        return text;
    }
}

public sealed class KeyModifiersJsonConverter : JsonConverter<KeyModifiers>
{
    public override KeyModifiers Read(ref System.Text.Json.Utf8JsonReader reader, Type typeToConvert, System.Text.Json.JsonSerializerOptions options)
    {
        var names = System.Text.Json.JsonSerializer.Deserialize<List<string>>(ref reader, options) ?? new List<string>();
        return KeyModifiersExt.FromNames(names) ?? throw new System.Text.Json.JsonException("Unknown modifier name.");
    }

    public override void Write(System.Text.Json.Utf8JsonWriter writer, KeyModifiers value, System.Text.Json.JsonSerializerOptions options)
    {
        System.Text.Json.JsonSerializer.Serialize(writer, value.ToNames(), options);
    }
}

/// <summary>Windows virtual-key codes used by presets and defaults.</summary>
public static class KeyCodes
{
    public const int Backspace = 0x08;
    public const int Tab = 0x09;
    public const int Return = 0x0D;
    public const int Shift = 0x10;
    public const int Control = 0x11;
    public const int Menu = 0x12; // Alt
    public const int Pause = 0x13;
    public const int CapsLock = 0x14;
    public const int Escape = 0x1B;
    public const int Space = 0x20;
    public const int PageUp = 0x21;
    public const int PageDown = 0x22;
    public const int End = 0x23;
    public const int Home = 0x24;
    public const int Left = 0x25;
    public const int Up = 0x26;
    public const int Right = 0x27;
    public const int Down = 0x28;
    public const int Insert = 0x2D;
    public const int Delete = 0x2E;
    public const int K = 0x4B;
    public const int S = 0x53;
    public const int LWin = 0x5B;
    public const int RWin = 0x5C;
    public const int F1 = 0x70;
    public const int F24 = 0x87;
    public const int LShift = 0xA0;
    public const int RShift = 0xA1;
    public const int LControl = 0xA2;
    public const int RControl = 0xA3;
    public const int LMenu = 0xA4;
    public const int RMenu = 0xA5;

    /// <summary>True for keys that are only modifiers (they are tracked, not recorded as key presses).</summary>
    public static bool IsModifierKey(int vk) =>
        vk == Shift || vk == Control || vk == Menu
        || (vk >= LShift && vk <= RMenu)
        || vk == LWin || vk == RWin;

    /// <summary>Keys whose key-down event needs the "extended key" flag when sent.</summary>
    public static bool IsExtendedKey(int vk) => vk switch
    {
        PageUp or PageDown or End or Home or Left or Up or Right or Down or Insert or Delete => true,
        0x2C or 0x6F or 0x90 => true, // Print Screen, numpad divide, Num Lock
        RControl or RMenu or LWin or RWin or 0x5D => true,
        _ => false,
    };
}

public static class KeyNames
{
    private static readonly Dictionary<int, string> Names = BuildNames();

    private static Dictionary<int, string> BuildNames()
    {
        var map = new Dictionary<int, string>
        {
            [0x08] = "Backspace", [0x09] = "Tab", [0x0C] = "Clear", [0x0D] = "Enter",
            [0x10] = "Shift", [0x11] = "Ctrl", [0x12] = "Alt", [0x13] = "Pause", [0x14] = "Caps Lock",
            [0x1B] = "Esc", [0x20] = "Space", [0x21] = "Page Up", [0x22] = "Page Down", [0x23] = "End",
            [0x24] = "Home", [0x25] = "←", [0x26] = "↑", [0x27] = "→", [0x28] = "↓",
            [0x2C] = "Print Screen", [0x2D] = "Insert", [0x2E] = "Delete",
            [0x5B] = "Left Win", [0x5C] = "Right Win", [0x5D] = "Menu",
            [0x6A] = "Num *", [0x6B] = "Num +", [0x6C] = "Num Separator", [0x6D] = "Num -",
            [0x6E] = "Num .", [0x6F] = "Num /", [0x90] = "Num Lock", [0x91] = "Scroll Lock",
            [0xA0] = "Left Shift", [0xA1] = "Right Shift", [0xA2] = "Left Ctrl", [0xA3] = "Right Ctrl",
            [0xA4] = "Left Alt", [0xA5] = "Right Alt",
            [0xBA] = ";", [0xBB] = "=", [0xBC] = ",", [0xBD] = "-", [0xBE] = ".", [0xBF] = "/", [0xC0] = "`",
            [0xDB] = "[", [0xDC] = "\\", [0xDD] = "]", [0xDE] = "'",
        };
        for (var digit = 0; digit <= 9; digit++)
        {
            map[0x30 + digit] = digit.ToString();
            map[0x60 + digit] = "Num " + digit;
        }
        for (var letter = 0; letter < 26; letter++)
        {
            map[0x41 + letter] = ((char)('A' + letter)).ToString();
        }
        for (var f = 1; f <= 24; f++)
        {
            map[0x6F + f] = "F" + f;
        }
        return map;
    }

    public static string NameFor(int keyCode) => Names.TryGetValue(keyCode, out var name) ? name : $"Key {keyCode}";

    /// <summary>Example: "Ctrl+K", "Ctrl+Alt+Shift+S", "Enter".</summary>
    public static string Display(int keyCode, KeyModifiers modifiers) => modifiers.Prefix() + NameFor(keyCode);
}

/// <summary>A global keyboard shortcut (used for the emergency stop).</summary>
public sealed record HotKey(int KeyCode, KeyModifiers Modifiers)
{
    /// <summary>Ctrl+Alt+Shift+S. Unlikely to collide with Discord, games or Windows shortcuts.</summary>
    public static readonly HotKey DefaultEmergencyStop = new(KeyCodes.S, KeyModifiers.Control | KeyModifiers.Option | KeyModifiers.Shift);

    public bool Matches(int keyCode, KeyModifiers modifiers) => KeyCode == keyCode && Modifiers == modifiers;

    public string DisplayString => KeyNames.Display(KeyCode, Modifiers);

    /// <summary>A usable emergency stop has a real key and at least one of Ctrl, Alt or Win.</summary>
    public bool IsValid =>
        KeyCode > 0 && KeyCode <= RecordingValidator.MaxKeyCode
        && !KeyCodes.IsModifierKey(KeyCode)
        && Modifiers.IntersectsWith(KeyModifiers.Control | KeyModifiers.Option | KeyModifiers.Command);
}
