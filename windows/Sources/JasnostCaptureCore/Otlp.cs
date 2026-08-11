using System.Globalization;
using System.Text.Json.Nodes;

namespace JasnostCaptureCore;

/// <summary>Which member an <see cref="OtlpAnyValue"/> carries on the wire.</summary>
public enum OtlpValueKind
{
    /// <summary><c>stringValue</c> — a JSON string.</summary>
    String,

    /// <summary><c>boolValue</c> — a native JSON boolean.</summary>
    Bool,

    /// <summary><c>intValue</c> — a decimal JSON <em>string</em>, per proto3 JSON int64 mapping.</summary>
    Int,

    /// <summary><c>doubleValue</c> — a native JSON number.</summary>
    Double,
}

/// <summary>
/// An OTLP <c>AnyValue</c>: exactly one of the four scalar members the capture projection uses.
/// </summary>
/// <remarks>
/// The JSON value kinds are part of the downstream SQL contract and must not drift:
/// <c>intValue</c> is a decimal string (proto3 JSON encodes int64 as a string so 64-bit values
/// survive JavaScript consumers), while <c>doubleValue</c> stays a bare JSON number. Emitting an
/// int as a number, or a double as a string, silently changes the column type downstream.
/// </remarks>
public sealed record OtlpAnyValue
{
    private OtlpAnyValue(OtlpValueKind kind, string text, bool flag, long integer, double number)
    {
        Kind = kind;
        Text = text;
        Flag = flag;
        Integer = integer;
        Number = number;
    }

    /// <summary>Which member is populated.</summary>
    public OtlpValueKind Kind { get; }

    /// <summary>The string payload; empty for non-string kinds.</summary>
    public string Text { get; }

    /// <summary>The boolean payload; <see langword="false"/> for non-boolean kinds.</summary>
    public bool Flag { get; }

    /// <summary>The int64 payload; zero for non-integer kinds.</summary>
    public long Integer { get; }

    /// <summary>The double payload; zero for non-double kinds.</summary>
    public double Number { get; }

    public static OtlpAnyValue FromString(string value) =>
        new(OtlpValueKind.String, value, false, 0L, 0d);

    public static OtlpAnyValue FromBool(bool value) =>
        new(OtlpValueKind.Bool, string.Empty, value, 0L, 0d);

    public static OtlpAnyValue FromInt(long value) =>
        new(OtlpValueKind.Int, string.Empty, false, value, 0d);

    public static OtlpAnyValue FromDouble(double value) =>
        new(OtlpValueKind.Double, string.Empty, false, 0L, value);

    /// <summary>Renders the value as its single-member OTLP/JSON object.</summary>
    public JsonObject ToJson() => Kind switch
    {
        OtlpValueKind.String => new JsonObject { ["stringValue"] = Text },
        OtlpValueKind.Bool => new JsonObject { ["boolValue"] = Flag },
        OtlpValueKind.Int => new JsonObject
        {
            ["intValue"] = Integer.ToString(CultureInfo.InvariantCulture),
        },
        OtlpValueKind.Double => new JsonObject { ["doubleValue"] = Number },
        _ => throw new InvalidOperationException($"Unsupported OTLP value kind '{Kind}'."),
    };
}

/// <summary>One OTLP attribute. Attribute <em>order</em> inside a record is part of the contract.</summary>
public sealed record OtlpKeyValue(string Key, OtlpAnyValue Value)
{
    public static OtlpKeyValue Str(string key, string value) => new(key, OtlpAnyValue.FromString(value));

    public static OtlpKeyValue Bool(string key, bool value) => new(key, OtlpAnyValue.FromBool(value));

    public static OtlpKeyValue Int(string key, long value) => new(key, OtlpAnyValue.FromInt(value));

    public static OtlpKeyValue Double(string key, double value) => new(key, OtlpAnyValue.FromDouble(value));

    public JsonObject ToJson() => new()
    {
        ["key"] = Key,
        ["value"] = Value.ToJson(),
    };
}

/// <summary>
/// OTLP/JSON envelope writers shared by the logs and traces requests.
/// </summary>
/// <remarks>
/// Each request carries exactly one <c>resource*</c> element wrapping exactly one <c>scope*</c>
/// element — even when the payload is empty. The scope object contains nothing but its name.
/// </remarks>
public static class Otlp
{
    /// <summary>Instrumentation scope name identifying the native capture agent.</summary>
    public const string ScopeName = "jasnost.agent";

    /// <summary>Serializes an ordered attribute list; the order is preserved verbatim.</summary>
    public static JsonArray Attributes(IEnumerable<OtlpKeyValue> attributes)
    {
        JsonArray array = new();
        foreach (OtlpKeyValue attribute in attributes)
        {
            array.Add(attribute.ToJson());
        }

        return array;
    }

    /// <summary>The <c>{"name": "jasnost.agent"}</c> scope object — no version, no attributes.</summary>
    public static JsonObject Scope() => new() { ["name"] = ScopeName };

    /// <summary>An <c>ExportLogsServiceRequest</c> around one resource, one scope, and the records.</summary>
    public static JsonObject LogsRequest(JsonObject resource, IEnumerable<JsonObject> logRecords)
    {
        JsonArray records = new();
        foreach (JsonObject record in logRecords)
        {
            records.Add(record);
        }

        return new JsonObject
        {
            ["resourceLogs"] = new JsonArray
            {
                new JsonObject
                {
                    ["resource"] = resource,
                    ["scopeLogs"] = new JsonArray
                    {
                        new JsonObject
                        {
                            ["scope"] = Scope(),
                            ["logRecords"] = records,
                        },
                    },
                },
            },
        };
    }

    /// <summary>An <c>ExportTraceServiceRequest</c> around one resource, one scope, and the spans.</summary>
    public static JsonObject TraceRequest(JsonObject resource, IEnumerable<JsonObject> spans)
    {
        JsonArray items = new();
        foreach (JsonObject span in spans)
        {
            items.Add(span);
        }

        return new JsonObject
        {
            ["resourceSpans"] = new JsonArray
            {
                new JsonObject
                {
                    ["resource"] = resource,
                    ["scopeSpans"] = new JsonArray
                    {
                        new JsonObject
                        {
                            ["scope"] = Scope(),
                            ["spans"] = items,
                        },
                    },
                },
            },
        };
    }
}
