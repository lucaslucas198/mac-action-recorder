using System.Globalization;

namespace ActionRecorder.Core;

/// <summary>Human-readable one-line descriptions for the action list.</summary>
public static class ActionDescriber
{
    public static string Describe(MacroAction action)
    {
        switch (action.Kind)
        {
            case ActionKind.Move:
                return $"Move mouse to {Point(action)}";
            case ActionKind.Drag:
                return $"Drag ({ButtonName(action)}) to {Point(action)}";
            case ActionKind.MouseDown:
                return $"Press {ButtonName(action).ToLowerInvariant()} button at {Point(action)}";
            case ActionKind.MouseUp:
                return $"Release {ButtonName(action).ToLowerInvariant()} button at {Point(action)}";
            case ActionKind.Click:
                var prefix = (action.ClickCount ?? 1) switch
                {
                    2 => "double-click",
                    3 => "triple-click",
                    _ => "click",
                };
                return $"{ButtonName(action)} {prefix} at {Point(action)}";
            case ActionKind.Scroll:
                return $"Scroll (horizontal {action.ScrollX ?? 0}, vertical {action.ScrollY ?? 0})";
            case ActionKind.Key:
                var shown = KeyNames.Display(action.KeyCode ?? -1, action.Modifiers ?? KeyModifiers.None);
                return $"Press {shown}";
            case ActionKind.Text:
                return $"Type “{Preview(action.Text ?? "")}”";
            default:
                return $"Wait {FormatSeconds(action.Duration ?? 0)}";
        }
    }

    public static string FormatSeconds(double seconds) =>
        seconds >= 10
            ? seconds.ToString("0.0", CultureInfo.InvariantCulture) + " s"
            : seconds.ToString("0.00", CultureInfo.InvariantCulture) + " s";

    private static string Point(MacroAction action) =>
        $"({(int)Math.Round(action.X ?? 0, MidpointRounding.AwayFromZero)}, {(int)Math.Round(action.Y ?? 0, MidpointRounding.AwayFromZero)})";

    private static string ButtonName(MacroAction action) => (action.Button ?? MouseButton.Left).DisplayName();

    private static string Preview(string text)
    {
        var singleLine = text.Replace("\n", "⏎").Replace("\r", "");
        var elements = TextUnits.Split(singleLine);
        return elements.Count > 40 ? string.Concat(elements.Take(40)) + "…" : singleLine;
    }
}
