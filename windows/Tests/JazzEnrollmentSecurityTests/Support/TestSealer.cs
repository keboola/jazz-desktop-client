using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;

namespace JazzEnrollmentSecurityTests.Support;

/// <summary>
/// Builds a sealed device bundle the way the server does, so an identity can be shown to open one
/// addressed to its own wrapping key.
/// </summary>
/// <remarks>
/// This is a second, independent implementation of the seal side. The contract fixture already
/// proves the reader agrees with the server; this proves it agrees with a writer that only follows
/// the written rules, which is what catches a rule the reader has quietly stopped enforcing.
/// </remarks>
public static class TestSealer
{
    /// <summary>Seals <paramref name="plaintext"/> for the wrapping key named in <paramref name="binding"/>.</summary>
    public static byte[] Seal(
        byte[] plaintext,
        DeviceEnrollmentClaimBinding binding,
        DeviceBundleSealDescriptor descriptor)
    {
        using ECDiffieHellman ephemeral = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        byte[] ephemeralPoint = ephemeral.ExportParameters(false).Q.ToX963();
        byte[] salt = Enumerable.Repeat((byte)0x5a, 32).ToArray();
        byte[] iv = Enumerable.Repeat((byte)0xa5, 12).ToArray();

        var context = new JsonObject
        {
            ["bootstrapId"] = binding.BootstrapId,
            ["claimId"] = binding.ClaimId,
            ["deviceId"] = binding.DeviceId,
            ["claimSha256"] = binding.ClaimSha256,
            ["proofKeyThumbprint"] = binding.ProofKeyThumbprint,
            ["wrappingKeyThumbprint"] = binding.WrappingKeyThumbprint,
            ["bundleId"] = descriptor.BundleId,
            ["generation"] = descriptor.Generation,
            ["bundleSha256"] = EnrollmentEncoding.HexSha256(plaintext),
            ["sealedAt"] = descriptor.SealedAt,
            ["revealExpiresAt"] = descriptor.RevealExpiresAt,
        };
        var protectedHeader = new JsonObject
        {
            ["alg"] = "ECDH-ES",
            ["enc"] = "A256GCM",
            ["kdf"] = "HKDF-SHA256",
            ["typ"] = "application/jazz-device-enrollment-sealed+json",
            ["cty"] = "application/jazz-device-bundle+jws",
            ["salt"] = EnrollmentEncoding.EncodeBase64Url(salt),
            ["epk"] = new JsonObject
            {
                ["kty"] = "EC",
                ["crv"] = "P-256",
                ["format"] = "X9.63",
                ["publicKey"] = EnrollmentEncoding.EncodeBase64Url(ephemeralPoint),
            },
            ["context"] = context,
        };

        string protectedSegment = EnrollmentEncoding.EncodeBase64Url(
            EnrollmentContract.Canonical(protectedHeader));
        byte[] aad = Concat(
            DeviceBoundEnrollmentCrypto.SealAadDomain,
            new UTF8Encoding(false).GetBytes(protectedSegment));
        byte[] info = Concat(DeviceBoundEnrollmentCrypto.SealKdfDomain, SHA256.HashData(aad));

        byte[] recipientPoint = DeviceBoundEnrollmentCrypto.DecodeP256Point(binding.WrappingPublicKey);
        using ECDiffieHellman recipient = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = recipientPoint[1..33], Y = recipientPoint[33..65] },
        });

        byte[] secret = ephemeral.DeriveRawSecretAgreement(recipient.PublicKey);
        byte[] key = HKDF.DeriveKey(HashAlgorithmName.SHA256, secret, outputLength: 32, salt, info);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(key, tagSizeInBytes: 16))
        {
            aes.Encrypt(iv, plaintext, ciphertext, tag, aad);
        }

        return EnrollmentContract.Canonical(new JsonObject
        {
            ["protected"] = protectedSegment,
            ["iv"] = EnrollmentEncoding.EncodeBase64Url(iv),
            ["ciphertext"] = EnrollmentEncoding.EncodeBase64Url(ciphertext),
            ["tag"] = EnrollmentEncoding.EncodeBase64Url(tag),
        });
    }

    private static byte[] Concat(byte[] left, byte[] right)
    {
        var result = new byte[left.Length + right.Length];
        left.CopyTo(result, 0);
        right.CopyTo(result, left.Length);
        return result;
    }
}
