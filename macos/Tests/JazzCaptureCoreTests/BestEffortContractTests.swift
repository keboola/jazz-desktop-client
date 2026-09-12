import Foundation
import XCTest

@testable import JazzCaptureCore

final class BestEffortContractTests: XCTestCase {
    struct Fixture: Decodable {
        let epoch: JazzBestEffortEpoch
        let envelopes: [JazzBestEffortEnvelope]
        let selection: JazzBestEffortSelection
        let otlpRequests: [Otlp.ExportLogsServiceRequest]
        let identityPins: [String: String]
    }
    func fixture() throws -> Fixture {
        try JSONDecoder().decode(
            Fixture.self,
            from: Data(
                contentsOf: Bundle.module.url(
                    forResource: "best-effort-v1", withExtension: "json", subdirectory: "Fixtures")!
            ))
    }
    func mutate<T: Codable>(_ value: T, _ change: (inout [String: JazzArchiveJSONValue]) -> Void)
        throws -> T
    {
        let data = try JazzArchiveCanonicalJSON.encode(value)
        guard
            case .object(var object) = try JSONDecoder().decode(
                JazzArchiveJSONValue.self, from: data)
        else { throw JazzBestEffortContract.Failure.invalid }
        change(&object)
        return try JazzBestEffortContract.decode(
            T.self, from: JazzArchiveCanonicalJSON.encode(JazzArchiveJSONValue.object(object)))
    }
    func testGoldenRunnerMatchesExactOTLPAndSelectionWithoutArchiveAuthority() throws {
        let f = try fixture()
        try f.epoch.authorize(
            binding: f.epoch.binding, capability: f.epoch.capability,
            observedSourceId: f.epoch.binding.sourceId,
            now: Timestamps.parse("2026-07-22T09:30:00Z")!)
        for (row, expected) in zip(f.envelopes, f.otlpRequests) {
            try row.validate(epoch: f.epoch)
            let request = try JazzBestEffortContract.otlpRequest(row, epoch: f.epoch)
            XCTAssertEqual(request, expected)
            XCTAssertFalse(
                request.resourceLogs[0].scopeLogs[0].logRecords[0].attributes.contains {
                    $0.key == "sessionId" || $0.key.hasPrefix("jazz.live.")
                })
        }
        XCTAssertEqual(
            try JazzBestEffortContract.identityPins(
                epoch: f.epoch, envelopes: f.envelopes, prior: [:]), f.identityPins)
        let frozen = try JazzBestEffortContract.freeze(epoch: f.epoch, envelopes: f.envelopes)
        XCTAssertEqual(frozen, f.selection)
        XCTAssertEqual(
            try JazzBestEffortContract.resolve(frozen, epoch: f.epoch, envelopes: f.envelopes)
                .count, 2)
        XCTAssertThrowsError(
            try JazzBestEffortContract.resolve(frozen, epoch: f.epoch, envelopes: [f.envelopes[0]]))
        XCTAssertThrowsError(try JazzBestEffortContract.requireArchiveOrAnalysisAuthority(frozen))
        let successor = try JazzBestEffortContract.freeze(
            epoch: f.epoch, envelopes: [f.envelopes[0]], predecessor: frozen)
        XCTAssertNotEqual(successor.selectionId, frozen.selectionId)
        XCTAssertEqual(successor.supersedesSelectionId, frozen.selectionId)
        XCTAssertEqual(frozen, f.selection)
    }
    func testWrongScopeSourceGenerationCapabilityAndExpiredEpochRejected() throws {
        let f = try fixture()
        let now = Timestamps.parse("2026-07-22T09:30:00Z")!
        for field in ["sourceId", "bundleId", "projectId"] {
            let bad: JazzBestEffortEpoch = try mutate(f.epoch) { object in
                if case .object(var binding) = object["binding"] {
                    binding[field] = .string(
                        field == "bundleId"
                            ? "jdb_" + String(repeating: "2", count: 32)
                            : field == "projectId" ? "999998" : "another-source")
                    object["binding"] = .object(binding)
                }
            }
            XCTAssertThrowsError(
                try bad.authorize(
                    binding: f.epoch.binding, capability: f.epoch.capability,
                    observedSourceId: f.epoch.binding.sourceId, now: now))
        }
        XCTAssertThrowsError(
            try f.epoch.authorize(
                binding: f.epoch.binding, capability: f.epoch.capability, observedSourceId: "other",
                now: now))
        XCTAssertThrowsError(
            try f.epoch.authorize(
                binding: f.epoch.binding, capability: f.epoch.capability,
                observedSourceId: f.epoch.binding.sourceId,
                now: Timestamps.parse("2026-07-22T10:00:00Z")!))
    }
    func testUnknownCompleteMalformedAndDowngradeFieldsFailClosed() throws {
        let f = try fixture()
        XCTAssertNil(OtlpMapper.unixNanos(fromISO8601: "9999-01-01T00:00:00Z"))
        for (field, value) in [
            ("protocolVersion", JazzArchiveJSONValue.integer(2)), ("authority", .string("READY")),
            ("coverage", .string("complete")),
        ] {
            let bad: JazzBestEffortEnvelope = try mutate(f.envelopes[0]) { $0[field] = value }
            XCTAssertThrowsError(try bad.validate(epoch: f.epoch))
        }
        XCTAssertThrowsError(try mutate(f.envelopes[0]) { $0["captureCommit"] = .object([:]) })
        let badMedia: JazzBestEffortEnvelope = try mutate(f.envelopes[1]) {
            $0["mediaState"] = .string("available")
        }
        XCTAssertThrowsError(try badMedia.validate(epoch: f.epoch))
        XCTAssertThrowsError(
            try JazzBestEffortContract.decode(
                JazzBestEffortEpoch.self,
                from: Data("{\"protocolVersion\":1,\"protocolVersion\":2}".utf8)))
        XCTAssertThrowsError(
            try JazzBestEffortContract.decode(
                JazzBestEffortEpoch.self,
                from: Data(repeating: 32, count: JazzBestEffortContract.maximumBytes + 1)))
    }
    func testEpochCaptureAndCrossModeIdentityPinsCannotBeReassigned() throws {
        let f = try fixture()
        let pins = try JazzBestEffortContract.identityPins(
            epoch: f.epoch, envelopes: f.envelopes, prior: [:])
        XCTAssertEqual(
            try JazzBestEffortContract.identityPins(
                epoch: f.epoch, envelopes: f.envelopes, prior: pins), pins)
        let changed: JazzBestEffortEpoch = try mutate(f.epoch) {
            $0["startedAt"] = .string("2026-07-22T09:01:00Z")
        }
        XCTAssertThrowsError(
            try JazzBestEffortContract.identityPins(epoch: changed, envelopes: [], prior: pins))
        let changedID: JazzBestEffortEpoch = try mutate(f.epoch) {
            $0["epochId"] = .string("bep-22222222-2222-7222-8222-222222222222")
        }
        XCTAssertThrowsError(
            try JazzBestEffortContract.identityPins(epoch: changedID, envelopes: [], prior: pins))
        let archived = ["item:" + f.envelopes[0].item.itemId: f.envelopes[0].item.canonicalDigest]
        XCTAssertThrowsError(
            try JazzBestEffortContract.identityPins(
                epoch: f.epoch, envelopes: f.envelopes, prior: archived))
    }

