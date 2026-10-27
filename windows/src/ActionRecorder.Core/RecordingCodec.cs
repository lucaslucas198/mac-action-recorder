using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace ActionRecorder.Core;

public enum RecordingErrorKind
{
    NotFound,
    TooLarge,
    InvalidJson,
    MissingVersion,
    UnsupportedVersion,
    NewerVersion,
    Invalid,
    Io,
}

public sealed class RecordingException : Exception
{
    public RecordingErrorKind Kind { get; }

    public RecordingException(RecordingErrorKind kind, string message) : base(message)
    {
        Kind = kind;
    }

    public static RecordingException NotFound(string name) => new(RecordingErrorKind.NotFound, $"Recording not found: {name}");

    public static RecordingException TooLarge(long bytes) =>
        new(RecordingErrorKind.TooLarge, $"The file is too large to be a recording ({bytes} bytes).");

    public static RecordingException InvalidJson(string detail) =>
        new(RecordingErrorKind.InvalidJson, $"The file is not a valid recording: {detail}");

    public static RecordingException MissingVersion() =>
        new(RecordingErrorKind.MissingVersion, "The file has no formatVersion, so it is not a recording.");

    public static RecordingException UnsupportedVersion(long version) =>
        new(RecordingErrorKind.UnsupportedVersion, $"Unsupported recording format version {version}.");

    public static RecordingException NewerVersion(long version) =>
        new(RecordingErrorKind.NewerVersion,
            $"This recording uses format version {version}, which is newer than this app supports ({RecordingFormat.CurrentVersion}). Update Action Recorder.");

    public static RecordingException Invalid(IEnumerable<string> messages) =>
        new(RecordingErrorKind.Invalid, "The recording failed validation. " + string.Join(" ", messages.Take(3)));

    public static RecordingException Io(string detail) => new(RecordingErrorKind.Io, $"File error: {detail}");
}

/// <summary>Reads and writes the versioned JSON recording format (shared with the Mac app).</summary>
public static class RecordingCodec
{
    /// <summary>Files larger than this are rejected before parsing (50 MB).</summary>
    public const int DefaultMaxFileSize = 50 * 1024 * 1024;

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    // ---------------------------------------------------------------- encode

