using System.Security.Cryptography;

namespace JazzEnrollmentSecurity;

/// <summary>
/// DEVELOPMENT ONLY. A P-256 key pair held in ordinary process memory and persisted as a plaintext
/// private scalar. This is NOT a security boundary and must never ship to a user's machine.
/// </summary>
/// <remarks>
/// <para>
/// The macOS client seals its device identity to the hardware: both keys live in the Secure Enclave
/// and only opaque, device-bound references are persisted. The Windows counterpart is CNG with a
/// TPM-backed or at minimum DPAPI-protected key, which is host code that cannot be written or
/// verified without a real Windows machine. Until that exists, this backend stands in so the module
/// is usable and testable end to end.
/// </para>
/// <para>
/// What it gives up is everything the real one provides. The private scalar is exportable, it is
/// written to the identity store in the clear, and copying that store to another machine copies the
/// device identity with it - which is precisely the attack ADR 0004 exists to prevent. Nothing here
/// resists an attacker who can read the user's profile.
/// </para>
/// <para>
/// The backend records itself in the persisted identity under the identifier
/// <see cref="BackendIdentifier"/>, which contains the word INSECURE. A vault configured with a real
/// hardware backend refuses to load a record written by this one, so a development identity can
/// never be silently promoted into a production install.
/// </para>
/// </remarks>
public sealed class DevelopmentUnprotectedKeyBackend : IDeviceEnrollmentKeyBackend
{
    /// <summary>
    /// The backend name stamped into every identity this backend creates. It says INSECURE because
    /// anything that reads the persisted record should be able to tell at a glance.
    /// </summary>
    public const string BackendIdentifier = "development-unprotected-software-p256-INSECURE-v1";

    /// <inheritdoc />
    public string Identifier => BackendIdentifier;

    /// <summary>
    /// Always <see langword="false"/>. The vault refuses this backend unless the caller has
    /// explicitly opted in to unprotected development keys.
    /// </summary>
    public bool IsHardwareBacked => false;

    /// <inheritdoc />
    public DeviceEnrollmentKeyPair Generate()
    {
        using ECDsa proof = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using ECDiffieHellman wrapping = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        return Restore(
            proof.ExportECPrivateKey(),
            wrapping.ExportECPrivateKey());
    }

    /// <inheritdoc />
    public DeviceEnrollmentKeyPair Restore(byte[] proofReference, byte[] wrappingReference)
    {
        // "Reference" is a euphemism here: for this backend the stored bytes are the private key
        // itself, which is exactly why it is not a security boundary.
        var proof = new DevelopmentUnprotectedProofSigner(proofReference);
        var wrapping = new DevelopmentUnprotectedKeyAgreement(wrappingReference);
        return new DeviceEnrollmentKeyPair(proofReference, wrappingReference, proof, wrapping);
    }
}

/// <summary>DEVELOPMENT ONLY software ES256 signer over an exportable private key.</summary>
public sealed class DevelopmentUnprotectedProofSigner : IDeviceEnrollmentProofSigner
{
    private readonly byte[] privateKey;

    /// <summary>Wraps an SEC1 private key. The bytes are the secret, not a handle to one.</summary>
    public DevelopmentUnprotectedProofSigner(byte[] sec1PrivateKey)
    {
        privateKey = sec1PrivateKey;
        using ECDsa key = Load();
        PublicKeyX963 = key.ExportParameters(includePrivateParameters: false).Q.ToX963();
    }

    /// <inheritdoc />
    public byte[] PublicKeyX963 { get; }

    /// <inheritdoc />
    public byte[] SignRaw(byte[] message)
    {
        using ECDsa key = Load();
        return key.SignData(
            message,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    private ECDsa Load()
    {
        ECDsa key = ECDsa.Create();
        key.ImportECPrivateKey(privateKey, out _);
        return key;
    }
}

/// <summary>DEVELOPMENT ONLY software ECDH-ES agreement over an exportable private key.</summary>
public sealed class DevelopmentUnprotectedKeyAgreement : IDeviceEnrollmentKeyAgreement
{
    private readonly byte[] privateKey;

    /// <summary>Wraps an SEC1 private key. The bytes are the secret, not a handle to one.</summary>
    public DevelopmentUnprotectedKeyAgreement(byte[] sec1PrivateKey)
    {
        privateKey = sec1PrivateKey;
        using ECDiffieHellman key = Load();
        PublicKeyX963 = key.ExportParameters(includePrivateParameters: false).Q.ToX963();
    }

    /// <inheritdoc />
    public byte[] PublicKeyX963 { get; }

    /// <inheritdoc />
    public byte[] DeriveSymmetricKey(byte[] peerPublicKeyX963, byte[] salt, byte[] sharedInfo)
    {
        byte[] point = peerPublicKeyX963;
        if (point.Length != 65 || point[0] != 0x04)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.MalformedSealedBundle);
        }

        using ECDiffieHellman key = Load();
        using ECDiffieHellman peer = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = point[1..33], Y = point[33..65] },
        });

        byte[] secret = key.DeriveRawSecretAgreement(peer.PublicKey);
        try
        {
            return HKDF.DeriveKey(HashAlgorithmName.SHA256, secret, outputLength: 32, salt, sharedInfo);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secret);
        }
    }

    private ECDiffieHellman Load()
    {
        ECDiffieHellman key = ECDiffieHellman.Create();
        key.ImportECPrivateKey(privateKey, out _);
        return key;
    }
}

/// <summary>Conversions between .NET's split coordinates and the X9.63 encoding the contract uses.</summary>
public static class EcPointExtensions
{
    /// <summary>The uncompressed X9.63 encoding <c>0x04 || X || Y</c> of a P-256 point.</summary>
    public static byte[] ToX963(this ECPoint point)
    {
        byte[] x = point.X ?? throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        byte[] y = point.Y ?? throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        if (x.Length != 32 || y.Length != 32)
        {
            throw new DeviceBoundEnrollmentException(DeviceBoundEnrollmentError.InvalidClaim);
        }

        var encoded = new byte[65];
        encoded[0] = 0x04;
        x.CopyTo(encoded, 1);
        y.CopyTo(encoded, 33);
        return encoded;
    }
}
