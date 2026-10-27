using System.Text;
using ActionRecorder.Core;

namespace ActionRecorder.Tests;

public static class CodecTests
{
    private static Recording Sample()
    {
        var r = new Recording("Sample macro")
        {
            CreatedAt = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc),
            ModifiedAt = new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc),
            TargetApp = new TargetApp("discord.exe", "Discord"),
            RecordedScreen = new ScreenSize(1920, 1080),
            PlaybackDefaults = new PlaybackDefaults(1.5, 3, 0.5),
            Notes = "notes ünïcode ✓",
        };
        r.Actions.Add(Act.Move(10.5, 20.25));
        r.Actions.Add(Act.Click(100, 200, MouseButton.Right, 2, delay: 0.4));
        r.Actions.Add(Act.Scroll(0, -240, 5, 6));
        r.Actions.Add(Act.Key(KeyCodes.K, KeyModifiers.Control | KeyModifiers.Shift, delay: 0.1));
        r.Actions.Add(Act.Text("héllo 😀 \"quoted\" \n line"));
        r.Actions.Add(Act.Wait(1.25));
        r.Actions.Add(Act.MouseDown(1, 2));
        r.Actions.Add(Act.Drag(3, 4));
        r.Actions.Add(Act.MouseUp(3, 4));
        return r;
    }

    [Test]
    public static void RoundTripKeepsEverything()
    {
        var original = Sample();
        var decoded = RecordingCodec.Decode(RecordingCodec.Encode(original));
        Check.Equal(original.Id, decoded.Id);
        Check.Equal(original.Name, decoded.Name);
        Check.Equal(original.CreatedAt, decoded.CreatedAt);
        Check.Equal(original.ModifiedAt, decoded.ModifiedAt);
        Check.Equal("discord.exe", decoded.TargetApp!.BundleId);
        Check.Equal("Discord", decoded.TargetApp!.Name);
        Check.Equal(1920.0, decoded.RecordedScreen!.Width);
        Check.Equal(1.5, decoded.PlaybackDefaults!.Speed);
        Check.Equal(3, decoded.PlaybackDefaults!.RepeatCount);
        Check.Equal(original.Notes, decoded.Notes);
        Check.Equal("windows", decoded.Platform);
        Check.Equal(original.Actions.Count, decoded.Actions.Count);
        for (var i = 0; i < original.Actions.Count; i++)
        {
            var a = original.Actions[i];
            var b = decoded.Actions[i];
            Check.Equal(a.Id, b.Id, $"id {i}");
            Check.Equal(a.Kind, b.Kind, $"kind {i}");
            Check.Equal(a.Delay, b.Delay, $"delay {i}");
            Check.Equal(a.X, b.X, $"x {i}");
            Check.Equal(a.Y, b.Y, $"y {i}");
            Check.Equal(a.Button, b.Button, $"button {i}");
            Check.Equal(a.ClickCount, b.ClickCount, $"clickCount {i}");
            Check.Equal(a.ScrollX, b.ScrollX, $"scrollX {i}");
            Check.Equal(a.ScrollY, b.ScrollY, $"scrollY {i}");
            Check.Equal(a.KeyCode, b.KeyCode, $"keyCode {i}");
            Check.Equal(a.Modifiers, b.Modifiers, $"modifiers {i}");
            Check.Equal(a.Text, b.Text, $"text {i}");
            Check.Equal(a.Duration, b.Duration, $"duration {i}");
        }
    }

    [Test]
    public static void OutputUsesTheSharedFieldNames()
    {
        var json = RecordingCodec.EncodeToString(Sample());
        foreach (var field in new[] { "\"formatVersion\": 1", "\"actions\"", "\"kind\": \"click\"", "\"clickCount\": 2", "\"button\": \"right\"",
                     "\"modifiers\"", "\"control\"", "\"shift\"", "\"bundleID\"", "\"recordedScreen\"", "\"playbackDefaults\"", "\"scrollY\": -240",
                     "\"createdAt\": \"2026-01-01T00:00:00Z\"" })
        {
            Check.True(json.Contains(field), $"missing {field}");
        }
    }

    [Test]
    public static void ReadsAFileWrittenByTheMacApp()
    {
        // Same shape as Samples/discord-send-message.macro.json (no platform field).
        const string json = """
        {
          "actions": [
            { "delay": 0, "id": "5B0F1E64-2D4C-4B7E-9A10-000000000001", "keyCode": 40, "kind": "key", "modifiers": ["command"] },
            { "delay": 0, "duration": 0.4, "id": "5B0F1E64-2D4C-4B7E-9A10-000000000002", "kind": "wait" },
            { "delay": 0, "id": "5B0F1E64-2D4C-4B7E-9A10-000000000003", "kind": "text", "text": "general" }
          ],
          "createdAt": "2026-01-01T00:00:00Z",
          "formatVersion": 1,
          "id": "5B0F1E64-2D4C-4B7E-9A10-0000000000AA",
          "modifiedAt": "2026-01-01T00:00:00Z",
          "name": "Mac sample",
          "someFutureField": { "ignored": true }
        }
        """;
        var recording = RecordingCodec.Decode(Encoding.UTF8.GetBytes(json));
        Check.Equal(3, recording.Actions.Count);
        Check.True(recording.Platform == null, "mac files have no platform");
        Check.False(recording.IsFromWindows);
        Check.Equal(KeyModifiers.Command, recording.Actions[0].Modifiers!.Value);
    }

    [Test]
    public static void RejectsMalformedInputWithoutCrashing()
    {
        var bad = new[]
        {
            "", "not json", "[]", "null", "{}", "{\"formatVersion\": \"1\"}", "{\"formatVersion\": 1}",
            "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": 5}",
            "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"nope\", \"actions\": []}",
            "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": [{\"kind\": \"explode\"}]}",
            "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": [{\"kind\": \"click\", \"x\": \"a\"}]}",
            "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": [{\"kind\": \"key\", \"keyCode\": 1, \"modifiers\": [\"hyper\"]}]}",
            "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": [{\"kind\": \"key\", \"keyCode\": 1, \"id\": \"zzz\"}]}",
            "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": [{\"kind\": \"click\", \"button\": \"banana\", \"x\": 1, \"y\": 1, \"clickCount\": 1}]}",
        };
        foreach (var text in bad)
        {
            Check.Throws<RecordingException>(() => RecordingCodec.Decode(Encoding.UTF8.GetBytes(text)));
        }
        // Truncated real file
        var good = RecordingCodec.Encode(Sample());
        Check.Throws<RecordingException>(() => RecordingCodec.Decode(good.Take(good.Length / 2).ToArray()));
        // Deep nesting does not overflow the stack
        var deep = new string('[', 5000) + new string(']', 5000);
        Check.Throws<RecordingException>(() => RecordingCodec.Decode(Encoding.UTF8.GetBytes(deep)));
    }

    [Test]
    public static void VersionHandling()
    {
        string With(string version) => "{\"formatVersion\": " + version + ", \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": []}";
        Check.Equal(RecordingErrorKind.MissingVersion, Check.Throws<RecordingException>(() => RecordingCodec.Decode(Encoding.UTF8.GetBytes("{\"name\":\"x\"}"))).Kind);
        Check.Equal(RecordingErrorKind.UnsupportedVersion, Check.Throws<RecordingException>(() => RecordingCodec.Decode(Encoding.UTF8.GetBytes(With("0")))).Kind);
        Check.Equal(RecordingErrorKind.NewerVersion, Check.Throws<RecordingException>(() => RecordingCodec.Decode(Encoding.UTF8.GetBytes(With("2")))).Kind);
        Check.Equal(RecordingErrorKind.InvalidJson, Check.Throws<RecordingException>(() => RecordingCodec.Decode(Encoding.UTF8.GetBytes(With("1.5")))).Kind);
        var ok = RecordingCodec.Decode(Encoding.UTF8.GetBytes(With("1")));
        Check.Equal(RecordingFormat.CurrentVersion, ok.FormatVersion);
    }

    [Test]
    public static void ValidationErrorsBlockLoading()
    {
        string Action(string body) => "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": [" + body + "]}";
        var cases = new[]
        {
            "{\"kind\":\"wait\",\"duration\":-1}",
            "{\"kind\":\"wait\"}",
            "{\"kind\":\"click\",\"x\":1,\"y\":1,\"button\":\"left\",\"clickCount\":9}",
            "{\"kind\":\"click\",\"x\":1,\"y\":1,\"button\":\"left\"}",
            "{\"kind\":\"move\",\"x\":9999999,\"y\":1}",
            "{\"kind\":\"move\",\"y\":1}",
            "{\"kind\":\"key\",\"keyCode\":999}",
            "{\"kind\":\"key\"}",
            "{\"kind\":\"text\",\"text\":\"\"}",
            "{\"kind\":\"text\"}",
            "{\"kind\":\"scroll\"}",
            "{\"kind\":\"move\",\"x\":1,\"y\":1,\"delay\":999999}",
            "{\"kind\":\"move\",\"x\":1,\"y\":1,\"delay\":-2}",
        };
        foreach (var body in cases)
        {
            var ex = Check.Throws<RecordingException>(() => RecordingCodec.Decode(Encoding.UTF8.GetBytes(Action(body))));
            Check.Equal(RecordingErrorKind.Invalid, ex.Kind, body);
        }
    }

    [Test]
    public static void OversizedFilesAreRejectedBeforeParsing()
    {
        var ex = Check.Throws<RecordingException>(() => RecordingCodec.Decode(new byte[2048], maxBytes: 1024));
        Check.Equal(RecordingErrorKind.TooLarge, ex.Kind);
    }

    [Test]
    public static void SampleFileFromTheRepositoryLoads()
    {
        var path = FindUp("windows/samples/discord-send-message.macro.json");
        if (path == null) throw new AssertionFailed("sample file not found");
        var recording = RecordingCodec.Decode(File.ReadAllBytes(path));
        Check.True(recording.IsFromWindows);
        Check.True(recording.Actions.Count >= 5);
        Check.Equal(0, RecordingValidator.Errors(RecordingValidator.Validate(recording)).Count);
    }

    public static string? FindUp(string relative)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            var candidate = Path.Combine(dir.FullName, relative);
            if (File.Exists(candidate)) return candidate;
            candidate = Path.Combine(dir.FullName, relative.Replace("windows/", ""));
            if (File.Exists(candidate)) return candidate;
            dir = dir.Parent;
        }
        return null;
    }
}
