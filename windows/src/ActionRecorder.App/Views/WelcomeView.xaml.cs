using ActionRecorder.Core;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;
using ActionRecorder.Model;

namespace ActionRecorder.Desktop;

public partial class WelcomeView : UserControl
{
    private AppModel? _hooked;

    public WelcomeView()
    {
        InitializeComponent();
        DataContextChanged += (_, _) => Hook();
        Loaded += (_, _) => Hook();
    }

    private AppModel? Model => DataContext as AppModel;

    private void Hook()
    {
        var model = Model;
        if (ReferenceEquals(model, _hooked)) return;
        if (_hooked != null) _hooked.PropertyChanged -= OnModelChanged;
        _hooked = model;
        if (_hooked != null) _hooked.PropertyChanged += OnModelChanged;
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AppModel.SetupFraction) || Model == null) return;
        // The bar glides to each new position instead of jumping. It only ever moves because a check finished.
        var animation = new DoubleAnimation(Model.SetupFraction, TimeSpan.FromMilliseconds(260))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        SetupBar.BeginAnimation(System.Windows.Controls.Primitives.RangeBase.ValueProperty, animation);
    }

    private void OnGetStarted(object sender, RoutedEventArgs e) => StartSetup();

    /// <summary>Leaves the home page and runs the checks.</summary>
    public void StartSetup()
    {
        HomePage.Visibility = Visibility.Collapsed;
        SetupPage.Visibility = Visibility.Visible;
        SetupBar.BeginAnimation(System.Windows.Controls.Primitives.RangeBase.ValueProperty, null);
        SetupBar.Value = 0;
        _ = Model?.RunSetupAsync();
    }

    private void OnEnter(object sender, RoutedEventArgs e)
    {
        Model?.CompleteWelcome();
        // Show the home page again next time Settings > About > "Show the welcome screen" is used.
        HomePage.Visibility = Visibility.Visible;
        SetupPage.Visibility = Visibility.Collapsed;
    }
}
