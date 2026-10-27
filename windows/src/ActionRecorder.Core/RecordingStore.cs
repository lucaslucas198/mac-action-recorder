using System.Globalization;

namespace ActionRecorder.Core;

/// <summary>Stores each recording as <c>&lt;uuid&gt;.macro.json</c> inside one folder.</summary>
public sealed class RecordingStore
{
    public string Directory { get; }

    public RecordingStore(string directory)
    {
        Directory = directory;
        try
        {
            System.IO.Directory.CreateDirectory(directory);
        }
        catch (Exception ex)
        {
            throw RecordingException.Io($"Could not create {directory}: {ex.Message}");
        }
    }

    public string FilePathFor(Guid id) => Path.Combine(Directory, $"{id.ToString("D").ToUpperInvariant()}.{RecordingFormat.FileExtension}");

    public bool Exists(Guid id) => File.Exists(FilePathFor(id));

    /// <summary>Writes the recording atomically (a crash mid-write cannot leave a half-written file).</summary>
    public void Save(Recording recording)
    {
        var data = RecordingCodec.Encode(recording);
        try
        {
            AtomicFile.WriteAllBytes(FilePathFor(recording.Id), data);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw RecordingException.Io(ex.Message);
        }
    }

    public Recording Load(Guid id) => Load(FilePathFor(id));

    public Recording Load(string path)
    {
        return RecordingCodec.Decode(ReadFile(path));
    }

    /// <summary>Loads every readable recording, newest first. Files that fail to load are reported in
    /// <c>Failures</c> instead of aborting the whole listing.</summary>
    public (List<Recording> Recordings, List<(string Path, Exception Error)> Failures) LoadAll()
    {
        var recordings = new List<Recording>();
        var failures = new List<(string, Exception)>();
        string[] files;
        try
        {
            files = System.IO.Directory.GetFiles(Directory, "*." + RecordingFormat.FileExtension);
        }
        catch (Exception)
        {
            files = Array.Empty<string>();
        }
        foreach (var file in files)
        {
            try
            {
                recordings.Add(Load(file));
            }
            catch (Exception ex)
            {
                failures.Add((file, ex));
            }
        }
        recordings.Sort((a, b) => b.CreatedAt.CompareTo(a.CreatedAt));
        return (recordings, failures);
    }

    public void Delete(Guid id)
    {
        var path = FilePathFor(id);
        if (!File.Exists(path))
        {
            throw RecordingException.NotFound(Path.GetFileName(path));
        }
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw RecordingException.Io(ex.Message);
        }
    }

    /// <summary>Saves a copy under a new id and name ("&lt;name&gt; copy").</summary>
    public Recording Duplicate(Recording recording, DateTime? now = null)
    {
        var stamp = now ?? DateTime.UtcNow;
        var copy = recording.Clone();
        copy.Id = Guid.NewGuid();
        copy.Name = recording.Name + " copy";
        copy.CreatedAt = stamp;
        copy.ModifiedAt = stamp;
        foreach (var action in copy.Actions)
        {
            action.Id = Guid.NewGuid();
        }
        Save(copy);
        return copy;
    }

    /// <summary>Imports a recording file into the store. The file is fully validated first; if its id already
    /// exists in the store, the import gets a new id so nothing is overwritten.</summary>
    public Recording ImportFile(string path)
    {
        var recording = Load(path);
        if (Exists(recording.Id))
        {
            recording.Id = Guid.NewGuid();
        }
        Save(recording);
        return recording;
    }

    /// <summary>Writes a standalone copy of the recording to <paramref name="path"/> for sharing or moving to another PC.</summary>
    public void Export(Recording recording, string path)
    {
        var data = RecordingCodec.Encode(recording);
        try
        {
            AtomicFile.WriteAllBytes(path, data);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw RecordingException.Io(ex.Message);
        }
    }

    /// <summary>Copies every recording into a new timestamped folder under <paramref name="backupRoot"/> and keeps
    /// only the newest <paramref name="keep"/> backup folders. Returns the new backup folder.</summary>
    public string CreateBackup(string backupRoot, int keep, DateTime? now = null)
    {
        var stamp = (now ?? DateTime.Now).ToString("yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture);
        var folder = Path.Combine(backupRoot, "backup-" + stamp);
        try
        {
            System.IO.Directory.CreateDirectory(folder);
            foreach (var file in System.IO.Directory.GetFiles(Directory, "*." + RecordingFormat.FileExtension))
            {
                File.Copy(file, Path.Combine(folder, Path.GetFileName(file)), overwrite: false);
            }
        }
        catch (Exception ex)
        {
            throw RecordingException.Io($"Backup failed: {ex.Message}");
        }
        PruneBackups(backupRoot, Math.Max(1, keep));
        return folder;
    }

    private static void PruneBackups(string root, int keep)
    {
        try
        {
            var backups = System.IO.Directory.GetDirectories(root, "backup-*")
                .OrderByDescending(p => Path.GetFileName(p), StringComparer.Ordinal)
                .ToList();
            foreach (var old in backups.Skip(keep))
            {
                try { System.IO.Directory.Delete(old, recursive: true); } catch (Exception) { }
            }
        }
        catch (Exception)
        {
            // pruning is best-effort
        }
    }

    private static byte[] ReadFile(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (info.Exists && info.Length > RecordingCodec.DefaultMaxFileSize)
            {
                throw RecordingException.TooLarge(info.Length);
            }
            return File.ReadAllBytes(path);
        }
        catch (RecordingException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw RecordingException.Io($"Could not read {Path.GetFileName(path)}: {ex.Message}");
        }
    }
}
