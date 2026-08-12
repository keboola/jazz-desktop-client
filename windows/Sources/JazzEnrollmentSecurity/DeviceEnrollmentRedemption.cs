using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzEnrollmentSecurity;

/// <summary>
/// The exact one-time handoff copied from the authenticated web control plane.
/// </summary>
/// <remarks>
/// <c>RedemptionUrl</c> is routing, not signed authority. The client obtains authority from the
/// bearer-authenticated context endpoint and independently verifies the eventual bundle against its
/// code-signed issuer policy.
/// </remarks>
public sealed partial record DeviceRedemptionBootstrap(
    long SchemaVersion,
    string Kind,
    string BootstrapId,
    string DeviceId,
    string BundleId,
    long Generation,
    string Bearer,
    string IssuedAt,
    string ExpiresAt,
    string ServerTime,
    string RedemptionUrl)
{
    /// <summary>The only schema version this client speaks.</summary>
    public const int ExpectedSchemaVersion = 1;

    /// <summary>The only <c>kind</c> a bootstrap may declare.</summary>
    public const string ExpectedKind = "jazz-device-redemption-bootstrap";

    private static readonly string[] Keys =
    {
        "schemaVersion", "kind", "bootstrapId", "deviceId", "bundleId", "generation",
        "bearer", "issuedAt", "expiresAt", "serverTime", "redemptionURL",
    };

    /// <summary>Parses a pasted bootstrap document.</summary>
    /// <exception cref="DeviceEnrollmentRedemptionException">The bootstrap was refused.</exception>
    public static DeviceRedemptionBootstrap Parse(string text)
    {
        string trimmed = text.Trim();
        byte[] bytes;
        try
        {
            bytes = new UTF8Encoding(false, true).GetBytes(trimmed);
        }
        catch (EncoderFallbackException)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedBootstrap);
        }

        JsonObject? root = bytes.Length is > 0 and <= 16_384 ? StrictJson.TryParseObject(bytes) : null;
        if (root is null || !StrictJson.HasExactlyKeys(root, Keys))
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedBootstrap);
        }

        DeviceRedemptionBootstrap value = FromJson(root);
        value.Validate();
        return value;
    }

    /// <summary>Rebuilds a bootstrap from a persisted pending record.</summary>
    internal static DeviceRedemptionBootstrap FromJson(JsonObject root)
    {
        long? schemaVersion = StrictJson.IntegerOrNull(root, "schemaVersion");
        long? generation = StrictJson.IntegerOrNull(root, "generation");
        string?[] text =
        {
            StrictJson.StringOrNull(root, "kind"),
            StrictJson.StringOrNull(root, "bootstrapId"),
            StrictJson.StringOrNull(root, "deviceId"),
            StrictJson.StringOrNull(root, "bundleId"),
            StrictJson.StringOrNull(root, "bearer"),
            StrictJson.StringOrNull(root, "issuedAt"),
            StrictJson.StringOrNull(root, "expiresAt"),
            StrictJson.StringOrNull(root, "serverTime"),
            StrictJson.StringOrNull(root, "redemptionURL"),
        };
        if (schemaVersion is null || generation is null || Array.Exists(text, value => value is null))
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedBootstrap);
        }

        return new DeviceRedemptionBootstrap(
            schemaVersion.Value,
            text[0]!,
            text[1]!,
            text[2]!,
            text[3]!,
            generation.Value,
            text[4]!,
            text[5]!,
            text[6]!,
            text[7]!,
            text[8]!);
    }

    /// <summary>This bootstrap as a JSON object, for the pending record.</summary>
    internal JsonObject ToJson() => new()
    {
        ["schemaVersion"] = SchemaVersion,
        ["kind"] = Kind,
        ["bootstrapId"] = BootstrapId,
        ["deviceId"] = DeviceId,
        ["bundleId"] = BundleId,
        ["generation"] = Generation,
        ["bearer"] = Bearer,
        ["issuedAt"] = IssuedAt,
        ["expiresAt"] = ExpiresAt,
        ["serverTime"] = ServerTime,
        ["redemptionURL"] = RedemptionUrl,
    };

    /// <summary>The validated redemption endpoint.</summary>
    public string RedemptionEndpoint => RedemptionUrl;

    /// <summary>The parsed bootstrap expiry.</summary>
    public DateTimeOffset ExpiresAtInstant =>
        Timestamp(ExpiresAt)
        ?? throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedBootstrap);

    /// <summary>Re-runs every structural check, as a restored pending record must.</summary>
    /// <exception cref="DeviceEnrollmentRedemptionException">The bootstrap is not usable.</exception>
    internal void Validate()
    {
        byte[]? bearerBytes = EnrollmentEncoding.DecodeBase64Url(Bearer, maximumBytes: 32);
        DateTimeOffset? issued = Timestamp(IssuedAt);
        DateTimeOffset? expires = Timestamp(ExpiresAt);
        DateTimeOffset? server = Timestamp(ServerTime);
        bool valid =
            SchemaVersion == ExpectedSchemaVersion
            && Kind == ExpectedKind
            && BootstrapIdPattern().IsMatch(BootstrapId)
            && DeviceIdPattern().IsMatch(DeviceId)
            && BundleIdPattern().IsMatch(BundleId)
            && Generation is >= 1 and <= 9_007_199_254_740_991
            && BearerPattern().IsMatch(Bearer)
            && bearerBytes is { Length: 32 }
            && issued is not null
            && expires is not null
            && server is not null
            && issued == server
            && expires > issued
            && (expires.Value - issued.Value) <= TimeSpan.FromSeconds(900);
        if (!valid)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedBootstrap);
        }

        if (!IsCanonicalRedemptionEndpoint(RedemptionUrl, BootstrapId))
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.InsecureRedemptionRoute);
        }
    }

    private static bool IsCanonicalRedemptionEndpoint(string url, string bootstrapId)
    {
        StrictAbsoluteUrl? parsed = StrictAbsoluteUrl.TryParse(url);
        if (parsed is null
            || parsed.Scheme != "https"
            || parsed.Host.Length == 0
            || parsed.UserInfo is not null
            || parsed.Query is not null
            || parsed.Fragment is not null
            || parsed.Port is < 1 or > 65_535)
        {
            return false;
        }

        // The deployment supplies the path prefix; only the final segment is pinned, and the prefix
        // may not smuggle an empty segment past a proxy that would collapse it differently.
        string suffix = "/api/device-enrollment/redemptions/" + bootstrapId;
        return parsed.EncodedPath.EndsWith(suffix, StringComparison.Ordinal)
            && !parsed.EncodedPath[..^suffix.Length].Contains("//", StringComparison.Ordinal);
    }

    internal static DateTimeOffset? Timestamp(string value) =>
        SecondsTimestampPattern().IsMatch(value) ? Timestamps.TryParseRfc3339(value) : null;

    [GeneratedRegex("^jbt_[a-f0-9]{32}$")]
    private static partial Regex BootstrapIdPattern();

    [GeneratedRegex("^jdb_[a-f0-9]{32}$")]
    private static partial Regex BundleIdPattern();

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,63}$")]
    private static partial Regex DeviceIdPattern();

    [GeneratedRegex("^[A-Za-z0-9_-]{43}$")]
    private static partial Regex BearerPattern();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")]
    private static partial Regex SecondsTimestampPattern();
}

