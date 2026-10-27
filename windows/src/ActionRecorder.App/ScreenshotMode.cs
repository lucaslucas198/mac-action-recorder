using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ActionRecorder.Core;
using ActionRecorder.Model;
using ActionRecorder.Native;

namespace ActionRecorder.Desktop;

/// <summary>`ActionRecorder.exe --screenshots folder` renders the main screens with sample data into PNG files (used by CI and for the README).</summary>
internal static class ScreenshotMode
{
    public static async Task<int> RunAsync(string folder, Report report)
    {
        try
        {
            Directory.CreateDirectory(folder);
            var dataRoot = Path.Combine(Path.GetTempPath(), "ar-shots-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dataRoot);
            AppPaths.RootOverride = dataRoot;

            var settingsStore = new SettingsStore(AppPaths.SettingsFile);
            var initial = new AppSettings { HasCompletedWelcome = false, AcknowledgedRecordingWarning = true, BackupEnabled = false, HideWindowDuringPlayback = false, HideWindowWhileRecording = false };
            settingsStore.Save(initial);

            ThemeManager.Apply("dark");
            AppModel? model = null;
            var services = new AppServices
            {
                Ui = new WpfUiThread(Application.Current.Dispatcher),
                Capture = new DemoCapture(),
                HotKey = new DemoHotKey(),
                Performer = new DemoPerformer(),
                Probe = new DemoProbe(),
                SettingsStore = settingsStore,
                InstalledVersion = App.VersionText,
                AiFactory = _ => new AiAssistant(() => model!.Settings, _ => new DemoOllama()),
                UpdateFactory = null,
            };
            model = new AppModel(services) { SetupStageDwellMilliseconds = 0 };
            model.Initialize();

            var window = new MainWindow(model) { Width = 1280, Height = 820, WindowStartupLocation = WindowStartupLocation.Manual, Left = 20, Top = 20 };
            Application.Current.MainWindow = window;
            window.Show();
            await Flush();

            Save(window, Path.Combine(folder, "01-welcome.png"), report);

            window.Welcome.StartSetup();
            await model.RunSetupAsync();
            await Task.Delay(500);
            await Flush();
            Save(window, Path.Combine(folder, "02-checks.png"), report);

            model.CompleteWelcome();
            await model.RefreshAiStatusAsync();
            AddDemoMacro(model);
            await Flush();
            window.SelectActionForDemo(2);
            await Flush();
            Save(window, Path.Combine(folder, "03-main.png"), report);

            window.ShowSideTab(1);
            model.PlanImprovements();
            await Flush();
            Save(window, Path.Combine(folder, "04-check.png"), report);

            window.ShowSideTab(2);
            await model.ReviewWithAiAsync();
            await Flush();
            Save(window, Path.Combine(folder, "05-ai.png"), report);

            window.ShowSideTab(0);
            model.Speed = 2;
            model.Countdown = 0;
            model.Play();
            await Task.Delay(900);
            await Flush();
            Save(window, Path.Combine(folder, "06-playing.png"), report);
            var pill = new StatusPill(model) { Left = 400, Top = 300 };
            pill.Show();
            await Flush();
            Save(pill, Path.Combine(folder, "07-pill.png"), report);
            pill.Close();
            model.EmergencyStop();
            await Task.Delay(300);

            var names = new[] { "recording", "playback", "storage", "ai", "updates", "appearance", "privacy", "about" };
            for (var i = 0; i < names.Length; i++)
            {
                var settings = new SettingsWindow(model) { Left = 60, Top = 40 };
                settings.Show();
                settings.SelectPage(i);
                await Flush();
                Save(settings, Path.Combine(folder, $"08-settings-{names[i]}.png"), report);
                settings.Close();
            }

            ThemeManager.Apply("light");
            await Flush();
            Save(window, Path.Combine(folder, "09-main-light.png"), report);

            window.Close();
            model.Dispose();
            return report.Failures == 0 ? 0 : 1;
        }
        catch (Exception ex)
        {
            report.Fail("Screenshot mode crashed", ex.ToString());
            return 1;
        }
    }

    private static void AddDemoMacro(AppModel model)
    {
        model.NewEmptyRecording("Say good morning in #general");
        model.InsertActions(new[]
        {
            Act.Move(640, 420, 0.30),
            Act.Click(188, 962, delay: 0.55),
            Act.Key(KeyCodes.K, KeyModifiers.Control, delay: 0.40),
            Act.Wait(0.5),
            Act.Text("general", delay: 0.25),
            Act.Key(KeyCodes.Return, delay: 0.60),
            Act.Click(960, 1010, delay: 1.20),
            Act.Text("Good morning, everyone!", delay: 0.35),
            Act.Key(KeyCodes.Return, delay: 0.30),
        }, null);
        model.NewEmptyRecording("Welcome new members");
        model.InsertPreset("send-message", "Welcome to the server!", "", null);
        model.NewEmptyRecording("Daily check-in");
        model.InsertPreset("open-channel", "announcements", "", null);
        model.SelectedEntry = model.Recordings.First(r => r.Name == "Say good morning in #general");
    }

    private static async Task Flush()
    {
        await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        await Task.Delay(120);
        await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }

    private static void Save(Window window, string path, Report report)
    {
        try
        {
            var content = (FrameworkElement)window.Content;
            content.UpdateLayout();
            var width = (int)Math.Ceiling(content.ActualWidth);
            var height = (int)Math.Ceiling(content.ActualHeight);
            if (width <= 0 || height <= 0)
            {
                report.Fail(Path.GetFileName(path), "The window has no size.");
                return;
            }
            var dpi = VisualTreeHelper.GetDpi(content);
            var bitmap = new RenderTargetBitmap((int)(width * dpi.DpiScaleX), (int)(height * dpi.DpiScaleY), 96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, PixelFormats.Pbgra32);
            // Paint the window colour first, because transparent areas would otherwise be black.
            var background = new DrawingVisual();
            using (var context = background.RenderOpen())
            {
                var brush = window.Background ?? (Brush)Application.Current.FindResource("BgBrush");
                context.DrawRectangle(brush, null, new Rect(0, 0, width, height));
            }
            bitmap.Render(background);
            bitmap.Render(content);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = File.Create(path);
            encoder.Save(stream);
            report.Pass(Path.GetFileName(path), $"{bitmap.PixelWidth}×{bitmap.PixelHeight}");
        }
        catch (Exception ex)
        {
            report.Fail(Path.GetFileName(path), ex.Message);
        }
    }
}
