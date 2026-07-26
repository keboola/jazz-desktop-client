import Foundation
import XCTest

@testable import JasnostCaptureCore

final class LiveCompatibilityProjectionTests: XCTestCase {
    private struct Golden: Decodable {
        let protocolName: String
        let protocolVersion: Int
        let archiveFixture: String
        let archiveId: String
        let originId: String
        let captureId: String
        let items: [JazzLiveProjectionItem]

        enum CodingKeys: String, CodingKey {
            case protocolName = "protocol"
            case protocolVersion
            case archiveFixture
            case archiveId
            case originId
            case captureId
            case items
        }
    }

    private struct Fixture {
        let manifest: JazzArchiveManifest
        let session: JazzArchiveSession
        let records: [JazzArchiveRecord]
        let artifacts: [JazzArchiveArtifact]
        let commit: JazzArchiveCaptureCommit
        let golden: Golden
    }

    func testSwiftProjectionMatchesArchiveDerivedGoldenExactly() throws {
        let fixture = try loadFixture()
        let generated = try fixture.records.map(JazzLiveProjectionItem.observation)
            + fixture.artifacts.map {
                try JazzLiveProjectionItem.artifact(
                    $0,
                    fallbackCapturedAt: fixture.session.startedAt)
            }
            + [JazzLiveProjectionItem.commit(fixture.commit)]

        XCTAssertEqual(fixture.golden.protocolName, "dev.jazz.live-otlp-projection")
        XCTAssertEqual(fixture.golden.protocolVersion, 1)
        XCTAssertEqual(fixture.golden.archiveFixture, "02-labeled-narration")
        XCTAssertEqual(fixture.golden.archiveId, fixture.manifest.archiveId)
        XCTAssertEqual(fixture.golden.originId, fixture.manifest.originId)
        XCTAssertEqual(fixture.golden.captureId, fixture.session.captureId)
        XCTAssertEqual(generated, fixture.golden.items)

        let binding = try binding(for: fixture)
        let observation = try XCTUnwrap(generated.first)
        let attributes = JazzLiveOtlpProjection.attributes(
            item: observation, binding: binding)
        XCTAssertEqual(
            attributes.map(\.key),
            [
                "jazz.archive.id",
                "jazz.origin.id",
                "jazz.capture.id",
                "jazz.live.protocol_version",
                "jazz.live.kind",
                "jazz.live.item_id",
                "jazz.live.digest",
                "jazz.live.canonical",
                "jazz.live.captured_at",
                "jazz.stream.id",
                "jazz.stream.sequence",
                "jazz.record.type",
            ])
        let byKey = Dictionary(uniqueKeysWithValues: attributes.map { ($0.key, $0.value) })
        XCTAssertEqual(byKey["jazz.archive.id"], .string(fixture.manifest.archiveId))
        XCTAssertEqual(byKey["jazz.origin.id"], .string(fixture.manifest.originId))
        XCTAssertEqual(byKey["jazz.capture.id"], .string(fixture.session.captureId))
        XCTAssertEqual(byKey["jazz.live.protocol_version"], .int(1))
        XCTAssertEqual(byKey["jazz.live.item_id"], .string(observation.itemId))
        XCTAssertEqual(byKey["jazz.live.digest"], .string(observation.canonicalDigest))
        XCTAssertEqual(byKey["jazz.live.canonical"], .string(observation.canonicalJcs))
        XCTAssertEqual(byKey["jazz.live.captured_at"], .string(observation.capturedAt))

        let commit = try XCTUnwrap(generated.last)
        let commitAttributes = try JazzLiveOtlpProjection.commitSpanAttributes(
            commit: commit, binding: binding)
        XCTAssertEqual(
            commitAttributes.first { $0.key == "jazz.live.item_id" }?.value,
            .string(fixture.commit.commitId))
        XCTAssertFalse(commitAttributes.contains { $0.key == "jazz.stream.sequence" })
    }

