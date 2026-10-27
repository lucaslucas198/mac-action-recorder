using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Tests;

/// <summary>Answers HTTP calls from a function instead of the network.</summary>
public sealed class FakeHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, (HttpStatusCode, string)> _respond;
    public readonly List<string> Requests = new();
    public readonly List<string> Bodies = new();

    public FakeHandler(Func<HttpRequestMessage, (HttpStatusCode, string)> respond) => _respond = respond;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        lock (Requests)
        {
            Requests.Add(request.Method + " " + request.RequestUri);
        }
        if (request.Content != null)
        {
            var body = await request.Content.ReadAsStringAsync(cancellationToken);
            lock (Bodies) Bodies.Add(body);
        }
        var (status, text) = _respond(request);
        return new HttpResponseMessage(status) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
    }
}

public sealed class ThrowingHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        throw new HttpRequestException("connection refused");
}

public static class ServiceTests
{
    private const string Tags = """{"models":[{"name":"llama3.2:3b","size":2019393189},{"name":"nomic-embed-text:latest","size":274302450}]}""";

    private static string Chat(string content) => JsonSerializer.Serialize(new { model = "m", message = new { role = "assistant", content }, done = true });

    private static Recording Sample()
    {
        var r = new Recording("Demo");
        r.Actions.Add(Act.Key(KeyCodes.K, KeyModifiers.Control));
        r.Actions.Add(Act.Text("general", delay: 0.1));
        r.Actions.Add(Act.Key(KeyCodes.Return));
        r.Actions.Add(Act.Key(KeyCodes.Return));
        return r;
    }

    // ------------------------------------------------------------------ Ollama

    [Test]
    public static void OnlyLocalEndpointsAreAccepted()
    {
        Check.Throws<AiException>(() => new OllamaClient("http://192.168.0.5:11434"));
        Check.Throws<AiException>(() => new OllamaClient("https://example.com"));
        new OllamaClient("http://localhost:11434").Dispose();
    }

    [Test]
    public static async Task StatusListsModels()
    {
        var handler = new FakeHandler(r => (HttpStatusCode.OK, Tags));
        using var client = new OllamaClient(AiDefaults.Endpoint, handler);
        var status = await client.GetStatusAsync();
        Check.True(status.IsRunning);
        Check.True(status.HasModel);
        Check.Equal(2, status.Models.Count);
        Check.Equal("llama3.2:3b", status.Models[0].Name);
        Check.Equal("GET http://127.0.0.1:11434/api/tags", handler.Requests[0]);
    }

    [Test]
    public static async Task StatusWhenNoModelIsInstalled()
    {
        using var client = new OllamaClient(AiDefaults.Endpoint, new FakeHandler(r => (HttpStatusCode.OK, """{"models":[]}""")));
        var status = await client.GetStatusAsync();
        Check.True(status.IsRunning);
        Check.False(status.HasModel);
        Check.True(status.Message.Contains(OllamaClient.RecommendedModel));
    }

    [Test]
    public static async Task StatusWhenOllamaIsNotRunning()
    {
        using var client = new OllamaClient(AiDefaults.Endpoint, new ThrowingHandler());
        var status = await client.GetStatusAsync();
        Check.False(status.IsRunning);
        Check.True(status.Message.Contains("ollama.com/download"));
    }

    [Test]
    public static async Task StatusOnServerErrorAndGarbage()
    {
        using var broken = new OllamaClient(AiDefaults.Endpoint, new FakeHandler(r => (HttpStatusCode.InternalServerError, "oops")));
        Check.False((await broken.GetStatusAsync()).IsRunning);
        using var garbage = new OllamaClient(AiDefaults.Endpoint, new FakeHandler(r => (HttpStatusCode.OK, "<html>not json</html>")));
        var status = await garbage.GetStatusAsync();
        Check.True(status.IsRunning);
        Check.False(status.HasModel);
    }

