import Foundation

/// Random trace/span id generation for the per-session `capture-session` span. The RNG is
/// injectable so tests can assert exact ids; production uses the system RNG.
public enum OtlpIds {
    /// 16 random bytes as 32 lowercase hex chars (OTLP trace id).
    public static func traceId<R: RandomNumberGenerator>(using rng: inout R) -> String {
        hex(rng.next()) + hex(rng.next())
    }

    /// 8 random bytes as 16 lowercase hex chars (OTLP span id).
    public static func spanId<R: RandomNumberGenerator>(using rng: inout R) -> String {
        hex(rng.next())
    }

    public static func traceId() -> String {
        var rng = SystemRandomNumberGenerator()
        return traceId(using: &rng)
    }

    public static func spanId() -> String {
        var rng = SystemRandomNumberGenerator()
        return spanId(using: &rng)
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }
}

/// ActivityEvent → OTLP/JSON mapping. This IS the authoritative ActivityEvent → OTLP/JSON
/// mapping — the attribute names, nil-coercion, and numeric-omission rules are the frozen
/// downstream SQL contract (Keboola `logs` / `traces` tables, joined on `trace_id`). Do not
/// "improve" the mapping without changing the processor's SQL in the same PR.
///
/// Contract recap:
///   - body = eventType; severity INFO/9; record time = the event's own ISO-8601 timestamp.
///   - String attributes coerce nil → "" (a missing string must not change column typing).
///   - NUMERIC attributes (`sequence`, `target.boundingBox.*`, `viewport.*`) are OMITTED when
///     absent — emitting "" would make the same OTLP key a string in some records and a number
///     in others, corrupting Keboola column typing. The desktop agent has no viewport, so
///     `viewport.*` keys are never emitted here.
///   - `target.selectorCandidates` is "" on desktop — the agent has no DOM selectors.
///   - Narration is a special record: body "narration" with the audio reference + session
///     start + `host.name`.
public enum OtlpMapper {
    /// The `service.name` every capture source lands under in the Keboola `logs`/`traces`
    /// tables. All sources must share this value so they group into one service.
    public static let defaultServiceName = "jasnost-capture"
    /// Instrumentation scope name identifying the native agent. The scope is informational,
    /// not part of the SQL contract.
    public static let scopeName = "jasnost.agent"
    private static let spanName = "capture-session"
    /// proto `SpanKind.SPAN_KIND_INTERNAL`.
    private static let spanKindInternal = 1

    /// Everything the mapper needs to know about one capture session: the correlation ids
    /// (generated once at session start, persisted in the spool meta) and the resource
    /// identity. One context per session; every log record carries its traceId/spanId.
    public struct SessionContext: Equatable, Sendable {
        public var sessionId: String
        /// 32 lowercase hex chars, random per session.
        public var traceId: String
        /// 16 lowercase hex chars, random per session.
        public var spanId: String
        /// ISO-8601 session start — span start time and the narration record's
        /// `session.startedAt` (lets the transcript time-align to events).
        public var startedAt: String
        /// Optional session classification (e.g. "bdm-workshop"); omitted from the span when nil.
        public var kind: String?
        /// The captured user (email) — `service.instance.id` + `enduser.id`. WHO is recording.
        public var user: String
        /// The recording machine's name — `host.name` on every record (resource + per-event).
        /// WHICH machine is recording; distinct from ``user``. Coerces nil/empty → "" downstream.
        public var instanceName: String
        /// The session's Area (scope) id/name (ADR 0002), picked at session start. Session-scoped:
        /// stamped on every event as the "area.id"/"area.name" OTLP attribute (like session.kind).
        /// nil until a pick lands — the processor then reads it as the default "General" Area.
        public var areaId: String?
        public var areaName: String?
        public var serviceName: String

