using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ActionRecorder.Core;

/// <summary>All persistent app configuration. Stored as JSON so it is easy to inspect and transfer.
/// Every field has a default and unknown/missing/invalid keys are tolerated, so settings files written
/// by older or newer versions still load.</summary>
public sealed class AppSettings
{
    public int FormatVersion { get; set; } = 1;

    // Recording
    public RecordingOptions Recording { get; set; } = new();
    /// <summary>Seconds to wait after pressing Start Recording so you can switch to the target app.</summary>
    public int RecordingCountdown { get; set; } = 3;
    public bool HideWindowWhileRecording { get; set; } = true;

    // Playback defaults (new recordings start with these)
    public double DefaultSpeed { get; set; } = 1.0;
    /// <summary>0 = loop until stopped.</summary>
    public int DefaultRepeatCount { get; set; } = 1;
    public double DefaultLoopDelay { get; set; }
    public int PlaybackCountdown { get; set; } = 3;
    public double MinActionDelay { get; set; } = 0.02;
    public double TypingCharDelay { get; set; } = 0.012;
    public HotKey EmergencyStop { get; set; } = HotKey.DefaultEmergencyStop;
    public bool VerifyForeground { get; set; }
    public bool ConfirmBeforePlay { get; set; }
    public bool HideWindowDuringPlayback { get; set; } = true;

    // Storage
    /// <summary>null = the default folder inside %APPDATA%.</summary>
    public string? SaveDirectoryPath { get; set; }
    public bool AutoSave { get; set; } = true;
    public string? ExportDirectoryPath { get; set; }
    public bool BackupEnabled { get; set; } = true;
    public int BackupKeepCount { get; set; } = 5;
    public string? BackupDirectoryPath { get; set; }

    // Privacy
    public bool AcknowledgedRecordingWarning { get; set; }

    // Updates
    /// <summary>Look for a newer version on GitHub (a single read-only request, at most every few hours).</summary>
    public bool CheckForUpdates { get; set; } = true;
    /// <summary>Download a newer version in the background. It is only installed when you choose Restart to Update.</summary>
    public bool AutoDownloadUpdates { get; set; } = true;

    // Local AI (Ollama on this PC)
    public bool AiEnabled { get; set; } = true;
    public string AiEndpoint { get; set; } = AiDefaults.Endpoint;
    /// <summary>Empty = use the first model installed in Ollama.</summary>
    public string AiModel { get; set; } = "";

    // Look
    /// <summary>"dark", "light" or "system".</summary>
    public string Theme { get; set; } = "dark";

    // First run
    /// <summary>True once the Welcome screen has been closed with its Enter button.</summary>
    public bool HasCompletedWelcome { get; set; }

    /// <summary>Returns a copy with every value forced into a safe range.</summary>
    public AppSettings Sanitized()
    {
        var s = (AppSettings)MemberwiseClone();
        s.Recording = new RecordingOptions
        {
            IncludeMouseMove = Recording.IncludeMouseMove,
            RecordScroll = Recording.RecordScroll,
            RecordShortcuts = Recording.RecordShortcuts,
            RecordText = Recording.RecordText,
            MinEventInterval = Num.Clamp(Recording.MinEventInterval, 0, 1),
            MinMoveDistance = Num.Clamp(Recording.MinMoveDistance, 0, 100),
        };
        s.RecordingCountdown = Num.Clamp(RecordingCountdown, 0, 60);
        s.DefaultSpeed = PlaybackTiming.ClampSpeed(DefaultSpeed);
        s.DefaultRepeatCount = Num.Clamp(DefaultRepeatCount, 0, 100_000);
        s.DefaultLoopDelay = Num.Clamp(DefaultLoopDelay, 0, 3600);
        s.PlaybackCountdown = Num.Clamp(PlaybackCountdown, 0, 60);
        s.MinActionDelay = Num.Clamp(MinActionDelay, 0, 5);
        s.TypingCharDelay = Num.Clamp(TypingCharDelay, 0, 1);
        s.BackupKeepCount = Num.Clamp(BackupKeepCount, 1, 100);
        if (!EmergencyStop.IsValid)
        {
            s.EmergencyStop = HotKey.DefaultEmergencyStop;
        }
        if (!AiDefaults.IsLocalEndpoint(AiEndpoint))
        {
            s.AiEndpoint = AiDefaults.Endpoint;
        }
        s.AiModel = (AiModel ?? "").Trim();
        if (s.Theme != "dark" && s.Theme != "light" && s.Theme != "system")
        {
            s.Theme = "dark";
        }
        return s;
    }
}

