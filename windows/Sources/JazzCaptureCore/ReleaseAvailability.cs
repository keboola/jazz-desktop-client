using System.Text.Json;
using System.Text.RegularExpressions;

namespace JazzCaptureCore;

/// <summary>Pure parsing and comparison rules for the public release feed.</summary>
public static class ReleaseAvailability
{
    private static readonly Regex VersionPattern = new(
        @"^[0-9]+\.[0-9]+\.[0-9]+$",
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
                if (item.TryGetProperty("draft", out JsonElement draft) && draft.GetBoolean()) continue;
                if (item.TryGetProperty("prerelease", out JsonElement prerelease) && prerelease.GetBoolean()) continue;
                string? tag = item.TryGetProperty("tag_name", out JsonElement tagElement) ? tagElement.GetString() : null;
                string? url = item.TryGetProperty("html_url", out JsonElement urlElement) ? urlElement.GetString() : null;
                if (tag is null || url is null || !tag.StartsWith('v') || !TryParseVersion(tag[1..], out Version? candidate) || candidate <= current) continue;
                if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? uri)
                    || uri.Scheme != Uri.UriSchemeHttps
                    || !uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
                    || !uri.IsDefaultPort
                    || uri.UserInfo.Length != 0
                    || uri.Query.Length != 0
                    || uri.Fragment.Length != 0
                    || !uri.AbsolutePath.Equals(
                        "/keboola/jazz-desktop-client/releases/tag/" + tag,
                        StringComparison.Ordinal)) continue;
                if (release is null || candidate > release.Version) release = new AvailableRelease(candidate!, uri);
            }
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException) { return false; }
        return release is not null;
    }

    public static bool IsDue(DateTimeOffset? attemptedAt, DateTimeOffset now, TimeSpan cadence) =>
        attemptedAt is null || now - attemptedAt.Value >= cadence;

    private static bool TryParseVersion(string value, out Version? version)
    {
        version = null;
        return VersionPattern.IsMatch(value) && Version.TryParse(value, out version);
    }
}

public sealed record AvailableRelease(Version Version, Uri Url);
