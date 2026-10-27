namespace ActionRecorder.Core;

/// <summary>Optional, keyboard-only building blocks for common Discord tasks.
/// None of these contain screen coordinates. They rely on Discord's own keyboard shortcut
/// (the Quick Switcher, Ctrl+K), which is more robust than clicking at fixed positions.
/// Discord can change its shortcuts at any time; insert a preset, then check it behaves as expected.</summary>
public static class Presets
{
    public sealed record Info(string Id, string Title, string Detail, string? InputLabel, string? SecondInputLabel);

    public static readonly Info[] All =
    {
        new("open-channel", "Open channel with Quick Switcher", "Ctrl+K, type the channel or person, Enter.", "Channel or person", null),
        new("send-message", "Type message and send", "Types your text, then presses Enter.", "Message", null),
        new("open-and-send", "Open channel, then send message", "Quick Switcher to the channel, wait, type the message, Enter.", "Channel or person", "Message"),
    };

    public static List<MacroAction> Actions(string id, string input, string secondInput = "") => id switch
    {
        "open-channel" => OpenChannel(input),
        "send-message" => SendMessage(input),
        "open-and-send" => OpenChannel(input).Concat(new[] { Act.Wait(0.5) }).Concat(SendMessage(secondInput)).ToList(),
        _ => new List<MacroAction>(),
    };

    public static List<MacroAction> OpenChannel(string name) => new()
    {
        Act.Key(KeyCodes.K, KeyModifiers.Control, delay: 0.2),
        Act.Wait(0.4),
        Act.Text(name),
        Act.Wait(0.6),
        Act.Key(KeyCodes.Return),
    };

    public static List<MacroAction> SendMessage(string message) => new()
    {
        Act.Text(message, delay: 0.2),
        Act.Key(KeyCodes.Return, delay: 0.15),
    };
}
