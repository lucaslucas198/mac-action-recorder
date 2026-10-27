using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Model;

/// <summary>Everything the app model needs from the outside world. The WPF app passes the real Windows pieces; tests pass fakes.</summary>
public sealed class AppServices
{
    public required IUiThread Ui { get; init; }
    public required IInputCapture Capture { get; init; }
    public required IHotKeyRegistrar HotKey { get; init; }
    public required IActionPerformer Performer { get; init; }
    public required ISystemProbe Probe { get; init; }
    public required SettingsStore SettingsStore { get; init; }
    public required string InstalledVersion { get; init; }
    public Func<AppSettings, AiAssistant>? AiFactory { get; init; }
    public Func<UpdateService?>? UpdateFactory { get; init; }
    public Func<DateTime> Now { get; init; } = () => DateTime.Now;

    /// <summary>Name of this program's own executable, for ignoring it when looking for the target app.</summary>
    public string OwnProgramFileName { get; init; } = "ActionRecorder.exe";

    public static AppServices CreateDefault(IUiThread ui, string version, Func<AppSettings> settingsAccessor)
    {
        return new AppServices
        {
            Ui = ui,
            Capture = new InputRecorder(),
            HotKey = new HotKeyService(),
            Performer = new SendInputPerformer(),
            Probe = new WindowsSystemProbe(),
            SettingsStore = new SettingsStore(AppPaths.SettingsFile),
            InstalledVersion = version,
            AiFactory = s => new AiAssistant(settingsAccessor),
            UpdateFactory = () => new UpdateService(version),
            OwnProgramFileName = Path.GetFileName(Environment.ProcessPath ?? "ActionRecorder.exe"),
        };
    }
}