    func testCanonicalSpoolSidecarAndCommitSurviveRetryRelaunchAndJournalMove() throws {
        let fixture = try loadFixture()
        let binding = try binding(for: fixture)
        let record = try XCTUnwrap(fixture.records.first { !$0.artifactRefs.isEmpty })
        let event = try record.activityRecord().payload
        let artifactById = Dictionary(
            uniqueKeysWithValues: fixture.artifacts.map { ($0.artifactId, $0) })
        let artifacts = try record.artifactRefs.map {
            try XCTUnwrap(artifactById[$0.artifactId])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-live-projection-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let spool = EventSpool(root: root)
        try spool.createSession(EventSpool.SessionMeta(
            sessionId: event.sessionId,
            traceId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            spanId: "bbbbbbbbbbbbbbbb",
            startedAt: fixture.session.startedAt,
            user: "fixture@example.com",
            liveCanonicalBinding: binding))
        let first = try XCTUnwrap(try spool.appendCanonicalProjection(
            sessionId: event.sessionId,
            binding: binding,
            record: record,
            artifacts: artifacts,
            event: event))
        XCTAssertTrue(
            try XCTUnwrap(spool.sessions().first { $0.id == event.sessionId })
                .hasLiveCompatibilityProjection)
        let projected = try XCTUnwrap(spool.readLiveProjection(first))
        XCTAssertEqual(projected.binding, binding)
        XCTAssertEqual(
            projected.observation,
            try JazzLiveProjectionItem.observation(record))
        XCTAssertEqual(
            projected.artifacts,
            try artifacts.map {
                try JazzLiveProjectionItem.artifact(
                    $0,
                    fallbackCapturedAt: record.capturedAt)
            }.sorted { $0.itemId < $1.itemId })

        let relaunched = EventSpool(root: root)
        let repeated = try XCTUnwrap(try relaunched.appendCanonicalProjection(
            sessionId: event.sessionId,
            binding: binding,
            record: record,
            artifacts: artifacts,
            event: event))
        XCTAssertEqual(repeated.url, first.url)
        XCTAssertEqual(relaunched.readLiveProjection(repeated), projected)

        var conflictingRecord = record
        conflictingRecord.enrichedAt = "2026-07-24T12:00:00Z"
        XCTAssertThrowsError(try relaunched.appendCanonicalProjection(
            sessionId: event.sessionId,
            binding: binding,
            record: conflictingRecord,
            artifacts: artifacts,
            event: event)) { error in
                XCTAssertEqual(
                    error as? EventSpool.SpoolError,
                    .projectionConflict(record.observationId))
            }

        try relaunched.markSent(repeated)
        XCTAssertNil(try relaunched.appendCanonicalProjection(
            sessionId: event.sessionId,
            binding: binding,
            record: record,
            artifacts: artifacts,
            event: event))
        try relaunched.endSession(
            sessionId: event.sessionId,
            endedAt: fixture.commit.endedAt,
            captureCommit: fixture.commit)
        let expectedCommit = try JazzLiveProjectionItem.commit(fixture.commit)
        XCTAssertEqual(
            relaunched.sessionMeta(sessionId: event.sessionId)?.liveCaptureCommit,
            expectedCommit)

        try FileManager.default.removeItem(
            at: root.appendingPathComponent(event.sessionId, isDirectory: true))
        let journalOnly = EventSpool(root: root)
        XCTAssertEqual(
            journalOnly.sessionMeta(sessionId: event.sessionId)?.liveCanonicalBinding,
            binding)
        XCTAssertEqual(
            journalOnly.sessionMeta(sessionId: event.sessionId)?.liveCaptureCommit,
            expectedCommit)
        XCTAssertTrue(
            try XCTUnwrap(journalOnly.sessions().first { $0.id == event.sessionId })
                .hasLiveCompatibilityProjection)
    }

    func testSignedLiveProjectionWaitsForBothDestinationsAndReusesExactBytes() throws {
        let fixture = try loadFixture()
        let binding = try binding(for: fixture)
        let (route, envelope) = try signedEnrollment(
            streamEndpoint: "https://stream.example/otlp/123/source/secret")
        let requirements = try JazzLiveCompatibilityDeliveryRequirements(
            routeBinding: route,
            signedEnvelope: envelope)
        let record = try XCTUnwrap(fixture.records.first { !$0.artifactRefs.isEmpty })
        let event = try record.activityRecord().payload
        let artifactsById = Dictionary(
            uniqueKeysWithValues: fixture.artifacts.map { ($0.artifactId, $0) })
        let artifacts = try record.artifactRefs.map {
            try XCTUnwrap(artifactsById[$0.artifactId])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-live-dual-delivery-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let spool = EventSpool(root: root)
        try spool.createSession(EventSpool.SessionMeta(
            sessionId: event.sessionId,
            traceId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            spanId: "bbbbbbbbbbbbbbbb",
            startedAt: fixture.session.startedAt,
            user: "fixture@example.com",
            liveCanonicalBinding: binding,
            liveRouteBinding: route,
            liveDeliveryRequirements: requirements))
        let batch = try XCTUnwrap(try spool.appendCanonicalProjection(
            sessionId: event.sessionId,
            binding: binding,
            record: record,
            artifacts: artifacts,
            event: event))
        let context = OtlpMapper.SessionContext(
            sessionId: event.sessionId,
            traceId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            spanId: "bbbbbbbbbbbbbbbb",
            startedAt: fixture.session.startedAt,
            user: "fixture@example.com")
        let logsBody = try JSONEncoder().encode(
            OtlpMapper.logsRequest(
                logRecords: JazzLiveOtlpProjection.logRecords(
                    event: event,
                    batch: try XCTUnwrap(spool.readLiveProjection(batch)),
                    context: context,
                    now: try XCTUnwrap(Timestamps.parse(record.capturedAt))),
                in: context))

        XCTAssertThrowsError(try spool.markSent(batch)) {
            XCTAssertEqual(
                $0 as? EventSpool.SpoolError,
                .deliveryIncomplete(batch.url.lastPathComponent))
        }
        XCTAssertEqual(
            try spool.prepareLiveDeliveryPayload(logsBody, for: batch),
            logsBody)
        try spool.markLiveDeliveryAccepted(.legacy, for: batch)
        XCTAssertFalse(spool.liveDeliveryState(batch).isComplete)

        let relaunched = EventSpool(root: root)
        XCTAssertEqual(
            try relaunched.prepareLiveDeliveryPayload(
                Data(#"{"newEncoder":"must-not-replace"}"#.utf8),
                for: batch),
            logsBody)
        XCTAssertEqual(
            relaunched.deliveryBatches().map(\.sessionId),
            [batch.sessionId])
        XCTAssertEqual(
            relaunched.deliveryBatches().map(\.url.lastPathComponent),
            [batch.url.lastPathComponent])
        try relaunched.markLiveDeliveryAccepted(.jazz, for: batch)
        XCTAssertTrue(relaunched.liveDeliveryState(batch).isComplete)
        try relaunched.markSent(batch)
        XCTAssertTrue(relaunched.deliveryBatches().isEmpty)

        try relaunched.endSession(
            sessionId: event.sessionId,
            endedAt: fixture.commit.endedAt,
            captureCommit: fixture.commit)
        let endedMeta = try XCTUnwrap(
            relaunched.sessionMeta(sessionId: event.sessionId))
        let traceBody = try JSONEncoder().encode(
            OtlpMapper.liveTraceRequest(
                in: context,
                endedAt: fixture.commit.endedAt,
                binding: binding,
                captureCommit: try XCTUnwrap(endedMeta.liveCaptureCommit)))
        XCTAssertEqual(
            try relaunched.prepareLiveSpanDeliveryPayload(
                sessionId: event.sessionId,
                candidate: traceBody),
            traceBody)
        try relaunched.markLiveSpanDeliveryAccepted(
            .legacy,
            sessionId: event.sessionId)
        XCTAssertThrowsError(
            try relaunched.markSpanSent(sessionId: event.sessionId)) {
                XCTAssertEqual(
                    $0 as? EventSpool.SpoolError,
                    .deliveryIncomplete(event.sessionId))
            }

        let spanRelaunch = EventSpool(root: root)
        XCTAssertEqual(
            try spanRelaunch.prepareLiveSpanDeliveryPayload(
                sessionId: event.sessionId,
                candidate: Data(#"{"changed":true}"#.utf8)),
            traceBody)
        try spanRelaunch.markLiveSpanDeliveryAccepted(
            .jazz,
            sessionId: event.sessionId)
        try spanRelaunch.markSpanSent(sessionId: event.sessionId)
        XCTAssertTrue(spanRelaunch.isSpanSent(sessionId: event.sessionId))
        XCTAssertTrue(spanRelaunch.sessionsAwaitingSpan().isEmpty)
        XCTAssertEqual(
            spanRelaunch.sessionMeta(sessionId: event.sessionId)?.liveRouteBinding,
            route)
    }

    func testSignedArchiveOnlyProjectionJournalsAfterJazzAlone() throws {
        let fixture = try loadFixture()
        let binding = try binding(for: fixture)
        let (route, envelope) = try signedEnrollment(streamEndpoint: nil)
        let requirements = try JazzLiveCompatibilityDeliveryRequirements(
            routeBinding: route,
            signedEnvelope: envelope)
        let record = try XCTUnwrap(fixture.records.first { !$0.artifactRefs.isEmpty })
        let event = try record.activityRecord().payload
        let artifactsById = Dictionary(
            uniqueKeysWithValues: fixture.artifacts.map { ($0.artifactId, $0) })
        let artifacts = try record.artifactRefs.map {
            try XCTUnwrap(artifactsById[$0.artifactId])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-live-jazz-only-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let spool = EventSpool(root: root)
        try spool.createSession(EventSpool.SessionMeta(
            sessionId: event.sessionId,
            traceId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            spanId: "bbbbbbbbbbbbbbbb",
            startedAt: fixture.session.startedAt,
            user: "fixture@example.com",
            liveCanonicalBinding: binding,
            liveRouteBinding: route,
            liveDeliveryRequirements: requirements))
        let batch = try XCTUnwrap(try spool.appendCanonicalProjection(
            sessionId: event.sessionId,
            binding: binding,
            record: record,
            artifacts: artifacts,
            event: event))
        let logsBody = Data(#"{"resourceLogs":[]}"#.utf8)

        XCTAssertEqual(
            try spool.prepareLiveDeliveryPayload(logsBody, for: batch),
            logsBody)
        XCTAssertFalse(spool.liveDeliveryState(batch).requires(.legacy))
        try spool.markLiveDeliveryAccepted(.jazz, for: batch)
        XCTAssertTrue(spool.liveDeliveryState(batch).isComplete)
        try spool.markSent(batch)
        XCTAssertTrue(spool.deliveryBatches().isEmpty)

        try spool.endSession(
            sessionId: event.sessionId,
            endedAt: fixture.commit.endedAt,
            captureCommit: fixture.commit)
        let traceBody = Data(#"{"resourceSpans":[]}"#.utf8)
        XCTAssertEqual(
            try spool.prepareLiveSpanDeliveryPayload(
                sessionId: event.sessionId,
                candidate: traceBody),
            traceBody)
        XCTAssertFalse(
            spool.liveSpanDeliveryState(sessionId: event.sessionId)
                .requires(.legacy))
        try spool.markLiveSpanDeliveryAccepted(
            .jazz,
            sessionId: event.sessionId)
        try spool.markSpanSent(sessionId: event.sessionId)
        XCTAssertTrue(spool.isSpanSent(sessionId: event.sessionId))
        XCTAssertTrue(spool.sessionsAwaitingSpan().isEmpty)
    }

    func testOffModeSpoolRemainsLegacyAndCanonicalBindingCannotBeMixed() throws {
        let fixture = try loadFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-live-off-mode-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = EventSpool(root: root)
        let sessionId = "s-off"
        try spool.createSession(EventSpool.SessionMeta(
            sessionId: sessionId,
            traceId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            spanId: "bbbbbbbbbbbbbbbb",
            startedAt: fixture.session.startedAt,
            user: "fixture@example.com"))
        let event = ActivityEvent(
            sessionId: sessionId,
            eventId: "s-off-0",
            sequence: 0,
            timestamp: fixture.session.startedAt,
            eventType: "click",
            url: "app://fixture")
        let batch = try XCTUnwrap(try spool.appendProjection(
            sessionId: sessionId,
            observationId: Identifiers.newObservationId(),
            event: event))
        XCTAssertNil(spool.readLiveProjection(batch))
        XCTAssertFalse(
            try XCTUnwrap(spool.sessions().first { $0.id == sessionId })
                .hasLiveCompatibilityProjection)

        let record = try XCTUnwrap(fixture.records.first)
        let canonicalEvent = try record.activityRecord().payload
        XCTAssertThrowsError(try spool.appendCanonicalProjection(
            sessionId: sessionId,
            binding: try binding(for: fixture),
            record: record,
            artifacts: [],
            event: canonicalEvent))
    }

    private func binding(for fixture: Fixture) throws -> JazzLiveCanonicalBinding {
        try JazzLiveCanonicalBinding(
            archiveId: fixture.manifest.archiveId,
            originId: fixture.manifest.originId,
            captureId: fixture.session.captureId)
    }

    private func signedRoute() throws -> JazzArchiveUploadRouteBinding {
        try JazzArchiveUploadRouteBinding(
            ingestEndpoint: "https://jazz.example/api/archive-ingests",
            stackURL: "https://connection.example.keboola.com",
            projectId: "123",
            tokenId: "456",
            scope: JazzArchiveUploadScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: "device-7"),
            signedAuthority: JazzArchiveSignedEnrollmentAuthority(
                issuer: "https://issuer.example",
                audience: "jazz-desktop",
                bundleId: "jdb_00000000000000000000000000000007",
                generation: 7,
                envelopeDigest: String(repeating: "7", count: 64)))
    }

    private func signedEnrollment(
        streamEndpoint: String?
    ) throws -> (
        JazzArchiveUploadRouteBinding,
        JazzSignedDeviceCredentialEnvelope
    ) {
        let route = try signedRoute()
        let routing = JazzArchiveEnrollmentRouting(
            projectId: route.projectId,
            stackURL: route.stackURL,
            scope: route.scope,
            archiveIngestURL: route.ingestEndpoint,
            tokenId: route.tokenId,
            expiresAt: "2099-07-24T00:00:00.000Z",
            tokenBucketScope: JazzArchiveTokenBucketScope.none,
            signedAuthority: route.signedAuthority)
        return (
            route,
            try JazzSignedDeviceCredentialEnvelope(
                token: "scoped-device-token",
                expiresAt: routing.expiresAt,
                routeBinding: route,
                enrollmentRouting: routing,
                streamSourceId: streamEndpoint == nil ? nil : "legacy-source",
                streamEndpoint: streamEndpoint)
        )
    }

    private func loadFixture() throws -> Fixture {
        let decoder = JSONDecoder()
        let contract = contractRoot()
        let archiveRoot = contract.appendingPathComponent(
            "archive/fixtures/02-labeled-narration")
        let manifest = try decoder.decode(
            JazzArchiveManifest.self,
            from: Data(contentsOf: archiveRoot.appendingPathComponent("manifest.json")))
        let sessionRef = try XCTUnwrap(manifest.sessions.first)
        let sessionURL = archiveRoot.appendingPathComponent(sessionRef.path)
        let session = try decoder.decode(
            JazzArchiveSession.self,
            from: Data(contentsOf: sessionURL))
        let captureRoot = sessionURL.deletingLastPathComponent()
        let records = try decodeNDJSON(
            JazzArchiveRecord.self,
            at: captureRoot.appendingPathComponent("records.ndjson"))
        let artifacts = try decodeNDJSON(
            JazzArchiveArtifact.self,
            at: captureRoot.appendingPathComponent("artifacts.ndjson"))
        let commit = try decoder.decode(
            JazzArchiveCaptureCommit.self,
            from: Data(contentsOf: captureRoot.appendingPathComponent("commit.json")))
        let golden = try decoder.decode(
            Golden.self,
            from: Data(contentsOf: contract.appendingPathComponent(
                "live/otlp-fixtures/01-canonical-projection.json")))
        return Fixture(
            manifest: manifest,
            session: session,
            records: records,
            artifacts: artifacts,
            commit: commit,
            golden: golden)
    }

    private func decodeNDJSON<Value: Decodable>(
        _ type: Value.Type,
        at url: URL
    ) throws -> [Value] {
        let decoder = JSONDecoder()
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(type, from: Data($0.utf8)) }
    }

    private func contractRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            let contract = candidate.appendingPathComponent("contract")
            if FileManager.default.fileExists(atPath: contract.path) { return contract }
            candidate.deleteLastPathComponent()
        }
        preconditionFailure("contract root not found")
    }
}
