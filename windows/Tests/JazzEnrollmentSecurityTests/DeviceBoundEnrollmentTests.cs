using System.Text;
using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;
using JazzEnrollmentSecurityTests.Support;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// The device-bound claim and sealed-bundle grammar, checked against the cross-platform vector in
/// <c>contract/enrollment/device-bound/fixtures</c>.
/// </summary>
/// <remarks>
/// That fixture was produced independently of both clients, so decrypting it byte for byte is real
/// evidence that this port agrees with the server and with macOS, not merely with itself.
/// </remarks>
public sealed class DeviceBoundEnrollmentTests
{
    private static readonly DateTimeOffset Reveal = SignedEnrollmentRefusalTests.Instant("2026-07-24T09:31:00Z");

    private static readonly DeviceBundleSealDescriptor Descriptor = new(
        "jdb_018ff3a2679a7bd18a5e6c3d4b2a1908",
        7,
        "2026-07-24T09:31:00Z",
        "2026-07-24T09:41:00Z");

    private static readonly byte[] P256Order = Convert.FromHexString(
        "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");

    private static readonly byte[] P256HalfOrder = Convert.FromHexString(
        "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8");

    [Fact]
    public void TheContractGoldenClaimVerifiesAndDerivesTheExpectedBinding()
    {
        JsonObject fixture = Fixture();
        JsonObject expected = (JsonObject)fixture["expected"]!;

        VerifiedDeviceEnrollmentClaim verified = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));

        Assert.Equal(expected["claimSha256"]!.GetValue<string>(), verified.Binding.ClaimSha256);
        Assert.Equal(expected["proofKeyThumbprint"]!.GetValue<string>(), verified.Binding.ProofKeyThumbprint);
        Assert.Equal(expected["wrappingKeyThumbprint"]!.GetValue<string>(), verified.Binding.WrappingKeyThumbprint);
        Assert.Equal("jbt_11111111111111111111111111111111", verified.Payload.BootstrapId);
        Assert.Equal("jcl_22222222222222222222222222222222", verified.Payload.ClaimId);
        Assert.Equal("mac-finance-01", verified.Payload.DeviceId);
    }

    [Fact]
    public void TheContractGoldenSealDecryptsToTheExactSignedBundle()
    {
        JsonObject fixture = Fixture();
        JsonObject expected = (JsonObject)fixture["expected"]!;
        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));
        byte[] sealedBytes = SealedBytes(fixture);
        byte[] expectedSignedBundle = EnrollmentEncoding.DecodeBase64Url(
            fixture["signedDeviceBundle"]!.GetValue<string>(),
            maximumBytes: 131_072)!;

        Assert.Equal(
            expected["sealedBundleSha256"]!.GetValue<string>(),
            EnrollmentEncoding.HexSha256(sealedBytes));

        byte[] opened = DeviceBoundEnrollmentCrypto.OpenSealedBundle(
            sealedBytes,
            WrappingKey(fixture),
            claim.Binding,
            Descriptor,
            Reveal);

        Assert.Equal(expectedSignedBundle, opened);
        Assert.Equal(expected["bundleSha256"]!.GetValue<string>(), EnrollmentEncoding.HexSha256(opened));
    }

    [Fact]
    public void TheDecryptedBundleIsTheSameSignedEnrollmentTheJwsVerifierAccepts()
    {
        // The two fixture families are independent files. Chaining them proves the sealed transport
        // and the signature boundary agree on one artifact rather than on two similar ones.
        JsonObject fixture = Fixture();
        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));
        byte[] opened = DeviceBoundEnrollmentCrypto.OpenSealedBundle(
            SealedBytes(fixture),
            WrappingKey(fixture),
            claim.Binding,
            Descriptor,
            Reveal);

        using var harness = new SignedEnrollmentHarness();
        AuthorizedSignedDeviceBundle authorized = harness.Importer.Authorize(
            Encoding.UTF8.GetString(opened),
            SignedEnrollmentRefusalTests.Instant("2026-07-24T09:35:00Z"));

        Assert.Equal("jdb_018ff3a2679a7bd18a5e6c3d4b2a1908", authorized.Payload.BundleId);
        Assert.Equal(7, authorized.Payload.Generation);
        Assert.Equal(
            "ec80eb2df35b457027e5704fe523e45fba7200b12df23c68a4005284281985d2",
            authorized.EnvelopeDigest);
    }

    [Fact]
    public void ALocallyBuiltClaimIsCanonicalLowSAndReproducesTheGoldenPayloadDigest()
    {
        JsonObject fixture = Fixture();
        DeviceEnrollmentClaimPayload payload = GoldenClaimPayload(fixture);
        DevelopmentUnprotectedProofSigner signer = ProofSigner(fixture);

        byte[] first = DeviceBoundEnrollmentCrypto.MakeClaim(payload, signer);
        byte[] second = DeviceBoundEnrollmentCrypto.MakeClaim(payload, signer);
        VerifiedDeviceEnrollmentClaim firstVerified = DeviceBoundEnrollmentCrypto.VerifyClaim(first);
        VerifiedDeviceEnrollmentClaim secondVerified = DeviceBoundEnrollmentCrypto.VerifyClaim(second);

        byte[] proof = EnrollmentEncoding.DecodeBase64Url(
            StrictJson.StringOrNull(StrictJson.TryParseObject(first)!, "proof"),
            maximumBytes: 64)!;
        Assert.Equal(64, proof.Length);
        Assert.True(Compare(proof[32..64], P256HalfOrder) <= 0);

        // ECDSA is allowed to randomize k, so idempotence is the canonical payload digest and the
        // exact keys, never the signature bytes.
        Assert.Equal(firstVerified.Binding, secondVerified.Binding);
        Assert.Equal(firstVerified.CanonicalPayload, secondVerified.CanonicalPayload);
        Assert.Equal(
            ((JsonObject)fixture["expected"]!)["claimSha256"]!.GetValue<string>(),
            firstVerified.Binding.ClaimSha256);
    }

    [Fact]
    public void ClaimVerificationRefusesDuplicateUnknownNonCanonicalAndOversizedJson()
    {
        JsonObject fixture = Fixture();
        var envelope = (JsonObject)fixture["claimEnvelope"]!;
        string payload = envelope["payload"]!.GetValue<string>();
        string proof = envelope["proof"]!.GetValue<string>();

        AssertClaimRefused(
            DeviceBoundEnrollmentError.MalformedClaim,
            Encoding.UTF8.GetBytes($$"""{"payload":"{{payload}}","payload":"{{payload}}","proof":"{{proof}}"}"""));

        var unknown = (JsonObject)envelope.DeepClone();
        unknown["alg"] = "ES256";
        AssertClaimRefused(DeviceBoundEnrollmentError.MalformedClaim, EnrollmentContract.Canonical(unknown));

        AssertClaimRefused(
            DeviceBoundEnrollmentError.MalformedClaim,
            Encoding.UTF8.GetBytes(
                System.Text.Json.JsonSerializer.Serialize(
                    envelope.DeepClone(),
                    new System.Text.Json.JsonSerializerOptions { WriteIndented = true })));

        byte[] oversized = Concat(Encoding.UTF8.GetBytes("{"), new byte[20_001], Encoding.UTF8.GetBytes("}"));
        Array.Fill(oversized, (byte)0x20, 1, 20_001);
        AssertClaimRefused(DeviceBoundEnrollmentError.MalformedClaim, oversized);
    }

    [Theory]
    [InlineData("02", 32, "compressed point")]
    [InlineData("06", 64, "hybrid point")]
    [InlineData("04", 64, "uncompressed but off-curve point")]
    public void ClaimVerificationRefusesEveryNonCanonicalP256Point(string prefixHex, int tailLength, string reason)
    {
        JsonObject fixture = Fixture();
        byte[] point = Concat(
            Convert.FromHexString(prefixHex),
            prefixHex == "04" ? new byte[tailLength] : Enumerable.Repeat((byte)0x01, tailLength).ToArray());

        JsonObject payload = (JsonObject)GoldenClaimPayload(fixture).ToJson();
        ((JsonObject)payload["wrappingKey"]!)["publicKey"] = EnrollmentEncoding.EncodeBase64Url(point);

        AssertClaimRefused(
            DeviceBoundEnrollmentError.InvalidClaim,
            RawSignedClaim(payload, ProofSigner(fixture)),
            reason);
    }

    [Fact]
    public void ClaimVerificationRefusesHighSMalleationAndProofTamper()
    {
        JsonObject fixture = Fixture();
        var envelope = (JsonObject)fixture["claimEnvelope"]!;
        byte[] proof = EnrollmentEncoding.DecodeBase64Url(
            envelope["proof"]!.GetValue<string>(),
            maximumBytes: 64)!;

        // Negating s produces a second, equally valid ECDSA signature for the same message. It must
        // be refused, otherwise one claim would have two distinct wire forms.
        byte[] malleated = (byte[])proof.Clone();
        Subtract(P256Order, proof[32..64]).CopyTo(malleated.AsSpan(32));
        var highS = (JsonObject)envelope.DeepClone();
        highS["proof"] = EnrollmentEncoding.EncodeBase64Url(malleated);
        AssertClaimRefused(
            DeviceBoundEnrollmentError.NonCanonicalSignature,
            EnrollmentContract.Canonical(highS));

        byte[] flipped = (byte[])proof.Clone();
        flipped[0] ^= 1;
        var tampered = (JsonObject)envelope.DeepClone();
        tampered["proof"] = EnrollmentEncoding.EncodeBase64Url(flipped);
        AssertClaimRefused(
            DeviceBoundEnrollmentError.InvalidClaimProof,
            EnrollmentContract.Canonical(tampered));
    }

    [Fact]
    public void ACopiedClaimCannotBeOpenedWithASecondMachinesWrappingKey()
    {
        JsonObject fixture = Fixture();
        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));

        DeviceBoundEnrollmentException error = Assert.Throws<DeviceBoundEnrollmentException>(
            () => DeviceBoundEnrollmentCrypto.OpenSealedBundle(
                SealedBytes(fixture),
                P256TestKeys.RandomKeyAgreement(),
                claim.Binding,
                Descriptor,
                Reveal));

        Assert.Equal(DeviceBoundEnrollmentError.WrongRecipient, error.Reason);
        Assert.DoesNotContain("TEST-DEVICE-TOKEN", error.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("ciphertext")]
    [InlineData("tag")]
    public void SealedBundleTamperInTheAuthenticatedCiphertextFailsClosed(string field)
    {
        JsonObject fixture = Fixture();
        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));
        var envelope = (JsonObject)fixture["sealedBundle"]!.DeepClone();
        byte[] value = EnrollmentEncoding.DecodeBase64Url(
            envelope[field]!.GetValue<string>(),
            maximumBytes: 131_072)!;
        value[0] ^= 1;
        envelope[field] = EnrollmentEncoding.EncodeBase64Url(value);

        DeviceBoundEnrollmentException error = Assert.Throws<DeviceBoundEnrollmentException>(
            () => DeviceBoundEnrollmentCrypto.OpenSealedBundle(
                EnrollmentContract.Canonical(envelope),
                WrappingKey(fixture),
                claim.Binding,
                Descriptor,
                Reveal));

        Assert.Equal(DeviceBoundEnrollmentError.AuthenticationFailed, error.Reason);
        Assert.DoesNotContain("TEST-DEVICE-TOKEN", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void SealedBundleContextTamperFailsClosedBeforeDecryption()
    {
        JsonObject fixture = Fixture();
        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));
        var envelope = (JsonObject)fixture["sealedBundle"]!.DeepClone();
        JsonObject protectedHeader = (JsonObject)JsonNode.Parse(
            EnrollmentEncoding.DecodeBase64Url(envelope["protected"]!.GetValue<string>(), maximumBytes: 12_288)!)!;
        ((JsonObject)protectedHeader["context"]!)["deviceId"] = "second-mac";
        envelope["protected"] = EnrollmentEncoding.EncodeBase64Url(
            EnrollmentContract.Canonical(protectedHeader));

        DeviceBoundEnrollmentException error = Assert.Throws<DeviceBoundEnrollmentException>(
            () => DeviceBoundEnrollmentCrypto.OpenSealedBundle(
                EnrollmentContract.Canonical(envelope),
                WrappingKey(fixture),
                claim.Binding,
                Descriptor,
                Reveal));

        Assert.Equal(DeviceBoundEnrollmentError.ContextMismatch, error.Reason);
    }

    [Fact]
    public void SealedBundleRefusesAWrongExpectedDescriptor()
    {
        JsonObject fixture = Fixture();
        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));
        var wrongDescriptor = new DeviceBundleSealDescriptor(
            "jdb_99999999999999999999999999999999",
            7,
            "2026-07-24T09:31:00Z",
            "2026-07-24T09:41:00Z");

        DeviceBoundEnrollmentException error = Assert.Throws<DeviceBoundEnrollmentException>(
            () => DeviceBoundEnrollmentCrypto.OpenSealedBundle(
                SealedBytes(fixture),
                WrappingKey(fixture),
                claim.Binding,
                wrongDescriptor,
                Reveal));

        Assert.Equal(DeviceBoundEnrollmentError.ContextMismatch, error.Reason);
    }

    [Fact]
    public void SealedBundleRefusesDuplicateKeysUnknownMembersAndOversizedInput()
    {
        JsonObject fixture = Fixture();
        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));
        string wire = Encoding.UTF8.GetString(SealedBytes(fixture));

        int tagIndex = wire.IndexOf("\"tag\":", StringComparison.Ordinal);
        string duplicate = wire[..tagIndex] + "\"tag\":\"AAAAAAAAAAAAAAAAAAAAAA\"," + wire[tagIndex..];
        AssertSealRefused(
            DeviceBoundEnrollmentError.MalformedSealedBundle,
            Encoding.UTF8.GetBytes(duplicate),
            claim,
            fixture);

        var unknown = (JsonObject)fixture["sealedBundle"]!.DeepClone();
        unknown["jwk"] = new JsonObject { ["kty"] = "EC" };
        AssertSealRefused(
            DeviceBoundEnrollmentError.MalformedSealedBundle,
            EnrollmentContract.Canonical(unknown),
            claim,
            fixture);

        byte[] oversized = new byte[200_003];
        Array.Fill(oversized, (byte)0x20);
        oversized[0] = (byte)'{';
        oversized[^1] = (byte)'}';
        AssertSealRefused(
            DeviceBoundEnrollmentError.MalformedSealedBundle,
            oversized,
            claim,
            fixture);
    }

    [Fact]
    public void AnExpiredRevealFailsClosedAndSaysNothingAboutTheBundle()
    {
        JsonObject fixture = Fixture();
        VerifiedDeviceEnrollmentClaim claim = DeviceBoundEnrollmentCrypto.VerifyClaim(ClaimBytes(fixture));

        DeviceBoundEnrollmentException error = Assert.Throws<DeviceBoundEnrollmentException>(
            () => DeviceBoundEnrollmentCrypto.OpenSealedBundle(
                SealedBytes(fixture),
                WrappingKey(fixture),
                claim.Binding,
                Descriptor,
                SignedEnrollmentRefusalTests.Instant("2026-07-24T09:42:00Z")));

        Assert.Equal(DeviceBoundEnrollmentError.Expired, error.Reason);
        Assert.DoesNotContain("stream.example.test", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void TheContractFixtureNeverCarriesABootstrapBearer()
    {
        string raw = File.ReadAllText(
            EnrollmentContract.Path_("device-bound", "fixtures", "01-p256-device-bound-redemption.json"));

        Assert.DoesNotContain("TEST-ONLY-BOOTSTRAP-BEARER", raw, StringComparison.Ordinal);
        Assert.Contains("bearerSha256", raw, StringComparison.Ordinal);
    }

    [Fact]
    public void InspectionExposesOnlyTheValidatedDescriptorAndDigest()
    {
        JsonObject fixture = Fixture();

        DeviceBundleSealInspection inspection =
            DeviceBoundEnrollmentCrypto.InspectSealedBundle(SealedBytes(fixture));

        Assert.Equal(Descriptor, inspection.Descriptor);
        Assert.Equal(
            ((JsonObject)fixture["expected"]!)["bundleSha256"]!.GetValue<string>(),
            inspection.BundleSha256);
    }

    private static void AssertClaimRefused(DeviceBoundEnrollmentError expected, byte[] envelope, string? reason = null)
    {
        DeviceBoundEnrollmentException error = Assert.Throws<DeviceBoundEnrollmentException>(
            () => DeviceBoundEnrollmentCrypto.VerifyClaim(envelope));
        Assert.Equal(expected, error.Reason);
        Assert.True(reason is null || reason.Length > 0);
    }

    private static void AssertSealRefused(
        DeviceBoundEnrollmentError expected,
        byte[] wire,
        VerifiedDeviceEnrollmentClaim claim,
        JsonObject fixture)
    {
        DeviceBoundEnrollmentException error = Assert.Throws<DeviceBoundEnrollmentException>(
            () => DeviceBoundEnrollmentCrypto.OpenSealedBundle(
                wire,
                WrappingKey(fixture),
                claim.Binding,
                Descriptor,
                Reveal));
        Assert.Equal(expected, error.Reason);
    }

    private static byte[] RawSignedClaim(JsonObject payload, IDeviceEnrollmentProofSigner signer)
    {
        byte[] payloadBytes = EnrollmentContract.Canonical(payload);
        byte[] message = Concat(DeviceBoundEnrollmentCrypto.ClaimProofDomain, payloadBytes);
        byte[] lowS = DeviceBoundEnrollmentCrypto.NormalizeLowS(signer.SignRaw(message));
        return EnrollmentContract.Canonical(new JsonObject
        {
            ["payload"] = EnrollmentEncoding.EncodeBase64Url(payloadBytes),
            ["proof"] = EnrollmentEncoding.EncodeBase64Url(lowS),
        });
    }

    private static JsonObject Fixture() =>
        EnrollmentContract.ReadObject("device-bound", "fixtures", "01-p256-device-bound-redemption.json");

    private static byte[] ClaimBytes(JsonObject fixture) =>
        EnrollmentContract.Canonical(fixture["claimEnvelope"]!.DeepClone());

    private static byte[] SealedBytes(JsonObject fixture) =>
        EnrollmentContract.Canonical(fixture["sealedBundle"]!.DeepClone());

    private static DevelopmentUnprotectedProofSigner ProofSigner(JsonObject fixture) =>
        P256TestKeys.ProofSigner(((JsonObject)fixture["testOnly"]!)["proofPrivateKey"]!.GetValue<string>());

    private static DevelopmentUnprotectedKeyAgreement WrappingKey(JsonObject fixture) =>
        P256TestKeys.KeyAgreement(((JsonObject)fixture["testOnly"]!)["wrappingPrivateKey"]!.GetValue<string>());

    private static DeviceEnrollmentClaimPayload GoldenClaimPayload(JsonObject fixture)
    {
        var payload = (JsonObject)fixture["claimPayload"]!;
        var proofKey = (JsonObject)payload["proofKey"]!;
        var wrappingKey = (JsonObject)payload["wrappingKey"]!;
        return new DeviceEnrollmentClaimPayload(
            payload["bootstrapId"]!.GetValue<string>(),
            payload["claimId"]!.GetValue<string>(),
            payload["deviceId"]!.GetValue<string>(),
            payload["issuedAt"]!.GetValue<string>(),
            payload["expiresAt"]!.GetValue<string>(),
            DeviceEnrollmentPublicKey.Proof(proofKey["publicKey"]!.GetValue<string>()),
            DeviceEnrollmentPublicKey.Wrapping(wrappingKey["publicKey"]!.GetValue<string>()));
    }

    private static byte[] Concat(params byte[][] parts)
    {
        var result = new byte[parts.Sum(part => part.Length)];
        int offset = 0;
        foreach (byte[] part in parts)
        {
            part.CopyTo(result, offset);
            offset += part.Length;
        }

        return result;
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
        for (int i = 0; i < left.Length; i++)
        {
            if (left[i] != right[i])
            {
                return left[i] < right[i] ? -1 : 1;
            }
        }

        return 0;
    }
}