/// <summary>Server-derived authority, fetched before any device claim is sent.</summary>
public sealed partial record DeviceRedemptionContext(
    long SchemaVersion,
    string Kind,
    string OperationId,
    string BootstrapId,
    string DeviceId,
    string BundleId,
    long Generation,
    string Issuer,
    string Audience,
    string CompanyId,
    string AreaId,
    string ProjectId,
    string StackUrl,
    string ArchiveIngestUrl,
    string DeviceScopeSha256,
    string ServerTime,
    string ExpiresAt)
{
    /// <summary>The only schema version this client speaks.</summary>
    public const int ExpectedSchemaVersion = 1;

    /// <summary>The only <c>kind</c> a context may declare.</summary>
    public const string ExpectedKind = "jazz-device-redemption-context";

    private static readonly string[] Keys =
    {
        "schemaVersion", "kind", "operationId", "bootstrapId", "deviceId", "bundleId",
        "generation", "issuer", "audience", "companyId", "areaId", "projectId", "stackURL",
        "archiveIngestURL", "deviceScopeSHA256", "serverTime", "expiresAt",
    };

    /// <summary>Parses and binds a server context to the pasted bootstrap and the local trust root.</summary>
    /// <exception cref="DeviceEnrollmentRedemptionException">The context was refused.</exception>
    public static DeviceRedemptionContext Parse(
        byte[] data,
        DeviceRedemptionBootstrap bootstrap,
        EnrollmentTrustPolicy trustPolicy)
    {
        JsonObject? root = data.Length is > 0 and <= 32_768 ? StrictJson.TryParseObject(data) : null;
        if (root is null || !StrictJson.HasExactlyKeys(root, Keys))
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedContext);
        }

        DeviceRedemptionContext value = FromJson(root);
        value.Validate(bootstrap, trustPolicy);
        return value;
    }

    internal static DeviceRedemptionContext FromJson(JsonObject root)
    {
        long? schemaVersion = StrictJson.IntegerOrNull(root, "schemaVersion");
        long? generation = StrictJson.IntegerOrNull(root, "generation");
        string?[] text =
        {
            StrictJson.StringOrNull(root, "kind"),
            StrictJson.StringOrNull(root, "operationId"),
            StrictJson.StringOrNull(root, "bootstrapId"),
            StrictJson.StringOrNull(root, "deviceId"),
            StrictJson.StringOrNull(root, "bundleId"),
            StrictJson.StringOrNull(root, "issuer"),
            StrictJson.StringOrNull(root, "audience"),
            StrictJson.StringOrNull(root, "companyId"),
            StrictJson.StringOrNull(root, "areaId"),
            StrictJson.StringOrNull(root, "projectId"),
            StrictJson.StringOrNull(root, "stackURL"),
            StrictJson.StringOrNull(root, "archiveIngestURL"),
            StrictJson.StringOrNull(root, "deviceScopeSHA256"),
            StrictJson.StringOrNull(root, "serverTime"),
            StrictJson.StringOrNull(root, "expiresAt"),
        };
        if (schemaVersion is null || generation is null || Array.Exists(text, value => value is null))
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedContext);
        }

        return new DeviceRedemptionContext(
            schemaVersion.Value,
            text[0]!,
            text[1]!,
            text[2]!,
            text[3]!,
            text[4]!,
            generation.Value,
            text[5]!,
            text[6]!,
            text[7]!,
            text[8]!,
            text[9]!,
            text[10]!,
            text[11]!,
            text[12]!,
            text[13]!,
            text[14]!);
    }

    internal JsonObject ToJson() => new()
    {
        ["schemaVersion"] = SchemaVersion,
        ["kind"] = Kind,
        ["operationId"] = OperationId,
        ["bootstrapId"] = BootstrapId,
        ["deviceId"] = DeviceId,
        ["bundleId"] = BundleId,
        ["generation"] = Generation,
        ["issuer"] = Issuer,
        ["audience"] = Audience,
        ["companyId"] = CompanyId,
        ["areaId"] = AreaId,
        ["projectId"] = ProjectId,
        ["stackURL"] = StackUrl,
        ["archiveIngestURL"] = ArchiveIngestUrl,
        ["deviceScopeSHA256"] = DeviceScopeSha256,
        ["serverTime"] = ServerTime,
        ["expiresAt"] = ExpiresAt,
    };

    /// <summary>The device and authority this context binds a local key set to.</summary>
    public DeviceEnrollmentIdentityBinding IdentityBinding => new(DeviceId, AuthorityBindingSha256);

    /// <summary>Lower-hex SHA-256 of the canonical signed authority tuple.</summary>
    public string AuthorityBindingSha256 => CanonicalDigest(new JsonObject
    {
        ["schema"] = "jazz-device-enrollment-authority/v1",
        ["issuer"] = Issuer,
        ["audience"] = Audience,
        ["companyId"] = CompanyId,
        ["areaId"] = AreaId,
        ["projectId"] = ProjectId,
        ["stackURL"] = StackUrl,
        ["archiveIngestURL"] = ArchiveIngestUrl,
    });

    /// <summary>
    /// Binds the server's answer to the pasted bootstrap and to this machine's code-signed trust.
    /// </summary>
    /// <remarks>
    /// This is the authority-substitution gate. A server that answers with a different issuer,
    /// audience, project, stack or archive origin than the one this build trusts is refused here,
    /// before a device key is created and long before a claim carrying it is submitted.
    /// </remarks>
    internal void Validate(DeviceRedemptionBootstrap bootstrap, EnrollmentTrustPolicy trustPolicy)
    {
        DateTimeOffset? server = DeviceRedemptionBootstrap.Timestamp(ServerTime);
        DateTimeOffset? expires = DeviceRedemptionBootstrap.Timestamp(ExpiresAt);
        bool valid =
            SchemaVersion == ExpectedSchemaVersion
            && Kind == ExpectedKind
            && OperationIdPattern().IsMatch(OperationId)
            && BootstrapId == bootstrap.BootstrapId
            && DeviceId == bootstrap.DeviceId
            && BundleId == bootstrap.BundleId
            && Generation == bootstrap.Generation
            && Issuer == trustPolicy.Issuer
            && Audience == trustPolicy.Audience
            && ScopeIdPattern().IsMatch(CompanyId)
            && ScopeIdPattern().IsMatch(AreaId)
            && ProjectIdPattern().IsMatch(ProjectId)
            && KeboolaStack.Normalize(StackUrl) == StackUrl
            && JazzArchiveControlPlaneUrl.Normalize(ArchiveIngestUrl) == ArchiveIngestUrl
            && DigestPattern().IsMatch(DeviceScopeSha256)
            && server is not null
            && expires is not null
            && expires > server
            && ExpiresAt == bootstrap.ExpiresAt;
        if (!valid)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.AuthorityMismatch);
        }

        string expectedScope = CanonicalDigest(new JsonObject
        {
            ["schema"] = "jazz-device-enrollment-scope/v1",
            ["deviceId"] = DeviceId,
            ["companyId"] = CompanyId,
            ["areaId"] = AreaId,
            ["projectId"] = ProjectId,
        });
        if (expectedScope != DeviceScopeSha256)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.AuthorityMismatch);
        }

        try
        {
            _ = IdentityBinding;
        }
        catch (DeviceEnrollmentIdentityException)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.AuthorityMismatch);
        }
    }

    private static string CanonicalDigest(JsonObject value)
    {
        byte[] bytes = EnrollmentEncoding.TryCanonicalJson(value)
            ?? throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedContext);
        return EnrollmentEncoding.HexSha256(bytes);
    }

    [GeneratedRegex("^eio_[a-f0-9]{32}$")]
    private static partial Regex OperationIdPattern();

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,63}$")]
    private static partial Regex ScopeIdPattern();

    [GeneratedRegex("^[0-9]+$")]
    private static partial Regex ProjectIdPattern();

    [GeneratedRegex("^[a-f0-9]{64}$")]
    private static partial Regex DigestPattern();
}

