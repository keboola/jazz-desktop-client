using System.Globalization;
using System.Text.Json;

namespace JazzCaptureCore.Enrollment;

/// <summary>
/// Exact bucket grant represented by a server-issued enrollment bundle.
/// </summary>
/// <remarks>
/// Missing is deliberately distinct from <see cref="None"/>: an older bundle may still decode, but
/// cannot pass security validation.
/// </remarks>
public enum JazzArchiveTokenBucketScope
{
    /// <summary>The token may write exactly one sink bucket, named by <c>sinkBucketId</c>.</summary>
    Sink,

    /// <summary>The token holds exactly zero bucket permissions.</summary>
    None,
}

/// <summary>Wire spellings of <see cref="JazzArchiveTokenBucketScope"/>.</summary>
public static class JazzArchiveTokenBucketScopeNames
{
    /// <summary>Parses the wire spelling, or returns <see langword="null"/> for anything else.</summary>
    public static JazzArchiveTokenBucketScope? TryParse(string? value) => value switch
    {
        "sink" => JazzArchiveTokenBucketScope.Sink,
        "none" => JazzArchiveTokenBucketScope.None,
        _ => null,
    };

    /// <summary>The wire spelling of <paramref name="scope"/>.</summary>
    public static string ToWire(this JazzArchiveTokenBucketScope scope) =>
        scope == JazzArchiveTokenBucketScope.Sink ? "sink" : "none";
}

/// <summary>
/// The non-secret routing tuple plus the one-time credential reveal carried by an enrollment
/// bundle.
/// </summary>
/// <remarks>
/// This is the subset of the macOS <c>DeviceBundle</c> that the enrollment security boundary needs:
/// the value a verified signed bundle projects into. The macOS type additionally carries the MVP
/// operator-handoff profile and the live token-verification binding; neither has been ported yet
/// because neither is reachable without the Keboola Storage client, which the Windows client does
/// not have.
/// </remarks>
public sealed record DeviceBundle(
    string Kind,
    string DeviceId,
    string StackUrl,
    string ProjectId,
    string CompanyId,
    string AreaId,
    string ArchiveIngestUrl,
    string? StreamSourceId,
    string? StreamEndpoint,
    string Token,
    string TokenId,
    string ExpiresAt,
    JazzArchiveTokenBucketScope TokenBucketScope,
    string? SinkBucketId,
    IReadOnlyList<string> ComponentAccess,
    string? EnrollmentProfile = null)
{
    /// <summary>The only <c>kind</c> a Jazz device bundle may declare.</summary>
    public const string ExpectedKind = "jazz-device-bundle";

    /// <summary>Canonical stack base used for token verification.</summary>
    public string? NormalizedStackUrl => KeboolaStack.Normalize(StackUrl);

    /// <summary>Canonical archive control-plane base.</summary>
    public string? NormalizedArchiveIngestUrl => JazzArchiveControlPlaneUrl.Normalize(ArchiveIngestUrl);

    /// <summary>
    /// Overrides the compiler-generated positional-record <c>ToString()</c>, which would otherwise
    /// print every member -- including <see cref="Token"/>, the plaintext Storage credential, and
    /// <see cref="StreamEndpoint"/>, a capability URL whose *path* is itself the secret. Overriding
    /// <c>ToString()</c> is enough on its own: a record's generated <c>ToString()</c> is the only
    /// caller of its generated <c>PrintMembers</c> partial, so replacing <c>ToString()</c> means
    /// <c>PrintMembers</c> is never invoked and never needs its own override.
    /// </summary>
    /// <remarks>
    /// Only non-secret identity useful for operator diagnostics is included: <see cref="Kind"/>,
    /// <see cref="DeviceId"/>, <see cref="TokenId"/> (an opaque reference to the credential, never
    /// the credential itself), <see cref="ProjectId"/> and <see cref="ExpiresAt"/>. Every other
    /// member is left out deliberately rather than allow-listed field by field -- including
    /// <see cref="StackUrl"/>, <see cref="ArchiveIngestUrl"/>, <see cref="SinkBucketId"/> and
    /// <see cref="StreamSourceId"/> -- so that a future member added to this record cannot start
    /// leaking through this override by default.
    /// </remarks>
    public override string ToString() =>
        string.Format(
            CultureInfo.InvariantCulture,
            "DeviceBundle({0}, {1}, {2}, {3}, {4})",
            Kind, DeviceId, TokenId, ProjectId, ExpiresAt);
}

