using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore;
using Org.BouncyCastle.Asn1.X9;
using Org.BouncyCastle.Crypto.EC;

namespace JazzEnrollmentSecurity;

/// <summary>One of the two P-256 public keys a device publishes in its enrollment claim.</summary>
public sealed record DeviceEnrollmentPublicKey(
    string Kty,
    string Crv,
    string Format,
    string Alg,
    string Use,
    string PublicKey)
{
    /// <summary>The ES256 proof-of-possession profile.</summary>
    public static DeviceEnrollmentPublicKey Proof(string publicKey) =>
        new("EC", "P-256", "X9.63", "ES256", "sig", publicKey);

    /// <summary>The ECDH-ES wrapping profile.</summary>
    public static DeviceEnrollmentPublicKey Wrapping(string publicKey) =>
        new("EC", "P-256", "X9.63", "ECDH-ES", "enc", publicKey);

    /// <summary>This profile as a JSON object.</summary>
    public JsonObject ToJson() => new()
    {
        ["kty"] = Kty,
        ["crv"] = Crv,
        ["format"] = Format,
        ["alg"] = Alg,
        ["use"] = Use,
        ["publicKey"] = PublicKey,
    };
}

/// <summary>The canonical device enrollment claim payload, v1.</summary>
public sealed record DeviceEnrollmentClaimPayload(
    string BootstrapId,
    string ClaimId,
    string DeviceId,
    string IssuedAt,
    string ExpiresAt,
    DeviceEnrollmentPublicKey ProofKey,
    DeviceEnrollmentPublicKey WrappingKey)
{
    /// <summary>The only schema version this client speaks.</summary>
    public const int ExpectedSchemaVersion = 1;

    /// <summary>The only <c>kind</c> a claim may declare.</summary>
    public const string ExpectedKind = "jazz-device-enrollment-claim";

    /// <summary>Schema version, always <see cref="ExpectedSchemaVersion"/>.</summary>
    public long SchemaVersion { get; init; } = ExpectedSchemaVersion;

    /// <summary>Document kind, always <see cref="ExpectedKind"/>.</summary>
    public string Kind { get; init; } = ExpectedKind;

    /// <summary>This payload as a JSON object, ready to be canonicalized.</summary>
    public JsonObject ToJson() => new()
    {
        ["schemaVersion"] = SchemaVersion,
        ["kind"] = Kind,
        ["bootstrapId"] = BootstrapId,
        ["claimId"] = ClaimId,
        ["deviceId"] = DeviceId,
        ["issuedAt"] = IssuedAt,
        ["expiresAt"] = ExpiresAt,
        ["proofKey"] = ProofKey.ToJson(),
        ["wrappingKey"] = WrappingKey.ToJson(),
    };
}

/// <summary>Everything the server authenticates a sealed response against.</summary>
public sealed record DeviceEnrollmentClaimBinding(
    string BootstrapId,
    string ClaimId,
    string DeviceId,
    string ClaimSha256,
    string ProofPublicKey,
    string ProofKeyThumbprint,
    string WrappingPublicKey,
    string WrappingKeyThumbprint);

/// <summary>A claim whose proof of possession verified.</summary>
public sealed record VerifiedDeviceEnrollmentClaim(
    DeviceEnrollmentClaimPayload Payload,
    DeviceEnrollmentClaimBinding Binding,
    byte[] CanonicalPayload,
    byte[] CanonicalEnvelope);

/// <summary>The bundle identity a sealed response claims to carry.</summary>
public sealed record DeviceBundleSealDescriptor(
    string BundleId,
    long Generation,
    string SealedAt,
    string RevealExpiresAt);

/// <summary>
/// Authenticated values carried by the protected sealed-bundle context.
/// </summary>
/// <remarks>
/// A redemption client needs the descriptor before it can ask the device identity to open the
/// envelope. Exposing only these validated, non-secret values avoids duplicating the strict
/// protected-header parser in the networking layer. They are not trusted on their own:
/// <see cref="DeviceBoundEnrollmentCrypto.OpenSealedBundle"/> authenticates the same protected
/// segment with AES-GCM and binds it to the exact claim.
/// </remarks>
public sealed record DeviceBundleSealInspection(DeviceBundleSealDescriptor Descriptor, string BundleSha256);

