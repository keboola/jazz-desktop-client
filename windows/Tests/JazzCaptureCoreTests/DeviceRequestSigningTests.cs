using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Consent;

namespace JazzCaptureCoreTests;

/// <summary>
/// The expected values come from the server code (<c>device_auth_crypto.py</c> and
/// <c>device_auth.py</c> at keboola/jazz main), run with the fixed key below. ECDSA signatures are
/// random, so the payload bytes must match exactly and a signature made by the Python server code
/// must verify over the bytes this client builds.
/// </summary>
public sealed class DeviceRequestSigningTests
{
    private const string PublicKeyHex =
        "044efed899b0f6e9c38fbbb040db51935580957df0a481255a2b0788afccee3e791a539925516341a28f402c65f0f24b7673b9b9718bd8b95007a86e72f6d51aa0";
    private const string PrivateKeyHex = "1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff001";

    private const string RequestPayload =
        "{\"clientVersion\":\"0.27.0\",\"deviceId\":\"dev-1\",\"filesTokenId\":\"\",\"hostname\":\"PC-01\",\"method\":\"GET\",\"nonce\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"osUser\":\"acme\\\\jnovak\",\"path\":\"/device/policy\",\"timestamp\":\"2026-11-23T10:00:00.123Z\"}";
    private const string RequestSignatureFromServerCode =
        "36c2f54fd633d7f75a673ac9da12b8bad2a84793b73a99e9c26154d4c5148d8464a28a4608df5e5dccb49a01ed02e7cbaceddb70383920d8a9579c144ecadd70";

    private const string ConsentPayload =
        "{\"captureMode\":\"session\",\"clientVersion\":\"0.27.0\",\"consentKey\":\"acme\\\\jnovak\",\"decision\":\"withdrawn\",\"deviceId\":\"dev-1\",\"filesTokenId\":\"\",\"hostname\":\"PC-01\",\"method\":\"POST\",\"nonce\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"osUser\":\"acme\\\\jnovak\",\"path\":\"/device/consent\",\"textHash\":\"abababababababababababababababababababababababababababababababab\",\"textVersion\":\"0.3\",\"timestamp\":\"2026-11-23T10:00:00.123Z\",\"windowsSid\":\"S-1-5-21-1-2-3-1001\"}";
    private const string ConsentSignatureFromServerCode =
        "93917a30fe77c6d06e7d767893ed86482d582ea0efea9adaf4ef6325f9cddf954427be66e9488786c9b5daf10edc1dac51023ebe33f2a2aca17886df8a6935f2";

    private const string EnrollPayload =
        "{\"deviceId\":\"dev-1\",\"enrollmentCodeSha256\":\"LwGH2D5OWvpQMNKaz6WN5nKngthv6u4EJNKyy_HZfzc\",\"hostname\":\"PC-01\",\"keyProtection\":\"software\",\"osUser\":\"acme\\\\jnovak\",\"proofPublicKey\":\"BE7-2Jmw9unDj7uwQNtRk1WAlX3wpIElWisHiK_M7j55GlOZJVFjQaKPQCxl8PJLdnO5uXGL2LlQB6hucvbVGqA\",\"wrappingPublicKey\":\"BAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8\"}";
    private const string EnrollSignatureFromServerCode =
        "00046aecea5f52172af9e25252c8a05b612408d0b4c6223b5f457b31076c2a9f644e93f85bc530fcc8815f208e99c8ab59b68ea8b1134bf78d7ecd7bbe9fff72";

    private sealed class TestSigner : IDeviceSigner
    {
        private readonly ECDsa _key;

