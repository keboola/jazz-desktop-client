using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// Runs every <c>contract/conformance/fixtures/*.json</c> golden through the OTLP mapper.
/// </summary>
/// <remarks>
/// This suite is the executable specification for the projection: the fixtures are shared
/// verbatim with the macOS client, so a passing run means both clients are indistinguishable at
/// the contract boundary. Comparison is structural (object member order irrelevant, array order
/// binding, numbers by value) but JSON value kinds are binding — <c>intValue</c> must stay a JSON
/// string while <c>doubleValue</c>, <c>severityNumber</c>, and span <c>kind</c> stay JSON numbers.
/// </remarks>
public sealed class OtlpMapperConformanceTests
{
    /// <summary>Context value used when a fixture omits <c>service_name</c>.</summary>
    private const string DefaultServiceName = "jasnost-capture";

    public static IEnumerable<object[]> FixtureNames() =>
        ContractPaths.ConformanceFixtureNames().Select(name => new object[] { name });

    [Fact]
    public void FixtureSetIsNotEmpty()
    {
        IReadOnlyList<string> names = ContractPaths.ConformanceFixtureNames();

        Assert.NotEmpty(names);
        Assert.Equal(names.OrderBy(name => name, StringComparer.Ordinal).ToList(), names);
    }

    [Theory]
    [MemberData(nameof(FixtureNames))]
    public void FixtureProducesGoldenLogsRequest(string fixtureName)
    {
        Fixture fixture = Fixture.Load(fixtureName);

        JsonNode produced = Reparse(OtlpMapper.LogsRequest(fixture.Events, fixture.Context));

        AssertGolden(fixture.Name, "logs", fixture.ExpectedLogs, produced);
    }

    [Theory]
    [MemberData(nameof(FixtureNames))]
    public void FixtureProducesGoldenTraceRequest(string fixtureName)
    {
        Fixture fixture = Fixture.Load(fixtureName);

        JsonNode produced = Reparse(OtlpMapper.TraceRequest(fixture.Context, fixture.EndedAt));

        AssertGolden(fixture.Name, "traces", fixture.ExpectedTraces, produced);
    }

    /// <summary>
    /// Serializes and re-parses the produced tree, exactly as the macOS runner does, so the
    /// comparison sees the same JSON value kinds a real exporter would put on the wire.
    /// </summary>
    private static JsonNode Reparse(JsonObject produced) =>
        JsonNode.Parse(produced.ToJsonString())
        ?? throw new InvalidOperationException("Produced request serialized to JSON null.");

    private static void AssertGolden(string fixtureName, string side, JsonNode expected, JsonNode produced)
    {
        if (JsonDeepComparer.DeepEquals(expected, produced))
        {
            return;
        }

        JsonSerializerOptions indented = new() { WriteIndented = true };
        Assert.Fail(
            $"Conformance mismatch in fixture '{fixtureName}' ({side}).{Environment.NewLine}"
            + $"--- expected (golden '{side}') ---{Environment.NewLine}"
            + $"{expected.ToJsonString(indented)}{Environment.NewLine}"
            + $"--- produced (OtlpMapper) ---{Environment.NewLine}"
            + produced.ToJsonString(indented));
    }

    /// <summary>One parsed fixture file, decoded per the runner contract.</summary>
    private sealed class Fixture
    {
        private Fixture(
            string name,
            SessionContext context,
            IReadOnlyList<ActivityEvent> events,
            string endedAt,
            JsonNode expectedLogs,
            JsonNode expectedTraces)
        {
            Name = name;
            Context = context;
            Events = events;
            EndedAt = endedAt;
            ExpectedLogs = expectedLogs;
            ExpectedTraces = expectedTraces;
        }

        public string Name { get; }

        public SessionContext Context { get; }

        public IReadOnlyList<ActivityEvent> Events { get; }

        public string EndedAt { get; }

        public JsonNode ExpectedLogs { get; }

        public JsonNode ExpectedTraces { get; }

        public static Fixture Load(string fixtureName)
        {
            string path = Path.Combine(ContractPaths.ConformanceFixturesDirectory(), fixtureName);
            string text = File.ReadAllText(path, Encoding.UTF8);
            JsonObject root = JsonNode.Parse(text)?.AsObject()
                              ?? throw new InvalidOperationException($"Fixture '{fixtureName}' is not a JSON object.");
            JsonObject input = Required(root, "input").AsObject();

            return new Fixture(
                fixtureName,
                BuildContext(input["context"]?.AsObject()),
                BuildEvents(input["events"]),
                Text(input, "endedAt") ?? throw new InvalidOperationException($"Fixture '{fixtureName}' has no input.endedAt."),
                Required(root, "logs"),
                Required(root, "traces"));
        }

        private static JsonNode Required(JsonObject owner, string key) =>
            owner[key] ?? throw new InvalidOperationException($"Fixture is missing the required '{key}' member.");

        /// <summary>
        /// Reads <c>input.context</c>: every member defaults to the empty string, then
        /// <c>kind</c>/<c>area_id</c>/<c>area_name</c> treat the empty string as "unset" (null).
        /// <c>instance_name</c> deliberately keeps its empty string.
        /// </summary>
        private static SessionContext BuildContext(JsonObject? context) =>
            new(
                SessionId: Text(context, "session_id") ?? string.Empty,
                TraceId: Text(context, "trace_id") ?? string.Empty,
                SpanId: Text(context, "span_id") ?? string.Empty,
                StartedAt: Text(context, "started_at") ?? string.Empty,
                Kind: NullIfEmpty(Text(context, "kind")),
                User: Text(context, "user") ?? string.Empty,
                InstanceName: Text(context, "instance_name") ?? string.Empty,
                AreaId: NullIfEmpty(Text(context, "area_id")),
                AreaName: NullIfEmpty(Text(context, "area_name")),
                ServiceName: NullIfEmpty(Text(context, "service_name")) ?? DefaultServiceName);

        private static IReadOnlyList<ActivityEvent> BuildEvents(JsonNode? events)
        {
            if (events is null)
            {
                return Array.Empty<ActivityEvent>();
            }

            return JsonSerializer.Deserialize<List<ActivityEvent>>(events.ToJsonString())
                   ?? throw new InvalidOperationException("Fixture input.events did not decode.");
        }

        private static string? Text(JsonObject? owner, string key) =>
            owner?[key] is JsonNode node && node.GetValueKind() == JsonValueKind.String
                ? node.GetValue<string>()
                : null;

        private static string? NullIfEmpty(string? value) => string.IsNullOrEmpty(value) ? null : value;
    }
}
