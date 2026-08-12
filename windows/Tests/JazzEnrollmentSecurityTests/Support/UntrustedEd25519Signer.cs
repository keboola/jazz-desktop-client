using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

namespace JazzEnrollmentSecurityTests.Support;

/// <summary>
/// A second, perfectly valid Ed25519 key that the trust policy has never heard of.
/// </summary>
/// <remarks>
/// A corrupted signature only proves the verifier can spot corruption. A well-formed signature from
/// the wrong key is the interesting case: it proves the anchor set, not the document, decides.
/// </remarks>
public sealed class UntrustedEd25519Signer : IDisposable
{
    private readonly Ed25519PrivateKeyParameters privateKey;

    public UntrustedEd25519Signer()
    {
        var seed = new byte[32];
        new SecureRandom().NextBytes(seed);
        privateKey = new Ed25519PrivateKeyParameters(seed);
    }

    /// <summary>Base64url of this key's public point.</summary>
    public string PublicKeyBase64Url =>
        JazzEnrollmentSecurity.EnrollmentEncoding.EncodeBase64Url(privateKey.GeneratePublicKey().GetEncoded());

    /// <summary>Signs <paramref name="message"/> with the untrusted key.</summary>
    public byte[] Sign(byte[] message)
    {
        var signer = new Ed25519Signer();
        signer.Init(true, privateKey);
        signer.BlockUpdate(message, 0, message.Length);
        return signer.GenerateSignature();
    }

    public void Dispose()
    {
        // Nothing native to release; IDisposable keeps the call sites uniform with the harness.
    }
}