/// <summary>A raw, bounded response returned by the injectable HTTPS boundary.</summary>
public sealed class DeviceRedemptionHttpResponse
{
    /// <summary>Creates a response; header names are lowercased on the way in.</summary>
    public DeviceRedemptionHttpResponse(
        int statusCode,
        byte[] body,
        IReadOnlyDictionary<string, string>? headers = null)
    {
        StatusCode = statusCode;
        Body = body;
        var normalized = new Dictionary<string, string>(StringComparer.Ordinal);
        if (headers is not null)
        {
            foreach (KeyValuePair<string, string> entry in headers)
            {
                normalized[entry.Key.ToLowerInvariant()] = entry.Value;
            }
        }

        Headers = normalized;
    }

    /// <summary>HTTP status code.</summary>
    public int StatusCode { get; }

    /// <summary>Exact response body bytes.</summary>
    public byte[] Body { get; }

    /// <summary>Response headers, keyed by lowercased name.</summary>
    public IReadOnlyDictionary<string, string> Headers { get; }

    /// <summary>The header value, or <see langword="null"/>.</summary>
    public string? Header(string name) => Headers.TryGetValue(name, out string? value) ? value : null;
}

/// <summary>
/// The transport seam. The bearer is supplied only as an HTTP header value by the production
/// implementation, which this module does not contain: redemption talks to a server, and the
/// transport is not portable.
/// </summary>
public interface IDeviceRedemptionTransport
{
    /// <summary>Fetches the server-derived authority context.</summary>
    Task<DeviceRedemptionHttpResponse> FetchContextAsync(string endpoint, string bearer);