        public init(
            sessionId: String,
            traceId: String,
            spanId: String,
            startedAt: String,
            kind: String? = nil,
            user: String,
            instanceName: String = "",
            areaId: String? = nil,
            areaName: String? = nil,
            serviceName: String = OtlpMapper.defaultServiceName
        ) {
            self.sessionId = sessionId
            self.traceId = traceId
            self.spanId = spanId
            self.startedAt = startedAt
            self.kind = kind
            self.user = user
            self.instanceName = instanceName
            self.areaId = areaId
            self.areaName = areaName
            self.serviceName = serviceName
        }
    }

    // MARK: - Timestamps

    /// Parse an ISO-8601 timestamp (with or without fractional seconds) to unix nanos.
    /// The fraction is parsed digit-exact (up to 9 digits) rather than through Date, whose
    /// Double seconds would round sub-microsecond precision. `nil` for malformed/pre-1970
    /// input — callers fall back to "now".
    public static func unixNanos(fromISO8601 iso: String) -> UInt64? {
        var whole = iso
        var fractionNanos: UInt64 = 0
        if let dot = iso.firstIndex(of: ".") {
            let afterDot = iso[iso.index(after: dot)...]
            let digits = afterDot.prefix { $0.isASCII && $0.isNumber }
            // Reassemble without the fraction (keep the timezone designator that follows it).
            whole = String(iso[..<dot]) + String(afterDot.dropFirst(digits.count))
            // Pad/truncate the digits to 9 — "123" means .123 s = 123_000_000 ns.
            let padded = String(digits.prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
            fractionNanos = UInt64(padded) ?? 0
        }
        guard let date = Timestamps.parse(whole) else { return nil }
        let seconds = date.timeIntervalSince1970
        guard seconds >= 0 else { return nil }
        // `seconds` is whole at this point (fraction was stripped), so the conversion is exact.
        return UInt64(seconds.rounded()) * 1_000_000_000 + fractionNanos
    }

    /// Unix nanos for a Date (the "now" fallback). Sub-microsecond precision is lost to the
    /// Double conversion, which is fine for a fallback timestamp.
    public static func unixNanos(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000)
    }

    // MARK: - Resource

    /// Shared resource for logs AND traces: service.name + the captured user's identity
    /// (`service.instance.id` + `enduser.id`) + the machine name (`host.name`). NOTE: resource
    /// attrs do NOT populate Keboola's promoted columns (`service_instance_id`/`host_name` come
    /// back null — live-verified); they land only in the `resource` JSON column. The reliable
    /// carrier downstream is the per-event `attributes` JSON (that's why `enduser.id`/`host.name`
    /// are also stamped on every record). This resource copy is harmless forward-compat.
    public static func resource(_ context: SessionContext) -> Otlp.Resource {
        Otlp.Resource(attributes: [
            str("service.name", context.serviceName),
            str("service.instance.id", context.user),
            str("enduser.id", context.user),
            str("host.name", context.instanceName),
        ])
    }

    // MARK: - Log records

    /// Flat OTLP attributes for one event, per the contract above. Public so tests can assert
    /// the exact attribute set. Narration events get their dedicated four-attribute shape.
    // Per-element builders. Building each KeyValue through an explicitly-typed helper (rather
    // than `.init(key:value:)` shorthand inside one big array literal) keeps every statement
    // trivially type-checkable — the literal form tripped Swift's "unable to type-check this
    // expression in reasonable time" on the CI toolchain.
    private static func str(_ key: String, _ value: String) -> Otlp.KeyValue {
        Otlp.KeyValue(key: key, value: .string(value))
    }
    private static func bool(_ key: String, _ value: Bool) -> Otlp.KeyValue {
        Otlp.KeyValue(key: key, value: .bool(value))
    }
    private static func dbl(_ key: String, _ value: Double) -> Otlp.KeyValue {
        Otlp.KeyValue(key: key, value: .double(value))
    }

