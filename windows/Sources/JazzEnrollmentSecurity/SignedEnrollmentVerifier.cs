using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzEnrollmentSecurity;

/// <summary>The v2 signed enrollment payload, exactly as the issuer signed it.</summary>
public sealed record SignedDeviceBundlePayload(
    long SchemaVersion,
    string Kind,
    string BundleId,
    long Generation,
    string Issuer,
    string Audience,
    string IssuedAt,
    string BundleExpiresAt,
    string DeviceId,
    string CompanyId,
    string AreaId,
    string ProjectId,
    string StackUrl,
    string ArchiveIngestUrl,
    string Token,
    string TokenId,
    string ExpiresAt,
    JazzArchiveTokenBucketScope TokenBucketScope,
    string? SinkBucketId,
    IReadOnlyList<string> ComponentAccess,
    string? StreamSourceId,
    string? StreamEndpoint)
{
    /// <summary>The routing tuple and credential this payload projects into.</summary>
    public DeviceBundle DeviceBundle => new(
        Kind,
        DeviceId,
        StackUrl,
        ProjectId,
        CompanyId,
        AreaId,
        ArchiveIngestUrl,
        StreamSourceId,
        StreamEndpoint,
        Token,
        TokenId,
        ExpiresAt,
        TokenBucketScope,
        SinkBucketId,
        ComponentAccess);
}

/// <summary>A payload that passed signature, time, scope and replay admission.</summary>
public sealed record AuthorizedSignedDeviceBundle(
    SignedDeviceBundlePayload Payload,
    string EnvelopeDigest,
    EnrollmentAcceptanceDecision Acceptance)
{
    /// <summary>The routing tuple and credential carried by the authorized payload.</summary>
    public DeviceBundle Bundle => Payload.DeviceBundle;
}

/// <summary>
/// Verifies a flattened Ed25519 JWS enrollment bundle against a code-signed issuer policy.
/// </summary>
/// <remarks>
/// Nothing here trusts a value carried by the document itself. The algorithm is pinned, the key is
/// selected out of the code-signed anchor set by <c>kid</c> only, the issuer and audience must equal
/// the configured ones, and both the protected header and the payload must be byte-identical to
/// their own canonical re-serialization so there is exactly one spelling of any signed document.
/// </remarks>
public sealed partial class SignedEnrollmentVerifier
{
    /// <summary>The only signature algorithm accepted.</summary>
    public const string ExpectedAlgorithm = "EdDSA";

    /// <summary>The only protected <c>typ</c> accepted.</summary>
    public const string ExpectedType = "application/jazz-device-bundle+jws";

    private static readonly string[] EnvelopeKeys = { "protected", "payload", "signature" };
    private static readonly string[] ProtectedKeys = { "alg", "kid", "typ" };

    private static readonly string[] PayloadKeys =
    {
        "schemaVersion", "kind", "bundleId", "generation", "issuer", "audience", "issuedAt",
        "bundleExpiresAt", "deviceId", "companyId", "areaId", "projectId", "stackURL",
        "archiveIngestURL", "token", "tokenId", "expiresAt", "tokenBucketScope",
        "sinkBucketId", "componentAccess", "streamSourceId", "streamEndpoint",
    };

    /// <summary>Creates a verifier bound to <paramref name="trustPolicy"/>.</summary>
    public SignedEnrollmentVerifier(EnrollmentTrustPolicy trustPolicy) => TrustPolicy = trustPolicy;

    /// <summary>The code-signed trust this verifier answers to.</summary>
    public EnrollmentTrustPolicy TrustPolicy { get; }

