using System.Text.Json;
using System.Text.RegularExpressions;

namespace JazzCaptureCore;

/// <summary>Pure parsing and comparison rules for the public release feed.</summary>
public static class ReleaseAvailability
{
    public const string RepositoryOwner = "keboola";
    public const string RepositoryName = "jazz-windows-releases";
    public const long MaximumPackageBytes = 100L * 1024 * 1024;

    private static readonly Regex VersionPattern = new(
        @"^[0-9]+\.[0-9]+\.[0-9]+$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static readonly Regex Sha256Digest = new(
        @"^sha256:([0-9a-fA-F]{64})$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    public static bool TryGetNewer(string currentVersion, string json, out AvailableRelease? release)
    {
        release = null;
        if (!TryParseVersion(currentVersion, out Version? current)) return false;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Array) return false;
            foreach (JsonElement item in document.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                if (item.TryGetProperty("draft", out JsonElement draft) && draft.ValueKind == JsonValueKind.True) continue;
                if (item.TryGetProperty("prerelease", out JsonElement prerelease) && prerelease.ValueKind == JsonValueKind.True) continue;
                string? tag = item.TryGetProperty("tag_name", out JsonElement tagElement) ? tagElement.GetString() : null;
                string? url = item.TryGetProperty("html_url", out JsonElement urlElement) ? urlElement.GetString() : null;
                if (tag is null || url is null || !tag.StartsWith('v') || !TryParseVersion(tag[1..], out Version? candidate) || candidate <= current) continue;
                if (!TryCreateHttpsGitHubUri(url, "/keboola/jazz-windows-releases/releases/tag/" + tag, out Uri? page)) continue;
                if (!TryReadMsiAsset(item, tag, candidate!, out Uri? msi, out string? sha256, out long size)) continue;
                if (release is null || candidate > release.Version)
                    release = new AvailableRelease(candidate!, page!, msi!, sha256!, size);
            }
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException) { return false; }
        return release is not null;
    }

    public static bool IsDue(DateTimeOffset? attemptedAt, DateTimeOffset now, TimeSpan cadence) =>
        attemptedAt is null || now - attemptedAt.Value >= cadence;

    private static bool TryReadMsiAsset(JsonElement release, string tag, Version version, out Uri? msi, out string? sha256, out long size)
    {
        msi = null;
        sha256 = null;
        size = 0;
        if (!release.TryGetProperty("assets", out JsonElement assets) || assets.ValueKind != JsonValueKind.Array) return false;
        string fileName = "JazzCapture-" + version + "-win-x64-unsigned.msi";
        string expectedPath = "/keboola/jazz-windows-releases/releases/download/" + tag + "/" + fileName;
        foreach (JsonElement asset in assets.EnumerateArray())
        {
            if (asset.ValueKind != JsonValueKind.Object) continue;
            if (asset.TryGetProperty("name", out JsonElement nameElement) && nameElement.GetString() != fileName) continue;
            if (!asset.TryGetProperty("browser_download_url", out JsonElement downloadElement)) continue;
            if (!TryCreateHttpsGitHubUri(downloadElement.GetString(), expectedPath, out Uri? download)) continue;
            if (!asset.TryGetProperty("digest", out JsonElement digestElement) || digestElement.GetString() is not string digest) continue;
            Match match = Sha256Digest.Match(digest);
            if (!match.Success) continue;
            if (!asset.TryGetProperty("size", out JsonElement sizeElement) || sizeElement.ValueKind != JsonValueKind.Number) continue;
            if (!sizeElement.TryGetInt64(out long packageSize) || packageSize <= 0 || packageSize > MaximumPackageBytes) continue;
            msi = download;
            sha256 = match.Groups[1].Value;
            size = packageSize;
            return true;
        }

        return false;
    }

    private static bool TryCreateHttpsGitHubUri(string? value, string expectedPath, out Uri? uri)
    {
        uri = null;
        if (value is null || !Uri.TryCreate(value, UriKind.Absolute, out Uri? parsed)) return false;
        if (parsed.Scheme != Uri.UriSchemeHttps
            || !parsed.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
            || !parsed.IsDefaultPort
            || parsed.UserInfo.Length != 0
            || parsed.Query.Length != 0
            || parsed.Fragment.Length != 0
            || !parsed.AbsolutePath.Equals(expectedPath, StringComparison.Ordinal)) return false;
        uri = parsed;
        return true;
    }

    private static bool TryParseVersion(string value, out Version? version)
    {
        version = null;
        return VersionPattern.IsMatch(value) && Version.TryParse(value, out version);
    }
}

public sealed record AvailableRelease(Version Version, Uri Url, Uri MsiUrl, string Sha256, long Size);