    [Test]
    public static void ModelChoice()
    {
        var models = new List<AiModelInfo> { new("nomic-embed-text:latest", 1), new("llama3.2:3b", 2), new("qwen2.5:7b", 3) };
        Check.Equal("llama3.2:3b", OllamaClient.ChooseModel(models, ""));
        Check.Equal("qwen2.5:7b", OllamaClient.ChooseModel(models, "qwen2.5:7b"));
        Check.Equal("qwen2.5:7b", OllamaClient.ChooseModel(models, "QWEN2.5:7B"));
        Check.Equal("llama3.2:3b", OllamaClient.ChooseModel(models, "not-installed"));
        Check.Equal("qwen2.5:7b", OllamaClient.ChooseModel(models, "qwen2.5"));
        Check.True(OllamaClient.ChooseModel(new List<AiModelInfo>(), "x") == null);
        Check.Equal("only-embed", OllamaClient.ChooseModel(new List<AiModelInfo> { new("only-embed", 1) }, ""));
    }

    [Test]
    public static void ChatRequestHasTheDocumentedShape()
    {
        using var doc = JsonDocument.Parse(OllamaClient.BuildChatRequest("llama3.2:3b", "SYS \"quoted\"", "USER\nline"));
        var root = doc.RootElement;
        Check.Equal("llama3.2:3b", root.GetProperty("model").GetString());
        Check.False(root.GetProperty("stream").GetBoolean());
        var messages = root.GetProperty("messages");
        Check.Equal(2, messages.GetArrayLength());
        Check.Equal("system", messages[0].GetProperty("role").GetString());
        Check.Equal("SYS \"quoted\"", messages[0].GetProperty("content").GetString());
        Check.Equal("user", messages[1].GetProperty("role").GetString());
        Check.Equal("USER\nline", messages[1].GetProperty("content").GetString());
        Check.True(root.GetProperty("options").GetProperty("temperature").GetDouble() < 0.5);
    }

    [Test]
    public static void ChatReplyParsing()
    {
        Check.Equal("hello", OllamaClient.ParseChatReply(Encoding.UTF8.GetBytes(Chat("  hello \n"))));
        Check.Throws<AiException>(() => OllamaClient.ParseChatReply(Encoding.UTF8.GetBytes(Chat("   "))));
        Check.Throws<AiException>(() => OllamaClient.ParseChatReply(Encoding.UTF8.GetBytes("{\"error\":\"model not found\"}")));
        Check.Throws<AiException>(() => OllamaClient.ParseChatReply(Encoding.UTF8.GetBytes("garbage")));
        Check.Throws<AiException>(() => OllamaClient.ParseChatReply(Encoding.UTF8.GetBytes("[]")));
    }

    [Test]
    public static async Task ChatReturnsTheModelText()
    {
        var handler = new FakeHandler(r => (HttpStatusCode.OK, Chat("Looks fine.")));
        using var client = new OllamaClient(AiDefaults.Endpoint, handler);
        Check.Equal("Looks fine.", await client.ChatAsync("llama3.2:3b", "sys", "hi"));
        Check.Equal("POST http://127.0.0.1:11434/api/chat", handler.Requests[0]);
    }

    [Test]
    public static async Task ChatErrorsAreExplained()
    {
        using var missing = new OllamaClient(AiDefaults.Endpoint, new FakeHandler(r => (HttpStatusCode.NotFound, "{}")));
        var ex = await Assert<AiException>(() => missing.ChatAsync("nope", "s", "u"));
        Check.True(ex.Message.Contains("nope"));
        using var down = new OllamaClient(AiDefaults.Endpoint, new ThrowingHandler());
        await Assert<AiException>(() => down.ChatAsync("m", "s", "u"));
    }

    [Test]
    public static void PullProgressLines()
    {
        var line = OllamaClient.ParsePullLine("""{"status":"pulling abc","digest":"sha256:abc","total":1000,"completed":250}""")!;
        Check.Equal(0.25, line.Fraction!.Value);
        Check.Equal("pulling abc", line.Status);
        Check.True(OllamaClient.ParsePullLine("""{"status":"pulling manifest"}""")!.Fraction == null);
        Check.True(OllamaClient.ParsePullLine("""{"error":"pull model manifest: file does not exist"}""")!.Status.StartsWith("error:"));
        Check.True(OllamaClient.ParsePullLine("") == null);
        Check.True(OllamaClient.ParsePullLine("not json") == null);
    }

