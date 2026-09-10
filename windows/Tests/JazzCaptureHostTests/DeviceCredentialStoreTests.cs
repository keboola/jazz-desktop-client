using JazzCapture;
using JazzCaptureCore.Enrollment;
using System.Net;
using System.Net.Http;
using System.Security.AccessControl;
using System.Security.Principal;

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
        AssertCurrentUserOnly(new DirectoryInfo(store.SecurityDirectory).GetAccessControl());
        AssertCurrentUserOnly(new FileInfo(store.FilePath).GetAccessControl());
    }

    [Fact]
    public async Task ExpiredBundleIsRefusedWithoutPersistingIt()
    {
        var store = new DeviceCredentialStore(root);
        DeviceCredentialStatus status = await store.AuthorizeAndAcceptManualPasteAsync(Bundle("2000-01-01T00:00:00Z"), new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(DeviceCredentialState.Invalid, status.State);
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
    public async Task ManualPasteUsesTheProtectedStorePath()
    {
        var store = new DeviceCredentialStore(root);
        Assert.Equal(DeviceCredentialState.Active, (await store.AuthorizeAndAcceptManualPasteAsync(Bundle(), new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None)).State);
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
    public async Task InvalidSourceDoesNotReplaceExistingProtectedCredential()
    {
        var store = new DeviceCredentialStore(root);
        store.Write(DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow));
        var files = new FakeFiles("{\"kind\":\"not-jazz\"}");
        store = new DeviceCredentialStore(root, files, _ => true);
        store.Write(DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow));
        Assert.Equal(DeviceCredentialState.Invalid, (await store.ConsumeProvisioningFileAsync("p", new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None)).State);
        Assert.True(files.Truncated);
        Assert.Equal("device-1", store.Read()!.DeviceId);
    }

    [Fact]
    public async Task HttpVerifierUsesOnlyCanonicalRouteAndDoesNotExposeHeaderInErrors()
    {
        var handler = new Handler("{\"id\":\"token-1\",\"owner\":{\"id\":123},\"expires\":\"2099-01-01T00:00:00Z\",\"isMasterToken\":false,\"isDisabled\":false,\"isExpired\":false,\"canManageBuckets\":false,\"canManageTokens\":false,\"canReadAllFileUploads\":false,\"bucketPermissions\":{}}");
        using var client = new HttpClient(handler);
        DeviceBundle bundle = DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow);
        VerifiedDeviceToken result = await new KeboolaDeviceTokenVerifier(client).VerifyAsync(bundle, CancellationToken.None);
        Assert.Equal("https://connection.keboola.com/v2/storage/tokens/verify", handler.Uri);
        Assert.Equal("123-abcdefghijklmnop", handler.Token);
        Assert.False(result.HasAdmin);
    }

    [Fact]
    public async Task AdminOnlyOrMissingSecurityFieldsFailClosed()
    {
        foreach (string json in new[] {
            "{\"id\":\"token-1\",\"owner\":{\"id\":123},\"expires\":\"2099-01-01T00:00:00Z\",\"admin\":{}}",
            "{\"id\":\"token-1\",\"owner\":{\"id\":123},\"expires\":\"2099-01-01T00:00:00Z\"}" })
        {
            using var client = new HttpClient(new Handler(json));
            await Assert.ThrowsAsync<DeviceBundleException>(() => DeviceCredentialAuthorizer.AuthorizeAsync(Bundle(), new KeboolaDeviceTokenVerifier(client), DateTimeOffset.UtcNow, CancellationToken.None));
        }
    }

    [Fact]
    public async Task UnknownLengthResponseOverLimitIsRefused()
    {
        using var client = new HttpClient(new Handler(new string('x', 65 * 1024), unknownLength: true));
        await Assert.ThrowsAsync<DeviceBundleException>(() => new KeboolaDeviceTokenVerifier(client).VerifyAsync(DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow), CancellationToken.None));
    }

    [Fact]
    public async Task AcceptedSourceIsTruncatedEvenWhenDeleteFails()
    {
        var files = new FakeFiles(Bundle()) { DeleteFails = true };
        var store = new DeviceCredentialStore(root, files, _ => true);
        Assert.Equal(DeviceCredentialState.Active, (await store.ConsumeProvisioningFileAsync("p", new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None)).State);
        Assert.Equal(string.Empty, files.Text); Assert.True(files.Truncated);
    }

    [Fact]
    public async Task TruncateFailureNeverReportsAcceptedCredential()
    {
        var files = new FakeFiles(Bundle()) { TruncateFails = true };
        var store = new DeviceCredentialStore(root, files, _ => true);
        DeviceCredentialStatus status = await store.ConsumeProvisioningFileAsync("p", new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(DeviceCredentialState.Invalid, status.State); Assert.Equal(Bundle(), files.Text); Assert.Null(store.Read()); Assert.False(File.Exists(store.FilePath));
    }

    [Fact]
    public async Task TruncateFailureRestoresExactPreviousProtectedStore()
    {
        var files = new FakeFiles(Bundle()) { TruncateFails = true };
        var store = new DeviceCredentialStore(root, files, _ => true);
        store.Write(DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow));
        byte[] prior = File.ReadAllBytes(store.FilePath);
        await store.ConsumeProvisioningFileAsync("p", new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(prior, File.ReadAllBytes(store.FilePath)); Assert.Equal("device-1", store.Read()!.DeviceId);
    }

    [Theory]
    [InlineData("{\"kind\":\"bad\"}")]
    [InlineData("expired")]
    public async Task DeterministicSourceRefusalTruncates(string source)
    {
        string text = source == "expired" ? Bundle("2000-01-01T00:00:00Z") : source;
        var files = new FakeFiles(text); var store = new DeviceCredentialStore(root, files, _ => true);
        await store.ConsumeProvisioningFileAsync("p", new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.True(files.Truncated);
    }

    [Fact]
    public async Task VerificationUnavailableRetainsSource()
    {
        var files = new FakeFiles(Bundle()); var store = new DeviceCredentialStore(root, files, _ => true);
        await store.ConsumeProvisioningFileAsync("p", new ThrowingVerifier(), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(Bundle(), files.Text); Assert.False(files.Truncated);
    }

    [Theory]
    [InlineData(429)]
    [InlineData(503)]
    public async Task TransientHttpVerificationRetainsSource(int code)
    {
        var files = new FakeFiles(Bundle()); var store = new DeviceCredentialStore(root, files, _ => true);
        using var client = new HttpClient(new Handler("{}", status: (HttpStatusCode)code));
        await store.ConsumeProvisioningFileAsync("p", new KeboolaDeviceTokenVerifier(client), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(Bundle(), files.Text); Assert.False(files.Truncated); Assert.Null(store.Read());
    }

    [Fact]
    public async Task UnauthorizedHttpVerificationNeutralizesSource()
    {
        var files = new FakeFiles(Bundle()); var store = new DeviceCredentialStore(root, files, _ => true);
        using var client = new HttpClient(new Handler("{}", status: HttpStatusCode.Unauthorized));
        Assert.Equal(DeviceCredentialState.Invalid, (await store.ConsumeProvisioningFileAsync("p", new KeboolaDeviceTokenVerifier(client), DateTimeOffset.UtcNow, CancellationToken.None)).State);
        Assert.True(files.Truncated); Assert.Null(store.Read());
    }

    [Fact]
    public async Task ReadOnlyProvisioningAclFailsBeforeAuthorizationAndLeavesSource()
    {
        Directory.CreateDirectory(root);
        string source = Path.Combine(root, "read-only-provisioning.json");
        File.WriteAllText(source, Bundle());
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User!;
        var acl = new FileSecurity();
        acl.SetAccessRuleProtection(true, false);
        acl.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.ReadData, AccessControlType.Allow));
        new FileInfo(source).SetAccessControl(acl);
        var store = new DeviceCredentialStore(Path.Combine(root, "security"));

        DeviceCredentialStatus status = await store.ConsumeProvisioningFileAsync(source, new ThrowingVerifier(), DateTimeOffset.UtcNow, CancellationToken.None);

        Assert.Equal(DeviceCredentialState.Invalid, status.State);
        acl.ResetAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(source).SetAccessControl(acl);
        Assert.Equal(Bundle(), File.ReadAllText(source));
        Assert.Null(store.Read());
    }

    [Fact]
    public async Task PendingPromotesWhenSourceIsAbsent()
    {
        var files = new FakeFiles(string.Empty) { Present = false };
        var store = new DeviceCredentialStore(root, files, _ => true);
        store.Write(DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow));
        File.Move(store.FilePath, store.PendingFilePath);
        await store.ConsumeProvisioningFileAsync("p", new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal("device-1", store.Read()!.DeviceId); Assert.False(File.Exists(store.PendingFilePath));
    }

    [Fact]
    public async Task PendingPromotesWhenSourceIsEmpty()
    {
        var files = new FakeFiles(string.Empty);
        var store = new DeviceCredentialStore(root, files, _ => true);
        store.Write(DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow)); File.Move(store.FilePath, store.PendingFilePath);
        await store.ConsumeProvisioningFileAsync("p", new FakeVerifier(Valid()), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.NotNull(store.Read());
    }

    [Fact]
    public async Task CallerCancellationIsRethrown()
    {
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        using var client = new HttpClient(new CancelHandler());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new KeboolaDeviceTokenVerifier(client).VerifyAsync(DeviceBundleParser.Parse(Bundle(), DateTimeOffset.UtcNow), cancellation.Token));
    }

    [Fact]
    public async Task RedirectIsRetryableAndDoesNotIssueSecondTokenRequest()
    {
        var handler = new RedirectHandler(); using var client = new HttpClient(handler);
        var files = new FakeFiles(Bundle()); var store = new DeviceCredentialStore(root, files, _ => true);
        await store.ConsumeProvisioningFileAsync("p", new KeboolaDeviceTokenVerifier(client), DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(1, handler.Requests); Assert.Equal(Bundle(), files.Text); Assert.False(files.Truncated); Assert.Null(store.Read());
    }

    [Fact]
    public void ProductionVerifierDisablesAutoRedirect()
    {
        using HttpClientHandler handler = KeboolaDeviceTokenVerifier.CreateProductionHandler();
        Assert.False(handler.AllowAutoRedirect);
    }

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, true);
    }

    private static string Bundle(string expiry = "2099-01-01T00:00:00Z") => $$"""
        {"kind":"jazz-device-bundle","deviceId":"device-1","stackUrl":"https://connection.keboola.com","projectId":"123","companyId":"company-1","areaId":"area-1","archiveIngestUrl":"https://example.invalid/api/archive-ingests","streamSourceId":"source-1","streamEndpoint":"https://stream.example.invalid/v1/secret","token":"123-abcdefghijklmnop","tokenId":"token-1","expiresAt":"{{expiry}}","tokenBucketScope":"none","sinkBucketId":null,"componentAccess":[]}
        """;

    private static VerifiedDeviceToken Valid() => new("token-1", "123", "https://connection.keboola.com", "2099-01-01T00:00:00Z", false, false, false, false, false, false, new Dictionary<string, string>(), false);
    private static void AssertCurrentUserOnly(FileSystemSecurity security)
    {
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User!;
        Assert.True(security.AreAccessRulesProtected);
        Assert.All(security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>(), rule =>
        { Assert.Equal(current, rule.IdentityReference); Assert.Equal(AccessControlType.Allow, rule.AccessControlType); });
    }
    private sealed class FakeVerifier(VerifiedDeviceToken result) : IDeviceTokenVerifier
    {
        public Task<VerifiedDeviceToken> VerifyAsync(DeviceBundle bundle, CancellationToken cancellationToken) => Task.FromResult(result);
    }
    private sealed class Handler(string json, bool unknownLength = false, HttpStatusCode status = HttpStatusCode.OK) : HttpMessageHandler
    {
        public string? Uri { get; private set; }
        public string? Token { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Uri = request.RequestUri!.AbsoluteUri;
            Token = request.Headers.GetValues("X-StorageApi-Token").Single();
            HttpContent content = unknownLength ? new StreamContent(new NonSeekStream(System.Text.Encoding.UTF8.GetBytes(json))) : new StringContent(json);
            return Task.FromResult(new HttpResponseMessage(status) { Content = content });
        }
    }
    private sealed class NonSeekStream(byte[] bytes) : MemoryStream(bytes) { public override bool CanSeek => false; public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); } }
    private sealed class CancelHandler : HttpMessageHandler { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromCanceled<HttpResponseMessage>(cancellationToken); }
    private sealed class RedirectHandler : HttpMessageHandler { public int Requests { get; private set; } protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) { Requests++; var response = new HttpResponseMessage(HttpStatusCode.Found); response.Headers.Location = new Uri("https://foreign.invalid/"); return Task.FromResult(response); } }
    private sealed class ThrowingVerifier : IDeviceTokenVerifier { public Task<VerifiedDeviceToken> VerifyAsync(DeviceBundle b, CancellationToken c) => throw new DeviceBundleException(DeviceBundleError.VerificationUnavailable); }
    private sealed class FakeFiles(string text) : IProvisioningFileOperations
    {
        public string Text { get; private set; } = text; public bool Truncated { get; private set; } public bool DeleteFails { get; init; } public bool TruncateFails { get; init; } public bool Present { get; init; } = true;
        public bool Exists(string path) => Present; public string ReadAllText(string path) => Text;
        public void TruncateAndFlush(string path) { if (TruncateFails) throw new IOException(); Text = string.Empty; Truncated = true; }
        public void Delete(string path) { if (DeleteFails) throw new IOException(); }
    }
}
