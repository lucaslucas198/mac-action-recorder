using System.Collections.ObjectModel;
using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Model;

/// <summary>
/// Everything the window shows and does, with no WPF in it, so it can be tested without a screen.
/// The views bind to its properties and call its methods; all property changes happen on the UI thread.
/// </summary>
public sealed partial class AppModel : ObservableObject, IDisposable
{
    private readonly AppServices _s;
    private RecordingStore _store;
    private AppSettings _settings;
    private RecordingEntry? _selected;
    private Recording? _current;
    private AppStatus _status = AppStatus.Idle;
    private string _statusDetail = "";
    private string _notice = "";
    private NoticeKind _noticeKind = NoticeKind.Info;
    private CancellationTokenSource? _saveDelay;
    private bool _dirty;
    private bool _disposed;

    public AppModel(AppServices services)
    {
        _s = services;
        _settings = _s.SettingsStore.Load();
        _store = new RecordingStore(ResolveSaveFolder(_settings));
        Engine = new PlaybackEngine(_s.Performer, () => _s.Probe.ForegroundProgram()?.FileName);
        Engine.OnEvent = e => _s.Ui.Post(() => OnEngineEvent(e));
        _ai = _s.AiFactory?.Invoke(_settings) ?? new AiAssistant(() => _settings);
        _updater = _s.UpdateFactory?.Invoke();
        if (_updater != null) _updater.Changed += state => _s.Ui.Post(() => UpdateState = state);

        _speed = _settings.DefaultSpeed;
        _repeatCount = _settings.DefaultRepeatCount == 0 ? 1 : _settings.DefaultRepeatCount;
        _infinite = _settings.DefaultRepeatCount == 0;
        _loopDelay = _settings.DefaultLoopDelay;
        _countdown = _settings.PlaybackCountdown;
        _verifyForeground = _settings.VerifyForeground;

        SetupChecks = new ObservableCollection<SetupCheck>();
        PlaybackEnabled = true;
    }

    public PlaybackEngine Engine { get; }
    public string Version => _s.InstalledVersion;
    public IReadOnlyList<SpeedPreset> SpeedPresets => SpeedPreset.All;

    // ------------------------------------------------------------------ settings

    public AppSettings Settings => _settings;

    /// <summary>Applies new settings (from the Settings window), saves them and re-opens the recordings folder if it moved.</summary>
    public void ApplySettings(AppSettings updated)
    {
        var clean = updated.Sanitized();
        var oldFolder = _store.Directory;
        var newFolder = ResolveSaveFolder(clean);
        _settings = clean;
        TrySaveSettings();
        _s.HotKey.Set(_settings.EmergencyStop);
        if (!string.Equals(oldFolder, newFolder, StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                _store = new RecordingStore(newFolder);
                ReloadRecordings();
            }
            catch (RecordingException ex)
            {
                _store = new RecordingStore(oldFolder);
                _settings.SaveDirectoryPath = null;
                Show(NoticeKind.Error, ex.Message);
            }
        }
        RaiseAll(nameof(Settings), nameof(EmergencyStopText));
        RefreshFindings();
    }

    public string EmergencyStopText => _settings.EmergencyStop.DisplayString;

    /// <summary>True when Windows accepted the emergency-stop shortcut (another program may already own it).</summary>
    public bool EmergencyStopRegistered => _s.HotKey.IsRegistered;

    /// <summary>One line about this PC for the About and Privacy pages, for example "Windows 11 (build 22631) · 2 monitors".</summary>
    public string SystemSummary
    {
        get
        {
            var monitors = _s.Probe.MonitorCount;
            var screen = _s.Probe.PrimaryScreen();
            var parts = new List<string> { _s.Probe.WindowsDescription() };
            if (screen != null) parts.Add($"{screen.Width:0}×{screen.Height:0}");
            parts.Add(monitors == 1 ? "1 monitor" : $"{monitors} monitors");
            return string.Join(" · ", parts);
        }
    }

    public string RecordingsFolder => _store.Directory;

    private static string ResolveSaveFolder(AppSettings s) =>
        string.IsNullOrWhiteSpace(s.SaveDirectoryPath) ? AppPaths.DefaultRecordingsFolder : s.SaveDirectoryPath!;

    private void TrySaveSettings()
    {
        try
        {
            _s.SettingsStore.Save(_settings);
        }
        catch (Exception ex)
        {
            Show(NoticeKind.Warning, "Settings could not be saved: " + ex.Message);
        }
    }

    // ------------------------------------------------------------------ startup / shutdown