    [Test]
    public static async Task PullStreamsProgressAndSucceeds()
    {
        var body = string.Join("\n",
            """{"status":"pulling manifest"}""",
            """{"status":"pulling abc","digest":"sha256:abc","total":100,"completed":50}""",
            """{"status":"pulling abc","digest":"sha256:abc","total":100,"completed":100}""",
            """{"status":"success"}""");
        var handler = new FakeHandler(r => (HttpStatusCode.OK, body));
        using var client = new OllamaClient(AiDefaults.Endpoint, handler);
        var seen = new List<PullProgress>();
        await client.PullModelAsync("llama3.2:3b", new Progress<PullProgress>(p => { lock (seen) seen.Add(p); }));
        await Task.Delay(50);
        Check.True(handler.Bodies[0].Contains("llama3.2:3b"));
        lock (seen) Check.True(seen.Count >= 1);
    }

    [Test]
    public static async Task PullFailuresAreReported()
    {
        using var failing = new OllamaClient(AiDefaults.Endpoint, new FakeHandler(r => (HttpStatusCode.OK, """{"error":"disk full"}""")));
        var ex = await Assert<AiException>(() => failing.PullModelAsync("m", null));
        Check.True(ex.Message.Contains("disk full"));
        using var truncated = new OllamaClient(AiDefaults.Endpoint, new FakeHandler(r => (HttpStatusCode.OK, """{"status":"pulling manifest"}""")));
        await Assert<AiException>(() => truncated.PullModelAsync("m", null));
    }

    // ------------------------------------------------------------------ AI assistant

    private static AiAssistant Assistant(string chatReply, AppSettings? settings = null, FakeHandler? handler = null)
    {
        var h = handler ?? new FakeHandler(r => r.RequestUri!.AbsolutePath.EndsWith("/api/tags")
            ? (HttpStatusCode.OK, Tags)
            : (HttpStatusCode.OK, Chat(chatReply)));
        var s = settings ?? new AppSettings();
        return new AiAssistant(() => s, _ => h);
    }

    [Test]
    public static async Task AssistantReviewSendsASummaryAndReturnsText()
    {
        var handler = new FakeHandler(r => r.RequestUri!.AbsolutePath.EndsWith("/api/tags") ? (HttpStatusCode.OK, Tags) : (HttpStatusCode.OK, Chat("- Step 2 may be too fast")));
        var ai = Assistant("", handler: handler);
        var text = await ai.ReviewAsync(Sample());
        Check.Equal("- Step 2 may be too fast", text);
        var body = handler.Bodies.Last();
        Check.True(body.Contains("Macro: Demo"));
        Check.True(body.Contains("Ctrl+K"));
        Check.True(body.Contains("embed") == false, "the chat must use the chat model, not the embedding model");
        Check.True(body.Contains("llama3.2:3b"));
    }

    [Test]
    public static async Task AssistantProposesParsedEdits()
    {
        var ai = Assistant("PAUSE 2 0.5 | give the switcher time\nDELETE 4 | repeat of step 3\nDELETE 99 | nonsense");
        var edits = await ai.ProposeEditsAsync(Sample());
        Check.Equal(2, edits.Count);
        Check.True(edits.All(e => e.Source == EditSource.Ai));
    }

    [Test]
    public static async Task AssistantDraftsSteps()
    {
        var ai = Assistant("KEY ctrl+k\nTYPE general\nKEY enter");
        var draft = await ai.DraftStepsAsync("open the general channel");
        Check.Equal(3, draft.Actions.Count);
        Check.Equal(KeyModifiers.Control, draft.Actions[0].Modifiers!.Value);
    }

    [Test]
    public static async Task AssistantNamesAMacro()
    {
        var ai = Assistant("\"Open general channel.\"");
        Check.Equal("Open general channel", await ai.SuggestNameAsync(Sample()));
    }

    [Test]
    public static async Task AssistantRespectsTheOffSwitch()
    {
        var handler = new FakeHandler(r => (HttpStatusCode.OK, Tags));
        var ai = Assistant("", new AppSettings { AiEnabled = false }, handler);
        await Assert<AiException>(() => ai.ReviewAsync(Sample()));
        Check.Equal(0, handler.Requests.Count);
        Check.False((await ai.StatusAsync()).IsRunning);
    }

