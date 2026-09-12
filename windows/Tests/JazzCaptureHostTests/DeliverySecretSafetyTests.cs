using System.Reflection;
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
    /// only cover the two positional records.
    /// </summary>
    /// <remarks>
    /// A prior version of this test never brought a real credential into scope at all -- neither
    /// <see cref="SessionContext"/> nor <see cref="ActivityEvent"/> has an endpoint or token field to
    /// plant a sentinel in, so every <c>DoesNotContain</c> assertion passed regardless of whether the
    /// production wiring was safe (review finding: a tautological test). This version brings a real
    /// <see cref="DeviceBundle"/> and <see cref="MvpDeliveryTarget"/> carrying both sentinels into the
    /// same scope as the spool call -- the shape a live credential actually has in
    /// <c>App.xaml.cs</c> -- so the arrangement at least resembles the real capture-to-spool seam,
    /// even though <see cref="EventSpool.Spool"/> itself never receives either object.
    /// <see cref="EventSpoolsPublicSurfaceCannotAcceptOrReturnAnythingThatCarriesACredential"/> below
    /// is the guarantee that actually closes the gap: it proves structurally, not just for today's
    /// call pattern, that <see cref="EventSpool"/>'s public surface has no parameter or return type
    /// that could ever carry either secret, so a future change that threaded one in would first have
    /// to change a public signature this test pins.
    /// </remarks>
    [Fact]
    public void NoStreamEndpointOrTokenFieldEverReachesTheSpoolDirectory()
    {
        string root = Path.Combine(Path.GetTempPath(), "jazz-spool-secret-" + Guid.NewGuid().ToString("N"));
        try
        {
            // A live credential, carrying both sentinels, in scope for the whole test -- see this
            // method's own remarks -- even though nothing below ever passes it to the spool.
            using var client = RedirectSafeHttpClient.CreateForTests(new NeverCalledHandler());
            DeviceBundle bundle = Bundle(token: TokenSentinel);
            var target = new MvpDeliveryTarget(
                new MvpStreamSender($"https://stream.example.invalid/{EndpointPathSentinel}", client),
                DateTimeOffset.UtcNow.AddHours(1),
                bundle);

            // EventSpool.Spool requires the ArchiveIdentity.SessionId shape ("s-" + a UUIDv7) since
            // that is the only shape AdoptAtLaunch will ever re-enrol on a relaunch.
            string sessionId = JazzCaptureCore.Identifiers.Prefixed("s");
            var spool = new EventSpool(new EventDeliverySettings { SpoolDirectory = root });
            var context = new SessionContext(
                sessionId, new string('a', 32), new string('b', 16), "2026-01-01T00:00:00.000Z", null, "u", "h", null, null);
            var activityEvent = new ActivityEvent
            {
                EventId = sessionId + "-1",
                SessionId = sessionId,
                Sequence = 1,
                Timestamp = "2026-01-01T00:00:00.000Z",
                EventType = "click",
            };
            byte[] body = Encoding.UTF8.GetBytes(OtlpMapper.LogsRequest(new[] { activityEvent }, context).ToJsonString());

            Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(sessionId, 1, body));

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

            // The live credential is still exactly what it was constructed as -- proof this test
            // never quietly stopped exercising a real sentinel-carrying target along the way.
            Assert.DoesNotContain(EndpointPathSentinel, target.ToString(), StringComparison.Ordinal);
            Assert.Equal(TokenSentinel, bundle.Token);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    /// <summary>
    /// Replaces reliance on the test above alone with a structural guarantee (review finding: the
    /// runtime test above, even strengthened, still cannot prove a *future* capture-to-spool wiring
    /// change stays safe -- only that today's call pattern is). Not one public member of
    /// <see cref="EventSpool"/> -- constructor, method, or property -- may accept or return
    /// <see cref="DeviceBundle"/>, <see cref="MvpDeliveryTarget"/>, or <see cref="MvpStreamSender"/>,
    /// the three types in this assembly that can carry the Storage token or the stream endpoint's
    /// capability path. That holds regardless of how <c>App.SendCapturedEventAsync</c> is wired
    /// today or wired differently tomorrow: a future change that threaded a credential into a
    /// spooled file would first have to change <see cref="EventSpool"/>'s own public signature to
    /// accept one, which this test fails the moment it happens.
    /// </summary>
    [Fact]
    public void EventSpoolsPublicSurfaceCannotAcceptOrReturnAnythingThatCarriesACredential()
    {
        var credentialCarryingTypes = new HashSet<Type> { typeof(DeviceBundle), typeof(MvpDeliveryTarget), typeof(MvpStreamSender) };
        var offending = new List<string>();

        void Check(Type candidate, string where)
        {
            Type unwrapped = Nullable.GetUnderlyingType(candidate) ?? candidate;
            if (credentialCarryingTypes.Contains(unwrapped))
            {
                offending.Add(where + " is (or returns) " + unwrapped.Name);
            }
        }

        Type spoolType = typeof(EventSpool);
        const BindingFlags PublicInstance = BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly;

        foreach (ConstructorInfo constructor in spoolType.GetConstructors(BindingFlags.Public | BindingFlags.Instance))
        {
            foreach (ParameterInfo parameter in constructor.GetParameters())
            {
                Check(parameter.ParameterType, $"{spoolType.Name} constructor parameter '{parameter.Name}'");
            }
        }

        foreach (MethodInfo method in spoolType.GetMethods(PublicInstance))
        {
            if (method.IsSpecialName)
            {
                // Property accessors (get_X/set_X) are covered directly via GetProperties below.
                continue;
            }

            Check(method.ReturnType, $"{spoolType.Name}.{method.Name}'s return type");
            foreach (ParameterInfo parameter in method.GetParameters())
            {
                Check(parameter.ParameterType, $"{spoolType.Name}.{method.Name}'s parameter '{parameter.Name}'");
            }
        }

        foreach (PropertyInfo property in spoolType.GetProperties(PublicInstance))
        {
            Check(property.PropertyType, $"{spoolType.Name}.{property.Name}");
        }

        Assert.True(
            offending.Count == 0,
            "EventSpool's public surface must never accept or return a credential-carrying type: " + string.Join("; ", offending));
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