/// <summary>
/// Narrow signing boundary used by the device-claim encoder.
/// </summary>
/// <remarks>
/// A production implementation keeps the private key in hardware. Only the canonical public point
/// and a signature operation cross this boundary; a private scalar is never exposed.
/// </remarks>
public interface IDeviceEnrollmentProofSigner
{
    /// <summary>The X9.63 uncompressed public point of the signing key.</summary>
    byte[] PublicKeyX963 { get; }

    /// <summary>Signs <paramref name="message"/>, returning a raw 64-byte <c>r || s</c>.</summary>
    byte[] SignRaw(byte[] message);
}

/// <summary>
/// Narrow key-agreement boundary used by sealed enrollment-bundle redemption.
/// </summary>
/// <remarks>
/// The caller supplies only a peer public point and the public HKDF inputs. A production
/// implementation performs ECDH with a non-exportable private key and returns the derived symmetric
/// key, never the private scalar or the raw shared secret.
/// </remarks>
public interface IDeviceEnrollmentKeyAgreement
{
    /// <summary>The X9.63 uncompressed public point of the wrapping key.</summary>
    byte[] PublicKeyX963 { get; }

    /// <summary>Performs ECDH with <paramref name="peerPublicKeyX963"/> and HKDF-SHA256.</summary>
    byte[] DeriveSymmetricKey(byte[] peerPublicKeyX963, byte[] salt, byte[] sharedInfo);
}

/// <summary>
/// The portable half of device-bound enrollment: claim construction and verification, and sealed
/// bundle inspection and opening.
/// </summary>
/// <remarks>
/// Every private-key operation goes through <see cref="IDeviceEnrollmentProofSigner"/> or
/// <see cref="IDeviceEnrollmentKeyAgreement"/>, so this type never holds key material and can be
/// exercised against the shared contract vectors on any platform.
/// </remarks>
public static partial class DeviceBoundEnrollmentCrypto
{
    /// <summary>Domain separator prefixed to the canonical claim payload before signing.</summary>
    public static byte[] ClaimProofDomain { get; } = Utf8("JAZZ-DEVICE-ENROLLMENT-CLAIM-V1\0");

    /// <summary>Domain separator prefixed to the protected segment to build the AES-GCM AAD.</summary>
    public static byte[] SealAadDomain { get; } = Utf8("JAZZ-DEVICE-ENROLLMENT-SEAL-AAD-V1\0");

    /// <summary>Domain separator prefixed to the AAD digest to build the HKDF info.</summary>
    public static byte[] SealKdfDomain { get; } = Utf8("JAZZ-DEVICE-ENROLLMENT-SEAL-KDF-V1\0");

    private static readonly string[] ClaimEnvelopeKeys = { "payload", "proof" };

    private static readonly string[] ClaimPayloadKeys =
    {
        "schemaVersion", "kind", "bootstrapId", "claimId", "deviceId", "issuedAt",
        "expiresAt", "proofKey", "wrappingKey",
    };

    private static readonly string[] KeyKeys = { "kty", "crv", "format", "alg", "use", "publicKey" };

    private static readonly string[] EphemeralKeyKeys = { "kty", "crv", "format", "publicKey" };

    private static readonly string[] SealedEnvelopeKeys = { "protected", "iv", "ciphertext", "tag" };

    private static readonly string[] ProtectedKeys =
    {
        "alg", "enc", "kdf", "typ", "cty", "salt", "epk", "context",
    };

    private static readonly string[] ContextKeys =
    {
        "bootstrapId", "claimId", "deviceId", "claimSha256", "proofKeyThumbprint",
        "wrappingKeyThumbprint", "bundleId", "generation", "bundleSha256", "sealedAt",
        "revealExpiresAt",
    };

    private static readonly byte[] P256Order = Convert.FromHexString(
        "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");

    private static readonly byte[] P256HalfOrder = Convert.FromHexString(
        "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8");

