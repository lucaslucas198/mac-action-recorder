using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using ActionRecorder.Core;
using ActionRecorder.Model;
using ActionRecorder.Native;
using CoreMouseButton = ActionRecorder.Core.MouseButton;

namespace ActionRecorder.Desktop;

/// <summary>Draws numbered circles where the macro's clicks will land. One transparent, click-through window per monitor.</summary>
public sealed class ClicksOverlay
{
    private readonly IReadOnlyList<ClickMarker> _markers;
    private readonly List<OverlayWindow> _windows = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(8) };

    public ClicksOverlay(IReadOnlyList<ClickMarker> markers)
    {
        _markers = markers;
        _timer.Tick += (_, _) => CloseAll();
    }

    public event EventHandler? Closed;

    /// <summary>Shows the markers. Returns how many are outside every monitor (they cannot be shown).</summary>
    public int ShowOnScreens()
    {
        var monitors = Win32Info.Monitors();
        if (monitors.Count == 0) monitors.Add(Win32Info.VirtualScreen());
        var shown = 0;
        foreach (var monitor in monitors)
        {
            var here = _markers.Where(m => m.X >= monitor.Left && m.X < monitor.Left + monitor.Width &&
                                           m.Y >= monitor.Top && m.Y < monitor.Top + monitor.Height).ToList();
            if (here.Count == 0) continue;
            shown += here.Count;
            var window = new OverlayWindow(monitor, here);
            _windows.Add(window);
            window.Show();
            window.Place();
        }
        _timer.Start();
        return _markers.Count - shown;
    }

    public void CloseAll()
    {
        _timer.Stop();
        foreach (var window in _windows.ToList())
        {
            try { window.Close(); } catch (InvalidOperationException) { }
        }
        _windows.Clear();
        Closed?.Invoke(this, EventArgs.Empty);
    }

    private sealed class OverlayWindow : Window
    {
        private readonly MonitorBounds _monitor;
        private readonly IReadOnlyList<ClickMarker> _markers;
        private readonly Canvas _canvas = new() { Background = Brushes.Transparent, IsHitTestVisible = false };

        public OverlayWindow(MonitorBounds monitor, IReadOnlyList<ClickMarker> markers)
        {
            _monitor = monitor;
            _markers = markers;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            ResizeMode = ResizeMode.NoResize;
            Title = "Action Recorder click preview";
            Content = _canvas;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = monitor.Left;
            Top = monitor.Top;
            Width = 200;
            Height = 200;
            SourceInitialized += (_, _) => WindowTools.MakeOverlay(this, clickThrough: true);
            DpiChanged += (_, _) => Draw();
        }

        public void Place()
        {
            WindowTools.PlaceTopmost(this, _monitor.Left, _monitor.Top, _monitor.Width, _monitor.Height);
            Draw();
        }

        private void Draw()
        {
            _canvas.Children.Clear();
            var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            if (scale <= 0) scale = 1;
            const double diameter = 30;
            foreach (var marker in _markers)
            {
                var x = (marker.X - _monitor.Left) / scale;
                var y = (marker.Y - _monitor.Top) / scale;
                var color = marker.Button == CoreMouseButton.Left ? Color.FromRgb(0x4C, 0x8D, 0xFF) : Color.FromRgb(0xF0, 0x52, 0x5B);

                var ring = new System.Windows.Shapes.Ellipse
                {
                    Width = diameter,
                    Height = diameter,
                    Fill = new SolidColorBrush(Color.FromArgb(0xD0, color.R, color.G, color.B)),
                    Stroke = Brushes.White,
                    StrokeThickness = 2,
                };
                Canvas.SetLeft(ring, x - diameter / 2);
                Canvas.SetTop(ring, y - diameter / 2);
                _canvas.Children.Add(ring);

                var label = new TextBlock
                {
                    Text = marker.Number.ToString(),
                    Foreground = Brushes.White,
                    FontWeight = FontWeights.Bold,
                    FontSize = 13,
                    Width = diameter,
                    TextAlignment = TextAlignment.Center,
                };
                Canvas.SetLeft(label, x - diameter / 2);
                Canvas.SetTop(label, y - 9);
                _canvas.Children.Add(label);
            }
        }
    }
}
