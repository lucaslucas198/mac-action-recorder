using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using ActionRecorder.Core;
using ActionRecorder.Model;
using CoreMouseButton = ActionRecorder.Core.MouseButton;

namespace ActionRecorder.Desktop;

/// <summary>The "Details" tab: edit the selected action. Built in code so every field is checked by the compiler.</summary>
public sealed class InspectorView : StackPanel
{
    private readonly AppModel _model;
    private readonly TextBlock _error;

    public InspectorView(AppModel model)
    {
        _model = model;
        _error = new TextBlock
        {
            Foreground = (System.Windows.Media.Brush)Application.Current.FindResource("DangerBrush"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 10, 0, 0),
            FontSize = 12,
        };
    }

    /// <summary>Raised after a valid edit, with the id of the edited action so the list can select it again.</summary>
    public event Action<Guid>? Edited;

    public void Show(IReadOnlyList<ActionRow> rows)
    {
        Children.Clear();
        _error.Text = "";

        if (rows.Count == 0)
        {
            AddHint(_model.HasActions
                ? "Select an action in the list to see and change its details."
                : "Details appear here once the macro has actions.");
            return;
        }

        if (rows.Count > 1)
        {
            Children.Add(Heading($"{rows.Count} actions selected"));
            AddHint("Use the buttons above the list to duplicate, move or delete them together, or “Play only the selected actions”.");
            return;
        }

        var row = rows[0];
        var action = row.Action;
        Children.Add(Heading($"{row.KindName}  ·  #{row.Number}"));
        AddHint(row.Title);

        var editable = _model.CanEdit;

        AddNumberField("Wait before this action (seconds)", action.Delay, editable, (a, v) => { a.Delay = v; return null; }, action.Id);

        switch (action.Kind)
        {
            case ActionKind.Move:
                AddPosition(action, editable);
                break;
            case ActionKind.Drag:
            case ActionKind.MouseDown:
            case ActionKind.MouseUp:
                AddPosition(action, editable);
                AddButtonChoice(action, editable);
                break;
            case ActionKind.Click:
                AddPosition(action, editable);
                AddButtonChoice(action, editable);
                AddChoice("Clicks", new[] { "Single", "Double", "Triple" }, Math.Clamp((action.ClickCount ?? 1) - 1, 0, 2), editable,
                    index => Commit(action.Id, a => a.ClickCount = index + 1));
                break;
            case ActionKind.Scroll:
                AddNumberField("Scroll down / up (notches, negative = down)", action.ScrollY ?? 0, editable,
                    (a, v) => { a.ScrollY = (int)Math.Round(v); return null; }, action.Id);
                AddNumberField("Scroll right / left (notches)", action.ScrollX ?? 0, editable,
                    (a, v) => { a.ScrollX = (int)Math.Round(v); return null; }, action.Id);
                break;
            case ActionKind.Key:
                AddKeyEditor(action, editable);
                break;
            case ActionKind.Text:
                AddTextEditor(action, editable);
                break;
            case ActionKind.Wait:
                AddNumberField("Wait for (seconds)", action.Duration ?? 0, editable, (a, v) => { a.Duration = v; return null; }, action.Id);
                break;
        }

        if (!editable) AddHint("Editing is paused while recording or playing.");
        Children.Add(_error);
    }

    // ------------------------------------------------------------------ pieces

    private static TextBlock Heading(string text) => new()
    {
        Text = text,
        FontSize = 14,
        FontWeight = FontWeights.SemiBold,
        TextWrapping = TextWrapping.Wrap,
    };

    private void AddHint(string text)
    {
        Children.Add(new TextBlock
        {
            Text = text,
            Style = (Style)Application.Current.FindResource("MutedText"),
            Margin = new Thickness(0, 4, 0, 4),
        });
    }

    private void AddLabel(string text)
    {
        Children.Add(new TextBlock { Text = text, Style = (Style)Application.Current.FindResource("FieldLabel") });
    }

    private static string FormatNumber(double value) => value.ToString("0.###", CultureInfo.CurrentCulture);