/// <summary>Operator-safe reasons a device bundle was refused before its secret is persisted.</summary>
public enum DeviceBundleError
{
    Malformed,
    WrongKind,
    MissingCredential,
    Expired,
    InvalidRouting,
    MasterToken,
    InvalidCredential,
    VerificationUnavailable,
    MissingMvpProfile,
    TokenIdMismatch,
    ExpiryMismatch,
}

/// <summary>Never includes bundle text, a token, or an endpoint.</summary>
public sealed class DeviceBundleException : Exception
{
    public DeviceBundleException(DeviceBundleError reason) : base(Describe(reason)) => Reason = reason;
    public DeviceBundleError Reason { get; }
    public static string Describe(DeviceBundleError reason) => reason switch
    {
        DeviceBundleError.WrongKind => "The supplied document is not a Jazz device bundle.",
        DeviceBundleError.MissingCredential => "The device bundle is missing a scoped credential.",
        DeviceBundleError.Expired => "The device bundle credential has expired.",
        DeviceBundleError.InvalidRouting => "The device bundle has invalid routing metadata.",
        DeviceBundleError.MasterToken => "A project master token cannot be enrolled on a device.",
        DeviceBundleError.InvalidCredential => "The device credential was refused by the storage service.",
        DeviceBundleError.VerificationUnavailable => "The device credential could not be verified right now.",
        DeviceBundleError.MissingMvpProfile => "This unsigned device bundle is not an MVP enrollment handoff.",
        DeviceBundleError.TokenIdMismatch => "The verified credential does not match this device bundle.",
        DeviceBundleError.ExpiryMismatch => "The verified credential lifetime does not match this device bundle.",
        _ => "The device bundle is malformed.",
    };
}

