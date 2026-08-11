using System.Text.Json;
using System.Text.Json.Nodes;
using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// Unit-level goldens for projection rules the shared conformance fixtures do not cover:
/// narration as a total replacement, numeric omission, the "now" timestamp fallback, and the
/// span's conditional attributes.
/// </summary>
public sealed class OtlpMapperTests
{
    private static readonly SessionContext FullContext = new(
        SessionId: "sess-ctx",
        TraceId: "0123456789abcdef0123456789abcdef",
        SpanId: "0123456789abcdef",
        StartedAt: "2026-07-02T09:00:00.000Z",
        Kind: "process-mapping",
        User: "ann@acme.com",
        InstanceName: "Ann's PC",
        AreaId: "finance",
        AreaName: "Finance");

    [Fact]
    public void NarrationReplacesTheAttributeSetEvenWhenTheEventCarriesGenericFields()
    {
        // A narration event that also carries target/sequence/url/value/application: every one of
        // those must be ignored, leaving exactly the 13-key narration shape.
        ActivityEvent narration = new()
        {
            SessionId = "sess-conf-003",
            EventId = "evt-003",
            Sequence = 42,
            Timestamp = "2026-07-02T10:03:20.000Z",
            EventType = "narration",
            Url = "app://com.microsoft.Edge",
            Value = "ignored",
            System = "ignored",
            ScreenshotId = "shot-1",
            ClickCount = 2,
            DragEnd = new DragEnd(1.0, 2.0),
            InputMasked = true,
            IsSensitive = true,
            Application = new ApplicationRef("windows.aumid", "com.acme.app", "Acme", "1.0"),
            Target = new EventTarget
            {
                Tag = "Button",
                Role = "button",
                AccessibleName = "Save",
                BoundingBox = new BoundingBox(1, 2, 3, 4),
            },
            AudioFileId = "audio-77",
            LabelId = "lbl-9",
            Label = "Explain the refund flow",
            ProcessId = "refund",
            Process = "Refund handling",
        };

        IReadOnlyList<OtlpKeyValue> attributes = OtlpMapper.Attributes(narration, FullContext);

        Assert.Equal(
            new[]
            {
                "session.id",
                "sessionId",
                "audio_file_id",
                "session.startedAt",
                "enduser.id",
                "host.name",
                "label.id",
                "label.name",
                "session.kind",
                "area.id",
                "area.name",
                "process.id",
                "process.name",
            },
            attributes.Select(attribute => attribute.Key).ToArray());
        Assert.Equal("2026-07-02T09:00:00.000Z", StringAttribute(attributes, "session.startedAt"));
        Assert.Equal("audio-77", StringAttribute(attributes, "audio_file_id"));
    }

    [Fact]
    public void NarrationKeepsEventBodyAndTimestamp()
    {
        ActivityEvent narration = new()
        {
            SessionId = "sess-conf-003",
            EventId = "evt-003",
            Timestamp = "2026-07-02T10:03:20.000Z",
            EventType = "narration",
            Url = string.Empty,
        };

        JsonObject record = FirstLogRecord(OtlpMapper.LogsRequest(new[] { narration }, FullContext));

        Assert.Equal("narration", record["body"]!["stringValue"]!.GetValue<string>());
        Assert.Equal("1782986600000000000", record["timeUnixNano"]!.GetValue<string>());
        Assert.Equal("1782986600000000000", record["observedTimeUnixNano"]!.GetValue<string>());
    }

    [Fact]
    public void GenericAttributesOmitNumericKeysWhenTheValuesAreAbsent()
    {
        ActivityEvent minimal = new()
        {
            SessionId = "sess-conf-001",
            EventId = "evt-legacy-001",
            Timestamp = "2026-07-02T09:00:05.250Z",
            EventType = "click",
            Url = "app://com.google.Chrome",
        };

        IReadOnlyList<OtlpKeyValue> attributes = OtlpMapper.Attributes(minimal, FullContext);
        string[] keys = attributes.Select(attribute => attribute.Key).ToArray();

        Assert.Equal(31, keys.Length);
        Assert.DoesNotContain("sequence", keys);
        Assert.DoesNotContain("click_count", keys);
        Assert.DoesNotContain("drag_end.x", keys);
        Assert.DoesNotContain("drag_end.y", keys);
        Assert.DoesNotContain("target.boundingBox.x", keys);
        Assert.DoesNotContain("target.boundingBox.y", keys);
        Assert.DoesNotContain("target.boundingBox.width", keys);
        Assert.DoesNotContain("target.boundingBox.height", keys);

        // Strings coerce to "" and keep their key; booleans default to false and keep their key.
        Assert.Equal(string.Empty, StringAttribute(attributes, "page_title"));
        Assert.Equal(string.Empty, StringAttribute(attributes, "target.selectorCandidates"));
        Assert.False(attributes.Single(attribute => attribute.Key == "input_masked").Value.Flag);
        Assert.False(attributes.Single(attribute => attribute.Key == "is_sensitive").Value.Flag);
    }

