using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace JazzCaptureCore.Consent;

/// <summary>A text the server serves: the body, its version and the SHA-256 the server computed.</summary>
public sealed record ServedText(string Version, string Sha256, string Body)
{
    /// <summary>True when SHA-256 of the UTF-8 bytes of <see cref="Body"/> equals <see cref="Sha256"/>.</summary>
    public bool HashMatches()
    {
        string actual = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Body)));
        return string.Equals(actual, Sha256, StringComparison.OrdinalIgnoreCase);
    }
}

public enum ConsentPolicyKind
{
    PerPerson,
    CompanyWide,
}

public sealed record ConsentSettings(
    ConsentPolicyKind Policy,
    ServedText? Text,
    ServedText? Notice,
    ServedText? ModeNotice);

/// <summary>
/// The answer of <c>GET /device/policy</c>. The client takes the capture mode, the consent policy
/// and every text from here. It builds none of them in.
/// </summary>
public sealed record DevicePolicy(
    string Status,
    int RefreshSeconds,
    string? MinClientVersion,
    RecordingMode? Mode,
    ConsentSettings? Consent)
{
    public const string Kind = "jazz-windows-client-policy";
    public const int Schema = 1;
    public const string StatusActive = "active";
    public const string StatusAwaitingAdminFirstRun = "awaiting_admin_first_run";
    public const int DefaultRefreshSeconds = 300;
    public const int MinimumRefreshSeconds = 30;
    public const int MaximumRefreshSeconds = 3600;
    public const int MaximumDocumentBytes = 512 * 1024;

    public static bool TryParse(string json, out DevicePolicy? policy)
    {
        policy = null;
        if (json.Length > MaximumDocumentBytes) return false;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return false;
            if (Str(root, "kind") != Kind) return false;
            if (!root.TryGetProperty("schema", out JsonElement schema)
                || schema.ValueKind != JsonValueKind.Number
                || !schema.TryGetInt32(out int schemaValue)
                || schemaValue != Schema) return false;
            string? status = Str(root, "status");
            if (string.IsNullOrEmpty(status)) return false;

            int refresh = DefaultRefreshSeconds;
            if (root.TryGetProperty("consentRefreshSeconds", out JsonElement refreshElement)
                && refreshElement.ValueKind == JsonValueKind.Number
                && refreshElement.TryGetInt32(out int seconds))
            {
                refresh = Math.Clamp(seconds, MinimumRefreshSeconds, MaximumRefreshSeconds);
            }

            RecordingMode? mode = RecordingModeParser.TryParse(Str(root, "recording_mode"), out RecordingMode parsed)
                ? parsed
                : null;
            policy = new DevicePolicy(status, refresh, Str(root, "minClientVersion"), mode, ParseConsent(root));
            return true;
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException)
        {
            return false;
        }
    }

    private static ConsentSettings? ParseConsent(JsonElement root)
    {
        if (!root.TryGetProperty("consent", out JsonElement consent) || consent.ValueKind != JsonValueKind.Object)
            return null;
        ConsentPolicyKind kind;
        switch (Str(consent, "policy"))
        {
            case "per_person": kind = ConsentPolicyKind.PerPerson; break;
            case "company_wide": kind = ConsentPolicyKind.CompanyWide; break;
            default: return null;
        }

        return new ConsentSettings(
            kind,
            Text(consent, "text"),
            Text(consent, "notice"),
            Text(consent, "modeNotice"));
    }

    private static ServedText? Text(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out JsonElement element) || element.ValueKind != JsonValueKind.Object)
            return null;
        string? version = Str(element, "version");
        string? sha256 = Str(element, "sha256");
        string? body = Str(element, "body");
        return string.IsNullOrEmpty(version) || string.IsNullOrEmpty(sha256) || string.IsNullOrEmpty(body)
            ? null
            : new ServedText(version, sha256, body);
    }

    private static string? Str(JsonElement parent, string name) =>
        parent.TryGetProperty(name, out JsonElement element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;
}

/// <summary>Compares dotted client versions such as <c>0.27.1</c>.</summary>
public static class ClientVersion
{
    /// <summary>True when <paramref name="current"/> is older than <paramref name="minimum"/>. An unreadable value is not older.</summary>
    public static bool IsBelow(string current, string? minimum)
    {
        if (string.IsNullOrWhiteSpace(minimum)) return false;
        if (!Version.TryParse(current, out Version? have) || !Version.TryParse(minimum, out Version? need)) return false;
        return Normalize(have) < Normalize(need);
    }

    private static Version Normalize(Version version) =>
        new(version.Major, version.Minor, Math.Max(version.Build, 0), Math.Max(version.Revision, 0));
}