    /// <summary>Submits the exact claim bytes.</summary>
    Task<DeviceRedemptionHttpResponse> SubmitClaimAsync(string endpoint, string bearer, byte[] exactClaim);

    /// <summary>Polls for the sealed response.</summary>
    Task<DeviceRedemptionHttpResponse> PollAsync(string endpoint, string bearer);
}

/// <summary>Opaque persistence seam for the short-lived pending redemption record.</summary>
public interface IDeviceRedemptionPendingStore
{
    /// <summary>The stored record, or <see langword="null"/>.</summary>
    byte[]? Load();

    /// <summary>Atomically replaces the record with these exact bytes.</summary>
    void Replace(byte[] exactBytes);

    /// <summary>Removes the record.</summary>
    void Delete();
}

/// <summary>The exact signed bundle a completed redemption produced.</summary>
public sealed record RedeemedDeviceEnrollment(string BootstrapId, string ExactSignedBundle);

/// <summary>Non-secret summary of a pending redemption, safe to show in Settings.</summary>
public sealed record DeviceRedemptionPendingIdentity(
    string BootstrapId,
    string DeviceId,
    string BundleId,
    long Generation,
    string? Issuer,
    string? Audience);

/// <summary>
/// Restart-safe native redemption coordinator.
/// </summary>
/// <remarks>
/// Context is committed before key creation and claim construction, and the exact claim bytes are
/// committed before the POST. A crash at any network boundary therefore resumes with the same
/// authority, the same keys and the same bytes, so the server's one-shot claim binding still holds.
/// </remarks>
public sealed partial class DeviceEnrollmentRedemptionCoordinator
{
    private const string SealedContentType = "application/jazz-device-enrollment-sealed+json";

    private static readonly string[] PendingRecordKeys =
    {
        "schemaVersion", "bootstrap", "context", "exactClaimBase64", "claimSubmitted",
    };

    private static readonly string[] StatusKeys =
    {
        "schemaVersion", "kind", "bootstrapId", "deviceId", "bundleId", "generation",
        "state", "claimId", "disposition", "serverTime", "expiresAt",
    };

    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly IDeviceRedemptionPendingStore pendingStore;
    private readonly IDeviceRedemptionTransport transport;
    private readonly DeviceEnrollmentIdentityVault identityVault;
    private readonly EnrollmentTrustPolicy trustPolicy;
    private readonly EnrollmentRedemptionRoutePolicy routePolicy;
    private readonly Func<string> claimId;
    private readonly Func<DateTimeOffset> now;