/// <summary>Pure, intentionally conservative parser for the one-time provisioning document.</summary>
public static class DeviceBundleParser
{
    /// <summary>Parses exactly the unsigned MVP handoff schema.  This is intentionally separate
    /// from the signed-envelope projection: absence of a signature must never imply MVP.</summary>
    public static DeviceBundle ParseMvp(string text, DateTimeOffset now, bool requireUnexpired = true)
    {
        using var doc = ParseObject(text);
        JsonElement root = doc.RootElement;
        string Required(string name) => root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? throw new DeviceBundleException(DeviceBundleError.Malformed) : throw new DeviceBundleException(DeviceBundleError.Malformed);
        string? Optional(string name) => root.TryGetProperty(name, out var v)
            ? v.ValueKind == JsonValueKind.Null ? null : v.ValueKind == JsonValueKind.String ? v.GetString() : throw new DeviceBundleException(DeviceBundleError.Malformed) : null;
        string? OptionalEndpoint() => root.TryGetProperty("streamEndpoint", out var v)
            ? v.ValueKind == JsonValueKind.String ? v.GetString() : throw new DeviceBundleException(DeviceBundleError.Malformed) : null;
        string[] names = ["kind", "enrollmentProfile", "deviceId", "companyId", "areaId", "projectId", "stackURL", "archiveIngestURL", "token", "tokenId", "expiresAt", "componentAccess", "tokenBucketScope", "streamSourceId", "streamEndpoint", "sinkBucketId"];
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (JsonProperty p in root.EnumerateObject()) if (!seen.Add(p.Name) || !names.Contains(p.Name, StringComparer.Ordinal)) throw new DeviceBundleException(DeviceBundleError.Malformed);
        if (Required("enrollmentProfile") != "mvp") throw new DeviceBundleException(DeviceBundleError.MissingMvpProfile);
        if (Required("kind") != DeviceBundle.ExpectedKind) throw new DeviceBundleException(DeviceBundleError.WrongKind);
        string token = Required("token"), expiry = Required("expiresAt");
        if (!IsValidStorageToken(token)) throw new DeviceBundleException(DeviceBundleError.Malformed);
        if (Timestamps.TryParseRfc3339(expiry) is not { } parsed) throw new DeviceBundleException(DeviceBundleError.Malformed);
        if (requireUnexpired && parsed <= now) throw new DeviceBundleException(DeviceBundleError.Expired);
        JazzArchiveTokenBucketScope? scope = JazzArchiveTokenBucketScopeNames.TryParse(Required("tokenBucketScope"));
        bool hasSink = root.TryGetProperty("sinkBucketId", out _);
        string? sink = Optional("sinkBucketId");
        if (scope is null || (scope == JazzArchiveTokenBucketScope.Sink && (!hasSink || string.IsNullOrWhiteSpace(sink))) || (scope == JazzArchiveTokenBucketScope.None && hasSink)) throw new DeviceBundleException(DeviceBundleError.Malformed);
        if (!root.TryGetProperty("componentAccess", out var components) || components.ValueKind != JsonValueKind.Array) throw new DeviceBundleException(DeviceBundleError.Malformed);
        string[] access = components.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.String ? x.GetString() : null).ToArray()!;
        if (access.Any(string.IsNullOrWhiteSpace) || access.Distinct(StringComparer.Ordinal).Count() != access.Length) throw new DeviceBundleException(DeviceBundleError.Malformed);
        var bundle = new DeviceBundle(DeviceBundle.ExpectedKind, Required("deviceId"), Required("stackURL"), Required("projectId"), Required("companyId"), Required("areaId"), Required("archiveIngestURL"), Optional("streamSourceId"), OptionalEndpoint(), token, Required("tokenId"), expiry, scope.Value, sink, access, "mvp");
        if (!Within(bundle.DeviceId, 256) || !Within(bundle.CompanyId, 256) || !Within(bundle.AreaId, 256) || !Within(bundle.ProjectId, 256) || !Within(bundle.TokenId, 256) || !Within(bundle.ExpiresAt, 64) || !Within(bundle.Token, 8192) || !Within(bundle.StackUrl, 2048) || !Within(bundle.ArchiveIngestUrl, 4096) || (bundle.StreamSourceId is not null && !Within(bundle.StreamSourceId, 512)) || (bundle.StreamEndpoint is not null && (!Within(bundle.StreamEndpoint, 8192) || !StreamEndpoint.IsSecureSignedEndpoint(bundle.StreamEndpoint))) || bundle.ProjectId.Any(c => c is < '0' or > '9') || (sink is not null && !Within(sink, 256)) || access.Any(x => !Within(x, 256)) || bundle.NormalizedStackUrl is null || bundle.StackUrl != bundle.NormalizedStackUrl || bundle.NormalizedArchiveIngestUrl is null || bundle.ArchiveIngestUrl != bundle.NormalizedArchiveIngestUrl) throw new DeviceBundleException(DeviceBundleError.InvalidRouting);
        return bundle;
    }

    private static bool Within(string? value, int maximum) => !string.IsNullOrWhiteSpace(value) && value.Length <= maximum;

    private static System.Text.Json.JsonDocument ParseObject(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new DeviceBundleException(DeviceBundleError.Malformed);
        try { var doc = System.Text.Json.JsonDocument.Parse(text.Trim()); if (doc.RootElement.ValueKind != JsonValueKind.Object) { doc.Dispose(); throw new DeviceBundleException(DeviceBundleError.Malformed); } return doc; }
        catch (System.Text.Json.JsonException) { throw new DeviceBundleException(DeviceBundleError.Malformed); }
    }
    /// <summary>
    /// Storage device tokens are ASCII credential values. Reject controls, whitespace and other
    /// header-unsafe syntax before an intake decides whether the plaintext is retryable.
    /// This deliberately permits the punctuation used by scoped Storage token secrets while
    /// requiring the project-secret separator.
    /// </summary>
    public static bool IsValidStorageToken(string token)
    {
        int separator = token.IndexOf('-');
        if (separator <= 0 || token.Length - separator - 1 < 16) return false;
        for (int index = 0; index < separator; index++)
            if (token[index] is < '0' or > '9') return false;
        foreach (char value in token)
        {
            // HTTP header field values may carry visible ASCII punctuation used by Storage
            // secrets; whitespace, controls and non-ASCII are rejected before transport.
            if (value is < '!' or > '~') return false;
        }
        return true;
    }

    /// <summary>Parses and validates a bundle without logging or retaining its source text.</summary>
    public static DeviceBundle Parse(string text, DateTimeOffset now, bool requireUnexpired = true)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new DeviceBundleException(DeviceBundleError.Malformed);
        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(text.Trim());
            var root = document.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object) throw new DeviceBundleException(DeviceBundleError.Malformed);
            string Required(string name) => root.TryGetProperty(name, out var value) && value.ValueKind == System.Text.Json.JsonValueKind.String
                ? value.GetString() ?? throw new DeviceBundleException(DeviceBundleError.Malformed)
                : throw new DeviceBundleException(DeviceBundleError.Malformed);
            string? Optional(string name) => root.TryGetProperty(name, out var value)
                ? value.ValueKind == System.Text.Json.JsonValueKind.Null ? null : value.ValueKind == System.Text.Json.JsonValueKind.String ? value.GetString() : throw new DeviceBundleException(DeviceBundleError.Malformed)
                : null;
            string kind = Required("kind");
            if (kind != DeviceBundle.ExpectedKind) throw new DeviceBundleException(DeviceBundleError.WrongKind);
            string token = Required("token");
            string tokenId = Required("tokenId");
            if (string.IsNullOrWhiteSpace(token) || string.IsNullOrWhiteSpace(tokenId))
                throw new DeviceBundleException(DeviceBundleError.MissingCredential);
            if (!IsValidStorageToken(token)) throw new DeviceBundleException(DeviceBundleError.Malformed);
            string expiresAt = Required("expiresAt");
            DateTimeOffset? expiry = Timestamps.TryParseRfc3339(expiresAt);
            if (expiry is null) throw new DeviceBundleException(DeviceBundleError.Malformed);
            if (requireUnexpired && expiry <= now) throw new DeviceBundleException(DeviceBundleError.Expired);
            JazzArchiveTokenBucketScope? scope = JazzArchiveTokenBucketScopeNames.TryParse(Optional("tokenBucketScope"));
            if (scope is null) throw new DeviceBundleException(DeviceBundleError.Malformed);
            string? sink = Optional("sinkBucketId");
            if ((scope == JazzArchiveTokenBucketScope.Sink && string.IsNullOrWhiteSpace(sink)) || (scope == JazzArchiveTokenBucketScope.None && sink is not null))
                throw new DeviceBundleException(DeviceBundleError.Malformed);
            var access = root.TryGetProperty("componentAccess", out var components) && components.ValueKind == System.Text.Json.JsonValueKind.Array
                ? components.EnumerateArray().Select(value => value.ValueKind == System.Text.Json.JsonValueKind.String ? value.GetString() : null).ToArray()
                : throw new DeviceBundleException(DeviceBundleError.Malformed);
            if (access.Any(value => value is null)) throw new DeviceBundleException(DeviceBundleError.Malformed);
            var bundle = new DeviceBundle(kind, Required("deviceId"), Required("stackUrl"), Required("projectId"), Required("companyId"), Required("areaId"), Required("archiveIngestUrl"), Optional("streamSourceId"), Optional("streamEndpoint"), token, tokenId, expiresAt, scope.Value, sink, access!);
            if (string.IsNullOrWhiteSpace(bundle.DeviceId) || bundle.NormalizedStackUrl is null || bundle.NormalizedArchiveIngestUrl is null
                || bundle.StackUrl != bundle.NormalizedStackUrl || bundle.ArchiveIngestUrl != bundle.NormalizedArchiveIngestUrl
                || string.IsNullOrWhiteSpace(bundle.StreamSourceId) || string.IsNullOrWhiteSpace(bundle.StreamEndpoint)
                || !StreamEndpoint.IsSecureSignedEndpoint(bundle.StreamEndpoint))
                throw new DeviceBundleException(DeviceBundleError.InvalidRouting);
            return bundle;
        }
        catch (DeviceBundleException) { throw; }
        catch (System.Text.Json.JsonException) { throw new DeviceBundleException(DeviceBundleError.Malformed); }
    }
}
