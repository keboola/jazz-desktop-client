import XCTest

@testable import JazzCaptureCore

/// Pins the macOS client's cross-repository identifiers to `contract/identifiers.json`, the manifest
/// the Windows client and the processor test against too. Renaming a tag, header, route, bridge
/// name or OTLP key here without the manifest (or the reverse) fails this suite; the processor's
/// drift job then fails against the same manifest.
final class IdentifierParityTests: XCTestCase {
    private struct ManifestNotFound: Error {}

    /// Walk up from this source file to the repository's `contract/identifiers.json`.
    private func manifest() throws -> [String: Any] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("contract/identifiers.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                let object = try JSONSerialization.jsonObject(with: data)
                return try XCTUnwrap(object as? [String: Any])
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("contract/identifiers.json not found above \(#filePath)")
        throw ManifestNotFound()
    }

    private func section(_ manifest: [String: Any], _ key: String) throws -> [String: Any] {
        try XCTUnwrap(manifest[key] as? [String: Any], "manifest section \(key)")
    }

    private func canonical(_ section: [String: Any], _ key: String) throws -> String {
        let entry = try XCTUnwrap(section[key] as? [String: Any], "manifest entry \(key)")
        return try XCTUnwrap(entry["canonical"] as? String, "canonical value of \(key)")
    }

    func testStorageTagsMatchTheManifest() throws {
        let tags = try section(manifest(), "storageTags")
        XCTAssertEqual(JazzContractIdentifiers.StorageTag.capture, try canonical(tags, "capture"))
        XCTAssertEqual(
            JazzContractIdentifiers.StorageTag.archiveArtifact,
            try canonical(tags, "archiveArtifact"))
        XCTAssertEqual(
            JazzContractIdentifiers.StorageTag.narration, try canonical(tags, "narration"))
        XCTAssertEqual(
            JazzContractIdentifiers.StorageTag.areaRegistry, try canonical(tags, "areaRegistry"))
    }

    func testHeadersAndRoutesMatchTheManifest() throws {
        let root = try manifest()
        let header = JazzContractIdentifiers.Header.self
        let expected: [String: String] = [
            "deviceId": header.deviceId,
            "bootstrap": header.bootstrap,
            "replayCapability": header.replayCapability,
            "actionAuthorityProtocol": header.actionAuthorityProtocol,
            "archiveId": header.archiveId,
            "contentDigest": header.contentDigest,
            "rawSha256": header.rawSha256,
            "byteLength": header.byteLength,
        ]
        XCTAssertEqual(try XCTUnwrap(root["httpHeaders"] as? [String: String]), expected)

        let routes = try XCTUnwrap(root["deviceRoutes"] as? [String: String])
        XCTAssertEqual(JazzContractIdentifiers.DeviceRoute.recordingPlan, routes["recordingPlan"])
        XCTAssertEqual(JazzDeviceRecordingPlanRoute.planSuffix, routes["recordingPlan"])
    }

    func testWebBridgeMatchesTheManifest() throws {
        let bridge = try section(manifest(), "webBridge")
        XCTAssertEqual(JazzContractIdentifiers.WebBridge.handler, try canonical(bridge, "handler"))
        XCTAssertEqual(
            JazzContractIdentifiers.WebBridge.bdmSegmentHook,
            try canonical(bridge, "bdmSegmentHook"))
        XCTAssertEqual(JazzContractIdentifiers.WebBridge.embedMode, bridge["embedMode"] as? String)
        let types = try XCTUnwrap(bridge["webToNativeMessageTypes"] as? [String])
        XCTAssertEqual(JazzContractIdentifiers.WebBridge.webToNativeMessageTypes, Set(types))
    }

    func testSchemaIdBaseMatchesTheManifest() throws {
        let base = try XCTUnwrap(
            try section(manifest(), "schemaIdBase")["canonical"] as? String)
        for schemaId in [
            JazzArchiveContract.activityEvent.schemaId,
            JazzArchiveContract.mediaObservation.schemaId,
        ] {
            XCTAssertTrue(schemaId.hasPrefix(base), "\(schemaId) is not under \(base)")
        }
    }

    func testOtlpServiceScopeAndSessionAttributesMatchTheManifest() throws {
        let root = try manifest()
        let otlp = try section(root, "otlp")
        XCTAssertEqual(OtlpMapper.defaultServiceName, try canonical(otlp, "serviceName"))
        XCTAssertEqual(OtlpMapper.scopeName, try canonical(otlp, "scopeName"))

        // Drive the real mapper with every session-scoped value set: each manifest key must ride
        // both a generic record and the dedicated narration record.
        let expected = try XCTUnwrap(root["sessionAttributes"] as? [String])
        let context = OtlpMapper.SessionContext(
            sessionId: "s-parity",
            traceId: "0123456789abcdef0123456789abcdef",
            spanId: "0123456789abcdef",
            startedAt: "2026-07-02T09:00:00.000Z",
            kind: "process-mapping",
            user: "ann@example.com",
            instanceName: "Ann's Mac",
            areaId: "finance",
            areaName: "Finance",
            companyId: "acme",
            deviceId: "device-ann-01")
        for eventType in ["click", EventType.narration.rawValue] {
            let event = ActivityEvent(
                sessionId: "s-parity",
                eventId: "s-parity-1",
                timestamp: "2026-07-02T09:00:01.000Z",
                eventType: eventType,
                url: "app://com.example.x",
                audioFileId: "42",
                labelId: "l-parity",
                label: "Refund",
                processId: "refund",
                process: "Refund handling")
            let keys = Set(OtlpMapper.attributes(for: event, in: context).map(\.key))
            for key in expected {
                XCTAssertTrue(keys.contains(key), "\(eventType) record lacks \(key)")
            }
        }
    }
}
