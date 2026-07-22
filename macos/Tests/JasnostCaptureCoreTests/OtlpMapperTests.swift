import XCTest

@testable import JasnostCaptureCore

/// Deterministic RNG so trace/span ids are assertable.
private struct CountingRNG: RandomNumberGenerator {
    var state: UInt64 = 0
    mutating func next() -> UInt64 {
        state += 1
        return state
    }
}

private func attributeDict(_ attrs: [Otlp.KeyValue]) -> [String: Otlp.AnyValue] {
    var dict: [String: Otlp.AnyValue] = [:]
    for kv in attrs {
        XCTAssertNil(dict[kv.key], "duplicate attribute key \(kv.key)")
        dict[kv.key] = kv.value
    }
    return dict
}

/// Tests for the OTLP/JSON wire models — value encoding must match what the live Keboola
/// Data Stream accepted (intValue as STRING, doubleValue/boolValue native).
final class OtlpModelTests: XCTestCase {
    func testAnyValueEncodings() throws {
        let cases: [(Otlp.AnyValue, String)] = [
            (.string("x"), #"{"stringValue":"x"}"#),
            (.bool(false), #"{"boolValue":false}"#),
            (.int(123), #"{"intValue":"123"}"#),  // proto3 JSON: int64 is a decimal string
            (.double(1.5), #"{"doubleValue":1.5}"#),
        ]
        for (value, expected) in cases {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
        }
    }

    func testAnyValueDecodingRoundtripAndLenientInt() throws {
        for fixture in [#"{"stringValue":"x"}"#, #"{"boolValue":true}"#, #"{"doubleValue":2.5}"#] {
            let decoded = try JSONDecoder().decode(Otlp.AnyValue.self, from: Data(fixture.utf8))
            let reencoded = try JSONEncoder().encode(decoded)
            XCTAssertEqual(String(decoding: reencoded, as: UTF8.self), fixture)
        }
        // Spec string form and lenient bare-number form both decode to .int.
        for fixture in [#"{"intValue":"42"}"#, #"{"intValue":42}"#] {
            let decoded = try JSONDecoder().decode(Otlp.AnyValue.self, from: Data(fixture.utf8))
            XCTAssertEqual(decoded, .int(42))
        }
        // An empty object is not a valid AnyValue.
        XCTAssertThrowsError(try JSONDecoder().decode(Otlp.AnyValue.self, from: Data("{}".utf8)))
    }

    /// Decode a trimmed copy of the LIVE-ACCEPTED payload (HTTP 200 from the real stream,
    /// 2026-06-13) — proves the Codable models match the verified wire shape.
    func testDecodesLiveVerifiedLogsFixture() throws {
        let fixture = """
            {"resourceLogs":[{"resource":{"attributes":[
              {"key":"service.name","value":{"stringValue":"jasnost-capture"}},
              {"key":"enduser.id","value":{"stringValue":"petr@example.com"}}]},
             "scopeLogs":[{"scope":{"name":"jasnost.agent"},"logRecords":[{
               "timeUnixNano":"1781305072000000000",
               "observedTimeUnixNano":"1781305072000000000",
               "severityText":"INFO","severityNumber":9,
               "traceId":"aaaa1111bbbb2222cccc3333dddd4444","spanId":"abcd1234abcd1234",
               "body":{"stringValue":"click"},
               "attributes":[
                 {"key":"sequence","value":{"intValue":"1"}},
                 {"key":"input_masked","value":{"boolValue":false}},
                 {"key":"target.boundingBox.x","value":{"doubleValue":100.5}}]}]}]}]}
            """
        let request = try JSONDecoder().decode(
            Otlp.ExportLogsServiceRequest.self, from: Data(fixture.utf8))
        let record = request.resourceLogs[0].scopeLogs[0].logRecords[0]
        XCTAssertEqual(record.body, .string("click"))
        XCTAssertEqual(record.traceId, "aaaa1111bbbb2222cccc3333dddd4444")
        XCTAssertEqual(
            attributeDict(record.attributes),
            [
                "sequence": .int(1),
                "input_masked": .bool(false),
                "target.boundingBox.x": .double(100.5),
            ])
    }
}

final class OtlpIdsTests: XCTestCase {
    func testInjectableRNGProducesDeterministicIds() {
        var rng = CountingRNG()
        XCTAssertEqual(OtlpIds.traceId(using: &rng), "00000000000000010000000000000002")
        XCTAssertEqual(OtlpIds.spanId(using: &rng), "0000000000000003")
    }

    func testSystemRNGShapes() {
        let trace = OtlpIds.traceId()
        let span = OtlpIds.spanId()
        XCTAssertEqual(trace.count, 32)
        XCTAssertEqual(span.count, 16)
        XCTAssertTrue(trace.allSatisfy(\.isHexDigit))
        XCTAssertTrue(span.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(OtlpIds.traceId(), trace, "two random trace ids should differ")
    }
}

final class OtlpTimestampTests: XCTestCase {
    func testUnixNanosWithAndWithoutFractionalSeconds() {
        // 2026-06-13T10:00:00Z == 1781344800 epoch seconds.
        XCTAssertEqual(
            OtlpMapper.unixNanos(fromISO8601: "2026-06-13T10:00:00Z"),
            1_781_344_800_000_000_000)
        XCTAssertEqual(
            OtlpMapper.unixNanos(fromISO8601: "2026-06-13T10:00:00.123Z"),
            1_781_344_800_123_000_000)
        // Digit-exact down to nanoseconds (a Date roundtrip would round this).
        XCTAssertEqual(
            OtlpMapper.unixNanos(fromISO8601: "2026-06-13T10:00:00.123456789Z"),
            1_781_344_800_123_456_789)
        // Sub-nanosecond digits truncate.
        XCTAssertEqual(
            OtlpMapper.unixNanos(fromISO8601: "2026-06-13T10:00:00.1234567891Z"),
            1_781_344_800_123_456_789)
        // Timezone offsets after the fraction are honored (12:00+02:00 == 10:00Z).
        XCTAssertEqual(
            OtlpMapper.unixNanos(fromISO8601: "2026-06-13T12:00:00.5+02:00"),
            1_781_344_800_500_000_000)
    }

    func testUnixNanosRejectsMalformedAndPreEpoch() {
        XCTAssertNil(OtlpMapper.unixNanos(fromISO8601: ""))
        XCTAssertNil(OtlpMapper.unixNanos(fromISO8601: "not-a-date"))
        XCTAssertNil(OtlpMapper.unixNanos(fromISO8601: "2026-06-13"))  // date only
        XCTAssertNil(OtlpMapper.unixNanos(fromISO8601: "1969-12-31T23:59:59Z"))  // pre-epoch
    }
}

/// Golden tests for the authoritative ActivityEvent → log-record contract (the frozen downstream-SQL contract).
final class OtlpMapperTests: XCTestCase {
    private let context = OtlpMapper.SessionContext(
        sessionId: "s-test-1",
        traceId: "aaaa1111bbbb2222cccc3333dddd4444",
        spanId: "abcd1234abcd1234",
        startedAt: "2026-06-13T10:00:00.000Z",
        kind: "bdm-workshop",
        user: "petr@example.com",
        instanceName: "Padak's MacBook Pro",
        areaId: "area-fin",
        areaName: "Finance"
    )

    func testFullEventMapsEveryAttribute() {
        let event = ActivityEvent(
            sessionId: "s-test-1",
            eventId: "s-test-1-1",
            sequence: 1,
            timestamp: "2026-06-13T10:00:00.123Z",
            eventType: "click",
            url: "app://com.apple.finder",
            pageTitle: "Downloads",
            system: "Finder",
            target: EventTarget(
                tag: "AXButton", role: "AXButton", accessibleName: "Open", text: "Open",
                boundingBox: BoundingBox(x: 100.5, y: 200.25, width: 80, height: 24)),
            value: "Open",
            inputMasked: true,
            isSensitive: false,
            screenshotId: "84580000",
            labelId: "lbl-1",
            label: "sales commissions",
            processId: "proc-inv",
            process: "Invoicing"
        )
        let record = OtlpMapper.logRecord(for: event, in: context)

        XCTAssertEqual(record.body, .string("click"))
        XCTAssertEqual(record.severityText, "INFO")
        XCTAssertEqual(record.severityNumber, 9)
        XCTAssertEqual(record.traceId, context.traceId)
        XCTAssertEqual(record.spanId, context.spanId)
        // Record time = the event's own captured timestamp, not "now".
        XCTAssertEqual(record.timeUnixNano, "1781344800123000000")
        XCTAssertEqual(record.observedTimeUnixNano, record.timeUnixNano)

        // EXACT attribute set — any drift here breaks the downstream SQL contract.
        XCTAssertEqual(
            attributeDict(record.attributes),
            [
                "session.id": .string("s-test-1"),
                "sessionId": .string("s-test-1"),
                "eventId": .string("s-test-1-1"),
                "sequence": .int(1),
                "url": .string("app://com.apple.finder"),
                "page_title": .string("Downloads"),
                "system": .string("Finder"),
                "value": .string("Open"),
                "input_masked": .bool(true),
                "is_sensitive": .bool(false),
                "screenshot_id": .string("84580000"),
                "target.tag": .string("AXButton"),
                "target.role": .string("AXButton"),
                "target.accessibleName": .string("Open"),
                "target.selectorCandidates": .string(""),
                "target.boundingBox.x": .double(100.5),
                "target.boundingBox.y": .double(200.25),
                "target.boundingBox.width": .double(80),
                "target.boundingBox.height": .double(24),
                "enduser.id": .string("petr@example.com"),
                "host.name": .string("Padak's MacBook Pro"),
                "label.id": .string("lbl-1"),
                "label.name": .string("sales commissions"),
                "session.kind": .string("bdm-workshop"),
                "area.id": .string("area-fin"),
                "area.name": .string("Finance"),
                "process.id": .string("proc-inv"),
                "process.name": .string("Invoicing"),
            ])
    }

    func testMinimalEventCoercesStringsAndOmitsNumerics() {
        let event = ActivityEvent(
            sessionId: "s-test-1",
            eventId: "s-test-1-0",
            timestamp: "2026-06-13T10:00:00Z",
            eventType: "navigate",
            url: "app://x"
        )
        let record = OtlpMapper.logRecord(for: event, in: context)
        let attrs = attributeDict(record.attributes)

        // Strings: nil → "" (the key is ALWAYS present, value empty).
        XCTAssertEqual(
            attrs,
            [
                "session.id": .string("s-test-1"),
                "sessionId": .string("s-test-1"),
                "eventId": .string("s-test-1-0"),
                "url": .string("app://x"),
                "page_title": .string(""),
                "system": .string(""),
                "value": .string(""),
                "input_masked": .bool(false),
                "is_sensitive": .bool(false),
                "screenshot_id": .string(""),
                "target.tag": .string(""),
                "target.role": .string(""),
                "target.accessibleName": .string(""),
                "target.selectorCandidates": .string(""),
                "enduser.id": .string("petr@example.com"),
                "host.name": .string("Padak's MacBook Pro"),
                // No label open: keys ALWAYS present, value "" (never omitted, never null).
                "label.id": .string(""),
                "label.name": .string(""),
                "session.kind": .string("bdm-workshop"),
                // Area is session-scoped (from the context) so it rides even a minimal event; the
                // Process is segment-scoped and this event has none, so it is "" (present, empty).
                "area.id": .string("area-fin"),
                "area.name": .string("Finance"),
                "process.id": .string(""),
                "process.name": .string(""),
            ])
        // Numerics: the keys must be ABSENT (never ""), or Keboola column typing corrupts.
        for key in [
            "sequence",
            "target.boundingBox.x", "target.boundingBox.y",
            "target.boundingBox.width", "target.boundingBox.height",
            "viewport.width", "viewport.height", "viewport.scrollX", "viewport.scrollY",
        ] {
            XCTAssertNil(attrs[key], "numeric key \(key) must be omitted when absent")
        }
    }

    func testNarrationEventMapsToDedicatedRecord() {
        // Narration rides the spool as a synthetic ActivityEvent; the mapper gives it a
        // dedicated shape (audio ref + session start) PLUS enduser.id + host.name,
        // which ride every record so even narration is attributable to its user and machine
        // (without enduser.id the narration row would split the session under a NULL user).
        let event = ActivityEvent(
            sessionId: "s-test-1",
            eventId: "s-test-1-99",
            timestamp: "2026-06-13T10:05:00Z",
            eventType: "narration",
            url: "app://session",
            audioFileId: "84580000",
            labelId: "lbl-1",
            label: "sales commissions"
        )
        let record = OtlpMapper.logRecord(for: event, in: context)
        XCTAssertEqual(record.body, .string("narration"))
        XCTAssertEqual(
            attributeDict(record.attributes),
            [
                "session.id": .string("s-test-1"),
                "sessionId": .string("s-test-1"),
                "audio_file_id": .string("84580000"),
                "session.startedAt": .string("2026-06-13T10:00:00.000Z"),
                // Identity (WHO) + machine (WHICH) ride the narration record too.
                "enduser.id": .string("petr@example.com"),
                "host.name": .string("Padak's MacBook Pro"),
                // Audio ties to its label (mic records only while a label is open).
                "label.id": .string("lbl-1"),
                "label.name": .string("sales commissions"),
                "session.kind": .string("bdm-workshop"),
                // The narration record carries the session Area + (here unset) Process too.
                "area.id": .string("area-fin"),
                "area.name": .string("Finance"),
                "process.id": .string(""),
                "process.name": .string(""),
            ])
    }

    func testLabelStartEventCarriesLabelAttributes() {
        // A label_start event IS the bracketed-segment boundary: it carries the freshly-minted
        // labelId + human name, which then ride every subsequent event until the label ends.
        let event = ActivityEvent(
            sessionId: "s-test-1",
            eventId: "s-test-1-5",
            timestamp: "2026-06-13T10:02:00Z",
            eventType: "label_start",
            url: "app://session",
            labelId: "lbl-1",
            label: "sales commissions"
        )
        let record = OtlpMapper.logRecord(for: event, in: context)
        XCTAssertEqual(record.body, .string("label_start"))
        let attrs = attributeDict(record.attributes)
        XCTAssertEqual(attrs["label.id"], .string("lbl-1"))
        XCTAssertEqual(attrs["label.name"], .string("sales commissions"))
        // The explicit session type rides every record (the reliable per-event carrier).
        XCTAssertEqual(attrs["session.kind"], .string("bdm-workshop"))
    }

    func testUnparseableTimestampFallsBackToNow() {
        let event = ActivityEvent(
            sessionId: "s-test-1", eventId: "s-test-1-0",
            timestamp: "garbage", eventType: "click", url: "app://x"
        )
        let now = Date(timeIntervalSince1970: 1_781_344_800)
        let record = OtlpMapper.logRecord(for: event, in: context, now: now)
        XCTAssertEqual(record.timeUnixNano, "1781344800000000000")
    }

    func testSpanBuilderWithAndWithoutKind() {
        let span = OtlpMapper.span(in: context, endedAt: "2026-06-13T10:01:00Z")
        XCTAssertEqual(span.name, "capture-session")
        XCTAssertEqual(span.kind, 1)  // SPAN_KIND_INTERNAL
        XCTAssertEqual(span.traceId, context.traceId)
        XCTAssertEqual(span.spanId, context.spanId)
        XCTAssertEqual(span.startTimeUnixNano, "1781344800000000000")
        XCTAssertEqual(span.endTimeUnixNano, "1781344860000000000")
        XCTAssertEqual(
            attributeDict(span.attributes),
            [
                "session.id": .string("s-test-1"),
                "session.kind": .string("bdm-workshop"),
                "area.id": .string("area-fin"),
                "area.name": .string("Finance"),
                "session.endedAt": .string("2026-06-13T10:01:00Z"),
            ])

        // Normal captures carry no session.kind nor Area at all (keys absent, not "").
        var plain = context
        plain.kind = nil
        plain.areaId = nil
        let plainSpan = OtlpMapper.span(in: plain, endedAt: "2026-06-13T10:01:00Z")
        XCTAssertEqual(
            attributeDict(plainSpan.attributes),
            [
                "session.id": .string("s-test-1"),
                "session.endedAt": .string("2026-06-13T10:01:00Z"),
            ])
    }

    func testRequestEnvelopesCarryResourceAndScope() throws {
        let events = [
            ActivityEvent(
                sessionId: "s-test-1", eventId: "s-test-1-0",
                timestamp: "2026-06-13T10:00:00Z", eventType: "session_start", url: "app://x"),
            ActivityEvent(
                sessionId: "s-test-1", eventId: "s-test-1-1", sequence: 1,
                timestamp: "2026-06-13T10:00:01Z", eventType: "click", url: "app://x"),
        ]
        let logs = OtlpMapper.logsRequest(events: events, in: context)
        XCTAssertEqual(logs.resourceLogs.count, 1)
        // Resource identity rides logs AND traces: service.name + the user (twice) + host.name
        // (forward-compat fallback — the per-event host.name is what downstream actually reads).
        let expectedResource: [String: Otlp.AnyValue] = [
            "service.name": .string("jasnost-capture"),
            "service.instance.id": .string("petr@example.com"),
            "enduser.id": .string("petr@example.com"),
            "host.name": .string("Padak's MacBook Pro"),
        ]
        XCTAssertEqual(attributeDict(logs.resourceLogs[0].resource.attributes), expectedResource)
        XCTAssertEqual(logs.resourceLogs[0].scopeLogs[0].scope.name, "jasnost.agent")
        XCTAssertEqual(logs.resourceLogs[0].scopeLogs[0].logRecords.count, 2)

        let trace = OtlpMapper.traceRequest(in: context, endedAt: "2026-06-13T10:01:00Z")
        XCTAssertEqual(attributeDict(trace.resourceSpans[0].resource.attributes), expectedResource)
        XCTAssertEqual(trace.resourceSpans[0].scopeSpans[0].spans.count, 1)

        // The encoded JSON must roundtrip through the same models (wire-shape sanity).
        let decoded = try JSONDecoder().decode(
            Otlp.ExportLogsServiceRequest.self, from: JSONEncoder().encode(logs))
        XCTAssertEqual(decoded, logs)
    }
}
