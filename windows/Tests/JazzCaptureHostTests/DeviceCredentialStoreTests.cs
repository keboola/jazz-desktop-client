using JazzCapture;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

public sealed class DeviceCredentialStoreTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-device-store-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void WriteProtectsSecretsAndRoundTripsOnlyForCurrentUser()
    {
        var store = new DeviceCredentialStore(root);
        DeviceBundle bundle = DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow);

        store.Write(bundle);

        byte[] ciphertext = File.ReadAllBytes(store.FilePath);
        Assert.True(ciphertext.AsSpan().IndexOf(System.Text.Encoding.UTF8.GetBytes("123-abcdefghijklmnop")) < 0);
        Assert.Equal("device-1", store.Read()!.DeviceId);
        Assert.Equal(DeviceCredentialState.Active, store.State(DateTimeOffset.UtcNow));
    }

    [Fact]
    public void ExpiredBundleIsRefusedWithoutPersistingIt()
    {
        var store = new DeviceCredentialStore(root);
        Assert.Throws<DeviceBundleException>(() => DeviceBundleParser.Parse(Bundle("2000-01-01T00:00:00Z"), DateTimeOffset.UtcNow));
        Assert.Null(store.Read());
    }

    [Fact]
    public void StoredExpiredBundleReportsExpiredRatherThanInvalid()
    {
        var store = new DeviceCredentialStore(root);
        store.Write(DeviceBundleParser.Parse(Bundle("2000-01-01T00:00:00Z"), DateTimeOffset.UtcNow, requireUnexpired: false));
        Assert.Equal(DeviceCredentialState.Expired, store.State(DateTimeOffset.UtcNow));
    }

    [Fact]
    public void ManualPasteUsesTheProtectedStorePath()
    {
        var store = new DeviceCredentialStore(root);
        Assert.Equal(DeviceCredentialState.Active, store.AcceptManualPaste(Bundle(), DateTimeOffset.UtcNow).State);
        Assert.Equal("device-1", store.Read()!.DeviceId);
    }

    [Fact]
    public async Task VerificationFailureNeverWritesCredentials()
    {
        var store = new DeviceCredentialStore(root);
        DeviceCredentialStatus status = await store.AuthorizeAndAcceptManualPasteAsync(Bundle(), new FakeVerifier(Valid() with { IsMasterToken = true }), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(DeviceCredentialState.Invalid, status.State);
        Assert.Null(store.Read());
    }

    [Theory]
    [InlineData("master")]
    [InlineData("wrong-token")]
    [InlineData("broad")]
    [InlineData("expired")]
    public async Task StrictVerificationRefusalsNeverWrite(string refusal)
    {
        VerifiedDeviceToken value = refusal switch
        {
            "master" => Valid() with { IsMasterToken = true },
            "wrong-token" => Valid() with { TokenId = "other" },
            "broad" => Valid() with { CanManageTokens = true },
            _ => Valid() with { ExpiresAt = "2000-01-01T00:00:00Z" },
        };
        var store = new DeviceCredentialStore(root);
        DeviceCredentialStatus status = await store.AuthorizeAndAcceptManualPasteAsync(Bundle(), new FakeVerifier(value), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(DeviceCredentialState.Invalid, status.State);
        Assert.False(File.Exists(store.FilePath));
    }

    [Fact]
    public void InvalidSourceDoesNotReplaceExistingProtectedCredential()
    {
        var store = new DeviceCredentialStore(root);
        store.Write(DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow));
        string source = Path.Combine(root, "provisioning.json");
        Directory.CreateDirectory(root);
        File.WriteAllText(source, "{\"kind\":\"not-jazz\"}");

        Assert.Equal(DeviceCredentialState.Invalid, store.ConsumeProvisioningFile(source, DateTimeOffset.UtcNow));
        Assert.Equal("device-1", store.Read()!.DeviceId);
    }

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, true);
    }

    private static string Bundle(string expiry = "2099-01-01T00:00:00Z") => $$"""
        {"kind":"jazz-device-bundle","deviceId":"device-1","stackUrl":"https://connection.keboola.com","projectId":"123","companyId":"company-1","areaId":"area-1","archiveIngestUrl":"https://example.invalid/api/archive-ingests","streamSourceId":"source-1","streamEndpoint":"https://stream.example.invalid/v1/secret","token":"123-abcdefghijklmnop","tokenId":"token-1","expiresAt":"{{expiry}}","tokenBucketScope":"none","sinkBucketId":null,"componentAccess":[]}
        """;

    private static VerifiedDeviceToken Valid() => new("token-1", "123", "https://connection.keboola.com", "2099-01-01T00:00:00Z", false, false, false, false, false, false, new Dictionary<string, string>(), false);
    private sealed class FakeVerifier(VerifiedDeviceToken result) : IDeviceTokenVerifier
    {
        public Task<VerifiedDeviceToken> VerifyAsync(DeviceBundle bundle, CancellationToken cancellationToken) => Task.FromResult(result);
    }
}
