using System.Diagnostics;
using System.Net.Http;
using System.Security.Cryptography;
using ActionRecorder.Core;

namespace ActionRecorder.Native;

public enum UpdatePhase
{
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading,
    Ready,
    Failed,
}

public sealed record UpdateState(UpdatePhase Phase, string Message, AppVersion? Version = null, double? Progress = null, string? InstallerPath = null);

/// <summary>
/// Looks for a newer release on GitHub and installs it only when the user asks.
/// - The only requests are read-only GETs to the fixed repository addresses in <see cref="UpdateConfig"/>.
/// - The installer must be hosted under that repository's release downloads and must match the SHA-256 in the release's SHA256SUMS.txt.
/// - Nothing is installed or restarted without the user pressing the button.
/// </summary>
public sealed class UpdateService : IDisposable
{
    private readonly HttpClient _http;
    private readonly string _installedVersion;
    private readonly Uri _latestUri;
    private ReleaseInfo? _release;

    public UpdateState State { get; private set; } = new(UpdatePhase.Idle, "");

    public event Action<UpdateState>? Changed;

    public UpdateService(string installedVersion, HttpMessageHandler? handler = null, Uri? latestUri = null)
    {
        _installedVersion = installedVersion;
        _latestUri = latestUri ?? UpdateConfig.LatestReleaseApiUrl;
        _http = handler == null ? new HttpClient() : new HttpClient(handler);
        _http.Timeout = TimeSpan.FromSeconds(60);
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("ActionRecorder/" + installedVersion);
        _http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    private void Set(UpdateState state)
    {
        State = state;
        Changed?.Invoke(state);
    }

    public async Task CheckAsync(CancellationToken cancel = default)
    {
        if (State.Phase is UpdatePhase.Checking or UpdatePhase.Downloading) return;
        Set(new UpdateState(UpdatePhase.Checking, "Checking for updates…"));
        try
        {
            using var response = await _http.GetAsync(_latestUri, cancel).ConfigureAwait(false);
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                Set(new UpdateState(UpdatePhase.UpToDate, "You have the latest version."));
                return;
            }
            if (!response.IsSuccessStatusCode)
            {
                Set(new UpdateState(UpdatePhase.Failed, $"GitHub answered with an error ({(int)response.StatusCode})."));
                return;
            }
            var bytes = await response.Content.ReadAsByteArrayAsync(cancel).ConfigureAwait(false);
            var release = ReleaseInfo.Parse(bytes);
            if (release == null || !UpdateCheck.IsNewer(release.Version.ToString(), _installedVersion))
            {
                // Also covers releases that only contain the Mac app: there is simply nothing for Windows to install.
                Set(new UpdateState(UpdatePhase.UpToDate, "You have the latest version."));
                return;
            }
            _release = release;
            Set(new UpdateState(UpdatePhase.Available, $"Version {release.Version} is available.", release.Version));
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException)
        {
            if (cancel.IsCancellationRequested) throw;
            Set(new UpdateState(UpdatePhase.Failed, "Could not reach GitHub. Check your internet connection."));
        }
    }

    /// <summary>Downloads the installer and checks it against the release's checksum list.</summary>
    public async Task DownloadAsync(string? folder = null, CancellationToken cancel = default)
    {
        if (_release == null) return;
        var release = _release;
        try
        {
            Set(new UpdateState(UpdatePhase.Downloading, $"Downloading version {release.Version}…", release.Version, 0));

            string? expected = null;
            if (release.ChecksumUrl != null)
            {
                var sums = await _http.GetStringAsync(release.ChecksumUrl, cancel).ConfigureAwait(false);
                expected = UpdateCheck.FindChecksum(sums, UpdateConfig.InstallerAssetName);
            }
            if (expected == null)
            {
                Set(new UpdateState(UpdatePhase.Failed, "The release has no checksum for the installer, so it was not downloaded."));
                return;
            }

            var directory = folder ?? AppPaths.UpdateFolder;
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, UpdateConfig.InstallerAssetName);
            var partial = path + ".part";

            using (var response = await _http.GetAsync(release.InstallerUrl, HttpCompletionOption.ResponseHeadersRead, cancel).ConfigureAwait(false))
            {
                response.EnsureSuccessStatusCode();
                var total = response.Content.Headers.ContentLength;
                await using var input = await response.Content.ReadAsStreamAsync(cancel).ConfigureAwait(false);
                await using var output = File.Create(partial);
                var buffer = new byte[81920];
                long done = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, cancel).ConfigureAwait(false)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), cancel).ConfigureAwait(false);
                    done += read;
                    if (total > 0)
                    {
                        Set(new UpdateState(UpdatePhase.Downloading, $"Downloading version {release.Version}…", release.Version, (double)done / total.Value));
                    }
                }
            }

            string actual;
            await using (var file = File.OpenRead(partial))
            {
                actual = Convert.ToHexString(await SHA256.HashDataAsync(file, cancel).ConfigureAwait(false)).ToLowerInvariant();
            }
            if (!string.Equals(actual, expected, StringComparison.Ordinal))
            {
                File.Delete(partial);
                Set(new UpdateState(UpdatePhase.Failed, "The downloaded file did not match its checksum, so it was discarded."));
                return;
            }
            if (File.Exists(path)) File.Delete(path);
            File.Move(partial, path);
            Set(new UpdateState(UpdatePhase.Ready, $"Version {release.Version} is ready to install.", release.Version, 1, path));
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException or UnauthorizedAccessException)
        {
            if (cancel.IsCancellationRequested) throw;
            Set(new UpdateState(UpdatePhase.Failed, "The download did not finish: " + ex.Message));
        }
    }

    /// <summary>Starts the downloaded installer. The caller then closes the app; the installer reopens it when done.</summary>
    public bool LaunchInstaller()
    {
        if (State.Phase != UpdatePhase.Ready || State.InstallerPath == null || !File.Exists(State.InstallerPath)) return false;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = State.InstallerPath,
                Arguments = "/SILENT /NOCANCEL /CLOSEAPPLICATIONS /NORESTART",
                UseShellExecute = true,
            });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public void Dispose() => _http.Dispose();
}
