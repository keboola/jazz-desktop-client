using System.Text.Json;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// A narration clip is projected long after capture, possibly by a newer build after a relaunch.
/// Its client version must be the one that recorded it — persisted in the sidecar — and a sidecar
/// staged before the field existed must project an unknown (empty) version, never the replaying
/// executable's own.
/// </summary>
public sealed class PendingNarrationContextTests
{
    [Fact]
    public void TheRebuiltContextCarriesThePersistedClientVersion()
    {
        PendingNarration pending = Pending() with { ServiceVersion = "0.27.0" };

        Assert.Equal("0.27.0", pending.ToSessionContext().ServiceVersion);
    }

    [Fact]
    public void ASidecarStagedBeforeTheVersionExistedProjectsAnUnknownVersion()
    {
        string json = JsonSerializer.Serialize(Pending());
        using JsonDocument document = JsonDocument.Parse(json);
        var legacy = document.RootElement.EnumerateObject()
            .Where(property => property.Name != nameof(PendingNarration.ServiceVersion))
            .ToDictionary(property => property.Name, property => property.Value.Clone());

        PendingNarration decoded = JsonSerializer.Deserialize<PendingNarration>(JsonSerializer.Serialize(legacy))!;

        Assert.Null(decoded.ServiceVersion);
        SessionContext context = decoded.ToSessionContext();
        Assert.Equal(string.Empty, context.ServiceVersion);
        Assert.NotEqual(BuildIdentity.ProducerVersion, context.ServiceVersion);
        Assert.Equal(
            string.Empty,
            OtlpMapper.Resource(context)["attributes"]!.AsArray()
                .Single(attribute => attribute!["key"]!.GetValue<string>() == "service.version")!
                ["value"]!["stringValue"]!.GetValue<string>());
    }

    [Fact]
    public void TheRebuiltContextKeepsTheSessionIdentity()
    {
        SessionContext context = (Pending() with { CompanyId = "acme", DeviceId = "pc-1", AreaId = "fin" }).ToSessionContext();

        Assert.Equal("s-1", context.SessionId);
        Assert.Equal("0123456789abcdef0123456789abcdef", context.TraceId);
        Assert.Equal("0123456789abcdef", context.SpanId);
        Assert.Equal("2026-01-01T00:00:00.000Z", context.StartedAt);
        Assert.Null(context.Kind);
        Assert.Equal("user1", context.User);
        Assert.Equal("machine1", context.InstanceName);
        Assert.Equal("jazz-capture", context.ServiceName);
        Assert.Equal("acme", context.CompanyId);
        Assert.Equal("pc-1", context.DeviceId);
        Assert.Equal("fin", context.AreaId);
    }

    private static PendingNarration Pending() => new(
        SessionId: "s-1",
        ArchiveId: "ar-test",
        CaptureId: "cap-test",
        ArtifactId: "art-test-1",
        EventId: "s-1-1",
        Sequence: 1,
        Timestamp: "2026-01-01T00:00:00.000Z",
        LabelId: "lbl-1",
        Label: "Task step",
        MediaType: "audio/wav",
        Sha256: new string('0', 64),
        ByteLength: 0,
        StagedAt: "2026-01-01T00:00:00.000Z",
        TraceId: "0123456789abcdef0123456789abcdef",
        SpanId: "0123456789abcdef",
        SessionStartedAt: "2026-01-01T00:00:00.000Z",
        User: "user1",
        InstanceName: "machine1",
        ServiceName: "jazz-capture",
        FilesId: null);
}
