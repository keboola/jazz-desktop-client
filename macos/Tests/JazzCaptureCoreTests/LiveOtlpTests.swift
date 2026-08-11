import XCTest

@testable import JazzCaptureCore

/// Live end-to-end check against a REAL Keboola Data Stream. Gated on
/// `JAZZ_LIVE_OTLP_ENDPOINT` (the full OTLP base URL incl. the path-embedded secret) so
/// CI and normal `swift test` runs skip it. NEVER hardcode an endpoint here — the URL is a
/// secret — and never print it in assertion messages.
final class LiveOtlpTests: XCTestCase {
    func testPostsSessionSpanAndCorrelatedLogs() async throws {
        let env = ProcessInfo.processInfo.environment
        guard var endpoint = env["JAZZ_LIVE_OTLP_ENDPOINT"], !endpoint.isEmpty else {
            throw XCTSkip("JAZZ_LIVE_OTLP_ENDPOINT not set; skipping live OTLP test")
        }
        while endpoint.hasSuffix("/") { endpoint.removeLast() }

        // A tiny but contract-complete session: random ids, one click + one annotation,
        // then the capture-session span carrying the same traceId.
        let sessionId = "s-live-\(UUID().uuidString.lowercased())"
        let startedAt = Timestamps.iso8601(Date().addingTimeInterval(-5))
        let context = OtlpMapper.SessionContext(
            sessionId: sessionId,
            traceId: OtlpIds.traceId(),
            spanId: OtlpIds.spanId(),
            startedAt: startedAt,
            kind: "live-test",
            user: env["JAZZ_LIVE_USER"] ?? "live-test@jazz.invalid"
        )
        let events = [
            ActivityEvent(
                sessionId: sessionId, eventId: "\(sessionId)-1", sequence: 1,
                timestamp: Timestamps.iso8601(), eventType: "click",
                url: "app://com.apple.finder", pageTitle: "Downloads", system: "Finder",
                target: EventTarget(
                    tag: "AXButton", role: "AXButton", accessibleName: "Open",
                    boundingBox: BoundingBox(x: 100.5, y: 200.25, width: 80, height: 24))),
            ActivityEvent(
                sessionId: sessionId, eventId: "\(sessionId)-2", sequence: 2,
                timestamp: Timestamps.iso8601(), eventType: "annotation",
                url: "app://session", value: "LiveOtlpTests"),
        ]
        let logs = OtlpMapper.logsRequest(events: events, in: context)
        let trace = OtlpMapper.traceRequest(in: context, endedAt: Timestamps.iso8601())

        let payloads: [(path: String, body: Data)] = [
            ("/v1/traces", try JSONEncoder().encode(trace)),
            ("/v1/logs", try JSONEncoder().encode(logs)),
        ]
        for (path, body) in payloads {
            let url = try XCTUnwrap(URL(string: endpoint + path))
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            // Mention only the path — the endpoint embeds the stream secret.
            XCTAssertEqual(status, 200, "POST \(path) was not accepted by the stream")
        }
    }
}