    public void Initialize()
    {
        _s.HotKey.Pressed += () => _s.Ui.Post(EmergencyStop);
        var registered = _s.HotKey.Set(_settings.EmergencyStop);
        ReloadRecordings();
        if (!registered)
        {
            Show(NoticeKind.Warning,
                $"The emergency-stop shortcut {_settings.EmergencyStop.DisplayString} is used by another program. Choose a different one in Settings.");
        }
        if (_settings.BackupEnabled)
        {
            var folder = _settings.BackupDirectoryPath ?? AppPaths.DefaultBackupsFolder;
            var keep = _settings.BackupKeepCount;
            var store = _store;
            Task.Run(async () =>
            {
                await Task.Delay(3000).ConfigureAwait(false);
                try
                {
                    if (store.LoadAll().Recordings.Count > 0) store.CreateBackup(folder, keep);
                }
                catch (Exception)
                {
                    // A failed launch backup must never bother the user.
                }
            });
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        FlushSave();
        Engine.Stop();
        _recordingLoop?.Cancel();
        _aiCancel?.Cancel();
        try { if (_s.Capture.IsRunning) _s.Capture.Stop(); } catch (Exception) { }
        _s.HotKey.Dispose();
        _updater?.Dispose();
    }

    // ------------------------------------------------------------------ status & notices

    public AppStatus Status
    {
        get => _status;
        private set
        {
            if (Set(ref _status, value))
            {
                RaiseAll(nameof(StatusText), nameof(IsBusy), nameof(IsRecordingOrPreparing), nameof(CanRecord), nameof(CanPlay),
                    nameof(CanPause), nameof(CanResume), nameof(CanStop), nameof(CanEdit), nameof(IsPlayingOrPaused),
                    nameof(CanUndo), nameof(CanRedo));
                _undoCommand?.RaiseCanExecuteChanged();
                _redoCommand?.RaiseCanExecuteChanged();
            }
        }
    }

    public string StatusDetail
    {
        get => _statusDetail;
        private set => Set(ref _statusDetail, value);
    }

    public string StatusText => Status switch
    {
        AppStatus.Idle => "Ready",
        AppStatus.Preparing => StatusDetail.Length > 0 ? StatusDetail : "Getting ready…",
        AppStatus.Recording => "Recording",
        AppStatus.Playing => "Playing",
        AppStatus.Paused => "Paused",
        AppStatus.Stopped => StatusDetail.Length > 0 ? StatusDetail : "Stopped",
        _ => "Error",
    };

    public bool IsBusy => Status is AppStatus.Preparing or AppStatus.Recording or AppStatus.Playing or AppStatus.Paused;
    public bool IsRecordingOrPreparing => _recordingActive || Status == AppStatus.Recording;
    public bool IsPlayingOrPaused => Status is AppStatus.Playing or AppStatus.Paused || (Status == AppStatus.Preparing && Engine.State.IsActive);
    public bool CanRecord => !IsBusy;
    public bool CanPlay => !IsBusy && _current != null && _current.Actions.Count > 0;
    public bool CanPause => Status == AppStatus.Playing;
    public bool CanResume => Status == AppStatus.Paused;
    public bool CanStop => IsBusy;
    public bool CanEdit => !IsBusy && _current != null;

    public string Notice
    {
        get => _notice;
        private set => Set(ref _notice, value);
    }

    public NoticeKind NoticeKind
    {
        get => _noticeKind;
        private set => Set(ref _noticeKind, value);
    }

    public int NoticeSerial { get; private set; }

    public void Show(NoticeKind kind, string message)
    {
        NoticeKind = kind;
        Notice = message;
        NoticeSerial++;
        Raise(nameof(NoticeSerial));
        NoticeShown?.Invoke(kind, message);
    }

    public void DismissNotice() => Notice = "";

    /// <summary>Raised whenever a message should be shown to the user (the window turns it into a banner).</summary>
    public event Action<NoticeKind, string>? NoticeShown;

    // ------------------------------------------------------------------ recordings list

    public ObservableCollection<RecordingEntry> Recordings { get; } = new();
    public ObservableCollection<ActionRow> Rows { get; } = new();

    public RecordingEntry? SelectedEntry
    {
        get => _selected;
        set
        {
            if (ReferenceEquals(_selected, value)) return;
            if (IsBusy) return;
            FlushSave();
            _selected = value;
            Raise();
            LoadCurrent(value?.Recording);
        }
    }

    public Recording? Current => _current;

    public string CurrentName => _current?.Name ?? "";
    public int ActionCount => _current?.Actions.Count ?? 0;
    public string DurationText => _current == null ? "" : RecordingEntry.FormatDuration(_current.OriginalDuration);
    public bool HasRecording => _current != null;
    public bool HasActions => _current != null && _current.Actions.Count > 0;
    public string TargetText => _current?.TargetApp?.Name ?? "Not set";
    public bool FromMac => _current != null && !_current.IsFromWindows;

    private void LoadCurrent(Recording? recording)
    {
        _current = recording;
        _undo.Clear();
        _redo.Clear();
        _loadingOptions = true;
        if (recording != null)
        {
            var d = recording.PlaybackDefaults;
            if (d != null)
            {
                Speed = PlaybackTiming.ClampSpeed(d.Speed);
                Infinite = d.RepeatCount == 0;
                RepeatCount = d.RepeatCount == 0 ? 1 : d.RepeatCount;
                LoopDelay = Math.Max(0, d.LoopDelay);
            }
            else
            {
                Speed = _settings.DefaultSpeed;
                Infinite = _settings.DefaultRepeatCount == 0;
                RepeatCount = _settings.DefaultRepeatCount == 0 ? 1 : _settings.DefaultRepeatCount;
                LoopDelay = _settings.DefaultLoopDelay;
            }
        }
        _loadingOptions = false;
        RebuildRows();
        RefreshFindings();
        ClearProposals();
        RaiseCurrent();
    }

    private void RaiseCurrent()
    {
        RaiseAll(nameof(Current), nameof(CurrentName), nameof(ActionCount), nameof(DurationText), nameof(HasRecording),
            nameof(HasActions), nameof(TargetText), nameof(CanPlay), nameof(CanEdit), nameof(FromMac), nameof(EstimateText),
            nameof(CanUndo), nameof(CanRedo));
        _undoCommand?.RaiseCanExecuteChanged();
        _redoCommand?.RaiseCanExecuteChanged();
    }

    public void ReloadRecordings()
    {
        var (recordings, failures) = _store.LoadAll();
        var selectedId = _selected?.Id;
        Recordings.Clear();
        foreach (var r in recordings) Recordings.Add(new RecordingEntry(r));
        _selected = Recordings.FirstOrDefault(e => e.Id == selectedId) ?? Recordings.FirstOrDefault();
        Raise(nameof(SelectedEntry));
        LoadCurrent(_selected?.Recording);
        if (failures.Count > 0)
        {
            Show(NoticeKind.Warning, $"{failures.Count} file(s) in the recordings folder could not be read and were skipped: " +
                                     string.Join(", ", failures.Take(3).Select(f => Path.GetFileName(f.Path))));
        }
    }

    private void RebuildRows()
    {
        Rows.Clear();
        if (_current == null) return;
        var index = 0;
        foreach (var action in _current.Actions) Rows.Add(new ActionRow(action, index++));
    }

    private void RenumberRows()
    {
        for (var i = 0; i < Rows.Count; i++) Rows[i].Index = i;
    }

    public string EstimateText
    {
        get
        {
            if (_current == null || _current.Actions.Count == 0) return "";
            var config = BuildConfig(null);
            var total = PlaybackTiming.EstimatedTotal(_current.Actions, config);
            return total == null ? "until stopped" : "about " + RecordingEntry.FormatDuration(total.Value);
        }
    }

    // ------------------------------------------------------------------ saving

    /// <summary>Marks the current recording as changed and saves it shortly after (or at once when the delay is zero).</summary>
    private void MarkChanged()
    {
        if (_current == null) return;
        _current.ModifiedAt = DateTime.UtcNow;
        _dirty = true;
        _selected?.UpdateSubtitle();
        RaiseCurrent();
        if (!_settings.AutoSave) return;
        _saveDelay?.Cancel();
        var cancel = new CancellationTokenSource();
        _saveDelay = cancel;
        Task.Run(async () =>
        {
            try
            {
                await Task.Delay(600, cancel.Token).ConfigureAwait(false);
                _s.Ui.Post(FlushSave);
            }
            catch (OperationCanceledException)
            {
            }
        });
    }

    public bool HasUnsavedChanges => _dirty;

    /// <summary>Writes the current recording to disk now.</summary>
    public bool Save()
    {
        if (_current == null) return true;
        try
        {
            _store.Save(_current);
            _dirty = false;
            Raise(nameof(HasUnsavedChanges));
            return true;
        }
        catch (RecordingException ex)
        {
            Show(NoticeKind.Error, "Could not save: " + ex.Message);
            return false;
        }
    }

    public void FlushSave()
    {
        _saveDelay?.Cancel();
        if (_dirty && _settings.AutoSave) Save();
    }

    // ------------------------------------------------------------------ list actions

    public void RenameCurrent(string name)
    {
        if (_current == null || IsBusy) return;
        var trimmed = name.Trim();
        if (trimmed.Length == 0 || trimmed == _current.Name) return;
        PushUndo();
        _current.Name = trimmed.Length > 120 ? trimmed[..120] : trimmed;
        MarkChanged();
    }

    public void SetNotes(string notes)
    {
        if (_current == null || IsBusy) return;
        var text = string.IsNullOrWhiteSpace(notes) ? null : notes;
        if (text == _current.Notes) return;
        _current.Notes = text;
        MarkChanged();
    }

    public void DeleteRecording(RecordingEntry entry)
    {
        if (IsBusy) return;
        try
        {
            if (_store.Exists(entry.Id)) _store.Delete(entry.Id);
        }
        catch (RecordingException ex)
        {
            Show(NoticeKind.Error, ex.Message);
            return;
        }
        var wasSelected = ReferenceEquals(entry, _selected);
        var index = Recordings.IndexOf(entry);
        Recordings.Remove(entry);
        if (wasSelected)
        {
            _selected = Recordings.Count == 0 ? null : Recordings[Math.Min(index, Recordings.Count - 1)];
            _dirty = false;
            Raise(nameof(SelectedEntry));
            LoadCurrent(_selected?.Recording);
        }
        Show(NoticeKind.Info, $"Deleted “{entry.Name}”.");
    }

    /// <summary>Deletes every saved macro (used by "Delete all recordings" in Settings). Returns how many were removed.</summary>
    public int DeleteAllRecordings()
    {
        if (IsBusy) return 0;
        var removed = 0;
        foreach (var entry in Recordings.ToList())
        {
            try
            {
                if (_store.Exists(entry.Id)) _store.Delete(entry.Id);
                removed++;
            }
            catch (RecordingException ex)
            {
                Show(NoticeKind.Error, ex.Message);
                break;
            }
        }
        _dirty = false;
        ReloadRecordings();
        if (removed > 0) Show(NoticeKind.Info, $"Deleted {removed} macro{(removed == 1 ? "" : "s")}.");
        return removed;
    }

    public void DuplicateRecording(RecordingEntry entry)
    {
        if (IsBusy) return;
        try
        {
            FlushSave();
            var copy = _store.Duplicate(entry.Recording);
            var created = new RecordingEntry(copy);
            Recordings.Insert(0, created);
            SelectedEntry = created;
            Show(NoticeKind.Success, $"Created “{copy.Name}”.");
        }
        catch (RecordingException ex)
        {
            Show(NoticeKind.Error, ex.Message);
        }
    }

    public RecordingEntry NewEmptyRecording(string? name = null)
    {
        FlushSave();
        var now = _s.Now();
        var recording = new Recording(name ?? $"New macro {now:yyyy-MM-dd HH:mm}")
        {
            PlaybackDefaults = CurrentDefaults(),
            RecordedScreen = _s.Probe.PrimaryScreen(),
        };
        AddAndSelect(recording);
        return _selected!;
    }

    private void AddAndSelect(Recording recording)
    {
        try
        {
            _store.Save(recording);
        }
        catch (RecordingException ex)
        {
            Show(NoticeKind.Error, "Could not save: " + ex.Message);
        }
        var entry = new RecordingEntry(recording);
        Recordings.Insert(0, entry);
        _selected = entry;
        _dirty = false;
        Raise(nameof(SelectedEntry));
        LoadCurrent(recording);
    }

    // ------------------------------------------------------------------ import / export

    public sealed record ImportOutcome(Recording? Recording, string? Error, IReadOnlyList<string> Notes);

    /// <summary>Imports a recording file. Files from the Mac app are converted for Windows, and what changed is reported.</summary>
    public ImportOutcome ImportFile(string path)
    {
        if (IsBusy) return new ImportOutcome(null, "Finish the current recording or playback first.", Array.Empty<string>());
        try
        {
            FlushSave();
            var info = new FileInfo(path);
            if (info.Exists && info.Length > RecordingCodec.DefaultMaxFileSize) throw RecordingException.TooLarge(info.Length);
            var recording = RecordingCodec.Decode(File.ReadAllBytes(path));
            var notes = new List<string>();
            if (!recording.IsFromWindows)
            {
                var converted = MacConversion.FromMac(recording);
                recording = converted.Recording;
                notes.Add($"Converted from the Mac app: {converted.Converted} key press(es) translated.");
                notes.AddRange(converted.Problems);
            }
            if (_store.Exists(recording.Id)) recording.Id = Guid.NewGuid();
            AddAndSelect(recording);
            return new ImportOutcome(recording, null, notes);
        }
        catch (RecordingException ex)
        {
            return new ImportOutcome(null, ex.Message, Array.Empty<string>());
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new ImportOutcome(null, $"Could not read the file: {ex.Message}", Array.Empty<string>());
        }
    }

    public bool ExportCurrent(string path)
    {
        if (_current == null) return false;
        try
        {
            FlushSave();
            _store.Export(_current, path);
            Show(NoticeKind.Success, $"Exported to {path}");
            return true;
        }
        catch (RecordingException ex)
        {
            Show(NoticeKind.Error, ex.Message);
            return false;
        }
    }

    public string SuggestedExportFileName()
    {
        var name = _current?.Name ?? "macro";
        var invalid = Path.GetInvalidFileNameChars();
        var clean = new string(name.Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim();
        if (clean.Length == 0) clean = "macro";
        return (clean.Length > 60 ? clean[..60] : clean) + "." + RecordingFormat.FileExtension;
    }

    public string ExportFolder => _settings.ExportDirectoryPath ?? AppPaths.DefaultExportFolder;

    public string? CreateBackupNow()
    {
        try
        {
            FlushSave();
            var folder = _settings.BackupDirectoryPath ?? AppPaths.DefaultBackupsFolder;
            var made = _store.CreateBackup(folder, _settings.BackupKeepCount);
            Show(NoticeKind.Success, $"Backup saved to {made}");
            return made;
        }
        catch (RecordingException ex)
        {
            Show(NoticeKind.Error, ex.Message);
            return null;
        }
    }

    // ------------------------------------------------------------------ playback options (bound to the UI)

    private double _speed;
    private int _repeatCount;
    private bool _infinite;
    private double _loopDelay;
    private int _countdown;
    private bool _verifyForeground;

    public double Speed
    {
        get => _speed;
        set
        {
            var clamped = PlaybackTiming.ClampSpeed(value);
            if (Math.Abs(clamped - _speed) < 1e-9) return;
            _speed = clamped;
            Raise();
            RaiseAll(nameof(SpeedText), nameof(EstimateText));
            PlaybackOptionsChanged();
        }
    }

    public string SpeedText => SpeedPreset.Describe(_speed);

    public int RepeatCount
    {
        get => _repeatCount;
        set
        {
            var clamped = Num.Clamp(value, 1, 100_000);
            if (clamped == _repeatCount) return;
            _repeatCount = clamped;
            Raise();
            RaiseAll(nameof(RepeatText), nameof(EstimateText));
            PlaybackOptionsChanged();
        }
    }

    public bool Infinite
    {
        get => _infinite;
        set
        {
            if (!Set(ref _infinite, value)) return;
            RaiseAll(nameof(RepeatText), nameof(EstimateText));
            PlaybackOptionsChanged();
        }
    }

    public double LoopDelay
    {
        get => _loopDelay;
        set
        {
            var clamped = Num.Clamp(double.IsFinite(value) ? value : 0, 0, 3600);
            if (Math.Abs(clamped - _loopDelay) < 1e-9) return;
            _loopDelay = clamped;
            Raise();
            RaiseAll(nameof(EstimateText));
            PlaybackOptionsChanged();
        }
    }

    public int Countdown
    {
        get => _countdown;
        set
        {
            var clamped = Num.Clamp(value, 0, 60);
            if (!Set(ref _countdown, clamped)) return;
            RaiseAll(nameof(EstimateText));
        }
    }

    public bool VerifyForeground
    {
        get => _verifyForeground;
        set
        {
            if (!Set(ref _verifyForeground, value)) return;
            _settings.VerifyForeground = value;
            TrySaveSettings();
            RefreshFindings();
        }
    }

    public string RepeatText => Infinite ? "Repeat until stopped" : RepeatCount == 1 ? "Play once" : $"Repeat {RepeatCount} times";

    private PlaybackDefaults CurrentDefaults() => new(_speed, _infinite ? 0 : _repeatCount, _loopDelay);

    private bool _loadingOptions;

    private void PlaybackOptionsChanged()
    {
        if (_loadingOptions || _current == null || IsBusy) return;
        var defaults = CurrentDefaults();
        if (_current.PlaybackDefaults == defaults) return;
        _current.PlaybackDefaults = defaults;
        MarkChanged();
        RefreshFindings();
    }
}
