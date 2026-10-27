using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Shell;
using System.Windows.Threading;
using ActionRecorder.Core;
using ActionRecorder.Model;
using Microsoft.Win32;

namespace ActionRecorder.Desktop;

public partial class MainWindow : Window
{
    private readonly AppModel _model;
    private readonly InspectorView _inspector;
    private readonly DispatcherTimer _toastTimer = new() { Interval = TimeSpan.FromSeconds(7) };
    private readonly List<RadioButton> _speedPills = new();
    private bool _syncingSpeed;
    private StatusPill? _pill;
    private ClicksOverlay? _overlay;
    private WindowState _stateBeforeHide = WindowState.Normal;
    private bool _hiddenForRun;

    public MainWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        DataContext = model;
        VersionText.Text = "Version " + model.Version;

        _inspector = new InspectorView(model);
        _inspector.Edited += OnInspectorEdited;
        InspectorHost.Content = _inspector;
        _inspector.Show(Array.Empty<ActionRow>());

        BuildSpeedPills();
        SyncSpeedControls();
        Shell.IsEnabled = !model.ShowWelcome;

        model.PropertyChanged += OnModelChanged;
        model.NoticeShown += OnNoticeShown;
        model.CurrentRowChanged += OnCurrentRowChanged;
        _toastTimer.Tick += (_, _) =>
        {
            _toastTimer.Stop();
            _model.DismissNotice();
        };

        InputBindings.Add(new KeyBinding(model.UndoCommand, Key.Z, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(model.RedoCommand, Key.Y, ModifierKeys.Control));
        MacroList.PreviewMouseRightButtonDown += OnMacroListRightClick;
        Closing += OnClosing;
        Loaded += (_, _) => RefreshDraftList();
    }

    // Used by the screenshot mode.
    internal void SelectActionForDemo(int index)
    {
        if (index >= 0 && index < _model.Rows.Count) ActionList.SelectedIndex = index;
    }

    internal void ShowSideTab(int index) => SideTabs.SelectedIndex = index;

