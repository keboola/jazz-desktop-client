using System.Globalization;
using System.Text.Json.Nodes;

namespace JasnostCaptureCore;

/// <summary>
/// Everything the projection needs to know about one capture session.
/// </summary>
/// <param name="SessionId">Session identifier. Used for the <em>span's</em> <c>session.id</c>; log records use the event's own.</param>
/// <param name="TraceId">32 lowercase hex chars, minted once per session and shared by every record and the span.</param>
/// <param name="SpanId">16 lowercase hex chars, minted once per session.</param>
/// <param name="StartedAt">ISO 8601 session start: the span start time and the narration record's <c>session.startedAt</c>.</param>
/// <param name="Kind">Optional session classification. Emitted as <c>""</c> on log records but <em>dropped</em> from the span when null.</param>
/// <param name="User">The captured user — resource <c>service.instance.id</c>/<c>enduser.id</c> and a per-record <c>enduser.id</c>.</param>
/// <param name="InstanceName">The recording machine — <c>host.name</c>. An empty string is a legitimate value and is never coerced to null.</param>
/// <param name="AreaId">Optional Area scope id. Dropped from the span when null.</param>
/// <param name="AreaName">Optional Area name. Reaches the span only when <paramref name="AreaId"/> is also set.</param>
/// <param name="ServiceName">Resource <c>service.name</c>; every capture source shares the default so they group into one service.</param>
public sealed record SessionContext(
    string SessionId,
    string TraceId,
    string SpanId,
    string StartedAt,
    string? Kind,
    string User,
    string InstanceName,
    string? AreaId,
    string? AreaName,
    string ServiceName = OtlpMapper.DefaultServiceName);

/// <summary>
/// The authoritative ActivityEvent to OTLP/JSON projection.
/// </summary>
/// <remarks>
/// <para>
/// Attribute names, null-coercion, and numeric-omission are a frozen downstream SQL contract
/// (the Keboola <c>logs</c>/<c>traces</c> tables, joined on <c>trace_id</c>); the shared
/// <c>contract/conformance/fixtures</c> goldens pin every rule. Do not "improve" the mapping.
/// </para>
/// <para>
/// The two rules that generate the most bugs:
/// string attributes coerce null to <c>""</c> and always keep their key, because a missing string
/// must not change the column type; numeric attributes are omitted key-and-all, because emitting
/// <c>""</c> would make the same OTLP key a string in some records and a number in others.
/// Span-level <c>session.kind</c>/<c>area.*</c> invert this and are dropped rather than emptied.
/// </para>
/// </remarks>
public static class OtlpMapper
{
    /// <summary>The <c>service.name</c> every capture source lands under.</summary>
    public const string DefaultServiceName = "jasnost-capture";

    /// <summary>Log-record severity text; the projection is informational, never an error stream.</summary>
    public const string SeverityText = "INFO";

    /// <summary>OTLP <c>SeverityNumber.INFO</c>.</summary>
    public const int SeverityNumber = 9;

    /// <summary>Name of the single per-session span.</summary>
    public const string SpanName = "capture-session";

    /// <summary>proto <c>SpanKind.SPAN_KIND_INTERNAL</c>.</summary>
    public const int SpanKindInternal = 1;

    /// <summary>The one event type with a dedicated attribute shape.</summary>
    private const string NarrationEventType = "narration";

    /// <summary>Ticks (100 ns) to nanoseconds.</summary>
    private const long NanosPerTick = 100L;

    /// <summary>
    /// The shared resource for logs and traces: four string attributes, always present, in order.
    /// </summary>
    /// <remarks>
    /// Resource attributes do not populate the destination's promoted columns, which is why
    /// <c>enduser.id</c> and <c>host.name</c> are also stamped on every individual record.
    /// </remarks>
    public static JsonObject Resource(SessionContext context) => new()
    {
        ["attributes"] = Otlp.Attributes(new[]
        {
            OtlpKeyValue.Str("service.name", context.ServiceName),
            OtlpKeyValue.Str("service.instance.id", context.User),
            OtlpKeyValue.Str("enduser.id", context.User),
            OtlpKeyValue.Str("host.name", context.InstanceName),
        }),
    };

    /// <summary>
    /// The ordered attribute list for one event.
    /// </summary>
    /// <remarks>
    /// Narration is a <em>total replacement</em>, not an addition: a narration event carrying a
    /// target, a sequence, or a url still yields exactly the 13 narration keys.
    /// </remarks>
    public static IReadOnlyList<OtlpKeyValue> Attributes(ActivityEvent activityEvent, SessionContext context)
    {
        if (string.Equals(activityEvent.EventType, NarrationEventType, StringComparison.Ordinal))
        {
            return NarrationAttributes(activityEvent, context);
        }

        return GenericAttributes(activityEvent, context);
    }

