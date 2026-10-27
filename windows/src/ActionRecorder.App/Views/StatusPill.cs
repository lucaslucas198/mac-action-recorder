using ActionRecorder.Core;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using ActionRecorder.Model;

namespace ActionRecorder.Desktop;

/// <summary>
/// The always-visible indicator shown while recording or playing. It stays on top of every program, never takes focus,
/// and has a Stop button, so recording is never hidden and playback can always be stopped.
/// </summary>
public sealed class StatusPill : Window
{
    private readonly AppModel _model;
    private readonly Ellipse _dot = new() { Width = 11, Height = 11, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _title = new() { FontWeight = FontWeights.SemiBold, FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _detail = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0), MaxWidth = 320, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Button _stop = new() { Content = "Stop", Margin = new Thickness(14, 0, 0, 0), Padding = new Thickness(14, 5, 14, 5) };

    public StatusPill(AppModel model)
    {
        _model = model;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        FontFamily = (FontFamily)Application.Current.FindResource("UiFont");
        Title = "Action Recorder status";

        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_dot);
        row.Children.Add(_title);
        row.Children.Add(_detail);
        _stop.Style = (Style)Application.Current.FindResource("DangerButton");
        _stop.ToolTip = "Stop (" + model.EmergencyStopText + ")";
        _stop.Click += (_, _) => _model.EmergencyStop();
        row.Children.Add(_stop);

        var border = new Border
        {
            Margin = new Thickness(14),
            Padding = new Thickness(18, 10, 12, 10),
            CornerRadius = new CornerRadius(26),
            Background = (Brush)Application.Current.FindResource("SurfaceBrush"),
            BorderBrush = (Brush)Application.Current.FindResource("LineBrush"),
            BorderThickness = new Thickness(1),
            Child = row,
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Opacity = 0.35, Color = Colors.Black },
        };
        _title.SetResourceReference(TextBlock.ForegroundProperty, "TextBrush");
        _detail.SetResourceReference(TextBlock.ForegroundProperty, "MutedBrush");
        Content = border;

        SourceInitialized += (_, _) => WindowTools.MakeOverlay(this, clickThrough: false);
        Loaded += (_, _) => PlaceAtTop();
        SizeChanged += (_, _) => PlaceAtTop();
        model.PropertyChanged += OnModelChanged;
        Closed += (_, _) => model.PropertyChanged -= OnModelChanged;
        Update();
    }

    private void PlaceAtTop()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - ActualWidth) / 2;
        Top = area.Top + 6;
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Update();

    private void Update()
    {
        var status = _model.Status;
        var brushKey = status switch
        {
            AppStatus.Recording => "DangerBrush",
            AppStatus.Playing => "SuccessBrush",
            _ => "WarnBrush",
        };
        _dot.SetResourceReference(Shape.FillProperty, brushKey);

        switch (status)
        {
            case AppStatus.Recording:
                _title.Text = "Recording";
                _detail.Text = $"{_model.RecordingElapsedText}  ·  {_model.RecordedEventCount} events";
                _stop.Content = "Stop recording";
                break;
            case AppStatus.Preparing:
                _title.Text = _model.StatusText;
                _detail.Text = _model.IsRecordingOrPreparing ? "Switch to the program you want to record" : "Get the right program in front";
                _stop.Content = "Cancel";
                break;
            case AppStatus.Paused:
                _title.Text = "Paused";
                _detail.Text = _model.RepetitionText;
                _stop.Content = "Stop";
                break;
            default:
                _title.Text = "Playing";
                _detail.Text = _model.RepetitionText + (string.IsNullOrEmpty(_model.PlaybackText) ? "" : "  ·  " + _model.PlaybackText);
                _stop.Content = "Stop";
                break;
        }
    }
}
