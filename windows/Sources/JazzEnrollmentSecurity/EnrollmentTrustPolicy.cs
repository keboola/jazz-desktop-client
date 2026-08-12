using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Text.Json.Nodes;
using JazzCaptureCore.Enrollment;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace JazzEnrollmentSecurity;

/// <summary>
/// Out-of-band trust used to authenticate copied Jazz enrollment bundles.
/// </summary>
/// <remarks>
/// A bundle contains only a protected <c>kid</c> selector. It can never add a key, replace this
/// issuer/audience policy, or supply a URL from which a key is fetched. Production configuration is
/// read from the code-signed application assembly; an enterprise may therefore stamp the same values
/// through its signed build pipeline without making editable bundle JSON its own trust root.
/// </remarks>
public sealed class EnrollmentTrustPolicy
{
    private readonly Dictionary<string, byte[]> publicKeysByKeyId;

    /// <summary>Creates a policy, throwing when any part of the configuration is unusable.</summary>
    /// <exception cref="EnrollmentTrustPolicyException">The configuration is invalid.</exception>
    public EnrollmentTrustPolicy(
        string issuer,
        string audience,
        IReadOnlyDictionary<string, string> publicKeysByKeyId,
        TimeSpan clockSkew = default)
    {
        if (!EnrollmentUrlPolicy.IsSecureOrigin(issuer))
        {
            throw new EnrollmentTrustPolicyException(EnrollmentTrustPolicyError.InvalidIssuer);
        }

        if (string.IsNullOrEmpty(audience)
            || audience != audience.Trim()
            || EnrollmentEncoding.ScalarCount(audience) > 256)
        {
            throw new EnrollmentTrustPolicyException(EnrollmentTrustPolicyError.InvalidAudience);
        }

        if (clockSkew < TimeSpan.Zero)
        {
            throw new EnrollmentTrustPolicyException(EnrollmentTrustPolicyError.InvalidClockSkew);
        }

        if (publicKeysByKeyId.Count == 0)
        {
            throw new EnrollmentTrustPolicyException(EnrollmentTrustPolicyError.MissingPublicKeys);
        }

        var parsed = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (KeyValuePair<string, string> entry in publicKeysByKeyId)
        {
            if (!EnrollmentEncoding.IsValidKeyId(entry.Key))
            {
                throw new EnrollmentTrustPolicyException(EnrollmentTrustPolicyError.InvalidKeyId);
            }

            byte[]? raw = EnrollmentEncoding.DecodeBase64Url(entry.Value, maximumBytes: 32);
            if (raw is null || raw.Length != 32 || !IsUsableEd25519PublicKey(raw))
            {
                throw new EnrollmentTrustPolicyException(EnrollmentTrustPolicyError.InvalidPublicKey);
            }

            parsed[entry.Key] = raw;
        }

        Issuer = issuer;
        Audience = audience;
        ClockSkew = clockSkew;
        this.publicKeysByKeyId = parsed;
    }

    /// <summary>The single issuer origin this machine trusts.</summary>
    public string Issuer { get; }

    /// <summary>The single audience this client answers to.</summary>
    public string Audience { get; }

    /// <summary>Tolerance applied to both ends of the bundle validity window.</summary>
    public TimeSpan ClockSkew { get; }

    /// <summary>Whether a trust anchor is configured under <paramref name="keyId"/>.</summary>
    public bool HasPublicKey(string keyId) => publicKeysByKeyId.ContainsKey(keyId);

