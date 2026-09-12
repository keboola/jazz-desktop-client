using System.Text;
using JazzCapture;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="DeviceBundle"/> and <see cref="MvpDeliveryTarget"/> are both positional records, so
/// their compiler-generated <c>ToString()</c> would otherwise print every member -- including the
/// plaintext Keboola Storage token and the OTLP stream endpoint, a capability URL whose path is
/// itself a secret. Both types override <c>ToString()</c> to a fixed, non-secret shape.
/// </summary>
/// <remarks>
/// A prior version of this safety net asserted <c>DoesNotContain</c> against a
/// <c>(long?, enum)</c> record, which could never fail because neither member could ever contain a
/// secret-shaped string. Every test here plants a distinctive sentinel inside a member that can
/// actually carry a secret (the token, or the endpoint's capability path) and asserts the sentinel
/// is absent from <c>ToString()</c>. The last two tests guard the other direction: they pin the
/// exact text each override produces, so deleting an override and falling back to the generated
/// one fails a test instead of silently leaking.
/// </remarks>
public sealed class DeliverySecretSafetyTests
{
    private const string TokenSentinel = "token-SENTINEL-must-not-appear";
    private const string EndpointPathSentinel = "endpoint-path-SENTINEL-must-not-appear";
    private const string StackUrlSentinel = "stack-url-sentinel-must-not-appear";
    private const string ArchiveIngestUrlSentinel = "archive-ingest-sentinel-must-not-appear";

