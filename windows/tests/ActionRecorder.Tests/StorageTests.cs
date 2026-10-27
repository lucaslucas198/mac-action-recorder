using System.Text;
using System.Text.Json.Nodes;
using ActionRecorder.Core;

namespace ActionRecorder.Tests;

public static class StorageTests
{
    private static string TempDir()
    {
        var path = Path.Combine(Path.GetTempPath(), "ar-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static Recording Make(string name, params MacroAction[] actions)
    {
        var r = new Recording(name);
        r.Actions.AddRange(actions);
        return r;
    }

    [Test]
    public static void SaveLoadDeleteRoundTrip()
    {
        var store = new RecordingStore(TempDir());
        var r = Make("one", Act.Click(1, 2), Act.Text("hi"));
        store.Save(r);
        Check.True(store.Exists(r.Id));
        Check.True(store.FilePathFor(r.Id).EndsWith(".macro.json"));
        var loaded = store.Load(r.Id);
        Check.Equal("one", loaded.Name);
        Check.Equal(2, loaded.Actions.Count);
        store.Delete(r.Id);
        Check.False(store.Exists(r.Id));
        Check.Equal(RecordingErrorKind.NotFound, Check.Throws<RecordingException>(() => store.Delete(r.Id)).Kind);
    }

    [Test]
    public static void SavingTwiceReplacesTheFile()
    {
        var dir = TempDir();
        var store = new RecordingStore(dir);
        var r = Make("v1", Act.Click(1, 1));
        store.Save(r);
        r.Name = "v2";
        r.Actions.Add(Act.Text("more"));
        store.Save(r);
        Check.Equal("v2", store.Load(r.Id).Name);
        Check.Equal(2, store.Load(r.Id).Actions.Count);
        Check.Equal(1, Directory.GetFiles(dir).Length);
    }

    [Test]
    public static void LoadAllSkipsBrokenFilesAndReportsThem()
    {
        var dir = TempDir();
        var store = new RecordingStore(dir);
        var older = Make("older", Act.Click(1, 1));
        older.CreatedAt = new DateTime(2020, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var newer = Make("newer", Act.Click(1, 1));
        newer.CreatedAt = new DateTime(2025, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        store.Save(older);
        store.Save(newer);
        File.WriteAllText(Path.Combine(dir, "broken.macro.json"), "{ nope");
        File.WriteAllText(Path.Combine(dir, "notes.txt"), "ignore me");
        var (recordings, failures) = store.LoadAll();
        Check.SequenceEqual(new[] { "newer", "older" }, recordings.Select(r => r.Name));
        Check.Equal(1, failures.Count);
        Check.True(failures[0].Path.EndsWith("broken.macro.json"));
    }

    [Test]
    public static void DuplicateGetsNewIdsAndName()
    {
        var store = new RecordingStore(TempDir());
        var r = Make("orig", Act.Click(1, 1), Act.Text("x"));
        store.Save(r);
        var copy = store.Duplicate(r);
        Check.True(copy.Id != r.Id);
        Check.Equal("orig copy", copy.Name);
        Check.True(copy.Actions.Select(a => a.Id).Intersect(r.Actions.Select(a => a.Id)).Count() == 0);
        Check.Equal(2, store.LoadAll().Recordings.Count);
    }

    [Test]
    public static void ExportAndImportBetweenStores()
    {
        var storeA = new RecordingStore(TempDir());
        var storeB = new RecordingStore(TempDir());
        var r = Make("travel", Act.Click(10, 20), Act.Text("héllo"));
        storeA.Save(r);
        var exportPath = Path.Combine(TempDir(), "travel.macro.json");
        storeA.Export(r, exportPath);
        var imported = storeB.ImportFile(exportPath);
        Check.Equal(r.Id, imported.Id);
        Check.Equal("héllo", storeB.Load(imported.Id).Actions[1].Text);
        // Importing the same file again must not overwrite: it gets a new id.
        var again = storeB.ImportFile(exportPath);
        Check.True(again.Id != r.Id);
        Check.Equal(2, storeB.LoadAll().Recordings.Count);
    }

    [Test]
    public static void ImportRejectsInvalidFilesWithoutSavingAnything()
    {
        var store = new RecordingStore(TempDir());
        var path = Path.Combine(TempDir(), "bad.macro.json");
        File.WriteAllText(path, "{\"formatVersion\": 1, \"name\": \"x\", \"createdAt\": \"2026-01-01T00:00:00Z\", \"actions\": [{\"kind\":\"wait\"}]}");
        Check.Throws<RecordingException>(() => store.ImportFile(path));
        Check.Equal(0, store.LoadAll().Recordings.Count);
        Check.Equal(RecordingErrorKind.Io, Check.Throws<RecordingException>(() => store.ImportFile(Path.Combine(TempDir(), "missing.json"))).Kind);
    }

    [Test]
    public static void BackupsAreCreatedAndPruned()
    {
        var store = new RecordingStore(TempDir());
        store.Save(Make("a", Act.Click(1, 1)));
        store.Save(Make("b", Act.Click(1, 1)));
        var root = TempDir();
        var start = new DateTime(2026, 1, 1, 10, 0, 0);
        for (var i = 0; i < 5; i++)
        {
            var folder = store.CreateBackup(root, keep: 3, now: start.AddMinutes(i));
            Check.Equal(2, Directory.GetFiles(folder).Length);
        }
        Check.Equal(3, Directory.GetDirectories(root).Length);
        Check.True(Directory.GetDirectories(root).Any(d => d.EndsWith("backup-20260101-100400-000")), "newest kept");
        Check.False(Directory.GetDirectories(root).Any(d => d.EndsWith("backup-20260101-100000-000")), "oldest pruned");
    }

    // ----------------------------------------------------------------- settings

    [Test]
    public static void SettingsRoundTrip()
    {
        var path = Path.Combine(TempDir(), "settings.json");
        var store = new SettingsStore(path);
        var s = new AppSettings
        {
            DefaultSpeed = 2.5,
            DefaultRepeatCount = 7,
            DefaultLoopDelay = 1.5,
            PlaybackCountdown = 9,
            VerifyForeground = true,
            ConfirmBeforePlay = true,
            EmergencyStop = new HotKey(KeyCodes.F1 + 4, KeyModifiers.Control | KeyModifiers.Shift),
            SaveDirectoryPath = @"C:\Macros",
            AiModel = "llama3.2",
            Theme = "light",
            HasCompletedWelcome = true,
            CheckForUpdates = false,
        };
        s.Recording.IncludeMouseMove = false;
        s.Recording.MinMoveDistance = 8;
        store.Save(s);
        var loaded = store.Load();
        Check.Equal(2.5, loaded.DefaultSpeed);
        Check.Equal(7, loaded.DefaultRepeatCount);
        Check.Equal(1.5, loaded.DefaultLoopDelay);
        Check.Equal(9, loaded.PlaybackCountdown);
        Check.True(loaded.VerifyForeground);
        Check.True(loaded.ConfirmBeforePlay);
        Check.Equal(KeyCodes.F1 + 4, loaded.EmergencyStop.KeyCode);
        Check.Equal(KeyModifiers.Control | KeyModifiers.Shift, loaded.EmergencyStop.Modifiers);
        Check.Equal(@"C:\Macros", loaded.SaveDirectoryPath);
        Check.Equal("llama3.2", loaded.AiModel);
        Check.Equal("light", loaded.Theme);
        Check.True(loaded.HasCompletedWelcome);
        Check.False(loaded.CheckForUpdates);
        Check.False(loaded.Recording.IncludeMouseMove);
        Check.Equal(8.0, loaded.Recording.MinMoveDistance);
    }

    [Test]
    public static void MissingOrBrokenSettingsFallBackToDefaults()
    {
        var dir = TempDir();
        Check.Equal(1.0, new SettingsStore(Path.Combine(dir, "none.json")).Load().DefaultSpeed);
        var broken = Path.Combine(dir, "broken.json");
        File.WriteAllText(broken, "{{{{");
        Check.Equal(1.0, new SettingsStore(broken).Load().DefaultSpeed);
        var array = Path.Combine(dir, "array.json");
        File.WriteAllText(array, "[1,2,3]");
        Check.Equal(1.0, new SettingsStore(array).Load().DefaultSpeed);
    }

    [Test]
    public static void SettingsToleratesWrongTypesAndUnknownKeys()
    {
        var path = Path.Combine(TempDir(), "s.json");
        File.WriteAllText(path, """
        { "defaultSpeed": "fast", "defaultRepeatCount": 4.0, "autoSave": "yes", "theme": 7, "futureThing": [1,2],
          "recording": { "includeMouseMove": false, "minMoveDistance": "x" },
          "emergencyStop": { "keyCode": 83, "modifiers": ["bogus"] } }
        """);
        var s = new SettingsStore(path).Load();
        Check.Equal(1.0, s.DefaultSpeed);
        Check.Equal(4, s.DefaultRepeatCount);
        Check.True(s.AutoSave);
        Check.Equal("dark", s.Theme);
        Check.False(s.Recording.IncludeMouseMove);
        Check.Equal(3.0, s.Recording.MinMoveDistance);
        Check.True(s.EmergencyStop.Matches(HotKey.DefaultEmergencyStop.KeyCode, HotKey.DefaultEmergencyStop.Modifiers));
    }

    [Test]
    public static void SettingsAreSanitized()
    {
        var path = Path.Combine(TempDir(), "s.json");
        File.WriteAllText(path, """
        { "defaultSpeed": 9999, "defaultRepeatCount": -5, "defaultLoopDelay": 99999, "playbackCountdown": 500,
          "recordingCountdown": -1, "backupKeepCount": 0, "minActionDelay": 100, "typingCharDelay": -1,
          "theme": "neon", "aiEndpoint": "http://evil.example.com:11434",
          "emergencyStop": { "keyCode": 83, "modifiers": [] } }
        """);
        var s = new SettingsStore(path).Load();
        Check.Equal(PlaybackTiming.MaxSpeed, s.DefaultSpeed);
        Check.Equal(0, s.DefaultRepeatCount);
        Check.Equal(3600.0, s.DefaultLoopDelay);
        Check.Equal(60, s.PlaybackCountdown);
        Check.Equal(0, s.RecordingCountdown);
        Check.Equal(1, s.BackupKeepCount);
        Check.Equal(5.0, s.MinActionDelay);
        Check.Equal(0.0, s.TypingCharDelay);
        Check.Equal("dark", s.Theme);
        Check.Equal(AiDefaults.Endpoint, s.AiEndpoint);
        Check.Equal(HotKey.DefaultEmergencyStop, s.EmergencyStop);
    }

    [Test]
    public static void AiEndpointMustBeLocal()
    {
        Check.True(AiDefaults.IsLocalEndpoint("http://127.0.0.1:11434"));
        Check.True(AiDefaults.IsLocalEndpoint("http://localhost:11434"));
        Check.True(AiDefaults.IsLocalEndpoint("http://[::1]:11434"));
        Check.False(AiDefaults.IsLocalEndpoint("http://192.168.1.20:11434"));
        Check.False(AiDefaults.IsLocalEndpoint("https://api.example.com"));
        Check.False(AiDefaults.IsLocalEndpoint("ftp://localhost"));
        Check.False(AiDefaults.IsLocalEndpoint("not a url"));
        Check.False(AiDefaults.IsLocalEndpoint(null));
    }

    [Test]
    public static void EmergencyStopMustBeUsable()
    {
        Check.True(HotKey.DefaultEmergencyStop.IsValid);
        Check.False(new HotKey(KeyCodes.S, KeyModifiers.None).IsValid);
        Check.False(new HotKey(KeyCodes.S, KeyModifiers.Shift).IsValid);
        Check.False(new HotKey(KeyCodes.Control, KeyModifiers.Control).IsValid);
        Check.False(new HotKey(0, KeyModifiers.Control).IsValid);
        Check.True(new HotKey(KeyCodes.Pause, KeyModifiers.Control).IsValid);
        Check.Equal("Ctrl+Alt+Shift+S", HotKey.DefaultEmergencyStop.DisplayString);
    }

    // ----------------------------------------------------------------- versions & updates

    [Test]
    public static void VersionParsing()
    {
        Check.Equal("1.2.3", AppVersion.Parse("v1.2.3")!.ToString());
        Check.Equal("0.4.0", AppVersion.Parse(" 0.4.0\n")!.ToString());
        Check.Equal("1.2.3", AppVersion.Parse("1.2.3-beta")!.ToString());
        Check.True(AppVersion.Parse("404: Not Found") == null);
        Check.True(AppVersion.Parse("<html>") == null);
        Check.True(AppVersion.Parse("") == null);
        Check.True(AppVersion.Parse(null) == null);
        Check.True(AppVersion.Parse("1.2.3.4.5") == null);
        Check.True(AppVersion.Parse("1..2") == null);
        Check.True(AppVersion.Parse("1.2") == AppVersion.Parse("1.2.0") || AppVersion.Parse("1.2")!.Equals(AppVersion.Parse("1.2.0")));
    }

    [Test]
    public static void VersionOrdering()
    {
        Check.True(UpdateCheck.IsNewer("0.4.1", "0.4.0"));
        Check.True(UpdateCheck.IsNewer("v1.0", "0.9.9"));
        Check.True(UpdateCheck.IsNewer("0.10.0", "0.9.0"));
        Check.False(UpdateCheck.IsNewer("0.4.0", "0.4.0"));
        Check.False(UpdateCheck.IsNewer("0.3.9", "0.4.0"));
        Check.False(UpdateCheck.IsNewer("garbage", "0.4.0"));
        Check.False(UpdateCheck.IsNewer("0.5.0", "garbage"));
    }

    private static byte[] Release(string tag, string assetName, string url, bool draft = false, bool prerelease = false)
    {
        var obj = new JsonObject
        {
            ["tag_name"] = tag,
            ["draft"] = draft,
            ["prerelease"] = prerelease,
            ["assets"] = new JsonArray(new JsonObject { ["name"] = assetName, ["browser_download_url"] = url }),
        };
        return Encoding.UTF8.GetBytes(obj.ToJsonString());
    }

    [Test]
    public static void ReleaseParsingAcceptsOnlyTheRealInstaller()
    {
        var good = UpdateConfig.ReleaseDownloadPrefix + "v0.5.0/" + UpdateConfig.InstallerAssetName;
        var info = ReleaseInfo.Parse(Release("v0.5.0", UpdateConfig.InstallerAssetName, good));
        Check.Equal("0.5.0", info!.Version.ToString());
        Check.Equal(good, info.InstallerUrl.ToString());

        Check.True(ReleaseInfo.Parse(Release("v0.5.0", "other.zip", good)) == null);
        Check.True(ReleaseInfo.Parse(Release("v0.5.0", UpdateConfig.InstallerAssetName, "https://evil.example.com/x.exe")) == null);
        Check.True(ReleaseInfo.Parse(Release("v0.5.0", UpdateConfig.InstallerAssetName, "https://github.com/someone-else/repo/releases/download/v1/x.exe")) == null);
        Check.True(ReleaseInfo.Parse(Release("nonsense", UpdateConfig.InstallerAssetName, good)) == null);
        Check.True(ReleaseInfo.Parse(Release("v0.5.0", UpdateConfig.InstallerAssetName, good, draft: true)) == null);
        Check.True(ReleaseInfo.Parse(Release("v0.5.0", UpdateConfig.InstallerAssetName, good, prerelease: true)) == null);
        Check.True(ReleaseInfo.Parse(Encoding.UTF8.GetBytes("{\"message\":\"Not Found\"}")) == null);
        Check.True(ReleaseInfo.Parse(Encoding.UTF8.GetBytes("<html>")) == null);
        Check.True(ReleaseInfo.Parse(new byte[3_000_000]) == null);
    }

    [Test]
    public static void ChecksumLookup()
    {
        var hash = new string('a', 64);
        var other = new string('b', 64);
        var text = $"{other}  ActionRecorder-Windows.zip\n{hash}  ActionRecorder-Windows-Setup.exe\n";
        Check.Equal(hash, UpdateCheck.FindChecksum(text, "ActionRecorder-Windows-Setup.exe"));
        Check.True(UpdateCheck.FindChecksum(text, "missing.exe") == null);
        Check.True(UpdateCheck.FindChecksum("not a checksum file", "x") == null);
        Check.Equal(hash, UpdateCheck.FindChecksum($"{hash.ToUpperInvariant()} *ActionRecorder-Windows-Setup.exe", "ActionRecorder-Windows-Setup.exe"));
    }

    [Test]
    public static void SetupStagesIncreaseAndNeverFillTheBar()
    {
        var previous = 0.0;
        foreach (var stage in Enum.GetValues<SetupStage>())
        {
            Check.True(stage.Fraction() > previous);
            Check.True(stage.Fraction() < 1.0);
            previous = stage.Fraction();
            Check.True(stage.Title().Length > 0);
        }
        Check.Equal("Step 1 of 4", SetupStage.System.StepText());
    }

    // ----------------------------------------------------------------- mac conversion

    [Test]
    public static void MacRecordingsAreConverted()
    {
        var r = new Recording("from mac") { Platform = null, TargetApp = new TargetApp("com.hnc.Discord", "Discord"), RecordedScreen = new ScreenSize(1440, 900) };
        r.Actions.Add(Act.Key(40, KeyModifiers.Command));              // Cmd+K
        r.Actions.Add(Act.Key(36));                                     // Return
        r.Actions.Add(Act.Key(123, KeyModifiers.Option | KeyModifiers.Shift)); // Left
        r.Actions.Add(Act.Key(999));                                    // unknown
        r.Actions.Add(Act.Click(10, 10));
        var result = MacConversion.FromMac(r);
        Check.Equal(3, result.Converted);
        Check.Equal(4, result.Recording.Actions.Count);
        Check.Equal(KeyCodes.K, result.Recording.Actions[0].KeyCode!.Value);
        Check.Equal(KeyModifiers.Control, result.Recording.Actions[0].Modifiers!.Value);
        Check.Equal(KeyCodes.Return, result.Recording.Actions[1].KeyCode!.Value);
        Check.Equal(KeyCodes.Left, result.Recording.Actions[2].KeyCode!.Value);
        Check.Equal(KeyModifiers.Option | KeyModifiers.Shift, result.Recording.Actions[2].Modifiers!.Value);
        Check.True(result.Recording.IsFromWindows);
        Check.True(result.Recording.TargetApp == null);
        Check.True(result.Problems.Count >= 3);
        Check.True(r.Actions.Count == 5, "the original is untouched");
        Check.Equal(40, r.Actions[0].KeyCode!.Value);
    }

    [Test]
    public static void ConvertedDelaysSurviveRemovedKeys()
    {
        var r = new Recording("m") { Platform = null };
        r.Actions.Add(Act.Key(999, delay: 2));
        r.Actions.Add(Act.Key(36, delay: 1));
        var result = MacConversion.FromMac(r);
        Check.Equal(1, result.Recording.Actions.Count);
        Check.Equal(3.0, result.Recording.Actions[0].Delay);
    }

    [Test]
    public static void KeyNamesAndModifiers()
    {
        Check.Equal("Ctrl+K", KeyNames.Display(KeyCodes.K, KeyModifiers.Control));
        Check.Equal("Enter", KeyNames.Display(KeyCodes.Return, KeyModifiers.None));
        Check.Equal("Ctrl+Alt+Shift+Win+F5", KeyNames.Display(0x74, KeyModifiers.Control | KeyModifiers.Option | KeyModifiers.Shift | KeyModifiers.Command));
        Check.Equal("Key 250", KeyNames.NameFor(250));
        Check.Equal("A", KeyNames.NameFor(0x41));
        Check.Equal("F12", KeyNames.NameFor(0x7B));
        Check.True(KeyCodes.IsModifierKey(KeyCodes.LShift));
        Check.False(KeyCodes.IsModifierKey(KeyCodes.K));
        Check.True(KeyCodes.IsExtendedKey(KeyCodes.Left));
        Check.False(KeyCodes.IsExtendedKey(KeyCodes.K));
        Check.SequenceEqual(new[] { "control", "shift" }, (KeyModifiers.Shift | KeyModifiers.Control).ToNames());
    }

    [Test]
    public static void ActionDescriptions()
    {
        Check.Equal("Left double-click at (10, 20)", ActionDescriber.Describe(Act.Click(10, 20, MouseButton.Left, 2)));
        Check.Equal("Right click at (1, 2)", ActionDescriber.Describe(Act.Click(1, 2, MouseButton.Right)));
        Check.Equal("Press Ctrl+K", ActionDescriber.Describe(Act.Key(KeyCodes.K, KeyModifiers.Control)));
        Check.Equal("Wait 1.50 s", ActionDescriber.Describe(Act.Wait(1.5)));
        Check.Equal("Wait 12.0 s", ActionDescriber.Describe(Act.Wait(12)));
        Check.Equal("Type “a⏎b”", ActionDescriber.Describe(Act.Text("a\nb")));
        Check.True(ActionDescriber.Describe(Act.Text(new string('x', 100))).EndsWith("…”"));
        Check.Equal("Press middle button at (3, 4)", ActionDescriber.Describe(Act.MouseDown(3, 4, MouseButton.Other)).Replace("Press middle button", "Press middle button"));
    }

    [Test]
    public static void PresetsProduceValidKeyboardOnlyActions()
    {
        foreach (var preset in Presets.All)
        {
            var actions = Presets.Actions(preset.Id, "general", "hello");
            Check.True(actions.Count > 0);
            var r = new Recording("p");
            r.Actions.AddRange(actions);
            Check.Equal(0, RecordingValidator.Errors(RecordingValidator.Validate(r)).Count);
            Check.False(actions.Any(a => a.X != null || a.Y != null), "presets must not contain coordinates");
        }
        Check.Equal(0, Presets.Actions("nope", "x").Count);
    }
}
