using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using ActionRecorder.Core;

namespace ActionRecorder.Native;

public sealed class AiException : Exception
{
    public AiException(string message) : base(message)
    {
    }
}

public sealed record AiModelInfo(string Name, long SizeBytes);

public sealed record AiStatus(bool IsRunning, IReadOnlyList<AiModelInfo> Models, string Message)
{
    public bool HasModel => Models.Count > 0;
}

public sealed record PullProgress(string Status, long Completed, long Total)
{
    public double? Fraction => Total > 0 ? Math.Clamp((double)Completed / Total, 0, 1) : null;
}

/// <summary>
/// Talks to Ollama (https://ollama.com), a free program that runs language models on this PC.
/// The app only connects to an address on this computer (127.0.0.1 / localhost), so macro text never leaves the PC.
/// The model's replies are only ever read as text and passed through the strict parsers in the core library.
/// </summary>
public sealed class OllamaClient : IDisposable
{
    public const string RecommendedModel = "llama3.2:3b";
    public const string RecommendedModelSize = "about 2 GB";
    public const string DownloadPage = "https://ollama.com/download";

    private readonly HttpClient _http;
    private readonly Uri _baseUri;

    public OllamaClient(string endpoint, HttpMessageHandler? handler = null)
    {
        if (!AiDefaults.IsLocalEndpoint(endpoint)) throw new AiException("The AI helper only connects to a program on this PC.");
        _baseUri = new Uri(endpoint.TrimEnd('/') + "/");
        _http = handler == null ? new HttpClient() : new HttpClient(handler);
        _http.Timeout = Timeout.InfiniteTimeSpan; // each call sets its own limit
    }

    /// <summary>Checks that Ollama answers, and lists the models that are installed.</summary>
    public async Task<AiStatus> GetStatusAsync(CancellationToken cancel = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(3));
        try
        {
            using var response = await _http.GetAsync(new Uri(_baseUri, "api/tags"), timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return new AiStatus(false, Array.Empty<AiModelInfo>(), $"Ollama answered with an error ({(int)response.StatusCode}).");
            }
            var bytes = await response.Content.ReadAsByteArrayAsync(timeout.Token).ConfigureAwait(false);
            var models = ParseModels(bytes);
            return models.Count == 0
                ? new AiStatus(true, models, $"Ollama is running, but no model is installed yet. Download {RecommendedModel} ({RecommendedModelSize}) to start.")
                : new AiStatus(true, models, $"Ollama is running with {models.Count} model(s).");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or OperationCanceledException or IOException)
        {
            if (cancel.IsCancellationRequested) throw;
            return new AiStatus(false, Array.Empty<AiModelInfo>(),
                "Ollama is not running on this PC. Install it from ollama.com/download and start it, then press Check again.");
        }
    }

    public static List<AiModelInfo> ParseModels(byte[] json)
    {
        var models = new List<AiModelInfo>();
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty("models", out var array)
                || array.ValueKind != JsonValueKind.Array) return models;
            foreach (var item in array.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                var name = item.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
                if (string.IsNullOrWhiteSpace(name)) continue;
                var size = item.TryGetProperty("size", out var s) && s.ValueKind == JsonValueKind.Number && s.TryGetInt64(out var v) ? v : 0;
                models.Add(new AiModelInfo(name!, size));
            }
        }
        catch (JsonException)
        {
            // an unreadable list is treated as no models
        }
        return models;
    }

    /// <summary>Picks the model to use: the one chosen in settings if it is installed, otherwise the first installed.</summary>
    public static string? ChooseModel(IReadOnlyList<AiModelInfo> installed, string preferred)
    {
        if (installed.Count == 0) return null;
        if (!string.IsNullOrWhiteSpace(preferred))
        {
            var match = installed.FirstOrDefault(m => string.Equals(m.Name, preferred, StringComparison.OrdinalIgnoreCase))
                        ?? installed.FirstOrDefault(m => m.Name.StartsWith(preferred.Split(':')[0] + ":", StringComparison.OrdinalIgnoreCase) && !preferred.Contains(':'));
            if (match != null) return match.Name;
        }
        // Skip embedding-only models, which cannot chat.
        var chat = installed.FirstOrDefault(m => !m.Name.Contains("embed", StringComparison.OrdinalIgnoreCase));
        return (chat ?? installed[0]).Name;
    }

    /// <summary>Sends one question to the model and returns its text answer.</summary>
    public async Task<string> ChatAsync(string model, string system, string user, CancellationToken cancel = default, double timeoutSeconds = 180)
    {
        var body = BuildChatRequest(model, system, user);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        try
        {
            using var content = new StringContent(body, Encoding.UTF8, "application/json");
            using var response = await _http.PostAsync(new Uri(_baseUri, "api/chat"), content, timeout.Token).ConfigureAwait(false);
            var bytes = await response.Content.ReadAsByteArrayAsync(timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new AiException(response.StatusCode == HttpStatusCode.NotFound
                    ? $"The model “{model}” is not installed in Ollama."
                    : $"Ollama returned an error ({(int)response.StatusCode}): {Trim(Encoding.UTF8.GetString(bytes))}");
            }
            return ParseChatReply(bytes);
        }
        catch (Exception ex) when (ex is HttpRequestException)
        {
            throw new AiException("Could not reach Ollama. Is it running?");
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new AiException("The model took too long to answer. A smaller model may be faster.");
        }
    }

    public static string BuildChatRequest(string model, string system, string user)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            w.WriteStartObject();
            w.WriteString("model", model);
            w.WritePropertyName("messages");
            w.WriteStartArray();
            w.WriteStartObject(); w.WriteString("role", "system"); w.WriteString("content", system); w.WriteEndObject();
            w.WriteStartObject(); w.WriteString("role", "user"); w.WriteString("content", user); w.WriteEndObject();
            w.WriteEndArray();
            w.WriteBoolean("stream", false);
            w.WritePropertyName("options");
            w.WriteStartObject();
            w.WriteNumber("temperature", 0.2);
            w.WriteNumber("num_predict", 500);
            w.WriteEndObject();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    public static string ParseChatReply(byte[] json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Object)
            {
                if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String)
                {
                    throw new AiException(error.GetString() ?? "Ollama reported an error.");
                }
                if (root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.Object
                    && message.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.String)
                {
                    var text = (content.GetString() ?? "").Trim();
                    if (text.Length == 0) throw new AiException("The model returned an empty answer. Try again.");
                    return text;
                }
            }
        }
        catch (JsonException)
        {
            // fall through
        }
        throw new AiException("Ollama sent an answer this app could not read.");
    }

    /// <summary>Downloads a model through Ollama (it fetches from the Ollama library). Progress is reported as it streams in.</summary>
    public async Task PullModelAsync(string model, IProgress<PullProgress>? progress, CancellationToken cancel = default)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(_baseUri, "api/pull"))
            {
                Content = new StringContent(JsonSerializer.Serialize(new { model, stream = true }), Encoding.UTF8, "application/json"),
            };
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new AiException($"Ollama could not start the download ({(int)response.StatusCode}).");
            }
            using var stream = await response.Content.ReadAsStreamAsync(cancel).ConfigureAwait(false);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            string? line;
            var sawSuccess = false;
            while ((line = await reader.ReadLineAsync(cancel).ConfigureAwait(false)) != null)
            {
                var update = ParsePullLine(line);
                if (update == null) continue;
                if (update.Status.StartsWith("error:", StringComparison.Ordinal)) throw new AiException(update.Status[6..].Trim());
                if (update.Status == "success") sawSuccess = true;
                progress?.Report(update);
            }
            if (!sawSuccess) throw new AiException("The download ended before it finished.");
        }
        catch (HttpRequestException)
        {
            throw new AiException("Could not reach Ollama. Is it running?");
        }
    }

    public static PullProgress? ParsePullLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return null;
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String)
            {
                return new PullProgress("error: " + error.GetString(), 0, 0);
            }
            var status = root.TryGetProperty("status", out var s) && s.ValueKind == JsonValueKind.String ? s.GetString() ?? "" : "";
            long total = root.TryGetProperty("total", out var t) && t.ValueKind == JsonValueKind.Number && t.TryGetInt64(out var tv) ? tv : 0;
            long completed = root.TryGetProperty("completed", out var c) && c.ValueKind == JsonValueKind.Number && c.TryGetInt64(out var cv) ? cv : 0;
            return new PullProgress(status, completed, total);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string Trim(string text) => text.Length > 200 ? text[..200] + "…" : text;

    public void Dispose() => _http.Dispose();
}