public static class AiDefaults
{
    public const string Endpoint = "http://127.0.0.1:11434";

    /// <summary>The AI helper only talks to a program on this PC. Macro text never leaves the computer.</summary>
    public static bool IsLocalEndpoint(string? text)
    {
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) return false;
        return uri.IsLoopback;
    }
}

/// <summary>Loads and saves <see cref="AppSettings"/> as a JSON file.</summary>
public sealed class SettingsStore
{
    public string FilePath { get; }

    public SettingsStore(string filePath)
    {
        FilePath = filePath;
    }

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>Returns saved settings, or defaults when the file is missing or unreadable.</summary>
    public AppSettings Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return new AppSettings();
            var info = new FileInfo(FilePath);
            if (info.Length > 1_000_000) return new AppSettings();
            var node = JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject;
            return node == null ? new AppSettings() : FromJson(node).Sanitized();
        }
        catch (Exception)
        {
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        var json = ToJson(settings.Sanitized());
        var directory = Path.GetDirectoryName(FilePath);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        AtomicFile.WriteAllBytes(FilePath, System.Text.Encoding.UTF8.GetBytes(json.ToJsonString(WriteOptions)));
    }

    public static JsonObject ToJson(AppSettings s)
    {
        var o = new JsonObject
        {
            ["formatVersion"] = s.FormatVersion,
            ["recording"] = new JsonObject
            {
                ["includeMouseMove"] = s.Recording.IncludeMouseMove,
                ["recordScroll"] = s.Recording.RecordScroll,
                ["recordShortcuts"] = s.Recording.RecordShortcuts,
                ["recordText"] = s.Recording.RecordText,
                ["minEventInterval"] = s.Recording.MinEventInterval,
                ["minMoveDistance"] = s.Recording.MinMoveDistance,
            },
            ["recordingCountdown"] = s.RecordingCountdown,
            ["hideWindowWhileRecording"] = s.HideWindowWhileRecording,
            ["defaultSpeed"] = s.DefaultSpeed,
            ["defaultRepeatCount"] = s.DefaultRepeatCount,
            ["defaultLoopDelay"] = s.DefaultLoopDelay,
            ["playbackCountdown"] = s.PlaybackCountdown,
            ["minActionDelay"] = s.MinActionDelay,
            ["typingCharDelay"] = s.TypingCharDelay,
            ["emergencyStop"] = new JsonObject
            {
                ["keyCode"] = s.EmergencyStop.KeyCode,
                ["modifiers"] = new JsonArray(s.EmergencyStop.Modifiers.ToNames().Select(n => (JsonNode)JsonValue.Create(n)!).ToArray()),
            },
            ["verifyForeground"] = s.VerifyForeground,
            ["confirmBeforePlay"] = s.ConfirmBeforePlay,
            ["hideWindowDuringPlayback"] = s.HideWindowDuringPlayback,
            ["autoSave"] = s.AutoSave,
            ["backupEnabled"] = s.BackupEnabled,
            ["backupKeepCount"] = s.BackupKeepCount,
            ["acknowledgedRecordingWarning"] = s.AcknowledgedRecordingWarning,
            ["checkForUpdates"] = s.CheckForUpdates,
            ["autoDownloadUpdates"] = s.AutoDownloadUpdates,
            ["aiEnabled"] = s.AiEnabled,
            ["aiEndpoint"] = s.AiEndpoint,
            ["aiModel"] = s.AiModel,
            ["theme"] = s.Theme,
            ["hasCompletedWelcome"] = s.HasCompletedWelcome,
        };
        if (s.SaveDirectoryPath != null) o["saveDirectoryPath"] = s.SaveDirectoryPath;
        if (s.ExportDirectoryPath != null) o["exportDirectoryPath"] = s.ExportDirectoryPath;
        if (s.BackupDirectoryPath != null) o["backupDirectoryPath"] = s.BackupDirectoryPath;
        return o;
    }

    public static AppSettings FromJson(JsonObject o)
    {
        var s = new AppSettings();
        s.FormatVersion = Get(o, "formatVersion", s.FormatVersion);

        if (o["recording"] is JsonObject r)
        {
            s.Recording.IncludeMouseMove = Get(r, "includeMouseMove", s.Recording.IncludeMouseMove);
            s.Recording.RecordScroll = Get(r, "recordScroll", s.Recording.RecordScroll);
            s.Recording.RecordShortcuts = Get(r, "recordShortcuts", s.Recording.RecordShortcuts);
            s.Recording.RecordText = Get(r, "recordText", s.Recording.RecordText);
            s.Recording.MinEventInterval = Get(r, "minEventInterval", s.Recording.MinEventInterval);
            s.Recording.MinMoveDistance = Get(r, "minMoveDistance", s.Recording.MinMoveDistance);
        }
        s.RecordingCountdown = Get(o, "recordingCountdown", s.RecordingCountdown);
        s.HideWindowWhileRecording = Get(o, "hideWindowWhileRecording", s.HideWindowWhileRecording);
        s.DefaultSpeed = Get(o, "defaultSpeed", s.DefaultSpeed);
        s.DefaultRepeatCount = Get(o, "defaultRepeatCount", s.DefaultRepeatCount);
        s.DefaultLoopDelay = Get(o, "defaultLoopDelay", s.DefaultLoopDelay);
        s.PlaybackCountdown = Get(o, "playbackCountdown", s.PlaybackCountdown);
        s.MinActionDelay = Get(o, "minActionDelay", s.MinActionDelay);
        s.TypingCharDelay = Get(o, "typingCharDelay", s.TypingCharDelay);
        if (o["emergencyStop"] is JsonObject e)
        {
            var code = Get(e, "keyCode", -1);
            var names = new List<string>();
            if (e["modifiers"] is JsonArray array)
            {
                foreach (var item in array)
                {
                    if (item is JsonValue v && v.TryGetValue<string>(out var name)) names.Add(name);
                }
            }
            var modifiers = KeyModifiersExt.FromNames(names);
            if (modifiers != null) s.EmergencyStop = new HotKey(code, modifiers.Value);
        }
        s.VerifyForeground = Get(o, "verifyForeground", s.VerifyForeground);
        s.ConfirmBeforePlay = Get(o, "confirmBeforePlay", s.ConfirmBeforePlay);
        s.HideWindowDuringPlayback = Get(o, "hideWindowDuringPlayback", s.HideWindowDuringPlayback);
        s.SaveDirectoryPath = Get<string?>(o, "saveDirectoryPath", null);
        s.AutoSave = Get(o, "autoSave", s.AutoSave);
        s.ExportDirectoryPath = Get<string?>(o, "exportDirectoryPath", null);
        s.BackupEnabled = Get(o, "backupEnabled", s.BackupEnabled);
        s.BackupKeepCount = Get(o, "backupKeepCount", s.BackupKeepCount);
        s.BackupDirectoryPath = Get<string?>(o, "backupDirectoryPath", null);
        s.AcknowledgedRecordingWarning = Get(o, "acknowledgedRecordingWarning", s.AcknowledgedRecordingWarning);
        s.CheckForUpdates = Get(o, "checkForUpdates", s.CheckForUpdates);
        s.AutoDownloadUpdates = Get(o, "autoDownloadUpdates", s.AutoDownloadUpdates);
        s.AiEnabled = Get(o, "aiEnabled", s.AiEnabled);
        s.AiEndpoint = Get(o, "aiEndpoint", s.AiEndpoint);
        s.AiModel = Get(o, "aiModel", s.AiModel);
        s.Theme = Get(o, "theme", s.Theme);
        s.HasCompletedWelcome = Get(o, "hasCompletedWelcome", s.HasCompletedWelcome);
        return s;
    }

    /// <summary>Reads a value, returning the fallback when the key is missing or has the wrong type.</summary>
    private static T Get<T>(JsonObject o, string key, T fallback)
    {
        try
        {
            if (o[key] is JsonValue value && value.TryGetValue<T>(out var result) && result != null)
            {
                return result;
            }
            // JSON numbers may arrive as double where an int is wanted (and vice versa).
            if (o[key] is JsonValue number && typeof(T) == typeof(int) && number.TryGetValue<double>(out var d)
                && d == Math.Floor(d) && Math.Abs(d) < int.MaxValue)
            {
                return (T)(object)(int)d;
            }
        }
        catch (Exception)
        {
            // fall through to the fallback
        }
        return fallback;
    }
}

/// <summary>Writes a file so that a crash or power loss mid-write cannot leave a half-written file.</summary>
public static class AtomicFile
{
    public static void WriteAllBytes(string path, byte[] data)
    {
        var temp = path + "." + Guid.NewGuid().ToString("N")[..8] + ".tmp";
        try
        {
            File.WriteAllBytes(temp, data);
            if (File.Exists(path))
            {
                File.Replace(temp, path, null);
            }
            else
            {
                File.Move(temp, path);
            }
        }
        finally
        {
            if (File.Exists(temp))
            {
                try { File.Delete(temp); } catch (IOException) { }
            }
        }
    }
}
