using System.Text;
using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace JazzEnrollmentSecurityTests.Support;

/// <summary>
/// A throwaway ledger plus the RFC 8032 test key, so a negative vector can be re-signed rather than
/// merely corrupted.
/// </summary>
/// <remarks>
/// A tampered-but-unsigned bundle proves very little: it would be rejected by the signature check
/// whatever the payload said. The interesting negatives are the ones that carry a <em>valid</em>
/// signature over a payload the policy must still refuse, and those need the private seed.
/// </remarks>
public sealed class SignedEnrollmentHarness : IDisposable
{
    private readonly Ed25519PrivateKeyParameters privateKey;

    public SignedEnrollmentHarness(bool includeTrustAnchor = true)
    {
        JsonObject key = ReadTestKey();
        KeyId = key["kid"]!.GetValue<string>();
        privateKey = new Ed25519PrivateKeyParameters(
            Convert.FromHexString(key["privateKeySeedHex"]!.GetValue<string>()));
        PublicKeyBase64Url = EnrollmentEncoding.EncodeBase64Url(privateKey.GeneratePublicKey().GetEncoded());

        Root = Path.Combine(Path.GetTempPath(), "jazz-enrollment-security-" + Guid.NewGuid().ToString("N"));
        Store = new FileEnrollmentAcceptanceStore(Path.Combine(Root, "acceptance.json"));
        TrustPolicy = new EnrollmentTrustPolicy(
            "https://jazz.example.test",
            "jazz-desktop-client",
            new Dictionary<string, string> { [KeyId] = PublicKeyBase64Url });
        Importer = new SignedEnrollmentImporter(includeTrustAnchor ? TrustPolicy : null, Store);
    }

    /// <summary>The fixture key id, which every contract golden names in its protected header.</summary>
    public string KeyId { get; }

    /// <summary>Base64url of the fixture public key.</summary>
    public string PublicKeyBase64Url { get; }

    /// <summary>Temporary directory holding this harness's ledger.</summary>
    public string Root { get; }

    /// <summary>The ledger under test.</summary>
    public FileEnrollmentAcceptanceStore Store { get; }

    /// <summary>The trust policy the harness's importer uses.</summary>
    public EnrollmentTrustPolicy TrustPolicy { get; }

    /// <summary>Verifier plus durable admission, in that order.</summary>
    public SignedEnrollmentImporter Importer { get; }

    /// <summary>Reads a golden fixture from <c>contract/enrollment/fixtures</c>.</summary>
    public static JsonObject Golden(string name) => EnrollmentContract.ReadObject("fixtures", name);

    /// <summary>The flattened JWS of a golden, serialized exactly as a user would paste it.</summary>
    public static string GoldenJwsText(JsonObject golden) =>
        EnrollmentContract.CanonicalText(golden["jws"]!.DeepClone());

    /// <summary>The decoded payload object of a golden's JWS.</summary>
    public static JsonObject DecodedPayload(JsonObject golden)
    {
        string segment = golden["jws"]!["payload"]!.GetValue<string>();
        byte[] bytes = EnrollmentEncoding.DecodeBase64Url(segment, maximumBytes: 98_304)!;
        return (JsonObject)JsonNode.Parse(bytes)!;
    }

    /// <summary>Builds an envelope whose signature is recomputed over the supplied payload bytes.</summary>
    public string SignedEnvelope(string protectedSegment, byte[] payloadBytes)
    {
        string payloadSegment = EnrollmentEncoding.EncodeBase64Url(payloadBytes);
        byte[] signingInput = Encoding.ASCII.GetBytes(protectedSegment + "." + payloadSegment);
        var signer = new Ed25519Signer();
        signer.Init(true, privateKey);
        signer.BlockUpdate(signingInput, 0, signingInput.Length);
        return EnvelopeText(
            protectedSegment,
            payloadSegment,
            EnrollmentEncoding.EncodeBase64Url(signer.GenerateSignature()));
    }

    /// <summary>Builds an envelope from three already-encoded segments.</summary>
    public static string EnvelopeText(string protectedSegment, string payloadSegment, string signature) =>
        EnrollmentContract.CanonicalText(new JsonObject
        {
            ["protected"] = protectedSegment,
            ["payload"] = payloadSegment,
            ["signature"] = signature,
        });

    /// <summary>Canonical UTF-8 bytes of a JSON tree.</summary>
    public static byte[] Canonical(JsonNode? value) => EnrollmentContract.Canonical(value);

    /// <summary>The fixture key document, kept byte-identical to the macOS copy.</summary>
    public static JsonObject ReadTestKey()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "test-only-rfc8032-ed25519-key.json");
        return (JsonObject)JsonNode.Parse(File.ReadAllBytes(path))!;
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(Root))
            {
                Directory.Delete(Root, recursive: true);
            }
        }
        catch (IOException)
        {
            // A leftover temporary directory is not worth failing a test over.
        }
    }
}

/// <summary>Counts how many times a token-bearing call would have been made.</summary>
/// <remarks>
/// Every negative test asserts this counter does not move. That is the whole point of the ordering:
/// a refusal that happens after the request has already carried the token is not a refusal.
/// </remarks>
public sealed class TokenRequestProbe
{
    /// <summary>How many times the token-bearing operation ran.</summary>
    public int RequestCount { get; private set; }

    /// <summary>The operation an importer caller would perform with the authorized bundle.</summary>
    public Task<string> RequestAsync(AuthorizedSignedDeviceBundle authorized)
    {
        RequestCount++;
        return Task.FromResult(authorized.Payload.TokenId);
    }
}
