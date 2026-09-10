using System.Globalization;
using System.Text.Json;

namespace JazzCaptureCore;

/// <summary>Pure parsing and comparison rules for the public release feed.</summary>
public static class ReleaseAvailability
{
    public static bool TryGetNewer(string currentVersion, string json, out AvailableRelease? release)
    {
        release = null;
        if (!Version.TryParse(currentVersion, out Version? current)) return false;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            foreach (JsonElement item in document.RootElement.EnumerateArray())
            {
                if (item.TryGetProperty("draft", out JsonElement draft) && draft.GetBoolean()) continue;
                if (item.TryGetProperty("prerelease", out JsonElement prerelease) && prerelease.GetBoolean()) continue;
                string? tag = item.TryGetProperty("tag_name", out JsonElement tagElement) ? tagElement.GetString() : null;
                string? url = item.TryGetProperty("html_url", out JsonElement urlElement) ? urlElement.GetString() : null;
                if (tag is null || url is null || !tag.StartsWith('v') || !Version.TryParse(tag[1..], out Version? candidate) || candidate <= current) continue;
                if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? uri) || uri.Scheme != Uri.UriSchemeHttps || uri.Host != "github.com") continue;
                if (release is null || candidate > release.Version) release = new AvailableRelease(candidate, uri);
            }
        }
        catch (JsonException) { return false; }
        return release is not null;
    }

    public static bool IsDue(DateTimeOffset? attemptedAt, DateTimeOffset now, TimeSpan cadence) =>
        attemptedAt is null || now - attemptedAt.Value >= cadence;
}

public sealed record AvailableRelease(Version Version, Uri Url);
