using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Desktop;

/// <summary>Stand-ins used only by the screenshot mode, so the screens can be rendered with sample data and without touching the PC.</summary>
internal sealed class DemoCapture : IInputCapture
{
    public bool IsRunning { get; private set; }
    public int EventCount => 0;
    public double ElapsedSeconds => 0;
    public string? Start(HotKey? ignoredHotKey = null, bool includeInjected = false)
    {
        IsRunning = true;
        return null;
    }

    public List<RawEvent> Stop()
    {
        IsRunning = false;
        return new List<RawEvent>();
    }

    public void Dispose()
    {
    }
}

internal sealed class DemoHotKey : IHotKeyRegistrar
{
    public event Action? Pressed
    {
        add { }
        remove { }
    }

    public bool IsRegistered => true;
    public bool Set(HotKey hotKey) => true;

    public void Dispose()
    {
    }
}

internal sealed class DemoProbe : ISystemProbe
{
    public ProgramInfo? ForegroundProgram() => new("discord.exe", "Discord");
    public ScreenSize? PrimaryScreen() => new(1920, 1080);
    public bool ForegroundIsMoreElevated() => false;
    public string WindowsDescription() => "Windows 11 (build 26100)";
    public int WindowsBuild => 26100;
    public int MonitorCount => 1;
}

internal sealed class DemoPerformer : IActionPerformer
{
    public void Perform(MacroAction action)
    {
    }

    public void Cleanup()
    {
    }
}

/// <summary>Pretends to be Ollama with one installed model, for the screenshots only.</summary>
internal sealed class DemoOllama : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        string body;
        if (request.RequestUri!.AbsolutePath.EndsWith("/api/tags", StringComparison.Ordinal))
        {
            body = """{"models":[{"name":"llama3.2:3b","size":2019393189}]}""";
        }
        else
        {
            var reply = "- Add a short wait after Ctrl+K so the Quick Switcher can open.\n- The click at step 2 depends on the window position; check it if you move Discord.\n- Typing and Enter send the message right away, so test with a private channel first.";
            body = JsonSerializer.Serialize(new { model = "m", message = new { role = "assistant", content = reply }, done = true });
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
    }
}