    /// <summary>Creates a coordinator over injected transport, storage, identity and trust.</summary>
    public DeviceEnrollmentRedemptionCoordinator(
        IDeviceRedemptionPendingStore pendingStore,
        IDeviceRedemptionTransport transport,
        DeviceEnrollmentIdentityVault identityVault,
        EnrollmentTrustPolicy trustPolicy,
        EnrollmentRedemptionRoutePolicy routePolicy,
        Func<string>? claimId = null,
        Func<DateTimeOffset>? now = null)
    {
        this.pendingStore = pendingStore;
        this.transport = transport;
        this.identityVault = identityVault;
        this.trustPolicy = trustPolicy;
        this.routePolicy = routePolicy;
        this.claimId = claimId ?? (() => "jcl_" + Guid.NewGuid().ToString("N"));
        this.now = now ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>Persists a newly pasted bootstrap before any request, then advances one step.</summary>
    /// <exception cref="DeviceEnrollmentRedemptionException">Redemption stopped.</exception>
    public async Task<RedeemedDeviceEnrollment?> BeginAsync(string text)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            DeviceRedemptionBootstrap bootstrap = DeviceRedemptionBootstrap.Parse(text);
            if (!routePolicy.Allows(bootstrap.RedemptionEndpoint))
            {
                throw new DeviceEnrollmentRedemptionException(
                    DeviceEnrollmentRedemptionError.InsecureRedemptionRoute);
            }

            if (now().AddSeconds(-30) >= bootstrap.ExpiresAtInstant)
            {
                throw new DeviceEnrollmentRedemptionException(
                    DeviceEnrollmentRedemptionError.BootstrapExpired);
            }

            PendingRecord? existing = LoadPending();
            if (existing is null)
            {
                Persist(new PendingRecord(1, bootstrap, null, null, false));
            }
            else if (existing.Bootstrap != bootstrap)
            {
                if (now().AddSeconds(-30) < existing.Bootstrap.ExpiresAtInstant)
                {
                    throw new DeviceEnrollmentRedemptionException(
                        DeviceEnrollmentRedemptionError.PendingConflict);
                }

                // Expiry is authenticated by the strict persisted bootstrap record. Only that
                // short-lived record is dropped, never the identity or an activated credential.
                DeletePending();
                Persist(new PendingRecord(1, bootstrap, null, null, false));
            }

            return await ResumeLockedAsync().ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Resumes the exact persisted state; <see langword="null"/> while the server is working.</summary>
    /// <exception cref="DeviceEnrollmentRedemptionException">Redemption stopped.</exception>
    public async Task<RedeemedDeviceEnrollment?> ResumeAsync()
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            return await ResumeLockedAsync().ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Removes the bootstrap bearer, only after the caller committed the signed credential. A
    /// mismatched completion can never delete another pending enrollment.
    /// </summary>
    public void CompleteActivation(string bootstrapId)
    {
        gate.Wait();
        try
        {
            PendingRecord? pending = LoadPending();
            if (pending is null)
            {
                return;
            }

            if (pending.Bootstrap.BootstrapId != bootstrapId)
            {
                throw new DeviceEnrollmentRedemptionException(
                    DeviceEnrollmentRedemptionError.PendingConflict);
            }

            DeletePending();
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Explicit operator recovery for abandoned, unauthorized, quarantined or corrupt pending state.
    /// This removes only the short-lived redemption record; it never revokes device keys or deletes
    /// an already activated credential.
    /// </summary>
    public void DiscardPendingEnrollment()
    {
        gate.Wait();
        try
        {
            DeletePending();
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Whether a redemption is in flight. Corruption or a denied read counts as "pending", because
    /// it is not evidence of absence and must not unblock a legacy fallback path.
    /// </summary>
    public bool HasPendingEnrollment()
    {
        gate.Wait();
        try
        {
            return pendingStore.Load() is not null;
        }
        catch (Exception)
        {
            return true;
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Non-secret summary of the pending redemption, or <see langword="null"/>.</summary>
    public DeviceRedemptionPendingIdentity? PendingIdentity()
    {
        gate.Wait();
        try
        {
            PendingRecord? pending = LoadPending();
            return pending is null
                ? null
                : new DeviceRedemptionPendingIdentity(
                    pending.Bootstrap.BootstrapId,
                    pending.Bootstrap.DeviceId,
                    pending.Bootstrap.BundleId,
                    pending.Bootstrap.Generation,
                    pending.Context?.Issuer,
                    pending.Context?.Audience);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<RedeemedDeviceEnrollment?> ResumeLockedAsync()
    {
        PendingRecord? loaded = LoadPending();
        if (loaded is null)
        {
            return null;
        }

        PendingRecord pending = loaded;
        if (!routePolicy.Allows(pending.Bootstrap.RedemptionEndpoint))
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.InsecureRedemptionRoute);
        }

        if (now().AddSeconds(-30) >= pending.Bootstrap.ExpiresAtInstant)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.BootstrapExpired);
        }

        if (pending.Context is null)
        {
            DeviceRedemptionHttpResponse contextResponse = await SendAsync(
                () => transport.FetchContextAsync(
                    pending.Bootstrap.RedemptionEndpoint,
                    pending.Bootstrap.Bearer)).ConfigureAwait(false);
            RequireSuccess(contextResponse);
            pending = pending with
            {
                Context = DeviceRedemptionContext.Parse(
                    contextResponse.Body,
                    pending.Bootstrap,
                    trustPolicy),
            };

            // Committed before the claim on purpose: the context may stop being readable once the
            // server advances the device revision, but a restart must keep its original authority.
            Persist(pending);
        }

        DeviceRedemptionContext context = pending.Context!;
        DeviceEnrollmentIdentity identity = identityVault.LoadOrCreate(context.IdentityBinding, now());

        if (pending.ExactClaimBase64 is null)
        {
            DateTimeOffset? serverTime = Timestamps.TryParseRfc3339(context.ServerTime);
            DateTimeOffset? contextExpiry = Timestamps.TryParseRfc3339(context.ExpiresAt);
            if (serverTime is null || contextExpiry is null)
            {
                throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedContext);
            }

            DateTimeOffset claimExpiry = Min(
                serverTime.Value.AddSeconds(300),
                contextExpiry.Value.AddSeconds(-1));
            if (claimExpiry <= serverTime.Value)
            {
                throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.BootstrapExpired);
            }

            byte[] exactClaimBytes = identity.MakeClaim(
                pending.Bootstrap.BootstrapId,
                claimId(),
                Timestamps.IsoSecondsUtc(serverTime.Value),
                Timestamps.IsoSecondsUtc(claimExpiry));
            _ = DeviceBoundEnrollmentCrypto.VerifyClaim(exactClaimBytes);
            pending = pending with { ExactClaimBase64 = Convert.ToBase64String(exactClaimBytes) };

            // The exact bytes are durable before the POST. A crash after the server's compare-and-set
            // safely re-POSTs the identical claim rather than minting a second one.
            Persist(pending);
        }

        byte[] exactClaim;
        try
        {
            exactClaim = Convert.FromBase64String(pending.ExactClaimBase64!);
        }
        catch (FormatException)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.PendingStateUnavailable);
        }

        PendingRecord snapshot = pending;
        DeviceRedemptionHttpResponse response = await SendAsync(() => snapshot.ClaimSubmitted
            ? transport.PollAsync(snapshot.Bootstrap.RedemptionEndpoint, snapshot.Bootstrap.Bearer)
            : transport.SubmitClaimAsync(
                snapshot.Bootstrap.RedemptionEndpoint,
                snapshot.Bootstrap.Bearer,
                exactClaim)).ConfigureAwait(false);

        if (response.StatusCode == 202)
        {
            ValidatePendingStatus(response.Body, pending, exactClaim);
            if (!pending.ClaimSubmitted)
            {
                pending = pending with { ClaimSubmitted = true };
                Persist(pending);
            }

            return null;
        }

        RequireSuccess(response);
        return OpenAndVerify(response, pending, context, identity, exactClaim);
    }

    private RedeemedDeviceEnrollment OpenAndVerify(
        DeviceRedemptionHttpResponse response,
        PendingRecord pending,
        DeviceRedemptionContext context,
        DeviceEnrollmentIdentity identity,
        byte[] exactClaim)
    {
        if (response.Body.Length > 200_000)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedResponse);
        }

