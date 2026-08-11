using System.Text.Json.Serialization;

namespace JazzCaptureCore;

/// <summary>
/// The application a captured event happened in.
/// </summary>
/// <param name="Namespace">Identifier namespace, e.g. <c>windows.aumid</c> or <c>macos.bundle-id</c>.</param>
/// <param name="Value">The identifier itself. Projected as <c>application.id</c> — the key is renamed.</param>
/// <param name="Name">Human-readable application name.</param>
/// <param name="Version">Application version string.</param>
public sealed record ApplicationRef(
    [property: JsonPropertyName("namespace")] string Namespace,
    [property: JsonPropertyName("value")] string Value,
    [property: JsonPropertyName("name")] string? Name = null,
    [property: JsonPropertyName("version")] string? Version = null);

/// <summary>Element rectangle in screen coordinates. All four components are required together.</summary>
public sealed record BoundingBox(
    [property: JsonPropertyName("x")] double X,
    [property: JsonPropertyName("y")] double Y,
    [property: JsonPropertyName("width")] double Width,
    [property: JsonPropertyName("height")] double Height);

/// <summary>Release point of a completed drag gesture.</summary>
public sealed record DragEnd(
    [property: JsonPropertyName("x")] double X,
    [property: JsonPropertyName("y")] double Y);

/// <summary>
/// The UI element an event was directed at, as resolved by the accessibility layer.
/// </summary>
/// <remarks>
/// <see cref="Text"/> is retained for archive records but is <em>never</em> projected to OTLP —
/// it can hold user content. The schema's <c>selectorCandidates</c> and <c>attributes</c> members
/// are browser-only and are ignored on input; the projection emits a constant empty
/// <c>target.selectorCandidates</c> instead.
/// </remarks>
public sealed record EventTarget
{
    [JsonPropertyName("tag")]
    public string? Tag { get; init; }

    [JsonPropertyName("role")]
    public string? Role { get; init; }

    [JsonPropertyName("accessibleName")]
    public string? AccessibleName { get; init; }

    [JsonPropertyName("text")]
    public string? Text { get; init; }

    [JsonPropertyName("boundingBox")]
    public BoundingBox? BoundingBox { get; init; }
}

/// <summary>
/// One captured activity event, mirroring <c>contract/schema/activity-event.schema.json</c>.
/// </summary>
/// <remarks>
/// Unknown JSON properties are ignored on purpose: browser-only members (<c>tabId</c>,
/// <c>frameId</c>, <c>viewport</c>, <c>rrwebChunkId</c>) travel through the same schema but have
/// no desktop meaning, and tolerating them keeps the model forward-compatible with schema
/// additions. Absent optional members stay <see langword="null"/> — the OTLP projection, not the
/// model, decides whether a missing value becomes an empty string or an omitted key.
/// </remarks>
public sealed record ActivityEvent
{
    [JsonPropertyName("sessionId")]
    public string SessionId { get; init; } = string.Empty;

    [JsonPropertyName("eventId")]
    public string EventId { get; init; } = string.Empty;

    /// <summary>Monotonic per-session ordinal. Numeric: omitted from OTLP when absent.</summary>
    [JsonPropertyName("sequence")]
    public int? Sequence { get; init; }

    /// <summary>ISO 8601 capture instant; the source of the record's nanosecond timestamps.</summary>
    [JsonPropertyName("timestamp")]
    public string Timestamp { get; init; } = string.Empty;

    /// <summary>One of the 24 contract event types. Only <c>narration</c> changes the projection.</summary>
    [JsonPropertyName("eventType")]
    public string EventType { get; init; } = string.Empty;

    [JsonPropertyName("url")]
    public string Url { get; init; } = string.Empty;

    [JsonPropertyName("application")]
    public ApplicationRef? Application { get; init; }

    /// <summary>Projected as <c>document.url</c>.</summary>
    [JsonPropertyName("documentURL")]
    public string? DocumentUrl { get; init; }

    [JsonPropertyName("pageTitle")]
    public string? PageTitle { get; init; }

    /// <summary>Legacy display hint (the owning application's short name).</summary>
    [JsonPropertyName("system")]
    public string? System { get; init; }

    [JsonPropertyName("target")]
    public EventTarget? Target { get; init; }

    /// <summary>Typed value, already redacted by the capture host.</summary>
    [JsonPropertyName("value")]
    public string? Value { get; init; }

    [JsonPropertyName("selectedText")]
    public string? SelectedText { get; init; }

    [JsonPropertyName("clipboardText")]
    public string? ClipboardText { get; init; }

    /// <summary>OS click multiplicity (1/2/3). Numeric: omitted from OTLP when absent.</summary>
    [JsonPropertyName("clickCount")]
    public int? ClickCount { get; init; }

    /// <summary>Drag release point. Numeric group: both keys omitted together when absent.</summary>
    [JsonPropertyName("dragEnd")]
    public DragEnd? DragEnd { get; init; }

    [JsonPropertyName("gestureId")]
    public string? GestureId { get; init; }

    /// <summary>True when <see cref="Value"/> was masked. Defaults to <see langword="false"/> in OTLP.</summary>
    [JsonPropertyName("inputMasked")]
    public bool? InputMasked { get; init; }

    [JsonPropertyName("isSensitive")]
    public bool? IsSensitive { get; init; }

    [JsonPropertyName("screenshotId")]
    public string? ScreenshotId { get; init; }

    /// <summary>Audio blob reference; only meaningful on <c>narration</c> events.</summary>
    [JsonPropertyName("audioFileId")]
    public string? AudioFileId { get; init; }

    [JsonPropertyName("labelId")]
    public string? LabelId { get; init; }

    /// <summary>Projected as <c>label.name</c>.</summary>
    [JsonPropertyName("label")]
    public string? Label { get; init; }

    [JsonPropertyName("processId")]
    public string? ProcessId { get; init; }

    /// <summary>Projected as <c>process.name</c>.</summary>
    [JsonPropertyName("process")]
    public string? Process { get; init; }
}