    [Test]
    public static async Task AssistantExplainsWhenThereIsNoModel()
    {
        var handler = new FakeHandler(r => (HttpStatusCode.OK, """{"models":[]}"""));
        var ai = Assistant("", handler: handler);
        var ex = await Assert<AiException>(() => ai.ReviewAsync(Sample()));
        Check.True(ex.Message.Contains("llama3.2"));
    }

    [Test]
    public static async Task AssistantNeverCallsANonLocalAddress()
    {
        var settings = new AppSettings { AiEndpoint = "http://example.com:11434" }; // not sanitized on purpose
        var ai = new AiAssistant(() => settings, _ => new FakeHandler(r => (HttpStatusCode.OK, Tags)));
        await Assert<AiException>(() => ai.ReviewAsync(Sample()));
    }

    // ------------------------------------------------------------------ updates

    private static string ReleaseJson(string tag, string installerUrl, string sumsUrl) => JsonSerializer.Serialize(new
    {
        tag_name = tag,
        draft = false,
        prerelease = false,
        assets = new object[]
        {
            new { name = UpdateConfig.InstallerAssetName, browser_download_url = installerUrl },
            new { name = UpdateConfig.ChecksumAssetName, browser_download_url = sumsUrl },
        },
    });

    private static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();

    [Test]
    public static async Task UpdateCheckFindsANewerRelease()
    {
        var installer = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.InstallerAssetName;
        var sums = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.ChecksumAssetName;
        var handler = new FakeHandler(r => (HttpStatusCode.OK, ReleaseJson("v0.5.0", installer, sums)));
        using var service = new UpdateService("0.4.0", handler);
        await service.CheckAsync();
        Check.Equal(UpdatePhase.Available, service.State.Phase);
        Check.Equal("0.5.0", service.State.Version!.ToString());
        Check.True(handler.Requests[0].Contains("releases/latest"));
    }

    [Test]
    public static async Task UpdateCheckIgnoresSameOrOlderOrMissingWindowsAsset()
    {
        var installer = UpdateConfig.ReleaseDownloadPrefix + "v0.4.0/" + UpdateConfig.InstallerAssetName;
        using (var same = new UpdateService("0.4.0", new FakeHandler(r => (HttpStatusCode.OK, ReleaseJson("v0.4.0", installer, installer)))))
        {
            await same.CheckAsync();
            Check.Equal(UpdatePhase.UpToDate, same.State.Phase);
        }
        // A release that only has the Mac files: nothing to install on Windows.
        var macOnly = """{"tag_name":"v9.0.0","draft":false,"prerelease":false,"assets":[{"name":"MacActionRecorder-macOS.zip","browser_download_url":"https://github.com/lucaslucas198/mac-action-recorder/releases/download/v9.0.0/MacActionRecorder-macOS.zip"}]}""";
        using (var mac = new UpdateService("0.4.0", new FakeHandler(r => (HttpStatusCode.OK, macOnly))))
        {
            await mac.CheckAsync();
            Check.Equal(UpdatePhase.UpToDate, mac.State.Phase);
        }
        using (var none = new UpdateService("0.4.0", new FakeHandler(r => (HttpStatusCode.NotFound, "{}"))))
        {
            await none.CheckAsync();
            Check.Equal(UpdatePhase.UpToDate, none.State.Phase);
        }
    }

    [Test]
    public static async Task UpdateCheckReportsNetworkProblems()
    {
        using var offline = new UpdateService("0.4.0", new ThrowingHandler());
        await offline.CheckAsync();
        Check.Equal(UpdatePhase.Failed, offline.State.Phase);
        using var limited = new UpdateService("0.4.0", new FakeHandler(r => (HttpStatusCode.Forbidden, "{}")));
        await limited.CheckAsync();
        Check.Equal(UpdatePhase.Failed, limited.State.Phase);
    }