        string envelopeSha256 = EnrollmentEncoding.HexSha256(response.Body);
        string? headerBundleDigest = response.Header("x-jazz-bundle-sha256");
        bool headersValid =
            response.Header("content-type") == SealedContentType
            && response.Header("etag") == $"\"sha256:{envelopeSha256}\""
            && headerBundleDigest is not null
            && Sha256HeaderPattern().IsMatch(headerBundleDigest)
            && response.Header("x-jazz-bootstrap-expires-at") == pending.Bootstrap.ExpiresAt;
        if (!headersValid)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedResponse);
        }

        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(exactClaim);
        DeviceBundleSealInspection inspection = DeviceBoundEnrollmentCrypto.InspectSealedBundle(response.Body);
        if (inspection.Descriptor.BundleId != pending.Bootstrap.BundleId
            || inspection.Descriptor.Generation != pending.Bootstrap.Generation
            || inspection.Descriptor.RevealExpiresAt != pending.Bootstrap.ExpiresAt
            || inspection.BundleSha256 != headerBundleDigest)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.SignedBundleMismatch);
        }

        byte[] plaintext = identity.OpenSealedBundle(
            response.Body,
            claim.Binding,
            inspection.Descriptor,
            now());

        string signedText;
        try
        {
            signedText = new UTF8Encoding(false, true).GetString(plaintext);
        }
        catch (DecoderFallbackException)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.SignedBundleMismatch);
        }

        if (EnrollmentEncoding.HexSha256(plaintext) != headerBundleDigest
            || !new UTF8Encoding(false).GetBytes(signedText).AsSpan().SequenceEqual(plaintext))
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.SignedBundleMismatch);
        }

        SignedDeviceBundlePayload payload =
            new SignedEnrollmentVerifier(trustPolicy).Verify(signedText, now()).Payload;
        bool matchesReservation =
            payload.BundleId == pending.Bootstrap.BundleId
            && payload.Generation == pending.Bootstrap.Generation
            && payload.DeviceId == context.DeviceId
            && payload.Issuer == context.Issuer
            && payload.Audience == context.Audience
            && payload.CompanyId == context.CompanyId
            && payload.AreaId == context.AreaId
            && payload.ProjectId == context.ProjectId
            && payload.StackUrl == context.StackUrl
            && payload.ArchiveIngestUrl == context.ArchiveIngestUrl;
        if (!matchesReservation)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.SignedBundleMismatch);
        }

        return new RedeemedDeviceEnrollment(pending.Bootstrap.BootstrapId, signedText);
    }

    private static void ValidatePendingStatus(byte[] data, PendingRecord pending, byte[] exactClaim)
    {
        JsonObject? status = data.Length is > 0 and <= 16_384 ? StrictJson.TryParseObject(data) : null;
        if (status is null || !StrictJson.HasOnlyKeys(status, StatusKeys))
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedResponse);
        }

        bool valid =
            StrictJson.IntegerOrNull(status, "schemaVersion") == 1
            && StrictJson.StringOrNull(status, "kind") == "jazz-device-redemption-status"
            && StrictJson.StringOrNull(status, "bootstrapId") == pending.Bootstrap.BootstrapId
            && StrictJson.StringOrNull(status, "deviceId") == pending.Bootstrap.DeviceId
            && StrictJson.StringOrNull(status, "bundleId") == pending.Bootstrap.BundleId
            && StrictJson.IntegerOrNull(status, "generation") == pending.Bootstrap.Generation
            && StrictJson.StringOrNull(status, "state") == "pending"
            && StrictJson.StringOrNull(status, "serverTime") is not null
            && StrictJson.StringOrNull(status, "expiresAt") == pending.Bootstrap.ExpiresAt;
        if (!valid)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedResponse);
        }

        if (StrictJson.StringOrNull(status, "claimId") is string reportedClaimId
            && DeviceBoundEnrollmentCrypto.VerifyClaim(exactClaim).Binding.ClaimId != reportedClaimId)
        {
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.MalformedResponse);
        }
    }

    private static async Task<DeviceRedemptionHttpResponse> SendAsync(
        Func<Task<DeviceRedemptionHttpResponse>> operation)
    {
        try
        {
            return await operation().ConfigureAwait(false);
        }
        catch (DeviceEnrollmentRedemptionException)
        {
            throw;
        }
        catch (Exception)
        {
            // The transport is a seam; any failure it reports is "the server did not answer", never
            // a reason to advance the local state machine.
            throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.ServerUnavailable);
        }
    }

    private static void RequireSuccess(DeviceRedemptionHttpResponse response)
    {
        switch (response.StatusCode)
        {
            case 200:
                return;
            case 401:
                throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.Unauthorized);
            case 410:
                throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.BootstrapExpired);
            case 423:
                throw new DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError.Quarantined);
            default:
                throw new DeviceEnrollmentRedemptionException(
                    DeviceEnrollmentRedemptionError.ServerUnavailable);
        }
    }

    private PendingRecord? LoadPending()
    {
        byte[]? data;
        try
        {
            data = pendingStore.Load();
        }
        catch (Exception)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.PendingStateUnavailable);
        }

        if (data is null)
        {
            return null;
        }

        JsonObject? root = data.Length is > 0 and <= 300_000 ? StrictJson.TryParseObject(data) : null;
        if (root is null
            || !StrictJson.HasOnlyKeys(root, PendingRecordKeys)
            || StrictJson.IntegerOrNull(root, "schemaVersion") != 1
            || StrictJson.ObjectOrNull(root, "bootstrap") is not JsonObject bootstrapObject)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.PendingStateUnavailable);
        }

        try
        {
            // A record that will not even decode is unusable local state, not a malformed document
            // the server sent, so it reports as such: that is what DiscardPendingEnrollment clears.
            // Failures from Validate() below keep their own reason, because "this route is no longer
            // on the allowlist" and "this context no longer matches your trust root" are things an
            // operator needs to be told apart.
            DeviceRedemptionBootstrap bootstrap = Decode(() =>
                DeviceRedemptionBootstrap.FromJson(bootstrapObject));
            bootstrap.Validate();
            if (!routePolicy.Allows(bootstrap.RedemptionEndpoint))
            {
                throw new DeviceEnrollmentRedemptionException(
                    DeviceEnrollmentRedemptionError.InsecureRedemptionRoute);
            }

            DeviceRedemptionContext? context = null;
            if (root.ContainsKey("context"))
            {
                if (StrictJson.ObjectOrNull(root, "context") is not JsonObject contextObject)
                {
                    throw new DeviceEnrollmentRedemptionException(
                        DeviceEnrollmentRedemptionError.PendingStateUnavailable);
                }

                context = Decode(() => DeviceRedemptionContext.FromJson(contextObject));
                context.Validate(bootstrap, trustPolicy);
            }

            string? exactClaimBase64 = null;
            if (root.ContainsKey("exactClaimBase64"))
            {
                exactClaimBase64 = StrictJson.StringOrNull(root, "exactClaimBase64");
                if (exactClaimBase64 is null || exactClaimBase64.Length > 30_000)
                {
                    throw new DeviceEnrollmentRedemptionException(
                        DeviceEnrollmentRedemptionError.PendingStateUnavailable);
                }

                byte[] exactClaim;
                try
                {
                    exactClaim = Convert.FromBase64String(exactClaimBase64);
                }
                catch (FormatException)
                {
                    throw new DeviceEnrollmentRedemptionException(
                        DeviceEnrollmentRedemptionError.PendingStateUnavailable);
                }

                VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(exactClaim);
                if (context is null
                    || claim.Payload.BootstrapId != bootstrap.BootstrapId
                    || claim.Payload.DeviceId != bootstrap.DeviceId)
                {
                    throw new DeviceEnrollmentRedemptionException(
                        DeviceEnrollmentRedemptionError.PendingStateUnavailable);
                }
            }

            // Required and boolean, never inferred. A record that lost the flag is a tampered
            // record, not a record that never submitted.
            if (root["claimSubmitted"] is not JsonNode flag
                || flag.GetValueKind() is not (System.Text.Json.JsonValueKind.True
                    or System.Text.Json.JsonValueKind.False))
            {
                throw new DeviceEnrollmentRedemptionException(
                    DeviceEnrollmentRedemptionError.PendingStateUnavailable);
            }

            bool claimSubmitted = flag.GetValueKind() == System.Text.Json.JsonValueKind.True;
            if (exactClaimBase64 is null && claimSubmitted)
            {
                throw new DeviceEnrollmentRedemptionException(
                    DeviceEnrollmentRedemptionError.PendingStateUnavailable);
            }

            return new PendingRecord(1, bootstrap, context, exactClaimBase64, claimSubmitted);
        }
        catch (DeviceEnrollmentRedemptionException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.PendingStateUnavailable);
        }
    }

    /// <summary>Maps a decode failure of persisted local state to "the pending record is unusable".</summary>
    private static T Decode<T>(Func<T> decode)
    {
        try
        {
            return decode();
        }
        catch (DeviceEnrollmentRedemptionException)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.PendingStateUnavailable);
        }
    }

    private void Persist(PendingRecord record)
    {
        // Absent optional members are omitted, never written as JSON null.
        var json = new JsonObject
        {
            ["schemaVersion"] = record.SchemaVersion,
            ["bootstrap"] = record.Bootstrap.ToJson(),
            ["claimSubmitted"] = record.ClaimSubmitted,
        };
        if (record.Context is not null)
        {
            json["context"] = record.Context.ToJson();
        }

        if (record.ExactClaimBase64 is not null)
        {
            json["exactClaimBase64"] = record.ExactClaimBase64;
        }

        byte[]? encoded = EnrollmentEncoding.TryCanonicalJson(json);
        if (encoded is null)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.PendingStateUnavailable);
        }

        try
        {
            pendingStore.Replace(encoded);
        }
        catch (Exception)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.PendingStateUnavailable);
        }
    }

    private void DeletePending()
    {
        try
        {
            pendingStore.Delete();
        }
        catch (Exception)
        {
            throw new DeviceEnrollmentRedemptionException(
                DeviceEnrollmentRedemptionError.PendingStateUnavailable);
        }
    }

    private static DateTimeOffset Min(DateTimeOffset left, DateTimeOffset right) =>
        left <= right ? left : right;

    private sealed record PendingRecord(
        long SchemaVersion,
        DeviceRedemptionBootstrap Bootstrap,
        DeviceRedemptionContext? Context,
        string? ExactClaimBase64,
        bool ClaimSubmitted);

    [GeneratedRegex("^[a-f0-9]{64}$")]
    private static partial Regex Sha256HeaderPattern();
}
