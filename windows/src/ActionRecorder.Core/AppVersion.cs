using System.Text.Json;

namespace ActionRecorder.Core;

/// <summary>A dotted version number such as "0.4.0". Missing trailing parts count as zero, so "1.2" equals "1.2.0".</summary>
public sealed class AppVersion : IComparable<AppVersion>, IEquatable<AppVersion>
{
    public IReadOnlyList<int> Components { get; }

    private AppVersion(List<int> components)
    {
        Components = components;
    }

    /// <summary>Accepts "1.2.3", "v1.2.3", " 1.2.3\n" and "1.2.3-beta" (the suffix is ignored).
    /// Returns null for anything else, such as an HTML error page.</summary>
    public static AppVersion? Parse(string? text)
    {
        if (text == null) return null;
        var line = text.Split('\n', '\r').FirstOrDefault() ?? "";
        line = line.Trim(' ', '\t');
        if (line.StartsWith('v') || line.StartsWith('V')) line = line[1..];

        var length = 0;
        while (length < line.Length && (char.IsAsciiDigit(line[length]) || line[length] == '.')) length++;
        if (length == 0 || length > 32) return null;
        // After the number only nothing, a space, or a "-" / "+" suffix may follow ("1.2.3-beta").
        // This keeps text such as "404: Not Found" from being read as version 404.
        if (length < line.Length && line[length] != '-' && line[length] != '+' && line[length] != ' ') return null;

        var parts = line[..length].Split('.');
        if (parts.Length > 4) return null;
        var values = new List<int>();
        foreach (var part in parts)
        {
            if (part.Length == 0 || part.Length > 9 || !int.TryParse(part, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var value))
            {
                return null;
            }
            values.Add(value);
        }
        return new AppVersion(values);
    }

    public override string ToString() => string.Join('.', Components);

    private int At(int index) => index < Components.Count ? Components[index] : 0;

    public int CompareTo(AppVersion? other)
    {
        if (other == null) return 1;
        var count = Math.Max(Components.Count, other.Components.Count);
        for (var i = 0; i < count; i++)
        {
            var c = At(i).CompareTo(other.At(i));
            if (c != 0) return c;
        }
        return 0;
    }

    public bool Equals(AppVersion? other) => other != null && CompareTo(other) == 0;
    public override bool Equals(object? obj) => Equals(obj as AppVersion);
    public override int GetHashCode()
    {
        var last = Components.Count;
        while (last > 0 && Components[last - 1] == 0) last--;
        var hash = new HashCode();
        for (var i = 0; i < last; i++) hash.Add(Components[i]);
        return hash.ToHashCode();
    }

    public static bool operator >(AppVersion a, AppVersion b) => a.CompareTo(b) > 0;
    public static bool operator <(AppVersion a, AppVersion b) => a.CompareTo(b) < 0;
}

/// <summary>Where updates come from. The app only ever contacts these fixed GitHub addresses, and only to read.</summary>
public static class UpdateConfig
{
    public const string Repository = "lucaslucas198/mac-action-recorder";

    /// <summary>GitHub's description of the newest published release (version number and file list).</summary>
    public static readonly Uri LatestReleaseApiUrl = new($"https://api.github.com/repos/{Repository}/releases/latest");

    /// <summary>The installer file in a release.</summary>
    public const string InstallerAssetName = "ActionRecorder-Windows-Setup.exe";

    /// <summary>The checksum list attached to every release.</summary>
    public const string ChecksumAssetName = "SHA256SUMS.txt";

    /// <summary>The only address prefix a downloadable release file may have.</summary>
    public static readonly string ReleaseDownloadPrefix = $"https://github.com/{Repository}/releases/download/";
}

/// <summary>The parts of GitHub's "latest release" answer that the updater uses.</summary>
public sealed record ReleaseInfo(AppVersion Version, Uri InstallerUrl, Uri? ChecksumUrl)
{
    /// <summary>Reads GitHub's JSON. Returns null unless it names a parseable version AND a file called
    /// <see cref="UpdateConfig.InstallerAssetName"/> hosted under this repository's release downloads.
    /// Anything else (an error message, a draft, a file from somewhere else) is ignored.</summary>
    public static ReleaseInfo? Parse(byte[] data)
    {
        if (data.Length >= 2_000_000) return null;
        try
        {
            using var document = JsonDocument.Parse(data);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("tag_name", out var tagElement) || tagElement.ValueKind != JsonValueKind.String) return null;
            var version = AppVersion.Parse(tagElement.GetString());
            if (version == null) return null;
            if (IsTrue(root, "draft") || IsTrue(root, "prerelease")) return null;

            Uri? installer = null;
            Uri? checksum = null;
            if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
            {
                foreach (var asset in assets.EnumerateArray())
                {
                    if (asset.ValueKind != JsonValueKind.Object) continue;
                    var name = asset.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
                    var address = asset.TryGetProperty("browser_download_url", out var a) && a.ValueKind == JsonValueKind.String ? a.GetString() : null;
                    if (name == null || address == null || !address.StartsWith(UpdateConfig.ReleaseDownloadPrefix, StringComparison.Ordinal)) continue;
                    if (!Uri.TryCreate(address, UriKind.Absolute, out var uri)) continue;
                    if (name == UpdateConfig.InstallerAssetName) installer ??= uri;
                    else if (name == UpdateConfig.ChecksumAssetName) checksum ??= uri;
                }
            }
            return installer == null ? null : new ReleaseInfo(version, installer, checksum);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool IsTrue(JsonElement root, string name) =>
        root.TryGetProperty(name, out var e) && e.ValueKind == JsonValueKind.True;
}

public static class UpdateCheck
{
    /// <summary>True only when both texts parse as versions and the remote one is strictly newer.</summary>
    public static bool IsNewer(string remote, string installed)
    {
        var r = AppVersion.Parse(remote);
        var i = AppVersion.Parse(installed);
        return r != null && i != null && r > i;
    }

    /// <summary>Finds the SHA-256 for a file in the text of SHA256SUMS.txt ("&lt;hex&gt;  &lt;name&gt;" per line).</summary>
    public static string? FindChecksum(string sumsText, string fileName)
    {
        foreach (var raw in sumsText.Split('\n'))
        {
            var line = raw.Trim();
            var space = line.IndexOf(' ');
            if (space != 64) continue;
            var hash = line[..64];
            var name = line[65..].TrimStart(' ', '*');
            if (name == fileName && hash.All(Uri.IsHexDigit)) return hash.ToLowerInvariant();
        }
        return null;
    }
}

/// <summary>The stages of "Check this PC", used to drive the progress bar in the Welcome screen.
/// The bar moves from stage to stage as each one really finishes; it is not a timer.</summary>
public enum SetupStage
{
    System = 0,
    Input = 1,
    Display = 2,
    Assistant = 3,
}

public static class SetupStageInfo
{
    public static int Count => Enum.GetValues<SetupStage>().Length;

    /// <summary>Where the bar sits while this stage is running (0..1). Strictly increasing, never full:
    /// the bar is full only when every check has finished.</summary>
    public static double Fraction(this SetupStage stage) => stage switch
    {
        SetupStage.System => 0.10,
        SetupStage.Input => 0.35,
        SetupStage.Display => 0.60,
        _ => 0.85,
    };

    public static string StepText(this SetupStage stage) => $"Step {(int)stage + 1} of {Count}";

    public static string Title(this SetupStage stage) => stage switch
    {
        SetupStage.System => "Checking Windows…",
        SetupStage.Input => "Testing keyboard and mouse access…",
        SetupStage.Display => "Reading your display setup…",
        _ => "Looking for the local AI helper…",
    };
}