    private static readonly byte[] ZeroScalar = new byte[32];

    /// <summary>Builds the ES256 profile for a device proof key.</summary>
    public static DeviceEnrollmentPublicKey ProofKeyProfile(byte[] x963)
    {
        RequireCanonicalP256(x963);
        return DeviceEnrollmentPublicKey.Proof(EnrollmentEncoding.EncodeBase64Url(x963));
    }

    /// <summary>Builds the ECDH-ES profile for a device wrapping key.</summary>
    public static DeviceEnrollmentPublicKey WrappingKeyProfile(byte[] x963)
    {
        RequireCanonicalP256(x963);
        return DeviceEnrollmentPublicKey.Wrapping(EnrollmentEncoding.EncodeBase64Url(x963));
    }

    /// <summary>Builds and signs the exact canonical claim bytes.</summary>
    /// <exception cref="DeviceBoundEnrollmentException">The claim or the signer is unusable.</exception>
    public static byte[] MakeClaim(DeviceEnrollmentClaimPayload payload, IDeviceEnrollmentProofSigner proofSigner)
    {
        byte[] payloadBytes = CanonicalPayload(payload);
        byte[] expected = DecodeP256Point(payload.ProofKey.PublicKey);
        if (!EnrollmentEncoding.ConstantTimeEquals(expected, proofSigner.PublicKeyX963))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        byte[] signature = proofSigner.SignRaw(Concat(ClaimProofDomain, payloadBytes));
        byte[] lowS = NormalizeLowS(signature);
        byte[]? envelope = EnrollmentEncoding.TryCanonicalJson(new JsonObject
        {
            ["payload"] = EnrollmentEncoding.EncodeBase64Url(payloadBytes),
            ["proof"] = EnrollmentEncoding.EncodeBase64Url(lowS),
        });
        return envelope ?? throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedClaim);
    }

    /// <summary>Verifies a claim envelope's proof of possession and derives its binding.</summary>
    /// <exception cref="DeviceBoundEnrollmentException">The claim was refused.</exception>
    public static VerifiedDeviceEnrollmentClaim VerifyClaim(byte[] envelopeBytes)
    {
        if (envelopeBytes.Length == 0 || envelopeBytes.Length > 20_000)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedClaim);
        }

        JsonObject? envelope = StrictJson.TryParseCanonicalObject(envelopeBytes);
        if (envelope is null || !StrictJson.HasExactlyKeys(envelope, ClaimEnvelopeKeys))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedClaim);
        }

        byte[]? payloadBytes = EnrollmentEncoding.DecodeBase64Url(
            StrictJson.StringOrNull(envelope, "payload"),
            maximumBytes: 8_192);
        byte[]? proof = EnrollmentEncoding.DecodeBase64Url(
            StrictJson.StringOrNull(envelope, "proof"),
            maximumBytes: 64);
        if (payloadBytes is null || proof is null || proof.Length != 64)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedClaim);
        }

        DeviceEnrollmentClaimPayload payload = DecodePayload(payloadBytes);
        RequireCanonicalLowS(proof);

        byte[] proofPoint = DecodeP256Point(payload.ProofKey.PublicKey);
        using ECDsa verifier = CreateEcdsa(proofPoint);
        if (!verifier.VerifyData(
                Concat(ClaimProofDomain, payloadBytes),
                proof,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.IeeeP1363FixedFieldConcatenation))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaimProof);
        }

        return new VerifiedDeviceEnrollmentClaim(
            payload,
            new DeviceEnrollmentClaimBinding(
                payload.BootstrapId,
                payload.ClaimId,
                payload.DeviceId,
                EnrollmentEncoding.HexSha256(payloadBytes),
                payload.ProofKey.PublicKey,
                KeyThumbprint(payload.ProofKey.PublicKey),
                payload.WrappingKey.PublicKey,
                KeyThumbprint(payload.WrappingKey.PublicKey)),
            payloadBytes,
            envelopeBytes);
    }

    /// <summary>Strictly inspects the authenticated-context candidate before opening.</summary>
    /// <exception cref="DeviceBoundEnrollmentException">The envelope is malformed.</exception>
    public static DeviceBundleSealInspection InspectSealedBundle(byte[] wireBytes)
    {
        ParsedSealedBundle parsed = ParseSealedBundle(wireBytes);
        string? bundleId = StrictJson.StringOrNull(parsed.Context, "bundleId");
        long? generation = StrictJson.IntegerOrNull(parsed.Context, "generation");
        string? sealedAt = StrictJson.StringOrNull(parsed.Context, "sealedAt");
        string? revealExpiresAt = StrictJson.StringOrNull(parsed.Context, "revealExpiresAt");
        string? bundleSha256 = StrictJson.StringOrNull(parsed.Context, "bundleSha256");
        if (bundleId is null || generation is null || sealedAt is null
            || revealExpiresAt is null || bundleSha256 is null)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidProtectedContext);
        }

        return new DeviceBundleSealInspection(
            new DeviceBundleSealDescriptor(bundleId, generation.Value, sealedAt, revealExpiresAt),
            bundleSha256);
    }

    /// <summary>Opens a sealed device bundle bound to this device's exact claim.</summary>
    /// <exception cref="DeviceBoundEnrollmentException">The envelope was refused.</exception>
    public static byte[] OpenSealedBundle(
        byte[] wireBytes,
        IDeviceEnrollmentKeyAgreement wrappingKey,
        DeviceEnrollmentClaimBinding binding,
        DeviceBundleSealDescriptor descriptor,
        DateTimeOffset now)
    {
        byte[] expectedRecipient = DecodeP256Point(binding.WrappingPublicKey);
        if (!EnrollmentEncoding.ConstantTimeEquals(expectedRecipient, wrappingKey.PublicKeyX963))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.WrongRecipient);
        }

        ParsedSealedBundle parsed = ParseSealedBundle(wireBytes);
        RequireContext(parsed.Context, binding, descriptor);

        DateTimeOffset? expiry = ParseSecondsTimestamp(
            StrictJson.StringOrNull(parsed.Context, "revealExpiresAt"));
        if (expiry is null || now.AddSeconds(-30) >= expiry)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.Expired);
        }

        byte[] aad = Concat(SealAadDomain, Utf8(parsed.ProtectedSegment));
        byte[] info = Concat(SealKdfDomain, SHA256.HashData(aad));

        byte[] key;
        try
        {
            key = wrappingKey.DeriveSymmetricKey(parsed.EphemeralPublicKey, parsed.Salt, info);
        }
        catch (Exception ex) when (ex is not DeviceBoundEnrollmentException)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.AuthenticationFailed);
        }

        if (key.Length != 32)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.AuthenticationFailed);
        }

        var plaintext = new byte[parsed.Ciphertext.Length];
        try
        {
            using var aes = new AesGcm(key, tagSizeInBytes: 16);
            aes.Decrypt(parsed.Iv, parsed.Ciphertext, parsed.Tag, plaintext, aad);
        }
        catch (CryptographicException)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.AuthenticationFailed);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }

        string? expectedDigest = StrictJson.StringOrNull(parsed.Context, "bundleSha256");
        byte[]? expectedDigestBytes = expectedDigest is null
            ? null
            : EnrollmentEncoding.TryDecodeHex(expectedDigest);
        if (plaintext.Length > 131_072
            || expectedDigestBytes is null
            || !EnrollmentEncoding.ConstantTimeEquals(SHA256.HashData(plaintext), expectedDigestBytes))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.DigestMismatch);
        }

        return plaintext;
    }

    /// <summary>RFC 7638-style thumbprint of an X9.63 P-256 public key.</summary>
    public static string KeyThumbprint(string encodedPublicKey)
    {
        byte[] raw = DecodeP256Point(encodedPublicKey);
        var jwk = new JsonObject
        {
            ["crv"] = "P-256",
            ["kty"] = "EC",
            ["x"] = EnrollmentEncoding.EncodeBase64Url(raw.AsSpan(1, 32)),
            ["y"] = EnrollmentEncoding.EncodeBase64Url(raw.AsSpan(33, 32)),
        };
        byte[] canonical = EnrollmentEncoding.TryCanonicalJson(jwk)
            ?? throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        return EnrollmentEncoding.EncodeBase64Url(SHA256.HashData(canonical));
    }

    /// <summary>
    /// Decodes and validates an X9.63 uncompressed P-256 point.
    /// </summary>
    /// <remarks>
    /// Compressed and hybrid encodings are refused outright rather than decoded, so the byte string
    /// in a signed document has exactly one meaning. The point is then checked against the curve
    /// equation, which is what stops an invalid-curve attack on the ECDH that follows.
    /// </remarks>
    public static byte[] DecodeP256Point(string encoded)
    {
        byte[] raw = EnrollmentEncoding.DecodeBase64Url(encoded, maximumBytes: 65)
            ?? throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        RequireCanonicalP256(raw);
        return raw;
    }

    /// <summary>Creates an ECDsa handle over a validated X9.63 public point.</summary>
    public static ECDsa CreateEcdsa(byte[] x963)
    {
        RequireCanonicalP256(x963);
        try
        {
            return ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = x963[1..33], Y = x963[33..65] },
            });
        }
        catch (CryptographicException)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }
    }

    /// <summary>Reduces a raw ECDSA signature to its canonical low-S form.</summary>
    public static byte[] NormalizeLowS(byte[] signature)
    {
        if (signature.Length != 64)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaimProof);
        }

        byte[] normalized = new byte[64];
        signature.AsSpan(0, 32).CopyTo(normalized);
        byte[] s = signature[32..64];
        if (Compare(s, P256HalfOrder) > 0)
        {
            s = Subtract(P256Order, s);
        }

        s.CopyTo(normalized.AsSpan(32));
        RequireCanonicalLowS(normalized);
        return normalized;
    }

    private static byte[] CanonicalPayload(DeviceEnrollmentClaimPayload payload)
    {
        byte[] canonical = EnrollmentEncoding.TryCanonicalJson(payload.ToJson())
            ?? throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);

        // Round-tripping through the strict decoder means an invalid claim can never be produced,
        // only refused: the encoder and the verifier apply exactly one set of rules.
        _ = DecodePayload(canonical);
        return canonical;
    }

    private static DeviceEnrollmentClaimPayload DecodePayload(byte[] data)
    {
        if (data.Length == 0 || data.Length > 8_192)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        JsonObject? payload = StrictJson.TryParseCanonicalObject(data);
        if (payload is null || !StrictJson.HasExactlyKeys(payload, ClaimPayloadKeys))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        JsonObject? proofObject = StrictJson.ObjectOrNull(payload, "proofKey");
        JsonObject? wrappingObject = StrictJson.ObjectOrNull(payload, "wrappingKey");
        if (proofObject is null || wrappingObject is null
            || !StrictJson.HasExactlyKeys(proofObject, KeyKeys)
            || !StrictJson.HasExactlyKeys(wrappingObject, KeyKeys))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        DeviceEnrollmentPublicKey proofKey = DecodePublicKey(proofObject);
        DeviceEnrollmentPublicKey wrappingKey = DecodePublicKey(wrappingObject);
        long? schemaVersion = StrictJson.IntegerOrNull(payload, "schemaVersion");
        string? kind = StrictJson.StringOrNull(payload, "kind");
        string? bootstrapId = StrictJson.StringOrNull(payload, "bootstrapId");
        string? claimId = StrictJson.StringOrNull(payload, "claimId");
        string? deviceId = StrictJson.StringOrNull(payload, "deviceId");
        string? issuedAtText = StrictJson.StringOrNull(payload, "issuedAt");
        string? expiresAtText = StrictJson.StringOrNull(payload, "expiresAt");
        if (schemaVersion is null || kind is null || bootstrapId is null || claimId is null
            || deviceId is null || issuedAtText is null || expiresAtText is null)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        DateTimeOffset? issuedAt = ParseSecondsTimestamp(issuedAtText);
        DateTimeOffset? expiresAt = ParseSecondsTimestamp(expiresAtText);
        bool valid =
            schemaVersion == DeviceEnrollmentClaimPayload.ExpectedSchemaVersion
            && kind == DeviceEnrollmentClaimPayload.ExpectedKind
            && BootstrapIdPattern().IsMatch(bootstrapId)
            && ClaimIdPattern().IsMatch(claimId)
            && DeviceIdPattern().IsMatch(deviceId)
            && issuedAt is not null
            && expiresAt is not null
            && expiresAt > issuedAt
            && (expiresAt.Value - issuedAt.Value) <= TimeSpan.FromSeconds(300)
            && proofKey is { Kty: "EC", Crv: "P-256", Format: "X9.63", Alg: "ES256", Use: "sig" }
            && wrappingKey is { Kty: "EC", Crv: "P-256", Format: "X9.63", Alg: "ECDH-ES", Use: "enc" }
            && proofKey.PublicKey != wrappingKey.PublicKey;
        if (!valid)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        // Both points are decoded and curve-checked here, not lazily at first use.
        _ = DecodeP256Point(proofKey.PublicKey);
        _ = DecodeP256Point(wrappingKey.PublicKey);

        return new DeviceEnrollmentClaimPayload(
            bootstrapId, claimId, deviceId, issuedAtText, expiresAtText, proofKey, wrappingKey)
        {
            SchemaVersion = schemaVersion.Value,
            Kind = kind,
        };
    }

    private static DeviceEnrollmentPublicKey DecodePublicKey(JsonObject value)
    {
        string?[] fields =
        {
            StrictJson.StringOrNull(value, "kty"),
            StrictJson.StringOrNull(value, "crv"),
            StrictJson.StringOrNull(value, "format"),
            StrictJson.StringOrNull(value, "alg"),
            StrictJson.StringOrNull(value, "use"),
            StrictJson.StringOrNull(value, "publicKey"),
        };
        if (Array.Exists(fields, field => field is null))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        return new DeviceEnrollmentPublicKey(fields[0]!, fields[1]!, fields[2]!, fields[3]!, fields[4]!, fields[5]!);
    }

    private sealed record ParsedSealedBundle(
        string ProtectedSegment,
        byte[] Salt,
        byte[] EphemeralPublicKey,
        JsonObject Context,
        byte[] Iv,
        byte[] Ciphertext,
        byte[] Tag);

    private static ParsedSealedBundle ParseSealedBundle(byte[] wireBytes)
    {
        if (wireBytes.Length == 0 || wireBytes.Length > 200_000)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedSealedBundle);
        }

        JsonObject? envelope = StrictJson.TryParseCanonicalObject(wireBytes);
        if (envelope is null || !StrictJson.HasExactlyKeys(envelope, SealedEnvelopeKeys))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedSealedBundle);
        }

        string? protectedSegment = StrictJson.StringOrNull(envelope, "protected");
        byte[]? protectedBytes = protectedSegment is { Length: <= 16_384 }
            ? EnrollmentEncoding.DecodeBase64Url(protectedSegment, maximumBytes: 12_288)
            : null;
        if (protectedSegment is null || protectedBytes is null)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedSealedBundle);
        }

        JsonObject? protectedHeader = StrictJson.TryParseCanonicalObject(protectedBytes);
        if (protectedHeader is null || !StrictJson.HasExactlyKeys(protectedHeader, ProtectedKeys))
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedSealedBundle);
        }

        JsonObject? ephemeral = StrictJson.ObjectOrNull(protectedHeader, "epk");
        JsonObject? context = StrictJson.ObjectOrNull(protectedHeader, "context");
        byte[]? salt = EnrollmentEncoding.DecodeBase64Url(
            StrictJson.StringOrNull(protectedHeader, "salt"),
            maximumBytes: 32);
        bool headerValid =
            StrictJson.StringOrNull(protectedHeader, "alg") == "ECDH-ES"
            && StrictJson.StringOrNull(protectedHeader, "enc") == "A256GCM"
            && StrictJson.StringOrNull(protectedHeader, "kdf") == "HKDF-SHA256"
            && StrictJson.StringOrNull(protectedHeader, "typ")
                == "application/jazz-device-enrollment-sealed+json"
            && StrictJson.StringOrNull(protectedHeader, "cty") == "application/jazz-device-bundle+jws"
            && salt is { Length: 32 }
            && ephemeral is not null
            && StrictJson.HasExactlyKeys(ephemeral, EphemeralKeyKeys)
            && StrictJson.StringOrNull(ephemeral, "kty") == "EC"
            && StrictJson.StringOrNull(ephemeral, "crv") == "P-256"
            && StrictJson.StringOrNull(ephemeral, "format") == "X9.63"
            && context is not null
            && StrictJson.HasExactlyKeys(context, ContextKeys);
        if (!headerValid)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedSealedBundle);
        }

        byte[]? ephemeralPublicKey = EnrollmentEncoding.DecodeBase64Url(
            StrictJson.StringOrNull(ephemeral!, "publicKey"),
            maximumBytes: 65);
        byte[]? iv = EnrollmentEncoding.DecodeBase64Url(StrictJson.StringOrNull(envelope, "iv"), maximumBytes: 12);
        byte[]? ciphertext = EnrollmentEncoding.DecodeBase64Url(
            StrictJson.StringOrNull(envelope, "ciphertext"),
            maximumBytes: 131_072);
        byte[]? tag = EnrollmentEncoding.DecodeBase64Url(StrictJson.StringOrNull(envelope, "tag"), maximumBytes: 16);
        if (ephemeralPublicKey is not { Length: 65 }
            || ephemeralPublicKey[0] != 0x04
            || iv is not { Length: 12 }
            || ciphertext is not { Length: > 0 }
            || tag is not { Length: 16 })
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedSealedBundle);
        }

        try
        {
            RequireCanonicalP256(ephemeralPublicKey);
        }
        catch (DeviceBoundEnrollmentException)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidProtectedContext);
        }

        ValidateContext(context!);
        return new ParsedSealedBundle(
            protectedSegment, salt!, ephemeralPublicKey, context!, iv, ciphertext, tag);
    }

    private static void ValidateContext(JsonObject context)
    {
        string? bootstrapId = StrictJson.StringOrNull(context, "bootstrapId");
        string? claimId = StrictJson.StringOrNull(context, "claimId");
        string? deviceId = StrictJson.StringOrNull(context, "deviceId");
        string? claimDigest = StrictJson.StringOrNull(context, "claimSha256");
        string? proofThumbprint = StrictJson.StringOrNull(context, "proofKeyThumbprint");
        string? wrappingThumbprint = StrictJson.StringOrNull(context, "wrappingKeyThumbprint");
        string? bundleId = StrictJson.StringOrNull(context, "bundleId");
        long? generation = StrictJson.IntegerOrNull(context, "generation");
        string? bundleDigest = StrictJson.StringOrNull(context, "bundleSha256");
        DateTimeOffset? sealedAt = ParseSecondsTimestamp(StrictJson.StringOrNull(context, "sealedAt"));
        DateTimeOffset? expiresAt = ParseSecondsTimestamp(StrictJson.StringOrNull(context, "revealExpiresAt"));

        bool valid =
            bootstrapId is not null && BootstrapIdPattern().IsMatch(bootstrapId)
            && claimId is not null && ClaimIdPattern().IsMatch(claimId)
            && deviceId is not null && DeviceIdPattern().IsMatch(deviceId)
            && claimDigest is not null && Sha256Pattern().IsMatch(claimDigest)
            && EnrollmentEncoding.DecodeBase64Url(proofThumbprint, maximumBytes: 32)?.Length == 32
            && EnrollmentEncoding.DecodeBase64Url(wrappingThumbprint, maximumBytes: 32)?.Length == 32
            && bundleId is not null && BundleIdPattern().IsMatch(bundleId)
            && generation is >= 1 and <= 9_007_199_254_740_991
            && bundleDigest is not null && Sha256Pattern().IsMatch(bundleDigest)
            && sealedAt is not null
            && expiresAt is not null
            && expiresAt > sealedAt
            && (expiresAt.Value - sealedAt.Value) <= TimeSpan.FromSeconds(900);
        if (!valid)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidProtectedContext);
        }
    }

    private static void RequireContext(
        JsonObject context,
        DeviceEnrollmentClaimBinding binding,
        DeviceBundleSealDescriptor descriptor)
    {
        bool matches =
            StrictJson.StringOrNull(context, "bootstrapId") == binding.BootstrapId
            && StrictJson.StringOrNull(context, "claimId") == binding.ClaimId
            && StrictJson.StringOrNull(context, "deviceId") == binding.DeviceId
            && StrictJson.StringOrNull(context, "claimSha256") == binding.ClaimSha256
            && StrictJson.StringOrNull(context, "proofKeyThumbprint") == binding.ProofKeyThumbprint
            && StrictJson.StringOrNull(context, "wrappingKeyThumbprint") == binding.WrappingKeyThumbprint
            && StrictJson.StringOrNull(context, "bundleId") == descriptor.BundleId
            && StrictJson.IntegerOrNull(context, "generation") == descriptor.Generation
            && StrictJson.StringOrNull(context, "sealedAt") == descriptor.SealedAt
            && StrictJson.StringOrNull(context, "revealExpiresAt") == descriptor.RevealExpiresAt;
        if (!matches)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.ContextMismatch);
        }
    }

    private static void RequireCanonicalLowS(byte[] signature)
    {
        if (signature.Length != 64)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaimProof);
        }

        byte[] r = signature[0..32];
        byte[] s = signature[32..64];
        bool canonical = !r.AsSpan().SequenceEqual(ZeroScalar)
            && !s.AsSpan().SequenceEqual(ZeroScalar)
            && Compare(r, P256Order) < 0
            && Compare(s, P256HalfOrder) <= 0;
        if (!canonical)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.NonCanonicalSignature);
        }
    }

    private static void RequireCanonicalP256(byte[] raw)
    {
        if (raw.Length != 65 || raw[0] != 0x04)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        try
        {
            X9ECParameters curve = CustomNamedCurves.GetByName("P-256");
            Org.BouncyCastle.Math.EC.ECPoint point = curve.Curve.DecodePoint(raw);
            if (!point.IsValid() || point.IsInfinity)
            {
                throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
            }
        }
        catch (Exception ex) when (ex is ArgumentException or FormatException or ArithmeticException)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }
    }

    private static byte[] Subtract(byte[] left, byte[] right)
    {
        var result = new byte[left.Length];
        int borrow = 0;
        for (int i = left.Length - 1; i >= 0; i--)
        {
            int value = left[i] - right[i] - borrow;
            if (value < 0)
            {
                value += 256;
                borrow = 1;
            }
            else
            {
                borrow = 0;
            }

            result[i] = (byte)value;
        }

        return result;
    }

    private static int Compare(byte[] left, byte[] right)
    {
        for (int i = 0; i < left.Length && i < right.Length; i++)
        {
            if (left[i] < right[i])
            {
                return -1;
            }

            if (left[i] > right[i])
            {
                return 1;
            }
        }

        return 0;
    }

    private static DateTimeOffset? ParseSecondsTimestamp(string? value) =>
        value is not null && SecondsTimestampPattern().IsMatch(value)
            ? Timestamps.TryParseRfc3339(value)
            : null;

    private static byte[] Concat(byte[] left, byte[] right)
    {
        var result = new byte[left.Length + right.Length];
        left.CopyTo(result, 0);
        right.CopyTo(result, left.Length);
        return result;
    }

    private static byte[] Utf8(string value) => new UTF8Encoding(false).GetBytes(value);

    [GeneratedRegex("^jbt_[a-f0-9]{32}$")]
    private static partial Regex BootstrapIdPattern();

    [GeneratedRegex("^jcl_[a-f0-9]{32}$")]
    private static partial Regex ClaimIdPattern();

    [GeneratedRegex("^jdb_[a-f0-9]{32}$")]
    private static partial Regex BundleIdPattern();

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,63}$")]
    private static partial Regex DeviceIdPattern();

    [GeneratedRegex("^[a-f0-9]{64}$")]
    private static partial Regex Sha256Pattern();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")]
    private static partial Regex SecondsTimestampPattern();
}
