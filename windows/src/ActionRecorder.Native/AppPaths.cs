namespace ActionRecorder.Native;

/// <summary>Where Action Recorder keeps its files. Everything stays inside the user's own profile.</summary>
public static class AppPaths
{
    public const string AppFolderName = "ActionRecorder";

    /// <summary>Test hook: when set, all paths live under this folder.</summary>
    public static string? RootOverride { get; set; }

    public static string DataRoot
    {
        get
        {
            if (RootOverride != null) return RootOverride;
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(appData)) appData = Path.Combine(Path.GetTempPath(), "ActionRecorder-data");
            return Path.Combine(appData, AppFolderName);
        }
    }

    public static string SettingsFile => Path.Combine(DataRoot, "settings.json");

    public static string DefaultRecordingsFolder => Path.Combine(DataRoot, "Recordings");

    public static string DefaultBackupsFolder => Path.Combine(DataRoot, "Backups");

    public static string UpdateFolder => Path.Combine(Path.GetTempPath(), "ActionRecorder-Update");

    public static string LogFile => Path.Combine(DataRoot, "last-run.log");

    public static string DefaultExportFolder
    {
        get
        {
            var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            return string.IsNullOrEmpty(documents) ? DataRoot : Path.Combine(documents, "Action Recorder");
        }
    }
}
