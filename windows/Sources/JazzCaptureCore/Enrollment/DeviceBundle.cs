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