        internal TestSigner()
        {
            byte[] pub = Convert.FromHexString(PublicKeyHex);
            _key = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                D = Convert.FromHexString(PrivateKeyHex),
                Q = new ECPoint { X = pub[1..33], Y = pub[33..65] },
            });
        }

        public byte[] PublicKeyX963 => Convert.FromHexString(PublicKeyHex);

        public byte[] SignRaw(byte[] message) =>
            _key.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    private static bool Verifies(byte[] domain, string payload, byte[] signature)
    {
        byte[] pub = Convert.FromHexString(PublicKeyHex);
        using ECDsa key = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = pub[1..33], Y = pub[33..65] },
        });
        return key.VerifyData(
            domain.Concat(Encoding.UTF8.GetBytes(payload)).ToArray(),
            signature,
            HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    private static SignedRequest PolicyRequest(string? ifNoneMatch = null, string filesTokenId = "") =>
        DeviceRequestSigning.Sign(
            new TestSigner(), "GET", "/device/policy", "dev-1", "2026-11-23T10:00:00.123Z", "AAAAAAAAAAAAAAAAAAAAAA",
            @"acme\jnovak", "PC-01", "0.27.0", filesTokenId, ifNoneMatch);

    [Fact]
    public void CanonicalJsonMatchesTheServerBytesIncludingEscapes()
    {
        byte[] bytes = DeviceRequestSigning.CanonicalJson(new Dictionary<string, string>
        {
            ["b"] = "q\"\\\n\t\u0001\u007f\u00e1\u2028",
            ["a"] = string.Empty,
        });

        Assert.Equal("7b2261223a22222c2262223a22715c225c5c5c6e5c745c75303030317fc3a1e280a8227d", Convert.ToHexString(bytes).ToLowerInvariant());
    }

    [Fact]
    public void ASignatureMadeByTheServerCodeVerifiesOverThePolicyPayloadThisClientBuilds()
    {
        Assert.True(Verifies(DeviceRequestSigning.RequestDomain, RequestPayload, Convert.FromHexString(RequestSignatureFromServerCode)));
    }

    [Fact]
    public void ThePolicySignatureOfThisClientVerifiesOverTheServerPayload()
    {
        SignedRequest request = PolicyRequest();

        byte[] signature = Convert.FromBase64String(PadBase64(request.Headers["X-Jazz-Device-Signature"]));

        Assert.Equal(64, signature.Length);
        Assert.True(Verifies(DeviceRequestSigning.RequestDomain, RequestPayload, signature));
        Assert.Null(request.Body);
    }

    [Fact]
    public void TheConsentSignatureCoversTheConsentFieldsAndTheBodyCarriesThem()
    {
        var fields = new Dictionary<string, string>
        {
            ["consentKey"] = @"acme\jnovak",
            ["decision"] = "withdrawn",
            ["windowsSid"] = "S-1-5-21-1-2-3-1001",
            ["textVersion"] = "0.3",
            ["textHash"] = string.Concat(Enumerable.Repeat("ab", 32)),
            ["captureMode"] = "session",
        };

        SignedRequest request = DeviceRequestSigning.Sign(
            new TestSigner(), "POST", "/device/consent", "dev-1", "2026-11-23T10:00:00.123Z", "AAAAAAAAAAAAAAAAAAAAAA",
            @"acme\jnovak", "PC-01", "0.27.0", string.Empty, null, fields);

        byte[] signature = Convert.FromBase64String(PadBase64(request.Headers["X-Jazz-Device-Signature"]));
        Assert.True(Verifies(DeviceRequestSigning.RequestDomain, ConsentPayload, signature));
        Assert.True(Verifies(DeviceRequestSigning.RequestDomain, ConsentPayload, Convert.FromHexString(ConsentSignatureFromServerCode)));
        using JsonDocument body = JsonDocument.Parse(request.Body!);
        Assert.Equal(
            new[] { "captureMode", "consentKey", "decision", "textHash", "textVersion", "windowsSid" },
            body.RootElement.EnumerateObject().Select(property => property.Name).OrderBy(name => name, StringComparer.Ordinal).ToArray());
    }

    [Fact]
    public void TheHeadersCarryTheSignedValuesAndTheOptionalOnes()
    {
        SignedRequest request = PolicyRequest("\"7-abc\"", "token-1");

        Assert.Equal("dev-1", request.Headers["X-Jazz-Device-Id"]);
        Assert.Equal("2026-11-23T10:00:00.123Z", request.Headers["X-Jazz-Device-Timestamp"]);
        Assert.Equal("AAAAAAAAAAAAAAAAAAAAAA", request.Headers["X-Jazz-Device-Nonce"]);
        Assert.Equal(@"acme\jnovak", request.Headers["X-Jazz-Os-User"]);
        Assert.Equal("PC-01", request.Headers["X-Jazz-Hostname"]);
        Assert.Equal("0.27.0", request.Headers["X-Jazz-Client-Version"]);
        Assert.Equal("token-1", request.Headers["X-Jazz-Files-Token-Id"]);
        Assert.Equal("\"7-abc\"", request.Headers["If-None-Match"]);
        Assert.False(PolicyRequest().Headers.ContainsKey("X-Jazz-Files-Token-Id"));
        Assert.False(PolicyRequest().Headers.ContainsKey("If-None-Match"));
    }

    [Fact]
    public void TheEnrollProofVerifiesAndMatchesTheServerPayload()
    {
        byte[] wrapping = new byte[65];
        wrapping[0] = 4;
        for (int index = 0; index < 64; index++) wrapping[index + 1] = (byte)index;

        string json = DeviceRequestSigning.EnrollBody(
            new TestSigner(), wrapping, "dev-1", "enroll-code-0123456789", "PC-01", @"acme\jnovak", "software");

        using JsonDocument body = JsonDocument.Parse(json);
        Assert.Equal(
            new[] { "deviceId", "enrollmentCodeSha256", "hostname", "keyProtection", "osUser", "proof", "proofPublicKey", "wrappingPublicKey" },
            body.RootElement.EnumerateObject().Select(property => property.Name).OrderBy(name => name, StringComparer.Ordinal).ToArray());
        byte[] proof = Convert.FromBase64String(PadBase64(body.RootElement.GetProperty("proof").GetString()!));
        Assert.True(Verifies(DeviceRequestSigning.EnrollDomain, EnrollPayload, proof));
        Assert.True(Verifies(DeviceRequestSigning.EnrollDomain, EnrollPayload, Convert.FromHexString(EnrollSignatureFromServerCode)));
        Assert.DoesNotContain("enroll-code-0123456789", json, StringComparison.Ordinal);
    }

    [Fact]
    public void ASignatureWithAHighSIsFlippedToLowS()
    {
        byte[] n = Convert.FromHexString("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");
        byte[] raw = new byte[64];
        raw[31] = 1;
        Array.Copy(n, 0, raw, 32, 32);
        raw[63] -= 1; // s = n - 1, which is high

        byte[] fixedUp = DeviceRequestSigning.NormalizeLowS(raw);

        Assert.Equal(raw[..32], fixedUp[..32]);
        Assert.Equal(1, fixedUp[63]);
        Assert.All(fixedUp[32..63], value => Assert.Equal(0, value));
        Assert.Same(fixedUp, DeviceRequestSigning.NormalizeLowS(fixedUp));
    }

    [Fact]
    public void AllSignaturesAreLowS()
    {
        var signer = new TestSigner();
        for (int round = 0; round < 40; round++)
        {
            byte[] signature = DeviceRequestSigning.Sign(signer, DeviceRequestSigning.RequestDomain, new byte[] { (byte)round });
            Assert.True(signature[32] < 0x80);
        }
    }

    [Fact]
    public void ANonAsciiNameIsSignedAsTheServerReadsTheHeader()
    {
        Assert.Equal(@"acme\jnovak", DeviceRequestSigning.HeaderSafe(@"acme\jnovak"));
        Assert.Equal("Nov\u00c3\u00a1k", DeviceRequestSigning.HeaderSafe("Nov\u00e1k"));
    }

    [Fact]
    public void TimestampAndNonceMatchTheServerPatterns()
    {
        string timestamp = DeviceRequestSigning.Timestamp(new DateTimeOffset(2026, 11, 23, 11, 0, 0, 7, TimeSpan.FromHours(1)));

        Assert.Equal("2026-11-23T10:00:00.007Z", timestamp);
        Assert.Matches("^[A-Za-z0-9_-]{16,128}$", DeviceRequestSigning.NewNonce());
        Assert.NotEqual(DeviceRequestSigning.NewNonce(), DeviceRequestSigning.NewNonce());
    }

    [Fact]
    public void TheCachedPolicyHoldsNeitherTheFilesTokenNorTheStreamUrl()
    {
        const string json = "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"status\":\"active\",\"streamUrl\":\"https://stream.example/secret\",\"filesToken\":{\"tokenId\":\"t1\",\"token\":\"secret-token\",\"expiresAt\":\"2026-11-23T11:00:00Z\"}}";

        string cached = DevicePolicyDocument.WithoutSecrets(json);

        Assert.DoesNotContain("secret", cached, StringComparison.Ordinal);
        Assert.True(DevicePolicy.TryParse(cached, out _));
        Assert.True(DevicePolicyDocument.TryReadFilesToken(json, out string id, out DateTimeOffset end));
        Assert.Equal("t1", id);
        Assert.Equal(new DateTimeOffset(2026, 11, 23, 11, 0, 0, TimeSpan.Zero), end);
        Assert.False(DevicePolicyDocument.TryReadFilesToken(cached, out _, out _));
    }

    private static string PadBase64(string value)
    {
        string padded = value.Replace('-', '+').Replace('_', '/');
        return padded.PadRight(padded.Length + ((4 - (padded.Length % 4)) % 4), '=');
    }
}