    /// <summary>
    /// Verifies an Ed25519 signature under the anchor named by <paramref name="keyId"/>.
    /// </summary>
    /// <returns>
    /// <see langword="false"/> when the key is unknown as well as when the signature is wrong;
    /// callers that must distinguish the two check <see cref="HasPublicKey(string)"/> first.
    /// </returns>
    public bool VerifySignature(string keyId, ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature)
    {
        if (!publicKeysByKeyId.TryGetValue(keyId, out byte[]? raw))
        {
            return false;
        }

        if (signature.Length != 64)
        {
            return false;
        }

        try
        {
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(raw));
            byte[] messageBytes = message.ToArray();
            verifier.BlockUpdate(messageBytes, 0, messageBytes.Length);
            return verifier.VerifySignature(signature.ToArray());
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static bool IsUsableEd25519PublicKey(byte[] raw)
    {
        try
        {
            _ = new Ed25519PublicKeyParameters(raw);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }
}

/// <summary>
/// Code-signed bootstrap configuration.
/// </summary>
/// <remarks>
/// Missing or partially invalid configuration yields <see langword="null"/> so the importer fails
/// closed before it can inspect a credential or start a network request. On macOS the carrier is the
/// code-signed <c>Info.plist</c>; the Windows counterpart is a JSON resource embedded in the signed
/// executable, which is covered by the same Authenticode signature as the code that reads it. A file
/// on disk beside the executable is deliberately not supported: it would let anyone who can write
/// next to the binary install their own trust root.
/// </remarks>
public static class EnrollmentTrustBootstrap
{
    /// <summary>Configuration key naming the trusted issuer origin.</summary>
    public const string IssuerKey = "JazzEnrollmentIssuer";

    /// <summary>Configuration key naming the audience this client answers to.</summary>
    public const string AudienceKey = "JazzEnrollmentAudience";

    /// <summary>Configuration key naming the base64url Ed25519 anchors, by key id.</summary>
    public const string PublicKeysKey = "JazzEnrollmentEd25519PublicKeys";

    /// <summary>Configuration key naming the native redemption origin allowlist.</summary>
    public const string RedemptionOriginsKey = "JazzEnrollmentRedemptionOrigins";

    /// <summary>Name of the embedded resource that carries the signed configuration.</summary>
    public const string EmbeddedResourceName = "JazzEnrollmentTrust.json";

    /// <summary>
    /// Builds a trust policy from an already-parsed configuration, or returns <see langword="null"/>.
    /// </summary>
    public static EnrollmentTrustPolicy? Load(EnrollmentTrustConfiguration? configuration)
    {
        if (configuration?.Issuer is not string issuer
            || configuration.Audience is not string audience
            || configuration.PublicKeys is not IReadOnlyDictionary<string, string> keys)
        {
            return null;
        }

        try
        {
            return new EnrollmentTrustPolicy(issuer, audience, keys);
        }
        catch (EnrollmentTrustPolicyException)
        {
            return null;
        }
    }

    /// <summary>
    /// Builds the native redemption route policy from the same configuration, or returns
    /// <see langword="null"/>.
    /// </summary>
    public static EnrollmentRedemptionRoutePolicy? LoadRedemptionRoutePolicy(
        EnrollmentTrustConfiguration? configuration)
    {
        if (configuration?.RedemptionOrigins is not IReadOnlyList<string> origins)
        {
            return null;
        }

        try
        {
            return new EnrollmentRedemptionRoutePolicy(origins);
        }
        catch (EnrollmentTrustPolicyException)
        {
            return null;
        }
    }

    /// <summary>
    /// Reads <see cref="EmbeddedResourceName"/> out of <paramref name="assembly"/>, or returns
    /// <see langword="null"/> when it is absent or not strict JSON of the expected shape.
    /// </summary>
    public static EnrollmentTrustConfiguration? LoadEmbeddedConfiguration(Assembly assembly)
    {
        string? name = Array.Find(
            assembly.GetManifestResourceNames(),
            candidate => candidate.EndsWith(EmbeddedResourceName, StringComparison.Ordinal));
        if (name is null)
        {
            return null;
        }

        using Stream? stream = assembly.GetManifestResourceStream(name);
        if (stream is null)
        {
            return null;
        }

        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return EnrollmentTrustConfiguration.TryParse(buffer.ToArray());
    }
}

/// <summary>The parsed code-signed enrollment trust configuration.</summary>
public sealed class EnrollmentTrustConfiguration
{
    /// <summary>Creates a configuration from already-validated parts.</summary>
    public EnrollmentTrustConfiguration(
        string? issuer,
        string? audience,
        IReadOnlyDictionary<string, string>? publicKeys,
        IReadOnlyList<string>? redemptionOrigins)
    {
        Issuer = issuer;
        Audience = audience;
        PublicKeys = publicKeys;
        RedemptionOrigins = redemptionOrigins;
    }

    /// <summary>The configured issuer origin, when present.</summary>
    public string? Issuer { get; }

    /// <summary>The configured audience, when present.</summary>
    public string? Audience { get; }

    /// <summary>The configured base64url Ed25519 anchors by key id, when present.</summary>
    public IReadOnlyDictionary<string, string>? PublicKeys { get; }

    /// <summary>The configured native redemption origin allowlist, when present.</summary>
    public IReadOnlyList<string>? RedemptionOrigins { get; }

    /// <summary>
    /// Parses the embedded configuration document, or returns <see langword="null"/>.
    /// </summary>
    /// <remarks>
    /// A member of the wrong JSON type makes the whole configuration <see langword="null"/> rather
    /// than partially applied: half a trust root is not a weaker trust root, it is an unusable one.
    /// </remarks>
    public static EnrollmentTrustConfiguration? TryParse(ReadOnlySpan<byte> utf8)
    {
        JsonObject? root = StrictJson.TryParseObject(utf8);
        if (root is null
            || !StrictJson.HasOnlyKeys(
                root,
                new[]
                {
                    EnrollmentTrustBootstrap.IssuerKey,
                    EnrollmentTrustBootstrap.AudienceKey,
                    EnrollmentTrustBootstrap.PublicKeysKey,
                    EnrollmentTrustBootstrap.RedemptionOriginsKey,
                }))
        {
            return null;
        }

        Dictionary<string, string>? publicKeys = null;
        if (root.TryGetPropertyValue(EnrollmentTrustBootstrap.PublicKeysKey, out JsonNode? keysNode)
            && keysNode is not null)
        {
            if (keysNode is not JsonObject keysObject)
            {
                return null;
            }

            publicKeys = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, JsonNode?> entry in keysObject)
            {
                string? encoded = StrictJson.StringOrNull(keysObject, entry.Key);
                if (encoded is null)
                {
                    return null;
                }

                publicKeys[entry.Key] = encoded;
            }
        }

        IReadOnlyList<string>? origins = null;
        if (root.TryGetPropertyValue(EnrollmentTrustBootstrap.RedemptionOriginsKey, out JsonNode? originsNode)
            && originsNode is not null)
        {
            origins = StrictJson.StringArrayOrNull(root, EnrollmentTrustBootstrap.RedemptionOriginsKey);
            if (origins is null)
            {
                return null;
            }
        }

        string? issuer = StrictJson.StringOrNull(root, EnrollmentTrustBootstrap.IssuerKey);
        string? audience = StrictJson.StringOrNull(root, EnrollmentTrustBootstrap.AudienceKey);
        if ((issuer is null && root.ContainsKey(EnrollmentTrustBootstrap.IssuerKey))
            || (audience is null && root.ContainsKey(EnrollmentTrustBootstrap.AudienceKey)))
        {
            return null;
        }

        return new EnrollmentTrustConfiguration(issuer, audience, publicKeys, origins);
    }
}

/// <summary>
/// Code-signed native-gateway allowlist, intentionally separate from the signed-bundle issuer.
/// </summary>
/// <remarks>
/// A deployment may route native traffic through a different gateway or a path prefix. Only its
/// HTTPS origin is pinned here; the copied <c>redemptionURL</c> still supplies that deployment path.
/// </remarks>
public sealed class EnrollmentRedemptionRoutePolicy : IEquatable<EnrollmentRedemptionRoutePolicy>
{
    private readonly HashSet<string> trustedOrigins;