    private static string TempDir()
    {
        var path = Path.Combine(Path.GetTempPath(), "ar-upd-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static FakeHandler UpdateServer(string payload, string? checksumOverride = null)
    {
        var installer = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.InstallerAssetName;
        var sums = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.ChecksumAssetName;
        return new FakeHandler(r =>
        {
            var url = r.RequestUri!.ToString();
            if (url.Contains("releases/latest")) return (HttpStatusCode.OK, ReleaseJson("v0.5.0", installer, sums));
            if (url == sums) return (HttpStatusCode.OK, $"{checksumOverride ?? Hash(payload)}  {UpdateConfig.InstallerAssetName}\n");
            if (url == installer) return (HttpStatusCode.OK, payload);
            return (HttpStatusCode.NotFound, "");
        });
    }

    [Test]
    public static async Task UpdateDownloadVerifiesTheChecksum()
    {
        var folder = TempDir();
        using var service = new UpdateService("0.4.0", UpdateServer("pretend-installer-bytes"));
        await service.CheckAsync();
        await service.DownloadAsync(folder);
        Check.Equal(UpdatePhase.Ready, service.State.Phase);
        Check.Equal("pretend-installer-bytes", File.ReadAllText(service.State.InstallerPath!));
        Check.Equal(0, Directory.GetFiles(folder, "*.part").Length);
    }

    [Test]
    public static async Task UpdateDownloadRejectsAMismatch()
    {
        var folder = TempDir();
        using var service = new UpdateService("0.4.0", UpdateServer("tampered", checksumOverride: new string('0', 64)));
        await service.CheckAsync();
        await service.DownloadAsync(folder);
        Check.Equal(UpdatePhase.Failed, service.State.Phase);
        Check.Equal(0, Directory.GetFiles(folder).Length);
        Check.False(service.LaunchInstaller());
    }

    [Test]
    public static async Task UpdateDownloadNeedsAChecksumEntry()
    {
        var installer = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.InstallerAssetName;
        var sums = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.ChecksumAssetName;
        var handler = new FakeHandler(r =>
        {
            var url = r.RequestUri!.ToString();
            if (url.Contains("releases/latest")) return (HttpStatusCode.OK, ReleaseJson("v0.5.0", installer, sums));
            if (url == sums) return (HttpStatusCode.OK, "nothing useful here");
            return (HttpStatusCode.OK, "bytes");
        });
        using var service = new UpdateService("0.4.0", handler);
        await service.CheckAsync();
        await service.DownloadAsync(TempDir());
        Check.Equal(UpdatePhase.Failed, service.State.Phase);
        Check.False(handler.Requests.Any(r => r.EndsWith(UpdateConfig.InstallerAssetName)), "must not download without a checksum");
    }

    [Test]
    public static async Task UpdateStateChangesAreAnnounced()
    {
        var seen = new List<UpdatePhase>();
        using var service = new UpdateService("0.4.0", UpdateServer("x"));
        service.Changed += s => seen.Add(s.Phase);
        await service.CheckAsync();
        await service.DownloadAsync(TempDir());
        Check.SequenceEqual(new[] { UpdatePhase.Checking, UpdatePhase.Available, UpdatePhase.Downloading, UpdatePhase.Ready }, seen.Distinct());
    }

    // ------------------------------------------------------------------ paths & system

    [Test]
    public static void PathsLiveInTheProfile()
    {
        AppPaths.RootOverride = null;
        Check.True(AppPaths.SettingsFile.EndsWith("settings.json"));
        Check.True(AppPaths.DefaultRecordingsFolder.Contains("ActionRecorder"));
        AppPaths.RootOverride = "/tmp/x";
        Check.True(AppPaths.SettingsFile.StartsWith("/tmp/x"));
        AppPaths.RootOverride = null;
    }

    [Test]
    public static void SystemQueriesDoNotThrowOffWindows()
    {
        if (OperatingSystem.IsWindows()) return;
        Check.True(Win32Info.PrimaryScreen() == null);
        Check.True(Win32Info.ForegroundProgram() == null);
        Check.False(Win32Info.ForegroundIsMoreElevated());
        Check.Equal(0, Win32Info.Monitors().Count);
        var recorder = new InputRecorder();
        Check.True(recorder.Start() != null);
        Check.Equal(0, recorder.Stop().Count);
    }

    public static async Task<T> Assert<T>(Func<Task> action) where T : Exception
    {
        try
        {
            await action();
        }
        catch (T ex)
        {
            return ex;
        }
        catch (Exception ex)
        {
            throw new AssertionFailed($"expected {typeof(T).Name} but got {ex.GetType().Name}: {ex.Message}");
        }
        throw new AssertionFailed($"expected {typeof(T).Name} but nothing was thrown");
    }
}