    public static func attributes(
        for event: ActivityEvent, in context: SessionContext
    ) -> [Otlp.KeyValue] {
        if event.eventType == EventType.narration.rawValue {
            // Narration record: the audio blob reference + session start for transcript
            // time-alignment. enduser.id AND host.name ride every record (incl. narration) so the
            // user (WHO) and machine (WHICH) are always attributable — without enduser.id the
            // narration row groups under a NULL user downstream and splits the session into a
            // phantom "unknown user" slice in the sidebar.
            return [
                str("session.id", event.sessionId),
                str("sessionId", event.sessionId),
                str("audio_file_id", event.audioFileId ?? ""),
                str("session.startedAt", context.startedAt),
                str("enduser.id", context.user),
                str("host.name", context.instanceName),
                // The narration record carries its label too — audio ties to its label
                // (the mic records ONLY while a label is open). nil/empty → "".
                str("label.id", event.labelId ?? ""),
                str("label.name", event.label ?? ""),
                // The session's type, like on every other record (see the note below).
                str("session.kind", context.kind ?? ""),
                // The session's Area (scope, session-wide like session.kind) + this segment's Process
                // (segment-scoped like the label). nil/empty -> "" (processor reads NULL area as General).
                str("area.id", context.areaId ?? ""),
                str("area.name", context.areaName ?? ""),
                str("process.id", event.processId ?? ""),
                str("process.name", event.process ?? ""),
            ]
        }

        var attrs: [Otlp.KeyValue] = []
        // session.id mirrors the smoke test's promoted-column name; sessionId is also kept
        // verbatim so downstream SQL can use either.
        attrs.append(str("session.id", event.sessionId))
        attrs.append(str("sessionId", event.sessionId))
        attrs.append(str("eventId", event.eventId))
        // Numeric: keep the key out of the record entirely when there is no value.
        if let sequence = event.sequence {
            attrs.append(Otlp.KeyValue(key: "sequence", value: .int(Int64(sequence))))
        }
        attrs.append(str("url", event.url))
        attrs.append(str("page_title", event.pageTitle ?? ""))
        attrs.append(str("system", event.system ?? ""))
        attrs.append(str("value", event.value ?? ""))
        attrs.append(bool("input_masked", event.inputMasked ?? false))
        attrs.append(bool("is_sensitive", event.isSensitive ?? false))
        attrs.append(str("screenshot_id", event.screenshotId ?? ""))
        attrs.append(str("target.tag", event.target?.tag ?? ""))
        attrs.append(str("target.role", event.target?.role ?? ""))
        attrs.append(str("target.accessibleName", event.target?.accessibleName ?? ""))
        // Always "" on desktop — the agent has no DOM selector candidates.
        attrs.append(str("target.selectorCandidates", ""))
        // Element rect for screenshot region-highlighting (#14). Numeric → omit when absent.
        if let box = event.target?.boundingBox {
            attrs.append(dbl("target.boundingBox.x", box.x))
            attrs.append(dbl("target.boundingBox.y", box.y))
            attrs.append(dbl("target.boundingBox.width", box.width))
            attrs.append(dbl("target.boundingBox.height", box.height))
        }
        // Identity on every record, not just the resource: resource attributes can be
        // normalized away by the destination, but the per-event attributes JSON survives.
        attrs.append(str("enduser.id", context.user))
        // The recording machine, same reasoning: the per-event host.name is the RELIABLE
        // carrier downstream reads (resource host.name does NOT populate the promoted column).
        attrs.append(str("host.name", context.instanceName))
        // The ACTIVE label (bracketed segment) on every record, "" when no label is open.
        // Per-event attributes are the reliable carrier (resource attrs don't promote on this
        // stream); downstream reads label via PARSE_JSON(attributes):"label.name", like enduser.id.
        attrs.append(str("label.id", event.labelId ?? ""))
        attrs.append(str("label.name", event.label ?? ""))
        // The session's type (process-mapping vs bdm-workshop) on every record. session.kind is
        // also a span attribute, but span/resource attrs don't promote to queryable columns on
        // this stream — the per-event attributes JSON is the reliable carrier the processor reads,
        // so it can label a session by its kind from the first event, before any BDM artifact
        // exists. "" when unset (older sessions) -> the processor falls back to artifact-based.
        attrs.append(str("session.kind", context.kind ?? ""))
        // The session's Area (scope, session-wide like session.kind) on every record, and this
        // segment's Process (segment-scoped like the label). "" when unset; the processor reads a
        // NULL area.id as the default "General" Area. ADR 0002 / docs/AREA_MODEL_PLAN.md.
        attrs.append(str("area.id", context.areaId ?? ""))
        attrs.append(str("area.name", context.areaName ?? ""))
        attrs.append(str("process.id", event.processId ?? ""))
        attrs.append(str("process.name", event.process ?? ""))
        return attrs
    }