    [Fact]
    public void GenericAttributesEmitNumericKeysWithProtoJsonTyping()
    {
        ActivityEvent rich = new()
        {
            SessionId = "sess-conf-001",
            EventId = "evt-drag-001",
            Sequence = 7,
            Timestamp = "2026-07-02T09:00:05.250Z",
            EventType = "drag",
            Url = "app://com.google.Chrome",
            ClickCount = 2,
            DragEnd = new DragEnd(420.5, 310.25),
            Target = new EventTarget { BoundingBox = new BoundingBox(20, 30, 180, 24) },
        };

        JsonObject record = FirstLogRecord(OtlpMapper.LogsRequest(new[] { rich }, FullContext));
        JsonArray attributes = record["attributes"]!.AsArray();

        Assert.Equal(39, attributes.Count);

        // int64 travels as a decimal STRING in proto3 JSON; doubles stay JSON numbers.
        JsonNode sequence = AttributeValue(attributes, "sequence");
        Assert.Equal(JsonValueKind.String, sequence["intValue"]!.GetValueKind());
        Assert.Equal("7", sequence["intValue"]!.GetValue<string>());
        Assert.Equal("2", AttributeValue(attributes, "click_count")["intValue"]!.GetValue<string>());

        JsonNode dragX = AttributeValue(attributes, "drag_end.x");
        Assert.Equal(JsonValueKind.Number, dragX["doubleValue"]!.GetValueKind());
        Assert.Equal(420.5, dragX["doubleValue"]!.GetValue<double>());
        Assert.Equal(24.0, AttributeValue(attributes, "target.boundingBox.height")["doubleValue"]!.GetValue<double>());

        // severityNumber is a bare number, the nano timestamps are strings.
        Assert.Equal(JsonValueKind.Number, record["severityNumber"]!.GetValueKind());
        Assert.Equal(JsonValueKind.String, record["timeUnixNano"]!.GetValueKind());
        Assert.Equal(JsonValueKind.False, AttributeValue(attributes, "input_masked")["boolValue"]!.GetValueKind());
    }

    [Fact]
    public void UnparseableEventTimestampFallsBackToTheInjectedNow()
    {
        ActivityEvent broken = new()
        {
            SessionId = "sess-conf-001",
            EventId = "evt-broken",
            Timestamp = "not-a-date",
            EventType = "click",
            Url = "app://com.google.Chrome",
        };
        DateTimeOffset now = DateTimeOffset.FromUnixTimeSeconds(1781344800);

        JsonObject record = FirstLogRecord(OtlpMapper.LogsRequest(new[] { broken }, FullContext, () => now));

        Assert.Equal("1781344800000000000", record["timeUnixNano"]!.GetValue<string>());
        Assert.Equal("1781344800000000000", record["observedTimeUnixNano"]!.GetValue<string>());
    }

    [Fact]
    public void UnparseableSpanTimestampsFallBackToTheInjectedNow()
    {
        SessionContext context = FullContext with { StartedAt = "2026-06-13" };
        DateTimeOffset now = DateTimeOffset.FromUnixTimeSeconds(1781344800);

        JsonObject span = FirstSpan(OtlpMapper.TraceRequest(context, "still-not-a-date", () => now));

        Assert.Equal("1781344800000000000", span["startTimeUnixNano"]!.GetValue<string>());
        Assert.Equal("1781344800000000000", span["endTimeUnixNano"]!.GetValue<string>());
        Assert.Equal("still-not-a-date", SpanAttribute(span, "session.endedAt"));
    }

    [Fact]
    public void SpanDropsUnsetKindAndAreaInsteadOfEmittingEmptyStrings()
    {
        SessionContext bare = FullContext with { Kind = null, AreaId = null, AreaName = null };

        JsonObject span = FirstSpan(OtlpMapper.TraceRequest(bare, "2026-07-02T09:12:00.000Z"));

        Assert.Equal(
            new[] { "session.id", "session.endedAt" },
            span["attributes"]!.AsArray().Select(attribute => attribute!["key"]!.GetValue<string>()).ToArray());
        // The span's session.id comes from the CONTEXT, unlike the log record's.
        Assert.Equal("sess-ctx", SpanAttribute(span, "session.id"));
        Assert.Equal(JsonValueKind.Number, span["kind"]!.GetValueKind());
        Assert.Equal(1, span["kind"]!.GetValue<int>());
    }

    [Fact]
    public void SpanEmitsAreaNameOnlyWhenAreaIdIsSet()
    {
        SessionContext orphanName = FullContext with { AreaId = null, AreaName = "Finance" };

        JsonObject span = FirstSpan(OtlpMapper.TraceRequest(orphanName, "2026-07-02T09:12:00.000Z"));
        string[] keys = span["attributes"]!.AsArray()
            .Select(attribute => attribute!["key"]!.GetValue<string>())
            .ToArray();

        Assert.DoesNotContain("area.id", keys);
        Assert.DoesNotContain("area.name", keys);

        SessionContext idOnly = FullContext with { AreaName = null };
        string[] idOnlyKeys = FirstSpan(OtlpMapper.TraceRequest(idOnly, "2026-07-02T09:12:00.000Z"))["attributes"]!
            .AsArray()
            .Select(attribute => attribute!["key"]!.GetValue<string>())
            .ToArray();

        Assert.Contains("area.id", idOnlyKeys);
        Assert.DoesNotContain("area.name", idOnlyKeys);
    }

