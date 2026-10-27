using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using ActionRecorder.Core;
using ActionRecorder.Model;
using ActionRecorder.Native;
using Microsoft.Win32;

namespace ActionRecorder.Desktop;

public partial class SettingsWindow : Window
{
    private readonly AppModel _model;
    private readonly AppSettings _draft;
    private readonly string _originalTheme;
    private readonly FrameworkElement[] _pages;
    private bool _saved;

    public SettingsWindow(AppModel model)
    {
        _model = model;
        _originalTheme = model.Settings.Theme;
        _draft = SettingsStore.FromJson(SettingsStore.ToJson(model.Settings));
        InitializeComponent();
        DataContext = _draft;

        _pages = new FrameworkElement[]
        {
            PageRecording, PagePlayback, PageStorage, PageAi, PageUpdates, PageAppearance, PagePrivacy, PageAbout,
        };

        HotKeyBox.Text = _draft.EmergencyStop.DisplayString;
        SaveFolderDefault.Text = "Default: " + AppPaths.DefaultRecordingsFolder;
        ThemeDark.IsChecked = _draft.Theme == "dark";
        ThemeLight.IsChecked = _draft.Theme == "light";
        ThemeSystem.IsChecked = _draft.Theme == "system";
        AboutVersion.Text = "Version " + model.Version;
        AboutSystem.Text = model.SystemSummary;
        RefreshAccess();
        RefreshAiText();
        RefreshUpdateText();

        model.PropertyChanged += OnModelChanged;
        Closed += (_, _) =>
        {
            model.PropertyChanged -= OnModelChanged;
            if (!_saved) ThemeManager.Apply(_originalTheme);
        };
    }

    internal void SelectPage(int index) => Nav.SelectedIndex = index;