    /// <summary>One event becomes one log record stamped with the session's trace and span ids.</summary>
    public static JsonObject LogRecord(
        ActivityEvent activityEvent,
        SessionContext context,
        Func<DateTimeOffset>? now = null)
    {
        string nanos = Nanos(activityEvent.Timestamp, now);
        return new JsonObject
        {
            ["timeUnixNano"] = nanos,
            ["observedTimeUnixNano"] = nanos,
            ["severityText"] = SeverityText,
            ["severityNumber"] = SeverityNumber,
            ["traceId"] = context.TraceId,
            ["spanId"] = context.SpanId,
            ["body"] = OtlpAnyValue.FromString(activityEvent.EventType).ToJson(),
            ["attributes"] = Otlp.Attributes(Attributes(activityEvent, context)),
        };
    }

    /// <summary>A full <c>/v1/logs</c> request body for one batch of a session's events.</summary>
    /// <param name="events">Events in capture order; the order is preserved in <c>logRecords</c>.</param>
    /// <param name="context">The session context.</param>
    /// <param name="now">Clock used only when an event timestamp is unparseable. Injectable for tests.</param>
    public static JsonObject LogsRequest(
        IReadOnlyList<ActivityEvent> events,
        SessionContext context,
        Func<DateTimeOffset>? now = null)
    {
        List<JsonObject> records = new(events.Count);
        foreach (ActivityEvent activityEvent in events)
        {
            records.Add(LogRecord(activityEvent, context, now));
        }

        return Otlp.LogsRequest(Resource(context), records);
    }

    /// <summary>
    /// The session's single <c>capture-session</c> span.
    /// </summary>
    /// <remarks>
    /// Every log record shares its <c>traceId</c> — that is what lets the destination join
    /// <c>logs</c> to <c>traces</c>. Unset kind/area are dropped, not emptied.
    /// </remarks>
    public static JsonObject Span(SessionContext context, string endedAt, Func<DateTimeOffset>? now = null)
    {
        List<OtlpKeyValue> attributes = new()
        {
            OtlpKeyValue.Str("session.id", context.SessionId),
        };

        if (context.Kind is not null)
        {
            attributes.Add(OtlpKeyValue.Str("session.kind", context.Kind));
        }

        if (context.AreaId is not null)
        {
            attributes.Add(OtlpKeyValue.Str("area.id", context.AreaId));
            if (context.AreaName is not null)
            {
                attributes.Add(OtlpKeyValue.Str("area.name", context.AreaName));
            }
        }

        attributes.Add(OtlpKeyValue.Str("session.endedAt", endedAt));

        return new JsonObject
        {
            ["traceId"] = context.TraceId,
            ["spanId"] = context.SpanId,
            ["name"] = SpanName,
            ["kind"] = SpanKindInternal,
            ["startTimeUnixNano"] = Nanos(context.StartedAt, now),
            ["endTimeUnixNano"] = Nanos(endedAt, now),
            ["attributes"] = Otlp.Attributes(attributes),
        };
    }

    /// <summary>A full <c>/v1/traces</c> request body carrying the single session span.</summary>
    public static JsonObject TraceRequest(SessionContext context, string endedAt, Func<DateTimeOffset>? now = null) =>
        Otlp.TraceRequest(Resource(context), new[] { Span(context, endedAt, now) });

    /// <summary>
    /// The narration shape: 13 attributes, nothing else.
    /// </summary>
    /// <remarks>
    /// The record still carries the event's own timestamp and <c>body</c>. <c>session.startedAt</c>
    /// stays a verbatim ISO 8601 string so a transcript can time-align to the events.
    /// </remarks>
    private static List<OtlpKeyValue> NarrationAttributes(ActivityEvent activityEvent, SessionContext context) =>
        new()
        {
            OtlpKeyValue.Str("session.id", activityEvent.SessionId),
            OtlpKeyValue.Str("sessionId", activityEvent.SessionId),
            OtlpKeyValue.Str("audio_file_id", activityEvent.AudioFileId ?? string.Empty),
            OtlpKeyValue.Str("session.startedAt", context.StartedAt),
            OtlpKeyValue.Str("enduser.id", context.User),
            OtlpKeyValue.Str("host.name", context.InstanceName),
            OtlpKeyValue.Str("label.id", activityEvent.LabelId ?? string.Empty),
            OtlpKeyValue.Str("label.name", activityEvent.Label ?? string.Empty),
            OtlpKeyValue.Str("session.kind", context.Kind ?? string.Empty),
            OtlpKeyValue.Str("area.id", context.AreaId ?? string.Empty),
            OtlpKeyValue.Str("area.name", context.AreaName ?? string.Empty),
            OtlpKeyValue.Str("process.id", activityEvent.ProcessId ?? string.Empty),
            OtlpKeyValue.Str("process.name", activityEvent.Process ?? string.Empty),
        };