/// <summary>The AI helper: review, suggest edits, draft steps and name a macro. Every answer is checked by the parsers in the core library.</summary>
public sealed class AiAssistant
{
    private readonly Func<AppSettings> _settings;
    private readonly Func<string, HttpMessageHandler?>? _handlerFactory;

    public AiAssistant(Func<AppSettings> settings, Func<string, HttpMessageHandler?>? handlerFactory = null)
    {
        _settings = settings;
        _handlerFactory = handlerFactory;
    }

    private OllamaClient NewClient()
    {
        var s = _settings();
        return new OllamaClient(s.AiEndpoint, _handlerFactory?.Invoke(s.AiEndpoint));
    }

    public async Task<AiStatus> StatusAsync(CancellationToken cancel = default)
    {
        var s = _settings();
        if (!s.AiEnabled) return new AiStatus(false, Array.Empty<AiModelInfo>(), "The AI helper is turned off in Settings.");
        using var client = NewClient();
        return await client.GetStatusAsync(cancel).ConfigureAwait(false);
    }

    private async Task<string> AskAsync(string system, string user, CancellationToken cancel)
    {
        var settings = _settings();
        if (!settings.AiEnabled) throw new AiException("The AI helper is turned off in Settings.");
        using var client = NewClient();
        var status = await client.GetStatusAsync(cancel).ConfigureAwait(false);
        if (!status.IsRunning) throw new AiException(status.Message);
        var model = OllamaClient.ChooseModel(status.Models, settings.AiModel)
                    ?? throw new AiException(status.Message);
        return await client.ChatAsync(model, system, user, cancel).ConfigureAwait(false);
    }

    public Task<string> ReviewAsync(Recording recording, CancellationToken cancel = default) =>
        AskAsync(AiPrompts.Review, "Review this macro.\n\n" + MacroSummary.Text(recording), cancel);

    public async Task<string> SuggestNameAsync(Recording recording, CancellationToken cancel = default)
    {
        var reply = await AskAsync(AiPrompts.Name, "Name this macro.\n\n" + MacroSummary.Text(recording), cancel).ConfigureAwait(false);
        return AiPrompts.CleanName(reply);
    }

    public async Task<List<MacroEdit>> ProposeEditsAsync(Recording recording, CancellationToken cancel = default)
    {
        var reply = await AskAsync(AiPrompts.Edit, "Suggest improvements for this macro.\n\n" + MacroSummary.NumberedText(recording), cancel).ConfigureAwait(false);
        return AIEditParser.Parse(reply, recording);
    }

    public async Task<MacroDraft> DraftStepsAsync(string request, CancellationToken cancel = default)
    {
        var reply = await AskAsync(AiPrompts.Draft, "Request: " + request, cancel).ConfigureAwait(false);
        return AIMacroDrafter.Parse(reply);
    }
}