    private void OnModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppModel.AiMessage):
            case nameof(AppModel.AiBusyText):
            case nameof(AppModel.AiState):
                RefreshAiText();
                break;
            case nameof(AppModel.UpdateState):
            case nameof(AppModel.UpdateText):
                RefreshUpdateText();
                break;
        }
    }

    private void OnNavChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_pages == null) return;
        for (var i = 0; i < _pages.Length; i++)
        {
            _pages[i].Visibility = i == Nav.SelectedIndex ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    // ------------------------------------------------------------------ appearance

    private void OnThemeChoice(object sender, RoutedEventArgs e)
    {
        _draft.Theme = ThemeLight.IsChecked == true ? "light" : ThemeSystem.IsChecked == true ? "system" : "dark";
        ThemeManager.Apply(_draft.Theme);
    }

    // ------------------------------------------------------------------ emergency stop shortcut

    private void OnHotKeyFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        HotKeyBox.Text = "Press the shortcut…";
    }

    private void OnHotKeyBlur(object sender, KeyboardFocusChangedEventArgs e)
    {
        HotKeyBox.Text = _draft.EmergencyStop.DisplayString;
    }

    private void OnHotKeyKey(object sender, KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.None or Key.ImeProcessed or Key.DeadCharProcessed or Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt
            or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
        {
            return;
        }

        var modifiers = KeyModifiers.None;
        var held = Keyboard.Modifiers;
        if (held.HasFlag(ModifierKeys.Control)) modifiers |= KeyModifiers.Control;
        if (held.HasFlag(ModifierKeys.Alt)) modifiers |= KeyModifiers.Option;
        if (held.HasFlag(ModifierKeys.Shift)) modifiers |= KeyModifiers.Shift;
        if (held.HasFlag(ModifierKeys.Windows)) modifiers |= KeyModifiers.Command;

        var candidate = new HotKey(KeyInterop.VirtualKeyFromKey(key), modifiers);
        if (!candidate.IsValid)
        {
            HotKeyHint.Text = "Hold at least one of Ctrl, Alt, Shift or Win while pressing the key.";
            return;
        }
        _draft.EmergencyStop = candidate;
        HotKeyBox.Text = candidate.DisplayString;
        HotKeyHint.Text = "Saved when you press Save. Pick something other programs don't use.";
        Keyboard.ClearFocus();
        FocusManager.SetFocusedElement(this, null);
    }

    // ------------------------------------------------------------------ storage

    private static string? PickFolder(Window owner, string title, string? current)
    {
        var dialog = new OpenFolderDialog { Title = title, Multiselect = false };
        if (!string.IsNullOrWhiteSpace(current) && System.IO.Directory.Exists(current)) dialog.InitialDirectory = current;
        return dialog.ShowDialog(owner) == true ? dialog.FolderName : null;
    }

    private void OnBrowseSave(object sender, RoutedEventArgs e)
    {
        var folder = PickFolder(this, "Choose where macros are saved", _draft.SaveDirectoryPath);
        if (folder != null) SaveFolderBox.Text = folder;
        SaveFolderBox.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
    }

    private void OnBrowseExport(object sender, RoutedEventArgs e)
    {
        var folder = PickFolder(this, "Choose the import and export folder", _draft.ExportDirectoryPath);
        if (folder != null) ExportFolderBox.Text = folder;
        ExportFolderBox.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
    }

    private void OnBrowseBackup(object sender, RoutedEventArgs e)
    {
        var folder = PickFolder(this, "Choose the backup folder", _draft.BackupDirectoryPath);
        if (folder != null) BackupFolderBox.Text = folder;
        BackupFolderBox.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
    }

    private void OnBackupNow(object sender, RoutedEventArgs e) => _model.CreateBackupNow();

    private void OnOpenFolder(object sender, RoutedEventArgs e)
    {
        try
        {
            System.IO.Directory.CreateDirectory(_model.RecordingsFolder);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_model.RecordingsFolder}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            ErrorText.Text = "Could not open the folder: " + ex.Message;
        }
    }

    // ------------------------------------------------------------------ AI

    private void RefreshAiText()
    {
        AiStatusText.Text = _model.AiBusy ? _model.AiBusyText : string.IsNullOrEmpty(_model.AiMessage) ? "Not checked yet." : _model.AiMessage;
    }

    private void OnAiCheck(object sender, RoutedEventArgs e) => _ = _model.RefreshAiStatusAsync();
    private void OnGetOllama(object sender, RoutedEventArgs e) => MainWindow.OpenLink(_model.OllamaDownloadPage);
    private void OnPullModel(object sender, RoutedEventArgs e) => _ = _model.PullRecommendedModelAsync();

    // ------------------------------------------------------------------ updates

    private void RefreshUpdateText()
    {
        UpdateStatus.Text = _model.UpdateText;
    }

    private void OnCheckUpdates(object sender, RoutedEventArgs e)
    {
        if (!_model.UpdatesSupported)
        {
            UpdateStatus.Text = "Updates are not available in this build.";
            return;
        }
        _ = _model.CheckForUpdatesAsync(userRequested: true);
    }

    // ------------------------------------------------------------------ privacy / about

    private void RefreshAccess()
    {
        var elevated = Win32Info.IsSelfElevated();
        var lines = new List<string>
        {
            "✓  Keyboard and mouse recording and playback: available (no permission prompt needed on Windows)",
            _model.EmergencyStopRegistered
                ? $"✓  Emergency stop {_model.EmergencyStopText}: ready"
                : $"!  Emergency stop {_model.EmergencyStopText}: another program already uses it. Choose a different one in Playback.",
            elevated
                ? "✓  Running as administrator: can also control programs that run as administrator"
                : "·  Not running as administrator: cannot control programs that run as administrator",
            "·  " + _model.SystemSummary,
        };
        AccessText.Text = string.Join("\n", lines);
    }

    private void OnDeleteAll(object sender, RoutedEventArgs e)
    {
        if (_model.Recordings.Count == 0)
        {
            Dialogs.Info(this, "Nothing to delete", "There are no saved macros.");
            return;
        }
        if (Dialogs.Confirm(this, "Delete all macros?", $"All {_model.Recordings.Count} saved macros will be deleted from this PC. Backups are not touched. This cannot be undone.",
                "Delete all", "Keep them", Dialogs.Tone.Danger))
        {
            _model.DeleteAllRecordings();
        }
    }

    private void OnOpenGitHub(object sender, RoutedEventArgs e) => MainWindow.OpenLink("https://github.com/" + UpdateConfig.Repository);

    private void OnShowWelcome(object sender, RoutedEventArgs e)
    {
        _model.ResetWelcome();
        Close();
    }

    // ------------------------------------------------------------------ save / cancel

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private void OnCancel(object sender, RoutedEventArgs e) => Close();

    private void OnSave(object sender, RoutedEventArgs e)
    {
        ErrorText.Text = "";
        // Make sure the box that still has the cursor is applied.
        Keyboard.ClearFocus();

        if (!AiDefaults.IsLocalEndpoint(_draft.AiEndpoint))
        {
            ErrorText.Text = "The AI address must be on this computer (127.0.0.1, localhost or ::1).";
            Nav.SelectedIndex = 3;
            return;
        }

        _draft.SaveDirectoryPath = Blank(_draft.SaveDirectoryPath);
        _draft.ExportDirectoryPath = Blank(_draft.ExportDirectoryPath);
        _draft.BackupDirectoryPath = Blank(_draft.BackupDirectoryPath);

        foreach (var folder in new[] { _draft.SaveDirectoryPath, _draft.ExportDirectoryPath, _draft.BackupDirectoryPath })
        {
            if (folder == null) continue;
            try
            {
                System.IO.Directory.CreateDirectory(folder);
            }
            catch (Exception ex)
            {
                ErrorText.Text = $"Cannot use the folder “{folder}”: {ex.Message}";
                Nav.SelectedIndex = 2;
                return;
            }
        }

        _saved = true;
        _model.ApplySettings(_draft);
        ThemeManager.Apply(_model.Settings.Theme);
        Close();
    }
}