    [Fact]
    public void LogRecordIdentityComesFromTheEventWhileSessionScopeComesFromTheContext()
    {
        ActivityEvent renamed = new()
        {
            SessionId = "sess-from-event",
            EventId = "evt-1",
            Timestamp = "2026-07-02T09:00:05.250Z",
            EventType = "click",
            Url = "app://x",
            Application = new ApplicationRef("windows.aumid", "com.acme.app", "Acme", "1.0"),
            DocumentUrl = "file:///doc",
            PageTitle = "Title",
            SelectedText = "sel",
            ClipboardText = "clip",
            Label = "Label name",
            LabelId = "lbl-1",
            Process = "Process name",
            ProcessId = "proc-1",
            Target = new EventTarget { Text = "never emitted" },
        };

        IReadOnlyList<OtlpKeyValue> attributes = OtlpMapper.Attributes(renamed, FullContext);

        Assert.Equal("sess-from-event", StringAttribute(attributes, "session.id"));
        Assert.Equal("sess-from-event", StringAttribute(attributes, "sessionId"));
        Assert.Equal("ann@acme.com", StringAttribute(attributes, "enduser.id"));
        Assert.Equal("Ann's PC", StringAttribute(attributes, "host.name"));
        // Key renames from the digest table.
        Assert.Equal("com.acme.app", StringAttribute(attributes, "application.id"));
        Assert.Equal("file:///doc", StringAttribute(attributes, "document.url"));
        Assert.Equal("Title", StringAttribute(attributes, "page_title"));
        Assert.Equal("sel", StringAttribute(attributes, "selected_text"));
        Assert.Equal("clip", StringAttribute(attributes, "clipboard_text"));
        Assert.Equal("Label name", StringAttribute(attributes, "label.name"));
        Assert.Equal("Process name", StringAttribute(attributes, "process.name"));
        // target.text is never projected.
        Assert.DoesNotContain("target.text", attributes.Select(attribute => attribute.Key));
    }

    [Fact]
    public void EmptyEventListStillEmitsTheSingleResourceAndScopeWrapper()
    {
        JsonObject request = OtlpMapper.LogsRequest(Array.Empty<ActivityEvent>(), FullContext);

        JsonArray resourceLogs = request["resourceLogs"]!.AsArray();
        Assert.Single(resourceLogs);
        JsonArray scopeLogs = resourceLogs[0]!["scopeLogs"]!.AsArray();
        Assert.Single(scopeLogs);
        Assert.Equal("jazz.agent", scopeLogs[0]!["scope"]!["name"]!.GetValue<string>());
        Assert.Empty(scopeLogs[0]!["logRecords"]!.AsArray());
        Assert.Equal(
            new[] { "service.name", "service.instance.id", "enduser.id", "host.name" },
            resourceLogs[0]!["resource"]!["attributes"]!.AsArray()
                .Select(attribute => attribute!["key"]!.GetValue<string>())
                .ToArray());
    }

    [Fact]
    public void UnknownEventPropertiesAreIgnoredOnDeserialization()
    {
        const string json = """
            {
              "sessionId": "s",
              "eventId": "e",
              "timestamp": "2026-07-02T09:00:05.250Z",
              "eventType": "click",
              "url": "app://x",
              "tabId": 12,
              "frameId": 0,
              "rrwebChunkId": "chunk",
              "viewport": { "width": 100, "height": 200, "scrollX": 0, "scrollY": 0 },
              "target": { "selectorCandidates": [ { "kind": "css", "value": "#a" } ], "attributes": { "id": "a" } }
            }
            """;

        ActivityEvent decoded = JsonSerializer.Deserialize<ActivityEvent>(json)!;

        Assert.Equal("click", decoded.EventType);
        Assert.NotNull(decoded.Target);
        Assert.Null(decoded.Sequence);
    }

    private static JsonObject FirstLogRecord(JsonObject logsRequest) =>
        logsRequest["resourceLogs"]![0]!["scopeLogs"]![0]!["logRecords"]![0]!.AsObject();

    private static JsonObject FirstSpan(JsonObject traceRequest) =>
        traceRequest["resourceSpans"]![0]!["scopeSpans"]![0]!["spans"]![0]!.AsObject();

    private static string StringAttribute(IReadOnlyList<OtlpKeyValue> attributes, string key) =>
        attributes.Single(attribute => attribute.Key == key).Value.Text;

    private static string SpanAttribute(JsonObject span, string key) =>
        AttributeValue(span["attributes"]!.AsArray(), key)["stringValue"]!.GetValue<string>();

    private static JsonNode AttributeValue(JsonArray attributes, string key) =>
        attributes.Single(attribute => attribute!["key"]!.GetValue<string>() == key)!["value"]!;
}