    /// <summary>Creates a policy from a duplicate-free list of canonical HTTPS origins.</summary>
    /// <exception cref="EnrollmentTrustPolicyException">The allowlist is empty or not canonical.</exception>
    public EnrollmentRedemptionRoutePolicy(IReadOnlyList<string> trustedOrigins)
    {
        if (trustedOrigins.Count == 0
            || new HashSet<string>(trustedOrigins, StringComparer.Ordinal).Count != trustedOrigins.Count)
        {
            throw new EnrollmentTrustPolicyException(EnrollmentTrustPolicyError.InvalidRedemptionOrigins);
        }

        var normalized = new HashSet<string>(StringComparer.Ordinal);
        foreach (string origin in trustedOrigins)
        {
            StrictAbsoluteUrl? url = StrictAbsoluteUrl.TryParse(origin);
            if (origin != origin.Trim()
                || url is null
                || url.Scheme != "https"
                || url.Host.Length == 0
                || url.UserInfo is not null
                || url.Query is not null
                || url.Fragment is not null
                || (url.EncodedPath.Length != 0 && url.EncodedPath != "/")
                || url.Port is < 1 or > 65_535)
            {
                throw new EnrollmentTrustPolicyException(
                    EnrollmentTrustPolicyError.InvalidRedemptionOrigins);
            }

            string canonical = "https://" + url.CanonicalHost + (url.Port is int port ? ":" + port : string.Empty);
            if (canonical != origin)
            {
                throw new EnrollmentTrustPolicyException(
                    EnrollmentTrustPolicyError.InvalidRedemptionOrigins);
            }

            normalized.Add(canonical);
        }

        this.trustedOrigins = normalized;
    }

