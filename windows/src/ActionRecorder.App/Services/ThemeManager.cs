using System.Windows;
using Microsoft.Win32;

namespace ActionRecorder.Desktop;

/// <summary>Switches between the dark and light colour sets and the matching Windows Fluent control theme.</summary>
public static class ThemeManager
{
    private static ResourceDictionary? _current;

    /// <summary>"dark", "light" or "system".</summary>
    public static void Apply(string setting)
    {
        var app = Application.Current;
        if (app == null) return;
        var dark = setting switch
        {
            "light" => false,
            "dark" => true,
            _ => !SystemUsesLightTheme(),
        };

        try
        {
            app.ThemeMode = setting switch
            {
                "light" => ThemeMode.Light,
                "dark" => ThemeMode.Dark,
                _ => ThemeMode.System,
            };
        }
        catch (Exception)
        {
            // The Fluent theme needs a recent Windows. The app's own colours still apply without it.
        }

        var dictionary = new ResourceDictionary
        {
            Source = new Uri(dark ? "pack://application:,,,/Themes/Dark.xaml" : "pack://application:,,,/Themes/Light.xaml", UriKind.Absolute),
        };
        if (_current != null) app.Resources.MergedDictionaries.Remove(_current);
        app.Resources.MergedDictionaries.Insert(0, dictionary);
        _current = dictionary;
        IsDark = dark;
    }

    public static bool IsDark { get; private set; } = true;

    private static bool SystemUsesLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value != 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
