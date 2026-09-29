using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the Windows client's cross-repository identifiers to <c>contract/identifiers.json</c>, the
/// manifest the macOS client and the processor test against too.
/// </summary>
/// <remarks>
/// The OTLP session attribute keys are asserted on the real mapper output rather than on hoisted
/// constants: the keys are inline in <see cref="OtlpMapper"/> by design (the conformance goldens pin
/// their order), and driving the mapper checks what is actually emitted.
/// </remarks>
public sealed class IdentifierParityTests
{
    private static readonly JsonObject Manifest = LoadManifest();

    private static JsonObject LoadManifest()
    {
        string path = Path.Combine(ContractPaths.Root(), "contract", "identifiers.json");
        return JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    }

    private static string Canonical(string section, string key) =>
        Manifest[section]![key]!["canonical"]!.GetValue<string>();

    [Fact]
    public void OtlpServiceAndScopeMatchTheManifest()
    {
        Assert.Equal(Canonical("otlp", "serviceName"), OtlpMapper.DefaultServiceName);
        Assert.Equal(Canonical("otlp", "scopeName"), Otlp.ScopeName);
    }

    [Fact]
    public void ArtifactKindTagsMatchTheManifest()
    {
        // KeboolaFilesClient stamps the artifact kind as the first Storage-File tag.
        Assert.Equal(Canonical("storageTags", "screenshot"), ScreenshotEvidenceV1.Kind);
        Assert.Equal(Canonical("storageTags", "narrationAudio"), NarrationAudioV1.Kind);
    }

    [Fact]
    public void PayloadSchemaIdsSitUnderTheManifestBase()
    {
        string schemaIdBase = Manifest["schemaIdBase"]!["canonical"]!.GetValue<string>();

        Assert.StartsWith(schemaIdBase, ArchiveContracts.ActivityEventPayloadSchema, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("click")]
    [InlineData("narration")]
    public void EveryRecordCarriesTheManifestSessionAttributes(string eventType)
    {
        SessionContext context = new(
            SessionId: "sess-parity",
            TraceId: "0123456789abcdef0123456789abcdef",
            SpanId: "0123456789abcdef",
            StartedAt: "2026-07-02T09:00:00.000Z",
            Kind: "process-mapping",
            User: "ann@example.com",
            InstanceName: "Ann's PC",
            AreaId: "finance",
            AreaName: "Finance",
            CompanyId: "acme",
            DeviceId: "device-ann-01");
        ActivityEvent activityEvent = new()
        {
            SessionId = "sess-parity",
            EventId = "evt-parity-1",
            Timestamp = "2026-07-02T09:00:01.000Z",
            EventType = eventType,
            Url = "app://com.example.x",
            AudioFileId = "42",
            LabelId = "lbl-parity",
            Label = "Refund",
            ProcessId = "refund",
            Process = "Refund handling",
        };

        string[] keys = OtlpMapper.Attributes(activityEvent, context)
            .Select(attribute => attribute.Key)
            .ToArray();

        foreach (JsonNode? key in Manifest["sessionAttributes"]!.AsArray())
        {
            Assert.Contains(key!.GetValue<string>(), keys);
        }
    }
}