    [Fact]
    public void DeviceBundleToStringCannotPrintTheStorageToken()
    {
        DeviceBundle bundle = Bundle(token: TokenSentinel);
        Assert.DoesNotContain(TokenSentinel, bundle.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void DeviceBundleToStringCannotPrintTheStreamEndpointOrItsCapabilityPath()
    {
        DeviceBundle bundle = Bundle(streamEndpoint: $"https://stream.example.invalid/{EndpointPathSentinel}");
        string text = bundle.ToString();
        Assert.DoesNotContain(EndpointPathSentinel, text, StringComparison.Ordinal);
        Assert.DoesNotContain(bundle.StreamEndpoint!, text, StringComparison.Ordinal);
    }

    [Fact]
    public void DeviceBundleToStringCannotPrintTheStackOrArchiveIngestUrls()
    {
        DeviceBundle bundle = Bundle(
            stackUrl: $"https://{StackUrlSentinel}.example.invalid",
            archiveIngestUrl: $"https://{ArchiveIngestUrlSentinel}.example.invalid/api/archive-ingests");
        string text = bundle.ToString();
        Assert.DoesNotContain(StackUrlSentinel, text, StringComparison.Ordinal);
        Assert.DoesNotContain(ArchiveIngestUrlSentinel, text, StringComparison.Ordinal);
    }

    [Fact]
    public void MvpDeliveryTargetToStringCannotPrintTheStreamEndpoint()
    {
        using var client = RedirectSafeHttpClient.CreateForTests(new NeverCalledHandler());
        var sender = new MvpStreamSender($"https://stream.example.invalid/{EndpointPathSentinel}", client);
        var target = new MvpDeliveryTarget(sender, DateTimeOffset.UtcNow, Bundle());
        string text = target.ToString();
        Assert.DoesNotContain(EndpointPathSentinel, text, StringComparison.Ordinal);
        Assert.DoesNotContain("stream.example.invalid", text, StringComparison.Ordinal);
    }

    /// <summary>
    /// <see cref="MvpDeliveryTarget"/> was widened to carry the <see cref="DeviceBundle"/> for
    /// screenshot delivery's Storage routing. Widening a positional record's member set is exactly
    /// the kind of change that can silently reopen a compiler-generated <c>ToString()</c> leak, so
    /// this pins the same guarantee against the new member that the pre-existing tests already pin
    /// against <see cref="MvpStreamSender"/>'s endpoint.
    /// </summary>
    [Fact]
    public void MvpDeliveryTargetToStringCannotPrintTheBundleStorageToken()
    {
        using var client = RedirectSafeHttpClient.CreateForTests(new NeverCalledHandler());
        var sender = new MvpStreamSender("https://stream.example.invalid/capability", client);
        var target = new MvpDeliveryTarget(sender, DateTimeOffset.UtcNow, Bundle(token: TokenSentinel));
        Assert.DoesNotContain(TokenSentinel, target.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void DeviceBundleToStringIsTheFixedNonSecretShape()
    {
        DeviceBundle bundle = Bundle(
            deviceId: "device-1",
            tokenId: "token-id-1",
            projectId: "12345",
            expiresAt: "2026-01-01T00:00:00Z");
        Assert.Equal("DeviceBundle(jazz-device-bundle, device-1, token-id-1, 12345, 2026-01-01T00:00:00Z)", bundle.ToString());
    }

    [Fact]
    public void MvpDeliveryTargetToStringIsTheFixedNonSecretShape()
    {
        using var client = RedirectSafeHttpClient.CreateForTests(new NeverCalledHandler());
        var sender = new MvpStreamSender("https://stream.example.invalid/capability", client);
        var expiresAt = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        var target = new MvpDeliveryTarget(sender, expiresAt, Bundle());
        Assert.Equal("MvpDeliveryTarget(2026-01-01T00:00:00.0000000+00:00)", target.ToString());
    }

    /// <summary>
    /// Issue #48: the durable event spool is a new place captured content lands at rest, so it gets
    /// its own sink-can-carry-a-secret test rather than relying on the sentinel tests above, which
    /// only cover the two positional records. <see cref="EventSpool.Spool"/> takes only a session id,
    /// a sequence, and the already-serialized body -- never a credential or an endpoint -- so this is
    /// a regression guard: if a future change ever threaded either into the spool's file name or
    /// bookkeeping, this test starts failing instead of silently writing a secret to disk.
    /// </summary>
    [Fact]
    public void NoStreamEndpointOrTokenFieldEverReachesTheSpoolDirectory()
    {
        string root = Path.Combine(Path.GetTempPath(), "jazz-spool-secret-" + Guid.NewGuid().ToString("N"));
        try
        {
            var spool = new EventSpool(new EventDeliverySettings { SpoolDirectory = root });
            var context = new SessionContext(
                "s-1", new string('a', 32), new string('b', 16), "2026-01-01T00:00:00.000Z", null, "u", "h", null, null);
            var activityEvent = new ActivityEvent
            {
                EventId = "s-1-1",
                SessionId = "s-1",
                Sequence = 1,
                Timestamp = "2026-01-01T00:00:00.000Z",
                EventType = "click",
            };
            byte[] body = Encoding.UTF8.GetBytes(OtlpMapper.LogsRequest(new[] { activityEvent }, context).ToJsonString());

            Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool("s-1", 1, body));

            foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                // Latin1 maps every byte value 1:1 to a char, so a substring search over it finds a
                // sentinel regardless of the file's real encoding -- a byte-content check, not a
                // text-decoding one, matching ScreenshotStagingAreaTests.NoFederationCredentialFieldEverReachesDisk.
                string content = Encoding.Latin1.GetString(File.ReadAllBytes(file));
                Assert.DoesNotContain(EndpointPathSentinel, content, StringComparison.Ordinal);
                Assert.DoesNotContain(TokenSentinel, content, StringComparison.Ordinal);
                Assert.DoesNotContain(EndpointPathSentinel, Path.GetFileName(file), StringComparison.Ordinal);
                Assert.DoesNotContain(TokenSentinel, Path.GetFileName(file), StringComparison.Ordinal);
            }
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private static DeviceBundle Bundle(
        string kind = DeviceBundle.ExpectedKind,
        string deviceId = "device-1",
        string stackUrl = "https://connection.keboola.com",
        string projectId = "12345",
        string companyId = "company-1",
        string areaId = "area-1",
        string archiveIngestUrl = "https://example.invalid/api/archive-ingests",
        string? streamSourceId = "source-1",
        string? streamEndpoint = "https://stream.example.invalid/capability",
        string token = "token-1",
        string tokenId = "token-id-1",
        string expiresAt = "2026-01-01T00:00:00Z",
        JazzArchiveTokenBucketScope tokenBucketScope = JazzArchiveTokenBucketScope.None,
        string? sinkBucketId = null,
        IReadOnlyList<string>? componentAccess = null,
        string? enrollmentProfile = "mvp") =>
        new(kind, deviceId, stackUrl, projectId, companyId, areaId, archiveIngestUrl, streamSourceId, streamEndpoint, token, tokenId, expiresAt, tokenBucketScope, sinkBucketId, componentAccess ?? Array.Empty<string>(), enrollmentProfile);

    private sealed class NeverCalledHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("MvpDeliveryTarget.ToString() must not perform I/O.");
    }
}