    // ------------------------------------------------------------------ model → window

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppModel.Speed):
                SyncSpeedControls();
                break;
            case nameof(AppModel.Status):
                OnStatusChanged();
                break;
            case nameof(AppModel.PlaybackFraction):
                UpdateTaskbar();
                break;
            case nameof(AppModel.Draft):
            case nameof(AppModel.HasDraft):
                RefreshDraftList();
                break;
            case nameof(AppModel.Rows):
                break;
            case nameof(AppModel.SelectedEntry):
                CloseOverlay();
                ShowInspector();
                break;
            case nameof(AppModel.ShowWelcome):
                Shell.IsEnabled = !_model.ShowWelcome;
                break;
        }
    }

    private void OnStatusChanged()
    {
        var status = _model.Status;
        var active = status is AppStatus.Preparing or AppStatus.Recording or AppStatus.Playing or AppStatus.Paused;

        if (active)
        {
            CloseOverlay();
            _pill ??= new StatusPill(_model);
            if (!_pill.IsVisible) _pill.Show();

            var hide = (status == AppStatus.Recording && _model.Settings.HideWindowWhileRecording) ||
                       (status is AppStatus.Playing or AppStatus.Paused && _model.Settings.HideWindowDuringPlayback);
            if (hide && !_hiddenForRun && WindowState != WindowState.Minimized)
            {
                _stateBeforeHide = WindowState;
                _hiddenForRun = true;
                WindowState = WindowState.Minimized;
            }
        }
        else
        {
            _pill?.Close();
            _pill = null;
            if (_hiddenForRun)
            {
                _hiddenForRun = false;
                WindowState = _stateBeforeHide == WindowState.Minimized ? WindowState.Normal : _stateBeforeHide;
                Activate();
            }
        }
        UpdateTaskbar();
        ShowInspector();
    }

    private void UpdateTaskbar()
    {
        switch (_model.Status)
        {
            case AppStatus.Playing:
                Taskbar.ProgressState = TaskbarItemProgressState.Normal;
                Taskbar.ProgressValue = Math.Clamp(_model.PlaybackFraction, 0, 1);
                break;
            case AppStatus.Paused:
                Taskbar.ProgressState = TaskbarItemProgressState.Paused;
                Taskbar.ProgressValue = Math.Clamp(_model.PlaybackFraction, 0, 1);
                break;
            case AppStatus.Recording:
            case AppStatus.Preparing:
                Taskbar.ProgressState = TaskbarItemProgressState.Indeterminate;
                break;
            case AppStatus.Error:
                Taskbar.ProgressState = TaskbarItemProgressState.Error;
                Taskbar.ProgressValue = 1;
                break;
            default:
                Taskbar.ProgressState = TaskbarItemProgressState.None;
                break;
        }
    }

    private void OnNoticeShown(NoticeKind kind, string message)
    {
        _toastTimer.Stop();
        _toastTimer.Interval = TimeSpan.FromSeconds(kind == NoticeKind.Error ? 12 : 7);
        _toastTimer.Start();
    }

    private void OnDismissNotice(object sender, RoutedEventArgs e)
    {
        _toastTimer.Stop();
        _model.DismissNotice();
    }

    private void OnCurrentRowChanged(ActionRow row)
    {
        ActionList.ScrollIntoView(row);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        _model.EmergencyStop();
        _model.FlushSave();
        CloseOverlay();
        _pill?.Close();
    }

    // ------------------------------------------------------------------ sidebar

    private void OnNewMacro(object sender, RoutedEventArgs e) => _model.NewEmptyRecording();

    private void OnImport(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Import a macro",
            Filter = "Macro files (*.macro.json;*.json)|*.macro.json;*.json|All files (*.*)|*.*",
            Multiselect = true,
            CheckFileExists = true,
        };
        if (dialog.ShowDialog(this) != true) return;
        foreach (var file in dialog.FileNames)
        {
            var outcome = _model.ImportFile(file);
            if (outcome.Recording == null)
            {
                Dialogs.Info(this, "Could not import", $"{System.IO.Path.GetFileName(file)}\n\n{outcome.Error}");
            }
            else if (outcome.Notes.Count > 0)
            {
                Dialogs.Info(this, "Imported from the Mac app",
                    "The macro was converted for Windows. Please check it before relying on it.\n\n• " + string.Join("\n• ", outcome.Notes));
            }
        }
    }

    private void OnMacroListRightClick(object sender, MouseButtonEventArgs e)
    {
        var source = e.OriginalSource as DependencyObject;
        while (source != null && source is not ListBoxItem) source = System.Windows.Media.VisualTreeHelper.GetParent(source);
        if (source is ListBoxItem item && !_model.IsBusy) item.IsSelected = true;
    }

    private RecordingEntry? EntryFrom(object sender) =>
        (sender as FrameworkElement)?.DataContext as RecordingEntry ?? _model.SelectedEntry;

    private void OnRenameEntry(object sender, RoutedEventArgs e)
    {
        if (EntryFrom(sender) is { } entry)
        {
            _model.SelectedEntry = entry;
            OnRenameCurrent(sender, e);
        }
    }

    private void OnDuplicateEntry(object sender, RoutedEventArgs e)
    {
        if (EntryFrom(sender) is { } entry) _model.DuplicateRecording(entry);
    }

    private void OnExportEntry(object sender, RoutedEventArgs e)
    {
        if (EntryFrom(sender) is not { } entry) return;
        _model.SelectedEntry = entry;
        ExportCurrent();
    }

    private void OnDeleteEntry(object sender, RoutedEventArgs e)
    {
        if (EntryFrom(sender) is not { } entry) return;
        if (Dialogs.Confirm(this, "Delete this macro?", $"“{entry.Name}” will be deleted from this PC. This cannot be undone.",
                "Delete", "Keep it", Dialogs.Tone.Danger))
        {
            _model.DeleteRecording(entry);
        }
    }

    private void ExportCurrent()
    {
        var dialog = new SaveFileDialog
        {
            Title = "Export macro",
            FileName = _model.SuggestedExportFileName(),
            Filter = "Macro files (*.macro.json)|*.macro.json",
            DefaultExt = ".macro.json",
            AddExtension = false,
            InitialDirectory = SafeDirectory(_model.ExportFolder),
            OverwritePrompt = true,
        };
        if (dialog.ShowDialog(this) == true) _model.ExportCurrent(dialog.FileName);
    }

    private static string SafeDirectory(string path)
    {
        try
        {
            System.IO.Directory.CreateDirectory(path);
            return path;
        }
        catch (Exception)
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        }
    }

    private void OnOpenSettings(object sender, RoutedEventArgs e)
    {
        var window = new SettingsWindow(_model) { Owner = this };
        window.ShowDialog();
    }

    // ------------------------------------------------------------------ header

    private void OnTitleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2 && _model.CanEdit) OnRenameCurrent(sender, e);
    }

    private void OnRenameCurrent(object sender, RoutedEventArgs e)
    {
        if (!_model.CanEdit) return;
        var name = Dialogs.Prompt(this, "Rename macro", "Name", _model.CurrentName, "Rename");
        if (name != null) _model.RenameCurrent(name);
    }

    private void OnDownloadUpdate(object sender, RoutedEventArgs e) => _ = _model.DownloadUpdateAsync();

    private void OnInstallUpdate(object sender, RoutedEventArgs e)
    {
        if (!Dialogs.Confirm(this, "Restart to update?", "Action Recorder will close, install the new version and open again.", "Restart now", "Later")) return;
        if (_model.InstallUpdate()) Application.Current.Shutdown();
    }

    // ------------------------------------------------------------------ transport

    private void OnRecord(object sender, RoutedEventArgs e)
    {
        if (_model.NeedsRecordingAcknowledgement)
        {
            var accepted = Dialogs.Confirm(this, "Before you record",
                "While recording, Action Recorder sees every key you press and every click you make, in any program. " +
                "It does this only between Record and Stop, keeps the result on this PC, and never sends it anywhere.\n\n" +
                "Recorded text is saved as readable text. If you type a password while recording, it will be in the macro. " +
                "Don't type passwords or other secrets while recording.",
                "I understand", "Cancel");
            if (!accepted) return;
            _model.AcknowledgeRecordingWarning();
        }
        _model.StartRecording();
    }

    private void OnStopRecording(object sender, RoutedEventArgs e) => _model.StopRecording();

    private void OnPlay(object sender, RoutedEventArgs e) => StartPlayback(null);

    private void OnPlaySelection(object sender, RoutedEventArgs e)
    {
        var indices = ActionList.SelectedItems.Cast<ActionRow>().Select(r => r.Index).ToList();
        if (indices.Count == 0)
        {
            _model.Show(NoticeKind.Info, "Select the actions to play first.");
            return;
        }
        var first = indices.Min();
        var last = indices.Max();
        StartPlayback((first, last + 1));
    }

    private void StartPlayback((int Start, int End)? section)
    {
        var question = _model.PlaybackConfirmation();
        if (question != null && !Dialogs.Confirm(this, "Start playing?", question, "Start", "Cancel", Dialogs.Tone.Warning)) return;
        _model.Play(section);
    }

    private void OnPause(object sender, RoutedEventArgs e) => _model.Pause();
    private void OnResume(object sender, RoutedEventArgs e) => _model.Resume();
    private void OnRestart(object sender, RoutedEventArgs e) => _model.Restart();
    private void OnEmergencyStop(object sender, RoutedEventArgs e) => _model.EmergencyStop();

    // ------------------------------------------------------------------ speed

    private void BuildSpeedPills()
    {
        foreach (var preset in _model.SpeedPresets)
        {
            var pill = new RadioButton
            {
                Content = preset.Label,
                Style = (Style)FindResource("PillRadio"),
                Tag = preset.Value,
                ToolTip = preset.Detail,
                GroupName = "speed",
            };
            pill.Click += (_, _) => _model.Speed = preset.Value;
            _speedPills.Add(pill);
            SpeedPills.Children.Add(pill);
        }
    }

    private void SyncSpeedControls()
    {
        _syncingSpeed = true;
        try
        {
            var speed = _model.Speed;
            foreach (var pill in _speedPills) pill.IsChecked = pill.Tag is double v && Math.Abs(v - speed) < 1e-9;
            SpeedSlider.Value = Math.Log2(speed);
            if (!SpeedBox.IsKeyboardFocused) SpeedBox.Text = speed.ToString("0.##", CultureInfo.CurrentCulture);
        }
        finally
        {
            _syncingSpeed = false;
        }
    }

    private void OnSpeedSliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_syncingSpeed || !IsLoaded) return;
        var speed = Math.Pow(2, e.NewValue);
        // Snap to a nice value so the box does not show 1.4983.
        speed = speed < 1 ? Math.Round(speed, 2) : Math.Round(speed, 1);
        _model.Speed = speed;
    }

    private void OnSpeedBoxCommit(object sender, RoutedEventArgs e)
    {
        var text = SpeedBox.Text.Trim().TrimEnd('x', 'X', '×').Trim();
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value) ||
            double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value))
        {
            if (double.IsFinite(value) && value > 0) _model.Speed = value;
        }
        SyncSpeedControls();
    }

    private void OnSpeedBoxKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            OnSpeedBoxCommit(sender, e);
            Keyboard.ClearFocus();
            e.Handled = true;
        }
    }

    // ------------------------------------------------------------------ action list

    private List<Guid> SelectedIds() => ActionList.SelectedItems.Cast<ActionRow>().Select(r => r.Id).ToList();

    private void SelectIds(IEnumerable<Guid> ids)
    {
        var set = new HashSet<Guid>(ids);
        ActionList.SelectedItems.Clear();
        foreach (var row in _model.Rows)
        {
            if (set.Contains(row.Id)) ActionList.SelectedItems.Add(row);
        }
        ShowInspector();
    }

    private void OnActionSelectionChanged(object sender, SelectionChangedEventArgs e) => ShowInspector();

    private void ShowInspector() =>
        _inspector.Show(ActionList.SelectedItems.Cast<ActionRow>().ToList());

    private void OnInspectorEdited(Guid id) => SelectIds(new[] { id });

    private void OnActionListKey(object sender, KeyEventArgs e)
    {
        if (!_model.CanEdit) return;
        if (e.Key == Key.Delete)
        {
            OnDeleteActions(sender, e);
            e.Handled = true;
        }
        else if (e.Key == Key.D && Keyboard.Modifiers == ModifierKeys.Control)
        {
            OnDuplicateActions(sender, e);
            e.Handled = true;
        }
        else if (e.Key == Key.Up && Keyboard.Modifiers == ModifierKeys.Alt)
        {
            OnMoveUp(sender, e);
            e.Handled = true;
        }
        else if (e.Key == Key.Down && Keyboard.Modifiers == ModifierKeys.Alt)
        {
            OnMoveDown(sender, e);
            e.Handled = true;
        }
        else if (e.SystemKey == Key.Up && Keyboard.Modifiers == ModifierKeys.Alt)
        {
            OnMoveUp(sender, e);
            e.Handled = true;
        }
        else if (e.SystemKey == Key.Down && Keyboard.Modifiers == ModifierKeys.Alt)
        {
            OnMoveDown(sender, e);
            e.Handled = true;
        }
    }

    private void OnDeleteActions(object sender, RoutedEventArgs e)
    {
        var ids = SelectedIds();
        if (ids.Count == 0) return;
        var firstIndex = ActionList.SelectedItems.Cast<ActionRow>().Min(r => r.Index);
        if (_model.DeleteActions(ids))
        {
            var rows = _model.Rows;
            if (rows.Count > 0) SelectIds(new[] { rows[Math.Min(firstIndex, rows.Count - 1)].Id });
            else ShowInspector();
        }
    }

    private void OnDuplicateActions(object sender, RoutedEventArgs e)
    {
        var ids = SelectedIds();
        if (ids.Count == 0) return;
        var created = _model.DuplicateActions(ids);
        if (created.Count > 0) SelectIds(created);
    }

    private void OnMoveUp(object sender, RoutedEventArgs e)
    {
        var ids = SelectedIds();
        if (_model.MoveUp(ids)) SelectIds(ids);
    }

    private void OnMoveDown(object sender, RoutedEventArgs e)
    {
        var ids = SelectedIds();
        if (_model.MoveDown(ids)) SelectIds(ids);
    }

    private void OnAddWait(object sender, RoutedEventArgs e)
    {
        var text = Dialogs.Prompt(this, "Add a wait", "Seconds to wait (for example 1.5)", "1", "Add");
        if (text == null) return;
        if (!(double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out var seconds) ||
              double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out seconds)) || !double.IsFinite(seconds) || seconds < 0)
        {
            _model.Show(NoticeKind.Warning, "Enter a number of seconds, for example 1.5.");
            return;
        }
        var last = ActionList.SelectedItems.Cast<ActionRow>().OrderBy(r => r.Index).LastOrDefault();
        var id = _model.InsertWait(seconds, last?.Id);
        if (id != null) SelectIds(new[] { id.Value });
    }

    private void OnPresets(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        foreach (var preset in Presets.All)
        {
            var info = preset;
            var item = new MenuItem { Header = info.Title, ToolTip = info.Detail };
            item.Click += (_, _) => InsertPreset(info);
            menu.Items.Add(item);
        }
        menu.PlacementTarget = sender as UIElement;
        menu.IsOpen = true;
    }

    private void InsertPreset(Presets.Info info)
    {
        var first = info.InputLabel == null ? "" : Dialogs.Prompt(this, info.Title, info.InputLabel, "", "Insert");
        if (first == null) return;
        var second = "";
        if (info.SecondInputLabel != null)
        {
            var answer = Dialogs.Prompt(this, info.Title, info.SecondInputLabel, "", "Insert");
            if (answer == null) return;
            second = answer;
        }
        var last = ActionList.SelectedItems.Cast<ActionRow>().OrderBy(r => r.Index).LastOrDefault();
        var count = _model.ActionCount;
        if (_model.InsertPreset(info.Id, first, second, last?.Id))
        {
            _model.Show(NoticeKind.Success, "Inserted. Discord can change its shortcuts, so play it once to check.");
            if (_model.ActionCount > count) ActionList.ScrollIntoView(_model.Rows[Math.Min(_model.Rows.Count - 1, (last?.Index ?? _model.Rows.Count - 1) + 1)]);
        }
    }

    // ------------------------------------------------------------------ click overlay

    private void OnShowClicks(object sender, RoutedEventArgs e)
    {
        if (_overlay != null)
        {
            CloseOverlay();
            return;
        }
        var markers = _model.ClickMarkers();
        if (markers.Count == 0)
        {
            _model.Show(NoticeKind.Info, "This macro has no clicks to show.");
            return;
        }
        _overlay = new ClicksOverlay(markers);
        _overlay.Closed += (_, _) => _overlay = null;
        _overlay.ShowOnScreens();
        _model.Show(NoticeKind.Info, "Showing where each click will land for 8 seconds. If the numbers are not where the buttons are, record again.");
    }

    private void CloseOverlay()
    {
        var overlay = _overlay;
        _overlay = null;
        overlay?.CloseAll();
    }

    // ------------------------------------------------------------------ check panel

    private void OnApplyFix(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is MacroFinding finding)
        {
            if (_model.ApplyFix(finding)) _model.Show(NoticeKind.Success, "Done. You can undo this.");
        }
    }

    private void OnPlanImprovements(object sender, RoutedEventArgs e) => _model.PlanImprovements();

    private void OnApplyProposals(object sender, RoutedEventArgs e)
    {
        _model.ApplySelectedProposals();
        ShowInspector();
    }

    // ------------------------------------------------------------------ AI panel

    private void OnAiRefresh(object sender, RoutedEventArgs e) => _ = _model.RefreshAiStatusAsync();

    private void OnGetOllama(object sender, RoutedEventArgs e) => OpenLink(_model.OllamaDownloadPage);

    private void OnPullModel(object sender, RoutedEventArgs e) => _ = _model.PullRecommendedModelAsync();

    private void OnAiCancel(object sender, RoutedEventArgs e) => _model.CancelAi();

    private void OnAiReview(object sender, RoutedEventArgs e) => _ = _model.ReviewWithAiAsync();

    private void OnAiEdits(object sender, RoutedEventArgs e)
    {
        SideTabs.SelectedIndex = 2;
        _ = _model.SuggestEditsWithAiAsync();
    }

    private void OnAiName(object sender, RoutedEventArgs e) => _ = _model.SuggestNameWithAiAsync();
    private void OnAcceptName(object sender, RoutedEventArgs e) => _model.AcceptSuggestedName();
    private void OnDismissName(object sender, RoutedEventArgs e) => _model.DismissSuggestedName();

    private void OnAiDraft(object sender, RoutedEventArgs e) => _ = _model.DraftWithAiAsync(DraftBox.Text);

    private void OnInsertDraft(object sender, RoutedEventArgs e)
    {
        var last = ActionList.SelectedItems.Cast<ActionRow>().OrderBy(r => r.Index).LastOrDefault();
        _model.InsertDraft(last?.Id);
    }

    private void OnDiscardDraft(object sender, RoutedEventArgs e) => _model.DiscardDraft();

    private void RefreshDraftList()
    {
        DraftList.Items.Clear();
        if (_model.Draft is not { } draft) return;
        foreach (var action in draft.Actions)
        {
            DraftList.Items.Add(new TextBlock
            {
                Text = "• " + ActionDescriber.Describe(action),
                Style = (Style)FindResource("BodyText"),
                Margin = new Thickness(0, 1, 0, 1),
            });
        }
    }

    internal static void OpenLink(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception)
        {
            // No default browser: nothing else to do.
        }
    }
}
