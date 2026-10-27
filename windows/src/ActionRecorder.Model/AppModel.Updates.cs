using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Model;

public sealed partial class AppModel
{
    private UpdateService? _updater;
    private UpdateState _updateState = new(UpdatePhase.Idle, "");

    public UpdateState UpdateState
    {
        get => _updateState;
        private set
        {
            if (Set(ref _updateState, value))
            {
                RaiseAll(nameof(UpdateAvailable), nameof(UpdateReady), nameof(UpdateBusy), nameof(UpdateText), nameof(ShowUpdateBanner));
            }
        }
    }

    public bool UpdatesSupported => _updater != null;
    public bool UpdateAvailable => UpdateState.Phase == UpdatePhase.Available;
    public bool UpdateReady => UpdateState.Phase == UpdatePhase.Ready;
    public bool UpdateBusy => UpdateState.Phase is UpdatePhase.Checking or UpdatePhase.Downloading;
    public bool ShowUpdateBanner => UpdateState.Phase is UpdatePhase.Available or UpdatePhase.Downloading or UpdatePhase.Ready;
    public string UpdateText => UpdateState.Message;

    /// <summary>Checks GitHub for a newer version (one read-only request), then downloads it if the setting allows. Does nothing if update checks are off.</summary>
    public async Task CheckForUpdatesAsync(bool userRequested)
    {
        if (_updater == null) return;
        if (!userRequested && !_settings.CheckForUpdates) return;
        await _updater.CheckAsync();
        if (_updater.State.Phase == UpdatePhase.Available && _settings.AutoDownloadUpdates && !IsBusy)
        {
            await _updater.DownloadAsync();
        }
    }

    public async Task DownloadUpdateAsync()
    {
        if (_updater == null || _updater.State.Phase != UpdatePhase.Available) return;
        await _updater.DownloadAsync();
    }

    /// <summary>Starts the downloaded installer. Returns true if the app should now close so the installer can replace it.</summary>
    public bool InstallUpdate()
    {
        if (_updater == null || _updater.State.Phase != UpdatePhase.Ready || IsBusy) return false;
        FlushSave();
        if (_updater.LaunchInstaller()) return true;
        Show(NoticeKind.Error, "The installer could not be started. Open it from the Downloads folder instead.");
        return false;
    }

    /// <summary>Called shortly after launch by the window. Waits a moment so startup stays fast.</summary>
    public async Task StartBackgroundUpdateCheckAsync(int delayMilliseconds = 4000)
    {
        if (_updater == null || !_settings.CheckForUpdates) return;
        if (delayMilliseconds > 0) await Task.Delay(delayMilliseconds);
        if (_disposed) return;
        await CheckForUpdatesAsync(userRequested: false);
    }
}