    func testExactReplayIdConflictAndSlotCollisionDoNotMutatePriorInputs() throws {
        let f = try fixture()
        let original = f.envelopes[0]
        XCTAssertEqual(
            try JazzBestEffortContract.merge(
                epoch: f.epoch, existing: [original], incoming: [original]), [original])
        func changed(_ slotCollision: Bool) throws -> JazzBestEffortEnvelope {
            try mutate(original) { object in
                guard case .object(var item) = object["item"],
                    case .string(let text) = item["canonicalJcs"],
                    case .object(var record) = try! JSONDecoder().decode(
                        JazzArchiveJSONValue.self, from: Data(text.utf8))
                else { return }
                if slotCollision {
                    let id = "obs-11111111-1111-7111-8111-111111111111"
                    item["itemId"] = .string(id)
                    record["observationId"] = .string(id)
                } else if case .object(var payload) = record["payload"] {
                    payload["url"] = .string("app://changed")
                    record["payload"] = .object(payload)
                }
                let data = try! JazzArchiveCanonicalJSON.encode(JazzArchiveJSONValue.object(record))
                item["canonicalJcs"] = .string(String(decoding: data, as: UTF8.self))
                item["canonicalDigest"] = .string(JazzArchiveDigest.sha256Hex(data))
                object["item"] = .object(item)
            }
        }
        for slot in [false, true] {
            let altered = try changed(slot)
            XCTAssertThrowsError(
                try JazzBestEffortContract.merge(
                    epoch: f.epoch, existing: [original], incoming: [altered]))
        }
        XCTAssertEqual(original, f.envelopes[0])
        XCTAssertThrowsError(
            try JazzBestEffortContract.merge(
                epoch: f.epoch, existing: [], incoming: Array(repeating: original, count: 257)))
        let forged: JazzBestEffortSelection = try mutate(f.selection) {
            $0["analysisEligibility"] = .string("eligible")
        }
        XCTAssertThrowsError(try JazzBestEffortContract.validateSelectionIdentity(forged))
    }
}