    private static bool TryParse(string text, out double value) =>
        double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.CurrentCulture, out value) ||
        double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);

    private TextBox AddField(string label, string initial, bool editable, Func<string, string?> apply, bool multiline = false)
    {
        AddLabel(label);
        var box = new TextBox
        {
            Text = initial,
            IsEnabled = editable,
            Padding = new Thickness(8, 6, 8, 6),
            AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            MinHeight = multiline ? 90 : 0,
            VerticalScrollBarVisibility = multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled,
        };
        void CommitIfChanged()
        {
            if (box.Text == initial) return;
            var error = apply(box.Text);
            if (error != null) _error.Text = error;
        }
        box.LostFocus += (_, _) => CommitIfChanged();
        if (!multiline)
        {
            box.KeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter)
                {
                    CommitIfChanged();
                    e.Handled = true;
                }
            };
        }
        Children.Add(box);
        return box;
    }

    private void AddNumberField(string label, double initial, bool editable, Func<MacroAction, double, string?> set, Guid id)
    {
        AddField(label, FormatNumber(initial), editable, text =>
        {
            if (!TryParse(text, out var value) || !double.IsFinite(value)) return "Enter a number.";
            string? problem = null;
            if (!_model.EditAction(id, a => problem = set(a, value), out var error))
            {
                return error ?? "That value is not allowed.";
            }
            if (problem != null) return problem;
            Edited?.Invoke(id);
            return null;
        });
    }

    private void AddPosition(MacroAction action, bool editable)
    {
        AddNumberField("X (pixels from the left of the main screen)", action.X ?? 0, editable, (a, v) => { a.X = v; return null; }, action.Id);
        AddNumberField("Y (pixels from the top of the main screen)", action.Y ?? 0, editable, (a, v) => { a.Y = v; return null; }, action.Id);
    }

    private void AddChoice(string label, IReadOnlyList<string> options, int selected, bool editable, Action<int> onChanged)
    {
        AddLabel(label);
        var combo = new ComboBox { IsEnabled = editable, ItemsSource = options, SelectedIndex = selected, Padding = new Thickness(8, 6, 8, 6) };
        var initial = selected;
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedIndex < 0 || combo.SelectedIndex == initial) return;
            onChanged(combo.SelectedIndex);
        };
        Children.Add(combo);
    }

    private void AddButtonChoice(MacroAction action, bool editable)
    {
        var current = action.Button ?? CoreMouseButton.Left;
        var names = new[] { "Left", "Right", "Other (middle)" };
        var values = new[] { CoreMouseButton.Left, CoreMouseButton.Right, CoreMouseButton.Other };
        AddChoice("Mouse button", names, Math.Max(0, Array.IndexOf(values, current)), editable,
            index => Commit(action.Id, a => a.Button = values[index]));
    }

    private void AddKeyEditor(MacroAction action, bool editable)
    {
        var keys = KeyChoices();
        var currentCode = action.KeyCode ?? 0;
        if (keys.All(k => k.Code != currentCode)) keys.Add((KeyNames.NameFor(currentCode), currentCode));

        AddLabel("Key");
        var combo = new ComboBox
        {
            IsEnabled = editable,
            ItemsSource = keys.Select(k => k.Name).ToList(),
            SelectedIndex = keys.FindIndex(k => k.Code == currentCode),
            Padding = new Thickness(8, 6, 8, 6),
            MaxDropDownHeight = 260,
        };
        var initialIndex = combo.SelectedIndex;
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedIndex < 0 || combo.SelectedIndex == initialIndex) return;
            var code = keys[combo.SelectedIndex].Code;
            Commit(action.Id, a => a.KeyCode = code);
        };
        Children.Add(combo);

        AddLabel("Held together with");
        var modifiers = action.Modifiers ?? KeyModifiers.None;
        var panel = new WrapPanel();
        foreach (var (name, value) in new[]
                 {
                     ("Ctrl", KeyModifiers.Control), ("Alt", KeyModifiers.Option), ("Shift", KeyModifiers.Shift), ("Win", KeyModifiers.Command),
                 })
        {
            var box = new CheckBox { Content = name, IsChecked = modifiers.Has(value), IsEnabled = editable, Margin = new Thickness(0, 0, 14, 4) };
            var flag = value;
            box.Click += (_, _) =>
            {
                var on = box.IsChecked == true;
                Commit(action.Id, a =>
                {
                    var m = a.Modifiers ?? KeyModifiers.None;
                    a.Modifiers = on ? m | flag : m & ~flag;
                });
            };
            panel.Children.Add(box);
        }
        Children.Add(panel);
    }

    private void AddTextEditor(MacroAction action, bool editable)
    {
        var secret = MacroAnalyzer.LooksLikeSecret(action.Text ?? "");
        var box = AddField("Text to type", action.Text ?? "", editable, text =>
        {
            return Commit(action.Id, a => a.Text = text) ? null : _error.Text;
        }, multiline: true);
        box.MaxLength = 5000;
        if (secret)
        {
            AddHint("This looks like a password or key. Saved macros store typed text in readable form.");
        }
    }

    private bool Commit(Guid id, Action<MacroAction> change)
    {
        if (_model.EditAction(id, change, out var error))
        {
            _error.Text = "";
            Edited?.Invoke(id);
            return true;
        }
        _error.Text = error ?? "That change is not allowed.";
        return false;
    }

    private static List<(string Name, int Code)> KeyChoices()
    {
        var codes = new List<int>
        {
            KeyCodes.Return, KeyCodes.Tab, KeyCodes.Escape, KeyCodes.Space, KeyCodes.Backspace, KeyCodes.Delete,
            KeyCodes.Left, KeyCodes.Up, KeyCodes.Right, KeyCodes.Down, KeyCodes.Home, KeyCodes.End, KeyCodes.PageUp, KeyCodes.PageDown, KeyCodes.Insert,
        };
        for (var c = 'A'; c <= 'Z'; c++) codes.Add(c);
        for (var d = '0'; d <= '9'; d++) codes.Add(d);
        for (var f = 0; f < 12; f++) codes.Add(KeyCodes.F1 + f);
        return codes.Select(c => (KeyNames.NameFor(c), c)).ToList();
    }
}
