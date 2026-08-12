using System.Security.Cryptography;
using JazzEnrollmentSecurity;
using Org.BouncyCastle.Asn1.X9;
using Org.BouncyCastle.Crypto.EC;
using Org.BouncyCastle.Math;

namespace JazzEnrollmentSecurityTests.Support;

/// <summary>
/// Rebuilds a P-256 key from the raw private scalar the shared contract fixture ships.
/// </summary>
/// <remarks>
/// The vectors were generated from fixed scalars (1, 2, 3) so the sealed bundle is reproducible on
/// every platform. .NET cannot import a scalar without its public point, so the point is recomputed
/// here rather than copied into the test - if the recomputation were wrong, nothing would decrypt.
/// </remarks>
public static class P256TestKeys
{
    private static readonly X9ECParameters Curve = CustomNamedCurves.GetByName("P-256");

    /// <summary>SEC1 private key bytes for the 32-byte big-endian scalar in <paramref name="rawScalar"/>.</summary>
    public static byte[] Sec1PrivateKey(byte[] rawScalar)
    {
        if (rawScalar.Length != 32)
        {
            throw new ArgumentException("A P-256 scalar is 32 bytes.", nameof(rawScalar));
        }

        var d = new BigInteger(1, rawScalar);
        Org.BouncyCastle.Math.EC.ECPoint q = Curve.G.Multiply(d).Normalize();
        byte[] x963 = q.GetEncoded(false);

        using ECDsa key = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            D = rawScalar,
            Q = new System.Security.Cryptography.ECPoint { X = x963[1..33], Y = x963[33..65] },
        });
        return key.ExportECPrivateKey();
    }

    /// <summary>SEC1 private key bytes for a base64url-encoded 32-byte scalar.</summary>
    public static byte[] Sec1PrivateKeyFromBase64Url(string encodedScalar) =>
        Sec1PrivateKey(EnrollmentEncoding.DecodeBase64Url(encodedScalar, maximumBytes: 32)
            ?? throw new ArgumentException("Not a 32-byte base64url scalar.", nameof(encodedScalar)));

    /// <summary>A development proof signer over the fixture's scalar.</summary>
    public static DevelopmentUnprotectedProofSigner ProofSigner(string encodedScalar) =>
        new(Sec1PrivateKeyFromBase64Url(encodedScalar));

    /// <summary>A development key agreement over the fixture's scalar.</summary>
    public static DevelopmentUnprotectedKeyAgreement KeyAgreement(string encodedScalar) =>
        new(Sec1PrivateKeyFromBase64Url(encodedScalar));

    /// <summary>A fresh, random development key agreement standing in for a second machine.</summary>
    public static DevelopmentUnprotectedKeyAgreement RandomKeyAgreement()
    {
        using ECDiffieHellman key = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        return new DevelopmentUnprotectedKeyAgreement(key.ExportECPrivateKey());
    }
}
