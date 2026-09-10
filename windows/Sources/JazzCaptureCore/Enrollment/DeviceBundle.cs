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
    IReadOnlyList<string> ComponentAccess)
{
    /// <summary>The only <c>kind</c> a Jazz device bundle may declare.</summary>
    public const string ExpectedKind = "jazz-device-bundle";

    /// <summary>Canonical stack base used for token verification.</summary>
    public string? NormalizedStackUrl => KeboolaStack.Normalize(StackUrl);

    /// <summary>Canonical archive control-plane base.</summary>
    public string? NormalizedArchiveIngestUrl => JazzArchiveControlPlaneUrl.Normalize(ArchiveIngestUrl);
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
        _ => "The device bundle is malformed.",
    };
}

/// <summary>Pure, intentionally conservative parser for the one-time provisioning document.</summary>
public static class DeviceBundleParser
{
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