    public static byte[] Encode(Recording recording)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream, WriterOptions))
        {
            w.WriteStartObject();
            w.WritePropertyName("actions");
            w.WriteStartArray();
            foreach (var action in recording.Actions)
            {
                WriteAction(w, action);
            }
            w.WriteEndArray();
            w.WriteString("createdAt", FormatDate(recording.CreatedAt));
            w.WriteNumber("formatVersion", recording.FormatVersion);
            w.WriteString("id", FormatGuid(recording.Id));
            w.WriteString("modifiedAt", FormatDate(recording.ModifiedAt));
            w.WriteString("name", recording.Name);
            if (recording.Notes != null) w.WriteString("notes", recording.Notes);
            if (recording.Platform != null) w.WriteString("platform", recording.Platform);
            if (recording.PlaybackDefaults is { } defaults)
            {
                w.WritePropertyName("playbackDefaults");
                w.WriteStartObject();
                w.WriteNumber("loopDelay", defaults.LoopDelay);
                w.WriteNumber("repeatCount", defaults.RepeatCount);
                w.WriteNumber("speed", defaults.Speed);
                w.WriteEndObject();
            }
            if (recording.RecordedScreen is { } screen)
            {
                w.WritePropertyName("recordedScreen");
                w.WriteStartObject();
                w.WriteNumber("height", screen.Height);
                w.WriteNumber("width", screen.Width);
                w.WriteEndObject();
            }
            if (recording.TargetApp is { } app)
            {
                w.WritePropertyName("targetApp");
                w.WriteStartObject();
                w.WriteString("bundleID", app.BundleId);
                w.WriteString("name", app.Name);
                w.WriteEndObject();
            }
            w.WriteEndObject();
        }
        return stream.ToArray();
    }

    private static void WriteAction(Utf8JsonWriter w, MacroAction a)
    {
        w.WriteStartObject();
        if (a.Button is { } button) w.WriteString("button", button.ToJson());
        if (a.ClickCount is int count) w.WriteNumber("clickCount", count);
        w.WriteNumber("delay", a.Delay);
        if (a.Duration is double duration) w.WriteNumber("duration", duration);
        w.WriteString("id", FormatGuid(a.Id));
        if (a.KeyCode is int keyCode) w.WriteNumber("keyCode", keyCode);
        w.WriteString("kind", a.Kind.ToJson());
        if (a.Modifiers is { } modifiers)
        {
            w.WritePropertyName("modifiers");
            w.WriteStartArray();
            foreach (var name in modifiers.ToNames()) w.WriteStringValue(name);
            w.WriteEndArray();
        }
        if (a.ScrollX is int sx) w.WriteNumber("scrollX", sx);
        if (a.ScrollY is int sy) w.WriteNumber("scrollY", sy);
        if (a.Text != null) w.WriteString("text", a.Text);
        if (a.X is double x) w.WriteNumber("x", x);
        if (a.Y is double y) w.WriteNumber("y", y);
        w.WriteEndObject();
    }

    private static string FormatGuid(Guid id) => id.ToString("D").ToUpperInvariant();

    private static string FormatDate(DateTime date)
    {
        var utc = date.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(date, DateTimeKind.Utc) : date.ToUniversalTime();
        return utc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    }

    // ---------------------------------------------------------------- decode

    /// <summary>Decodes, migrates and validates a recording. Never throws anything but RecordingException.</summary>
    public static Recording Decode(byte[] data, int maxBytes = DefaultMaxFileSize)
    {
        if (data.Length > maxBytes)
        {
            throw RecordingException.TooLarge(data.Length);
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data, new JsonDocumentOptions { MaxDepth = 32, AllowTrailingCommas = false });
        }
        catch (JsonException ex)
        {
            throw RecordingException.InvalidJson(ex.Message);
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw RecordingException.InvalidJson("expected a JSON object");
            }

            if (!root.TryGetProperty("formatVersion", out var versionElement) || versionElement.ValueKind == JsonValueKind.Null)
            {
                throw RecordingException.MissingVersion();
            }
            if (versionElement.ValueKind != JsonValueKind.Number || !versionElement.TryGetInt64(out var version))
            {
                throw RecordingException.InvalidJson("formatVersion: expected an integer");
            }
            if (version < 1)
            {
                throw RecordingException.UnsupportedVersion(version);
            }
            if (version > RecordingFormat.CurrentVersion)
            {
                throw RecordingException.NewerVersion(version);
            }

            Recording recording;
            try
            {
                recording = ReadRecording(root, (int)version);
            }
            catch (JsonException ex)
            {
                throw RecordingException.InvalidJson(ex.Message);
            }

            recording = Migrate(recording, (int)version);

            var errors = RecordingValidator.Errors(RecordingValidator.Validate(recording));
            if (errors.Count > 0)
            {
                throw RecordingException.Invalid(errors.Select(e => e.ToString()));
            }
            return recording;
        }
    }

    /// <summary>Upgrades older versions to the current model. Version 1 is current, so this is the
    /// hook where future versions add their steps (v1 to v2, v2 to v3, ...).</summary>
    public static Recording Migrate(Recording recording, int fromVersion)
    {
        recording.FormatVersion = RecordingFormat.CurrentVersion;
        return recording;
    }

    private static Recording ReadRecording(JsonElement root, int version)
    {
        var recording = new Recording
        {
            FormatVersion = version,
            Id = ReadGuid(root, "id", "id") ?? Guid.NewGuid(),
            Name = ReadString(root, "name", "name") ?? throw new JsonException("missing field 'name'"),
            CreatedAt = ReadDate(root, "createdAt") ?? throw new JsonException("missing field 'createdAt'"),
            Platform = null,
        };
        recording.ModifiedAt = ReadDate(root, "modifiedAt") ?? recording.CreatedAt;
        recording.Notes = ReadString(root, "notes", "notes");
        recording.Platform = ReadString(root, "platform", "platform");

        if (TryObject(root, "targetApp", out var app))
        {
            var bundle = ReadString(app, "bundleID", "targetApp.bundleID") ?? throw new JsonException("missing field 'targetApp.bundleID'");
            var name = ReadString(app, "name", "targetApp.name") ?? throw new JsonException("missing field 'targetApp.name'");
            recording.TargetApp = new TargetApp(bundle, name);
        }
        if (TryObject(root, "recordedScreen", out var screen))
        {
            var width = ReadNumber(screen, "width", "recordedScreen.width") ?? throw new JsonException("missing field 'recordedScreen.width'");
            var height = ReadNumber(screen, "height", "recordedScreen.height") ?? throw new JsonException("missing field 'recordedScreen.height'");
            recording.RecordedScreen = new ScreenSize(width, height);
        }
        if (TryObject(root, "playbackDefaults", out var defaults))
        {
            recording.PlaybackDefaults = new PlaybackDefaults(
                ReadNumber(defaults, "speed", "playbackDefaults.speed") ?? 1.0,
                (int)Math.Clamp(ReadInt(defaults, "repeatCount", "playbackDefaults.repeatCount") ?? 1, 0, 1_000_000),
                ReadNumber(defaults, "loopDelay", "playbackDefaults.loopDelay") ?? 0);
        }

        if (!root.TryGetProperty("actions", out var actions) || actions.ValueKind != JsonValueKind.Array)
        {
            throw new JsonException("missing field 'actions'");
        }

        foreach (var element in actions.EnumerateArray())
        {
            recording.Actions.Add(ReadAction(element, recording.Actions.Count));
        }
        return recording;
    }

    private static MacroAction ReadAction(JsonElement e, int index)
    {
        var path = $"actions[{index}]";
        if (e.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException($"{path}: expected an object");
        }

        var kindText = ReadString(e, "kind", $"{path}.kind") ?? throw new JsonException($"missing field '{path}.kind'");
        if (!EnumNames.TryParseKind(kindText, out var kind))
        {
            throw new JsonException($"{path}.kind: unknown action kind '{kindText}'");
        }

        var action = new MacroAction
        {
            Id = ReadGuid(e, "id", $"{path}.id") ?? Guid.NewGuid(),
            Kind = kind,
            Delay = ReadNumber(e, "delay", $"{path}.delay") ?? 0,
            X = ReadNumber(e, "x", $"{path}.x"),
            Y = ReadNumber(e, "y", $"{path}.y"),
            ClickCount = ReadInt(e, "clickCount", $"{path}.clickCount") is long cc ? ClampToInt(cc) : null,
            ScrollX = ReadInt(e, "scrollX", $"{path}.scrollX") is long sx ? ClampToInt(sx) : null,
            ScrollY = ReadInt(e, "scrollY", $"{path}.scrollY") is long sy ? ClampToInt(sy) : null,
            KeyCode = ReadInt(e, "keyCode", $"{path}.keyCode") is long kc ? ClampToInt(kc) : null,
            Text = ReadString(e, "text", $"{path}.text"),
            Duration = ReadNumber(e, "duration", $"{path}.duration"),
        };

        var buttonText = ReadString(e, "button", $"{path}.button");
        if (buttonText != null)
        {
            if (!EnumNames.TryParseButton(buttonText, out var button))
            {
                throw new JsonException($"{path}.button: unknown button '{buttonText}'");
            }
            action.Button = button;
        }

        if (e.TryGetProperty("modifiers", out var mods) && mods.ValueKind != JsonValueKind.Null)
        {
            if (mods.ValueKind != JsonValueKind.Array)
            {
                throw new JsonException($"{path}.modifiers: expected an array");
            }
            var names = new List<string>();
            foreach (var item in mods.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                {
                    throw new JsonException($"{path}.modifiers: expected strings");
                }
                names.Add(item.GetString()!);
            }
            action.Modifiers = KeyModifiersExt.FromNames(names)
                ?? throw new JsonException($"{path}.modifiers: unknown modifier name");
        }
        return action;
    }

    private static int ClampToInt(long value) => (int)Math.Clamp(value, int.MinValue, int.MaxValue);

    private static bool TryObject(JsonElement parent, string name, out JsonElement element)
    {
        if (parent.TryGetProperty(name, out element) && element.ValueKind != JsonValueKind.Null)
        {
            if (element.ValueKind != JsonValueKind.Object)
            {
                throw new JsonException($"{name}: expected an object");
            }
            return true;
        }
        return false;
    }

    private static string? ReadString(JsonElement parent, string name, string path)
    {
        if (!parent.TryGetProperty(name, out var element) || element.ValueKind == JsonValueKind.Null) return null;
        if (element.ValueKind != JsonValueKind.String) throw new JsonException($"{path}: expected a string");
        return element.GetString();
    }

    private static double? ReadNumber(JsonElement parent, string name, string path)
    {
        if (!parent.TryGetProperty(name, out var element) || element.ValueKind == JsonValueKind.Null) return null;
        if (element.ValueKind != JsonValueKind.Number || !element.TryGetDouble(out var value))
        {
            throw new JsonException($"{path}: expected a number");
        }
        return value;
    }

    private static long? ReadInt(JsonElement parent, string name, string path)
    {
        if (!parent.TryGetProperty(name, out var element) || element.ValueKind == JsonValueKind.Null) return null;
        if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt64(out var value))
        {
            throw new JsonException($"{path}: expected an integer");
        }
        return value;
    }

    private static Guid? ReadGuid(JsonElement parent, string name, string path)
    {
        var text = ReadString(parent, name, path);
        if (text == null) return null;
        if (!Guid.TryParse(text, out var guid)) throw new JsonException($"{path}: not a valid UUID");
        return guid;
    }

    private static DateTime? ReadDate(JsonElement parent, string name)
    {
        var text = ReadString(parent, name, name);
        if (text == null) return null;
        if (!DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            throw new JsonException($"{name}: not a valid ISO-8601 date");
        }
        return parsed.UtcDateTime;
    }

    public static string EncodeToString(Recording recording) => Encoding.UTF8.GetString(Encode(recording));
}
