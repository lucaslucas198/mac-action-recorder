using ActionRecorder.Core;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace ActionRecorder.Desktop;

/// <summary>Small themed dialogs, built in code so they match the rest of the app.</summary>
public static class Dialogs
{
    public enum Tone
    {
        Normal,
        Danger,
        Warning,
    }

    public static bool Confirm(Window? owner, string title, string message, string confirmText = "OK", string cancelText = "Cancel", Tone tone = Tone.Normal)
    {
        var result = false;
        var window = NewWindow(owner, title, 440);
        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.FindResource("HeadingText"), FontSize = 17, Margin = new Thickness(0, 0, 0, 10) });
        panel.Children.Add(new TextBlock { Text = message, Style = (Style)Application.Current.FindResource("BodyText"), Margin = new Thickness(0, 0, 0, 22) });

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = cancelText, Style = (Style)Application.Current.FindResource("SecondaryButton"), Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
        var ok = new Button
        {
            Content = confirmText,
            Style = (Style)Application.Current.FindResource(tone == Tone.Danger ? "DangerButton" : "PrimaryButton"),
            IsDefault = true,
        };
        ok.Click += (_, _) => { result = true; window.Close(); };
        cancel.Click += (_, _) => window.Close();
        if (!string.IsNullOrEmpty(cancelText)) buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        panel.Children.Add(buttons);
        window.Content = Frame(panel);
        window.ShowDialog();
        return result;
    }

    public static void Info(Window? owner, string title, string message) => Confirm(owner, title, message, "OK", "");

    /// <summary>Asks for one line of text. Returns null if cancelled.</summary>
    public static string? Prompt(Window? owner, string title, string label, string initial = "", string confirmText = "OK")
    {
        string? result = null;
        var window = NewWindow(owner, title, 420);
        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.FindResource("HeadingText"), FontSize = 17, Margin = new Thickness(0, 0, 0, 10) });
        panel.Children.Add(new TextBlock { Text = label, Style = (Style)Application.Current.FindResource("MutedText"), Margin = new Thickness(0, 0, 0, 6) });
        var box = new TextBox { Text = initial, Padding = new Thickness(8, 7, 8, 7), Margin = new Thickness(0, 0, 0, 20) };
        panel.Children.Add(box);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", Style = (Style)Application.Current.FindResource("SecondaryButton"), Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
        var ok = new Button { Content = confirmText, Style = (Style)Application.Current.FindResource("PrimaryButton"), IsDefault = true };
        ok.Click += (_, _) => { result = box.Text; window.Close(); };
        cancel.Click += (_, _) => window.Close();
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        panel.Children.Add(buttons);
        window.Content = Frame(panel);
        window.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        window.ShowDialog();
        return result;
    }

    private static Border Frame(UIElement content) => new()
    {
        Background = (System.Windows.Media.Brush)Application.Current.FindResource("SurfaceBrush"),
        BorderBrush = (System.Windows.Media.Brush)Application.Current.FindResource("LineBrush"),
        BorderThickness = new Thickness(1),
        Child = content,
    };

    private static Window NewWindow(Window? owner, string title, double width)
    {
        var window = new Window
        {
            Title = title,
            Width = width,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = owner != null && owner.IsVisible ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            ShowInTaskbar = false,
            Background = (System.Windows.Media.Brush)Application.Current.FindResource("SurfaceBrush"),
            FontFamily = (System.Windows.Media.FontFamily)Application.Current.FindResource("UiFont"),
        };
        if (owner != null && owner.IsVisible) window.Owner = owner;
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); };
        return window;
    }
}
