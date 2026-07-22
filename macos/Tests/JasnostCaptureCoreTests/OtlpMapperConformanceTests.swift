import XCTest

@testable import JasnostCaptureCore

/// Swift runner for the cross-platform conformance kit (ADR 0004).
///
/// The macOS `OtlpMapper` is the AUTHORITY the golden fixtures in `contract/conformance/fixtures/`
/// are generated from. This test proves the authority still produces those goldens (a drift guard:
/// change the mapper without re-running `generate.py` and this fails), and the Python runner
/// (`apps/processor/tests/test_conformance.py`) proves the Python mirror reproduces the SAME
/// goldens — so a divergence between the two implementations fails one of the two CI jobs. A future
/// Windows/.NET agent adds a third runner over these same fixtures.
///
/// Comparison is STRUCTURAL: both sides are re-parsed via `JSONSerialization` and deep-compared, so
/// `intValue` staying a string is enforced while a Double rendered as `64` vs `64.0` (JSONEncoder vs
/// the generator) is not a false failure — `NSNumber` equality treats them as equal, and the
/// contract-ordered attribute arrays line up positionally.
final class OtlpMapperConformanceTests: XCTestCase {
    /// Walk up from this source file until the directory holding `contract/conformance/fixtures`.
    private func fixturesDir() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("contract/conformance/fixtures")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("contract/conformance/fixtures not found above \(#filePath)")
    }

    private func context(from dict: [String: Any]) -> OtlpMapper.SessionContext {
        func s(_ key: String) -> String { dict[key] as? String ?? "" }
        return OtlpMapper.SessionContext(
            sessionId: s("session_id"),
            traceId: s("trace_id"),
            spanId: s("span_id"),
            startedAt: s("started_at"),
            // The wire coerces nil kind/area -> "" on records but the SPAN drops them when empty,
            // so an empty string in the fixture must map to nil here (matches the generator's
            // `if ctx.kind` / `if ctx.area_id` span logic).
            kind: s("kind").isEmpty ? nil : s("kind"),
            user: s("user"),
            instanceName: s("instance_name"),
            areaId: s("area_id").isEmpty ? nil : s("area_id"),
            areaName: s("area_name").isEmpty ? nil : s("area_name"),
            serviceName: dict["service_name"] as? String ?? OtlpMapper.defaultServiceName
        )
    }

    /// Re-encode a Codable OTLP value and parse it back to a Foundation object for structural
    /// comparison against the golden (also parsed from JSON).
    private func roundTrip<T: Encodable>(_ value: T) throws -> NSObject {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! NSObject
    }

    func testMapperReproducesTheGoldens() throws {
        let dir = try fixturesDir()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no conformance fixtures in \(dir.path)")

        let decoder = JSONDecoder()
        for file in files {
            let name = file.lastPathComponent
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let input = root["input"] as! [String: Any]
            let ctx = context(from: input["context"] as! [String: Any])
            let endedAt = input["endedAt"] as! String

            // Decode each event from its own JSON (camelCase keys match ActivityEvent's Codable).
            let eventDicts = input["events"] as! [[String: Any]]
            let events = try eventDicts.map { ev -> ActivityEvent in
                try decoder.decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: ev))
            }

            let producedLogs = try roundTrip(OtlpMapper.logsRequest(events: events, in: ctx))
            let goldenLogs = root["logs"] as! NSObject
            XCTAssertTrue(
                producedLogs.isEqual(goldenLogs),
                "logs diverge from the golden for \(name) — the Swift authority no longer matches "
                    + "contract/conformance/fixtures (update the processor mirror if the mapping changed on purpose)"
            )

            let producedTraces = try roundTrip(OtlpMapper.traceRequest(in: ctx, endedAt: endedAt))
            let goldenTraces = root["traces"] as! NSObject
            XCTAssertTrue(
                producedTraces.isEqual(goldenTraces),
                "traces diverge from the golden for \(name)"
            )
        }
    }
}