    /// One event → one log record carrying the session's traceId/spanId. The record time is
    /// the event's own captured timestamp (falling back to `now` if unparseable).
    public static func logRecord(
        for event: ActivityEvent, in context: SessionContext, now: Date = Date()
    ) -> Otlp.LogRecord {
        let nanos = unixNanos(fromISO8601: event.timestamp) ?? unixNanos(now)
        return Otlp.LogRecord(
            timeUnixNano: String(nanos),
            observedTimeUnixNano: String(nanos),
            severityText: "INFO",
            severityNumber: 9,  // SeverityNumber.INFO
            traceId: context.traceId,
            spanId: context.spanId,
            body: .string(event.eventType),
            attributes: attributes(for: event, in: context)
        )
    }

    /// A full `/v1/logs` request body for one batch of a session's events.
    public static func logsRequest(
        events: [ActivityEvent], in context: SessionContext, now: Date = Date()
    ) -> Otlp.ExportLogsServiceRequest {
        Otlp.ExportLogsServiceRequest(resourceLogs: [
            Otlp.ResourceLogs(
                resource: resource(context),
                scopeLogs: [
                    Otlp.ScopeLogs(
                        scope: Otlp.Scope(name: scopeName),
                        logRecords: events.map { logRecord(for: $0, in: context, now: now) }
                    )
                ]
            )
        ])
    }

    // MARK: - Capture-session span

    /// The session's single `capture-session` span, exported once at session end. Every log
    /// record shares its traceId — that is what lets Keboola `logs JOIN traces ON trace_id`.
    public static func span(
        in context: SessionContext, endedAt: String, now: Date = Date()
    ) -> Otlp.Span {
        var attrs: [Otlp.KeyValue] = [str("session.id", context.sessionId)]
        // nil kind is dropped: normal captures carry no session.kind.
        if let kind = context.kind {
            attrs.append(str("session.kind", kind))
        }
        // The session's Area on the span too (session-scoped, like kind); both id and name, parallel
        // to the per-event area.id/area.name. Dropped when unset.
        if let areaId = context.areaId {
            attrs.append(str("area.id", areaId))
            if let areaName = context.areaName {
                attrs.append(str("area.name", areaName))
            }
        }
        attrs.append(str("session.endedAt", endedAt))
        let start = unixNanos(fromISO8601: context.startedAt) ?? unixNanos(now)
        let end = unixNanos(fromISO8601: endedAt) ?? unixNanos(now)
        return Otlp.Span(
            traceId: context.traceId,
            spanId: context.spanId,
            name: spanName,
            kind: spanKindInternal,
            startTimeUnixNano: String(start),
            endTimeUnixNano: String(end),
            attributes: attrs
        )
    }

    /// A full `/v1/traces` request body for the session span.
    public static func traceRequest(
        in context: SessionContext, endedAt: String, now: Date = Date()
    ) -> Otlp.ExportTraceServiceRequest {
        Otlp.ExportTraceServiceRequest(resourceSpans: [
            Otlp.ResourceSpans(
                resource: resource(context),
                scopeSpans: [
                    Otlp.ScopeSpans(
                        scope: Otlp.Scope(name: scopeName),
                        spans: [span(in: context, endedAt: endedAt, now: now)]
                    )
                ]
            )
        ])
    }
}