    /// <summary>
    /// Verifies <paramref name="text"/> and returns the payload with acceptance still
    /// <see cref="EnrollmentAcceptanceDecision.Pending"/>. Durable replay admission is a separate,
    /// later step; this result must not reach anything token-bearing on its own.
    /// </summary>
    /// <exception cref="SignedEnrollmentException">The bundle was refused.</exception>
    public AuthorizedSignedDeviceBundle Verify(string text, DateTimeOffset now)
    {
        string trimmed = text.Trim();
        byte[] envelopeBytes;
        try
        {
            envelopeBytes = new UTF8Encoding(false, true).GetBytes(trimmed);
        }
        catch (EncoderFallbackException)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.MalformedEnvelope);
        }

        if (envelopeBytes.Length == 0 || envelopeBytes.Length > 200_000)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.MalformedEnvelope);
        }

        JsonObject? envelope = StrictJson.TryParseObject(envelopeBytes);
        if (envelope is null || !StrictJson.HasExactlyKeys(envelope, EnvelopeKeys))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.MalformedEnvelope);
        }

        string? protectedSegment = StrictJson.StringOrNull(envelope, "protected");
        string? payloadSegment = StrictJson.StringOrNull(envelope, "payload");
        string? signatureSegment = StrictJson.StringOrNull(envelope, "signature");
        if (protectedSegment is null || payloadSegment is null || signatureSegment is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.MalformedEnvelope);
        }

        byte[]? protectedBytes = protectedSegment.Length <= 2_048
            ? EnrollmentEncoding.DecodeBase64Url(protectedSegment, maximumBytes: 1_536)
            : null;
        byte[]? payloadBytes = payloadSegment.Length <= 131_072
            ? EnrollmentEncoding.DecodeBase64Url(payloadSegment, maximumBytes: 98_304)
            : null;
        byte[]? signature = signatureSegment.Length == 86
            ? EnrollmentEncoding.DecodeBase64Url(signatureSegment, maximumBytes: 64)
            : null;
        if (protectedBytes is null || payloadBytes is null || signature is null || signature.Length != 64)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidBase64Url);
        }

        JsonObject? protectedHeader = StrictJson.TryParseObject(protectedBytes);
        if (protectedHeader is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidProtectedHeader);
        }

        byte[]? canonicalProtected = EnrollmentEncoding.TryCanonicalJson(protectedHeader);
        if (canonicalProtected is null || !canonicalProtected.AsSpan().SequenceEqual(protectedBytes))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.NonCanonicalProtectedHeader);
        }

        if (!StrictJson.HasExactlyKeys(protectedHeader, ProtectedKeys))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidProtectedHeader);
        }

        if (StrictJson.StringOrNull(protectedHeader, "alg") != ExpectedAlgorithm)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.UnsupportedAlgorithm);
        }

        string? keyId = StrictJson.StringOrNull(protectedHeader, "kid");
        if (StrictJson.StringOrNull(protectedHeader, "typ") != ExpectedType
            || keyId is null
            || !EnrollmentEncoding.IsValidKeyId(keyId))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidProtectedHeader);
        }

        if (!TrustPolicy.HasPublicKey(keyId))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.UnknownKey);
        }

        byte[] signingInput = Encoding.ASCII.GetBytes(protectedSegment + "." + payloadSegment);
        if (!TrustPolicy.VerifySignature(keyId, signingInput, signature))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidSignature);
        }

        JsonObject? payloadObject = StrictJson.TryParseObject(payloadBytes);
        if (payloadObject is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
        }

        byte[]? canonicalPayload = EnrollmentEncoding.TryCanonicalJson(payloadObject);
        if (canonicalPayload is null || !canonicalPayload.AsSpan().SequenceEqual(payloadBytes))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.NonCanonicalPayload);
        }

        if (!StrictJson.HasExactlyKeys(payloadObject, PayloadKeys))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
        }

        SignedDeviceBundlePayload payload = Decode(payloadObject);
        Validate(payload, now);

        var canonicalEnvelope = new JsonObject
        {
            ["protected"] = protectedSegment,
            ["payload"] = payloadSegment,
            ["signature"] = signatureSegment,
        };
        byte[]? envelopeDigestBytes = EnrollmentEncoding.TryCanonicalJson(canonicalEnvelope);
        if (envelopeDigestBytes is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.MalformedEnvelope);
        }

        return new AuthorizedSignedDeviceBundle(
            payload,
            EnrollmentEncoding.HexSha256(envelopeDigestBytes),
            EnrollmentAcceptanceDecision.Pending);
    }

    private static SignedDeviceBundlePayload Decode(JsonObject payload)
    {
        long? schemaVersion = StrictJson.IntegerOrNull(payload, "schemaVersion");
        long? generation = StrictJson.IntegerOrNull(payload, "generation");
        string? kind = StrictJson.StringOrNull(payload, "kind");
        string? bundleId = StrictJson.StringOrNull(payload, "bundleId");
        string? issuer = StrictJson.StringOrNull(payload, "issuer");
        string? audience = StrictJson.StringOrNull(payload, "audience");
        string? issuedAt = StrictJson.StringOrNull(payload, "issuedAt");
        string? bundleExpiresAt = StrictJson.StringOrNull(payload, "bundleExpiresAt");
        string? deviceId = StrictJson.StringOrNull(payload, "deviceId");
        string? companyId = StrictJson.StringOrNull(payload, "companyId");
        string? areaId = StrictJson.StringOrNull(payload, "areaId");
        string? projectId = StrictJson.StringOrNull(payload, "projectId");
        string? stackUrl = StrictJson.StringOrNull(payload, "stackURL");
        string? archiveIngestUrl = StrictJson.StringOrNull(payload, "archiveIngestURL");
        string? token = StrictJson.StringOrNull(payload, "token");
        string? tokenId = StrictJson.StringOrNull(payload, "tokenId");
        string? expiresAt = StrictJson.StringOrNull(payload, "expiresAt");
        JazzArchiveTokenBucketScope? scope =
            JazzArchiveTokenBucketScopeNames.TryParse(StrictJson.StringOrNull(payload, "tokenBucketScope"));
        IReadOnlyList<string>? componentAccess = StrictJson.StringArrayOrNull(payload, "componentAccess");

        if (schemaVersion is null || generation is null || kind is null || bundleId is null
            || issuer is null || audience is null || issuedAt is null || bundleExpiresAt is null
            || deviceId is null || companyId is null || areaId is null || projectId is null
            || stackUrl is null || archiveIngestUrl is null || token is null || tokenId is null
            || expiresAt is null || scope is null || componentAccess is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
        }

        return new SignedDeviceBundlePayload(
            schemaVersion.Value,
            kind,
            bundleId,
            generation.Value,
            issuer,
            audience,
            issuedAt,
            bundleExpiresAt,
            deviceId,
            companyId,
            areaId,
            projectId,
            stackUrl,
            archiveIngestUrl,
            token,
            tokenId,
            expiresAt,
            scope.Value,
            OptionalString(payload, "sinkBucketId"),
            componentAccess,
            OptionalString(payload, "streamSourceId"),
            OptionalString(payload, "streamEndpoint"));
    }

    /// <summary>
    /// Reads an optional member that the v2 contract requires to be present and either a string or
    /// the JSON literal <c>null</c>.
    /// </summary>
    /// <remarks>
    /// The explicit <c>null</c> is the server's wire shape, not something this client emits: an
    /// absent key is a different document and would already have failed the exact-key-set check.
    /// </remarks>
    private static string? OptionalString(JsonObject payload, string key)
    {
        if (StrictJson.IsExplicitNull(payload, key))
        {
            return null;
        }

        return StrictJson.StringOrNull(payload, key)
            ?? throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
    }

    private void Validate(SignedDeviceBundlePayload payload, DateTimeOffset now)
    {
        bool structurallyValid =
            payload.SchemaVersion == 2
            && payload.Kind == DeviceBundle.ExpectedKind
            && BundleIdPattern().IsMatch(payload.BundleId)
            && payload.Generation >= 1
            && payload.Generation <= 9_007_199_254_740_991
            && EnrollmentEncoding.ScalarCount(payload.Issuer) <= 2_048
            && EnrollmentEncoding.ScalarCount(payload.Audience) <= 256
            && ScopeIdPattern().IsMatch(payload.DeviceId)
            && ScopeIdPattern().IsMatch(payload.CompanyId)
            && ScopeIdPattern().IsMatch(payload.AreaId)
            && ProjectIdPattern().IsMatch(payload.ProjectId)
            && EnrollmentEncoding.ScalarCount(payload.StackUrl) <= 2_048
            && EnrollmentEncoding.ScalarCount(payload.ArchiveIngestUrl) <= 2_048
            && payload.Token.Length > 0
            && EnrollmentEncoding.ScalarCount(payload.Token) <= 8_192
            && payload.TokenId.Length > 0
            && EnrollmentEncoding.ScalarCount(payload.TokenId) <= 256
            && payload.ComponentAccess.Count <= 128
            && IsSortedAndUnique(payload.ComponentAccess)
            && payload.ComponentAccess.All(component => ComponentPattern().IsMatch(component))
            && (payload.StreamSourceId is null
                || (payload.StreamSourceId.Length > 0
                    && EnrollmentEncoding.ScalarCount(payload.StreamSourceId) <= 512))
            && EnrollmentEncoding.ScalarCount(payload.StreamEndpoint ?? string.Empty) <= 8_192;
        if (!structurallyValid)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
        }

        if (payload.Issuer != TrustPolicy.Issuer)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.IssuerMismatch);
        }

        if (payload.Audience != TrustPolicy.Audience)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.AudienceMismatch);
        }

        if (!EnrollmentUrlPolicy.IsSecureOrigin(payload.Issuer)
            || KeboolaStack.Normalize(payload.StackUrl) != payload.StackUrl
            || JazzArchiveControlPlaneUrl.Normalize(payload.ArchiveIngestUrl) != payload.ArchiveIngestUrl)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
        }

        if (payload.StreamEndpoint is string endpoint && !EnrollmentUrlPolicy.IsSecureEndpoint(endpoint))
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
        }

        if (payload.StreamSourceId is not null && payload.StreamEndpoint is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
        }

        switch (payload.TokenBucketScope)
        {
            case JazzArchiveTokenBucketScope.Sink
                when payload.SinkBucketId is null
                    || payload.SinkBucketId.Length == 0
                    || EnrollmentEncoding.ScalarCount(payload.SinkBucketId) > 512:
                throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
            case JazzArchiveTokenBucketScope.None when payload.SinkBucketId is not null:
                throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
            default:
                break;
        }

        DateTimeOffset? issuedAt = Timestamps.TryParseRfc3339(payload.IssuedAt);
        DateTimeOffset? bundleExpiresAt = Timestamps.TryParseRfc3339(payload.BundleExpiresAt);
        DateTimeOffset? credentialExpiresAt = Timestamps.TryParseRfc3339(payload.ExpiresAt);
        if (issuedAt is null
            || bundleExpiresAt is null
            || credentialExpiresAt is null
            || bundleExpiresAt <= issuedAt
            || credentialExpiresAt < bundleExpiresAt)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
        }

        if (issuedAt > now + TrustPolicy.ClockSkew)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.NotYetValid);
        }

        DateTimeOffset earliestAcceptedNow = now - TrustPolicy.ClockSkew;
        if (earliestAcceptedNow >= bundleExpiresAt)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.BundleExpired);
        }

        if (earliestAcceptedNow >= credentialExpiresAt)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.CredentialExpired);
        }
    }

    private static bool IsSortedAndUnique(IReadOnlyList<string> values)
    {
        for (int i = 1; i < values.Count; i++)
        {
            if (string.CompareOrdinal(values[i - 1], values[i]) >= 0)
            {
                return false;
            }
        }

        return true;
    }

    [GeneratedRegex("^jdb_[a-f0-9]{32}$")]
    private static partial Regex BundleIdPattern();

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,63}$")]
    private static partial Regex ScopeIdPattern();

    [GeneratedRegex("^[0-9]+$")]
    private static partial Regex ProjectIdPattern();

    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$")]
    private static partial Regex ComponentPattern();
}