    /// <summary>The canonical origins this client will send a bootstrap bearer to.</summary>
    public IReadOnlyCollection<string> TrustedOrigins => trustedOrigins;

    /// <summary>Whether <paramref name="endpoint"/> lives on an allowlisted origin.</summary>
    public bool Allows(string endpoint)
    {
        StrictAbsoluteUrl? url = StrictAbsoluteUrl.TryParse(endpoint);
        if (url is null || url.Scheme != "https" || url.Host.Length == 0)
        {
            return false;
        }

        string origin = "https://" + url.CanonicalHost + (url.Port is int port ? ":" + port : string.Empty);
        return trustedOrigins.Contains(origin);
    }

    /// <inheritdoc />
    public bool Equals(EnrollmentRedemptionRoutePolicy? other) =>
        other is not null && trustedOrigins.SetEquals(other.trustedOrigins);

    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as EnrollmentRedemptionRoutePolicy);

    /// <inheritdoc />
    public override int GetHashCode() => trustedOrigins.Count;
}

/// <summary>URL shapes the enrollment trust boundary accepts.</summary>
public static class EnrollmentUrlPolicy
{
    /// <summary>
    /// Whether <paramref name="value"/> is a canonical origin: HTTPS anywhere, plain HTTP only for
    /// the three literal loopback hosts, with no credentials, port outside 1-65535, path, query or
    /// fragment.
    /// </summary>
    public static bool IsSecureOrigin([NotNullWhen(true)] string? value)
    {
        if (value is null
            || value != value.Trim()
            || value.Contains('\\', StringComparison.Ordinal)
            || value.Contains('?', StringComparison.Ordinal)
            || value.Contains('#', StringComparison.Ordinal))
        {
            return false;
        }

        StrictAbsoluteUrl? url = StrictAbsoluteUrl.TryParse(value);
        if (url is null
            || url.Host.Length == 0
            || url.UserInfo is not null
            || url.Query is not null
            || url.Fragment is not null
            || url.Port is < 1 or > 65_535
            || (url.EncodedPath.Length != 0 && url.EncodedPath != "/"))
        {
            return false;
        }

        return url.Scheme == "https"
            || (url.Scheme == "http" && EnrollmentHosts.IsLiteralLoopback(url.Host));
    }

    /// <summary>Whether <paramref name="value"/> is an acceptable signed OTLP stream endpoint.</summary>
    public static bool IsSecureEndpoint(string? value) => StreamEndpoint.IsSecureSignedEndpoint(value);
}
