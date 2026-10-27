using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// Downloads an allowlisted GitHub MSI, verifies length and SHA-256, then starts a detached
/// per-user <c>msiexec</c>. Capture is not stopped here; Windows Installer Restart Manager asks
/// the existing maintenance window to drain.
/// </summary>
internal sealed class MsiUpdateApplier
{
    private readonly Func<string, bool> _startInstaller;

    internal MsiUpdateApplier(Func<string, bool>? startInstaller = null)
    {
        _startInstaller = startInstaller ?? StartMsiexec;
    }

    internal async Task<MsiUpdateApplyResult> ApplyAsync(
        AvailableRelease release,
        string updatesDirectory,
        HttpClient http,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(release);
        ArgumentNullException.ThrowIfNull(http);
        if (release.Size <= 0 || release.Size > ReleaseAvailability.MaximumPackageBytes)
            return MsiUpdateApplyResult.Failed("Update package is larger than allowed.");

        string destination = Path.Combine(updatesDirectory, "JazzCapture-" + release.Version + "-win-x64-unsigned.msi");
        string temporary = destination + ".part";
        MsiUpdateApplyResult? downloadError = null;
        try
        {
            Directory.CreateDirectory(updatesDirectory);
            using HttpResponseMessage response = await http.GetAsync(
                release.MsiUrl,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                downloadError = MsiUpdateApplyResult.Failed("Update download failed.");
            }
            else if (response.Content.Headers.ContentLength is long declared && declared != release.Size)
            {
                downloadError = MsiUpdateApplyResult.Failed("Update package size did not match the release.");
            }
            else
            {
                await using Stream source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                await using FileStream file = new(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 64 * 1024, useAsync: true);
                using IncrementalHash hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                byte[] buffer = new byte[64 * 1024];
                long total = 0;
                while (downloadError is null)
                {
                    int read = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken).ConfigureAwait(false);
                    if (read == 0) break;
                    total += read;
                    if (total > release.Size)
                    {
                        downloadError = MsiUpdateApplyResult.Failed("Update package size did not match the release.");
                        break;
                    }
                    hasher.AppendData(buffer.AsSpan(0, read));
                    await file.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                }

                if (downloadError is null)
                {
                    await file.FlushAsync(cancellationToken).ConfigureAwait(false);
                    if (total != release.Size)
                        downloadError = MsiUpdateApplyResult.Failed("Update package size did not match the release.");
                    else
                    {
                        string actual = Convert.ToHexString(hasher.GetHashAndReset());
                        if (!actual.Equals(release.Sha256, StringComparison.OrdinalIgnoreCase))
                            downloadError = MsiUpdateApplyResult.Failed("Update file did not match its checksum.");
                    }
                }
            }
        }
        catch (Exception exception) when (
            exception is HttpRequestException or IOException or UnauthorizedAccessException or TaskCanceledException)
        {
            downloadError = MsiUpdateApplyResult.Failed("Update download failed.");
        }

        if (downloadError is { } failed)
        {
            TryDelete(temporary);
            return failed;
        }

        try
        {
            File.Move(temporary, destination, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            TryDelete(temporary);
            return MsiUpdateApplyResult.Failed("Update file could not be saved.");
        }

        if (!_startInstaller(destination))
        {
            TryDelete(destination);
            return MsiUpdateApplyResult.Failed("Could not start the installer.");
        }

        return MsiUpdateApplyResult.Ok;
    }

    private static bool StartMsiexec(string msiPath)
    {
        try
        {
            var info = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "msiexec.exe"),
                Arguments = "/i \"" + msiPath + "\" /qn /norestart",
                UseShellExecute = true,
            };
            Process.Start(info);
            return true;
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }
}

internal readonly record struct MsiUpdateApplyResult(bool Started, string? Error)
{
    internal static MsiUpdateApplyResult Ok => new(true, null);
    internal static MsiUpdateApplyResult Failed(string error) => new(false, error);
}
