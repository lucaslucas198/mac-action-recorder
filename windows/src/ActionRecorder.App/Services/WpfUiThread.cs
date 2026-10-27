using ActionRecorder.Core;
using System.Windows.Threading;
using ActionRecorder.Model;

namespace ActionRecorder.Desktop;

/// <summary>Runs work on the WPF UI thread. Safe to call from any thread, including after shutdown has begun.</summary>
public sealed class WpfUiThread : IUiThread
{
    private readonly Dispatcher _dispatcher;

    public WpfUiThread(Dispatcher dispatcher) => _dispatcher = dispatcher;

    public void Post(Action action)
    {
        if (_dispatcher.HasShutdownStarted) return;
        _dispatcher.BeginInvoke(DispatcherPriority.Normal, action);
    }
}