    /// <summary>
    /// The shape for every non-narration event: 31 unconditional keys plus up to eight numeric
    /// keys spliced in at fixed positions.
    /// </summary>
    private static List<OtlpKeyValue> GenericAttributes(ActivityEvent activityEvent, SessionContext context)
    {
        List<OtlpKeyValue> attributes = new(39);

        // session.id and sessionId are deliberate duplicates so downstream SQL can use either;
        // both come from the EVENT (the span's session.id comes from the context instead).
        attributes.Add(OtlpKeyValue.Str("session.id", activityEvent.SessionId));
        attributes.Add(OtlpKeyValue.Str("sessionId", activityEvent.SessionId));
        attributes.Add(OtlpKeyValue.Str("eventId", activityEvent.EventId));
        if (activityEvent.Sequence is int sequence)
        {
            attributes.Add(OtlpKeyValue.Int("sequence", sequence));
        }

        attributes.Add(OtlpKeyValue.Str("url", activityEvent.Url));
        attributes.Add(OtlpKeyValue.Str("application.namespace", activityEvent.Application?.Namespace ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("application.id", activityEvent.Application?.Value ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("application.name", activityEvent.Application?.Name ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("application.version", activityEvent.Application?.Version ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("document.url", activityEvent.DocumentUrl ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("page_title", activityEvent.PageTitle ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("system", activityEvent.System ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("value", activityEvent.Value ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("selected_text", activityEvent.SelectedText ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("clipboard_text", activityEvent.ClipboardText ?? string.Empty));
        if (activityEvent.ClickCount is int clickCount)
        {
            attributes.Add(OtlpKeyValue.Int("click_count", clickCount));
        }

        if (activityEvent.DragEnd is DragEnd dragEnd)
        {
            attributes.Add(OtlpKeyValue.Double("drag_end.x", dragEnd.X));
            attributes.Add(OtlpKeyValue.Double("drag_end.y", dragEnd.Y));
        }

        attributes.Add(OtlpKeyValue.Str("gesture_id", activityEvent.GestureId ?? string.Empty));
        attributes.Add(OtlpKeyValue.Bool("input_masked", activityEvent.InputMasked ?? false));
        attributes.Add(OtlpKeyValue.Bool("is_sensitive", activityEvent.IsSensitive ?? false));
        attributes.Add(OtlpKeyValue.Str("screenshot_id", activityEvent.ScreenshotId ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("target.tag", activityEvent.Target?.Tag ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("target.role", activityEvent.Target?.Role ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("target.accessibleName", activityEvent.Target?.AccessibleName ?? string.Empty));

        // Always "" on desktop: there are no DOM selector candidates to report.
        attributes.Add(OtlpKeyValue.Str("target.selectorCandidates", string.Empty));
        if (activityEvent.Target?.BoundingBox is BoundingBox box)
        {
            attributes.Add(OtlpKeyValue.Double("target.boundingBox.x", box.X));
            attributes.Add(OtlpKeyValue.Double("target.boundingBox.y", box.Y));
            attributes.Add(OtlpKeyValue.Double("target.boundingBox.width", box.Width));
            attributes.Add(OtlpKeyValue.Double("target.boundingBox.height", box.Height));
        }

        // Identity on every record: resource attributes can be normalized away by the
        // destination, but the per-record attributes survive.
        attributes.Add(OtlpKeyValue.Str("enduser.id", context.User));
        attributes.Add(OtlpKeyValue.Str("host.name", context.InstanceName));
        attributes.Add(OtlpKeyValue.Str("label.id", activityEvent.LabelId ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("label.name", activityEvent.Label ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("session.kind", context.Kind ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("area.id", context.AreaId ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("area.name", context.AreaName ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("process.id", activityEvent.ProcessId ?? string.Empty));
        attributes.Add(OtlpKeyValue.Str("process.name", activityEvent.Process ?? string.Empty));

        // target.text, viewport.*, tabId, frameId, and rrwebChunkId are never projected.
        return attributes;
    }

    /// <summary>
    /// Unix nanoseconds for an ISO 8601 instant as a decimal string, falling back to "now" when
    /// the input is unparseable or predates 1970.
    /// </summary>
    private static string Nanos(string iso8601, Func<DateTimeOffset>? now)
    {
        long nanos = Timestamps.UnixNanos(iso8601) ?? UnixNanos((now ?? DefaultClock)());
        return nanos.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>Unix nanoseconds for an instant, at the 100 ns resolution the CLR clock offers.</summary>
    private static long UnixNanos(DateTimeOffset instant)
    {
        long ticks = instant.ToUniversalTime().Ticks - DateTimeOffset.UnixEpoch.Ticks;
        return ticks <= 0 ? 0L : ticks * NanosPerTick;
    }

    private static DateTimeOffset DefaultClock() => DateTimeOffset.UtcNow;
}
