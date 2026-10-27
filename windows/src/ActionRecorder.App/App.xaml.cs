using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Markup;
using System.Windows.Threading;
using ActionRecorder.Model;
using ActionRecorder.Native;

namespace ActionRecorder.Desktop;

public partial class App : Application
{
    private AppModel? _model;
    private Mutex? _singleInstance;
    private EventWaitHandle? _activateSignal;
    private readonly List<string> _bindingErrors = new();

    internal static string VersionText { get; } = ComputeVersion();

    private static string ComputeVersion()
    {
        var text = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";
        var plus = text.IndexOf('+');
        return plus >= 0 ? text[..plus] : text;
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        var dataOverride = Environment.GetEnvironmentVariable("ACTION_RECORDER_DATA");
        if (!string.IsNullOrWhiteSpace(dataOverride)) AppPaths.RootOverride = dataOverride;

        // Numbers typed into boxes follow the Windows region setting, not US English.
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement),
            new FrameworkPropertyMetadata(XmlLanguage.GetLanguage(CultureInfo.CurrentCulture.IetfLanguageTag)));

        base.OnStartup(e);
        DispatcherUnhandledException += OnDispatcherException;

        var args = e.Args;
        string? ArgAfter(string name)
        {
            var index = Array.IndexOf(args, name);
            return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
        }

        if (args.Contains("--selftest-target"))
        {
            ThemeManager.Apply("dark");
            var window = new SelfTestTarget(ArgAfter("--selftest-target") ?? Path.Combine(Path.GetTempPath(), "ar-target.json"));
            MainWindow = window;
            window.Show();
            return;
        }

        if (args.Contains("--selftest"))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            _ = RunThenExit(() => SelfTest.RunAsync(ArgAfter("--out")));
            return;
        }

        if (args.Contains("--screenshots"))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var report = new Report(ArgAfter("--out"));
            _ = RunThenExit(() => ScreenshotMode.RunAsync(ArgAfter("--screenshots") ?? "screenshots", report));
            return;
        }

        var smoke = args.Contains("--smoke");
        if (smoke) ShutdownMode = ShutdownMode.OnExplicitShutdown;

        if (!smoke && string.IsNullOrWhiteSpace(dataOverride) && !AcquireSingleInstance())
        {
            Shutdown(0);
            return;
        }

        StartNormally(smoke ? new Report(ArgAfter("--out")) : null);
    }

    private async Task RunThenExit(Func<Task<int>> work)
    {
        var code = 1;
        try
        {
            code = await work();
        }
        catch (Exception ex)
        {
            WriteLog("Test mode crashed: " + ex);
        }
        Shutdown(code);
    }

    private void StartNormally(Report? smokeReport)
    {
        if (smokeReport != null) WatchBindingErrors();

        var settings = new SettingsStore(AppPaths.SettingsFile).Load();
        ThemeManager.Apply(settings.Theme);

        AppModel? model = null;
        var services = AppServices.CreateDefault(new WpfUiThread(Dispatcher), VersionText, () => model!.Settings);
        model = new AppModel(services);
        _model = model;
        model.Initialize();

        var window = new MainWindow(model);
        MainWindow = window;
        window.Show();

        _ = model.RefreshAiStatusAsync();
        _ = model.StartBackgroundUpdateCheckAsync();

        if (smokeReport != null) _ = RunSmokeAsync(model, window, smokeReport);
    }

    private async Task RunSmokeAsync(AppModel model, MainWindow window, Report report)
    {
        var code = 1;
        try
        {
            await Task.Delay(1500);
            report.Check(window.IsLoaded && window.IsVisible, "Main window opens", "The window is not visible.");
            report.Check(model.ShowWelcome, "Welcome screen appears on first run", "ShowWelcome was false on a fresh data folder.");

            model.SetupStageDwellMilliseconds = 0;
            window.Welcome.StartSetup();
            await Task.Delay(200);
            await model.RunSetupAsync();
            report.Check(model.SetupDone && model.SetupFraction >= 1, "Welcome checks finish", $"fraction={model.SetupFraction}");
            foreach (var check in model.SetupChecks) report.Info($"setup: {check.Title} = {check.State}: {check.Detail}");
            model.CompleteWelcome();

            model.NewEmptyRecording("Smoke test");
            model.InsertPreset("open-and-send", "general", "hello", null);
            await Task.Delay(300);
            report.Check(window.ActionList.Items.Count > 0 && model.HasActions, "Actions appear in the list", $"rows={window.ActionList.Items.Count}");

            window.ActionList.SelectedIndex = 0;
            await Task.Delay(200);
            report.Check(window.InspectorHost.Content is InspectorView, "Details panel is present", "No inspector.");

            var settingsWindow = new SettingsWindow(model) { Owner = window };
            settingsWindow.Show();
            await Task.Delay(300);
            for (var i = 0; i < 8; i++)
            {
                settingsWindow.SelectPage(i);
                await Task.Delay(40);
            }
            settingsWindow.Close();
            report.Pass("Settings window opens and every page loads");

            await Task.Delay(300);
            lock (_bindingErrors)
            {
                report.Check(_bindingErrors.Count == 0, "No data-binding errors in any screen",
                    string.Join(" || ", _bindingErrors.Take(12)));
            }
            code = report.Failures == 0 ? 0 : 1;
        }
        catch (Exception ex)
        {
            report.Fail("Smoke test crashed", ex.ToString());
        }
        report.Info($"{report.Passes} passed, {report.Failures} failed");
        Shutdown(code);
    }

    private void WatchBindingErrors()
    {
        PresentationTraceSources.Refresh();
        PresentationTraceSources.DataBindingSource.Listeners.Add(new BindingListener(message =>
        {
            lock (_bindingErrors) _bindingErrors.Add(message);
        }));
        PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Error;
    }

    private sealed class BindingListener : TraceListener
    {
        private readonly Action<string> _onError;
        private readonly System.Text.StringBuilder _buffer = new();

        public BindingListener(Action<string> onError) => _onError = onError;

        public override void Write(string? message) => _buffer.Append(message);

        public override void WriteLine(string? message)
        {
            _buffer.Append(message);
            var text = _buffer.ToString().Trim();
            _buffer.Clear();
            if (text.Length > 0) _onError(text.Length > 400 ? text[..400] : text);
        }
    }

    private bool AcquireSingleInstance()
    {
        try
        {
            _singleInstance = new Mutex(true, @"Local\ActionRecorder.SingleInstance", out var created);
            _activateSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\ActionRecorder.Activate");
            if (!created)
            {
                _activateSignal.Set();
                return false;
            }
            var thread = new Thread(() =>
            {
                while (true)
                {
                    _activateSignal.WaitOne();
                    Dispatcher.BeginInvoke(() =>
                    {
                        if (MainWindow is not { } window) return;
                        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
                        window.Activate();
                    });
                }
            })
            { IsBackground = true, Name = "Activation listener" };
            thread.Start();
        }
        catch (Exception)
        {
            // If the mutex cannot be created, just run; a second copy is harmless.
        }
        return true;
    }

    private void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        WriteLog(e.Exception.ToString());
        e.Handled = true;
        try
        {
            _model?.Show(NoticeKind.Error, "Something went wrong: " + e.Exception.Message + ". Details were saved to " + AppPaths.LogFile);
        }
        catch (Exception)
        {
        }
    }

    private static void WriteLog(string text)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataRoot);
            File.AppendAllText(AppPaths.LogFile, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {text}{Environment.NewLine}");
        }
        catch (Exception)
        {
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            _model?.Dispose();
        }
        catch (Exception)
        {
        }
        try
        {
            _singleInstance?.ReleaseMutex();
        }
        catch (Exception)
        {
        }
        base.OnExit(e);
    }
}
