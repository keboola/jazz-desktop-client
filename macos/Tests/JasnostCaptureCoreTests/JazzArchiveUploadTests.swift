import Foundation
import XCTest

@testable import JasnostCaptureCore

final class JazzArchiveUploadTests: XCTestCase {
    private let timestamp = "2026-07-23T10:00:00.000Z"
    private static let uploadOperationA =
        "uop-019b1876-6f80-7000-8000-000000000001"
    private static let uploadOperationB =
        "uop-019b1876-6f80-7000-8000-000000000002"
    private static let authorityA = try! JazzArchiveSignedEnrollmentAuthority(
        issuer: "https://issuer.example",
        audience: "jazz-desktop",
        bundleId: "jdb_00000000000000000000000000000001",
        generation: 1,
        envelopeDigest: String(repeating: "a", count: 64))
    private static let authorityRotated = try! JazzArchiveSignedEnrollmentAuthority(
        issuer: "https://issuer.example",
        audience: "jazz-desktop",
        bundleId: "jdb_00000000000000000000000000000002",
        generation: 2,
        envelopeDigest: String(repeating: "b", count: 64))
    private static let otherIssuerAuthority = try! JazzArchiveSignedEnrollmentAuthority(
        issuer: "https://other-issuer.example",
        audience: "jazz-desktop",
        bundleId: "jdb_00000000000000000000000000000003",
        generation: 3,
        envelopeDigest: String(repeating: "c", count: 64))
    private static let otherAudienceAuthority = try! JazzArchiveSignedEnrollmentAuthority(
        issuer: "https://issuer.example",
        audience: "other-desktop",
        bundleId: "jdb_00000000000000000000000000000004",
        generation: 4,
        envelopeDigest: String(repeating: "d", count: 64))
    private static let routeA = try! JazzArchiveUploadRouteBinding(
        ingestEndpoint: "https://ingest-a.example/api/archive-ingests",
        stackURL: "https://connection.example.keboola.com",
        projectId: "123",
        tokenId: "456",
        scope: JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "mac-1"),
        signedAuthority: authorityA)
    private static let rotatedTokenRoute = try! JazzArchiveUploadRouteBinding(
        ingestEndpoint: "https://ingest-a.example/api/archive-ingests",
        stackURL: "https://connection.example.keboola.com",
        projectId: "123",
        tokenId: "789",
        scope: JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "mac-1"),
        signedAuthority: authorityRotated)
    private static let routeB = try! JazzArchiveUploadRouteBinding(
        ingestEndpoint: "https://ingest-b.example/api/archive-ingests",
        stackURL: "https://connection.example.keboola.com",
        projectId: "123",
        tokenId: "789",
        scope: JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "mac-1"),
        signedAuthority: authorityRotated)
    private static let otherIssuerRoute = try! JazzArchiveUploadRouteBinding(
        ingestEndpoint: "https://ingest-a.example/api/archive-ingests",
        stackURL: "https://connection.example.keboola.com",
        projectId: "123",
        tokenId: "789",
        scope: JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "mac-1"),
        signedAuthority: otherIssuerAuthority)
    private static let otherAudienceRoute = try! JazzArchiveUploadRouteBinding(
        ingestEndpoint: "https://ingest-a.example/api/archive-ingests",
        stackURL: "https://connection.example.keboola.com",
        projectId: "123",
        tokenId: "789",
        scope: JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "mac-1"),
        signedAuthority: otherAudienceAuthority)

    private struct Fixture {
        let archiveRoot: URL
        let deliveryRoot: URL
        let archiveId: String
        let originId: String
        let captureId: String
        let streamId: String
        let actorId: String
        let sourceId: String
        let sessionId: String
        let manifest: JazzArchiveManifest
        let session: JazzArchiveSession
    }

    private actor CredentialProvider: JazzArchiveCredentialProvider {
        var error: JazzArchiveUploadError?
        private(set) var requestCount = 0

        init(error: JazzArchiveUploadError? = nil) { self.error = error }

        func credential(
            for routeBinding: JazzArchiveUploadRouteBinding
        ) throws -> JazzArchiveScopedDeviceCredential {
            requestCount += 1
            if let error { throw error }
            return try JazzArchiveScopedDeviceCredential(
                "8625-123456-scoped-device-token-value")
        }

        func count() -> Int { requestCount }
    }

    private enum ControlResponseStage: Equatable {
        case intent
        case finalize
        case status
    }

    private actor FakeControlPlane: JazzArchiveUploadControlPlane {
        nonisolated let routeBinding: JazzArchiveUploadRouteBinding
        private(set) var intentCount = 0
        private(set) var finalizeCount = 0
        private(set) var statusCount = 0
        private(set) var legacyReconciliationCount = 0
        private(set) var intentOperationIds: [String] = []
        private(set) var finalizeOperationIds: [String] = []
        var finalizeState: JazzArchiveRemoteState = .ready
        var rejectFirstOperationIdAsExtra: Bool
        var omitOperationEchoOnceAt: ControlResponseStage?
        let nextAttemptAt: String?
        let echoedOperationId: String?
        let intentError: JazzArchiveUploadError?
        let legacyReconciliationOperationId: String

        init(
            finalizeState: JazzArchiveRemoteState = .ready,
            rejectFirstOperationIdAsExtra: Bool = false,
            omitOperationEchoOnceAt: ControlResponseStage? = nil,
            nextAttemptAt: String? = nil,
            echoedOperationId: String? = nil,
            intentError: JazzArchiveUploadError? = nil,
            legacyReconciliationOperationId: String = Identifiers.newUploadOperationId(),
            routeBinding: JazzArchiveUploadRouteBinding = JazzArchiveUploadTests.routeA
        ) {
            self.finalizeState = finalizeState
            self.rejectFirstOperationIdAsExtra = rejectFirstOperationIdAsExtra
            self.omitOperationEchoOnceAt = omitOperationEchoOnceAt
            self.nextAttemptAt = nextAttemptAt
            self.echoedOperationId = echoedOperationId
            self.intentError = intentError
            self.legacyReconciliationOperationId = legacyReconciliationOperationId
            self.routeBinding = routeBinding
        }

        func createIntent(
            _ request: JazzArchiveUploadIntentRequest,
            credential: JazzArchiveScopedDeviceCredential
        ) throws -> JazzArchiveUploadIntentResponse {
            XCTAssertEqual(credential.description, "<redacted scoped device credential>")
            intentCount += 1
            intentOperationIds.append(request.uploadOperationId)
            if let intentError {
                throw intentError
            }
            if rejectFirstOperationIdAsExtra {
                rejectFirstOperationIdAsExtra = false
                let responseBody = try JSONSerialization.data(withJSONObject: [
                    "detail": [[
                        "type": "extra_forbidden",
                        "loc": ["body", "uploadOperationId"],
                        "msg": "Extra inputs are not permitted",
                        "input": request.uploadOperationId,
                        "url": "https://errors.pydantic.dev/2.11/v/extra_forbidden",
                    ]]
                ])
                XCTAssertTrue(
                    JazzArchiveUploadServerCompatibility.rejectsUploadOperationId(
                        statusCode: 422,
                        responseBody: responseBody,
                        expectedOperationId: request.uploadOperationId))
                throw JazzArchiveUploadError.retryable(
                    JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode)
            }
            return JazzArchiveUploadIntentResponse(
                status: status(request, state: .created, stage: .intent),
                upload: try JazzArchiveOpaqueUploadInstructions(
                    transport: JazzArchiveHTTPPutGrant.transport,
                    values: [
                        "method": .string("PUT"),
                        "url": .string(
                            "https://objects.example/quarantine?signature=secret-grant-marker"),
                        "headers": .object([
                            "X-Signed-Provider": .string("secret-header-marker")
                        ]),
                        "receiptHeader": .string("ETag"),
                    ]))
        }

        func reconcileLegacyIntent(
            _ request: JazzArchiveLegacyUploadReconciliationRequest,
            credential: JazzArchiveScopedDeviceCredential
        ) throws -> JazzArchiveUploadIntentResponse {
            legacyReconciliationCount += 1
            let exact = JazzArchiveUploadIntentRequest(
                uploadOperationId: legacyReconciliationOperationId,
                archiveId: request.archiveId,
                originId: request.originId,
                formatVersion: request.formatVersion,
                revision: request.revision,
                contentDigest: request.contentDigest,
                rawSHA256: request.rawSHA256,
                byteLength: request.byteLength,
                scope: request.scope)
            return JazzArchiveUploadIntentResponse(
                status: status(exact, state: .created, stage: .intent),
                upload: nil)
        }

        func finalize(
            ingestId: String,
            uploadOperationId: String,
            scope: JazzArchiveUploadScope,
            uploadReceipt: String,
            credential: JazzArchiveScopedDeviceCredential
        ) throws -> JazzArchiveRemoteStatus {
            finalizeCount += 1
            guard let lastRequest else {
                throw JazzArchiveUploadError.invalidServerResponse("MISSING_INTENT")
            }
            XCTAssertEqual(ingestId, "ingest-1")
            XCTAssertEqual(uploadOperationId, lastRequest.uploadOperationId)
            finalizeOperationIds.append(uploadOperationId)
            XCTAssertEqual(uploadReceipt, "opaque-receipt")
            return status(lastRequest, state: finalizeState, stage: .finalize)
        }

        func status(
            ingestId: String,
            scope: JazzArchiveUploadScope,
            credential: JazzArchiveScopedDeviceCredential
        ) throws -> JazzArchiveRemoteStatus {
            statusCount += 1
            guard let lastRequest else {
                throw JazzArchiveUploadError.invalidServerResponse("MISSING_INTENT")
            }
            return status(lastRequest, state: .ready, stage: .status)
        }

        private var lastRequest: JazzArchiveUploadIntentRequest?

        private func status(
            _ request: JazzArchiveUploadIntentRequest,
            state: JazzArchiveRemoteState,
            stage: ControlResponseStage
        ) -> JazzArchiveRemoteStatus {
            lastRequest = request
            let omitEcho = omitOperationEchoOnceAt == stage
            if omitEcho { omitOperationEchoOnceAt = nil }
            return JazzArchiveRemoteStatus(
                uploadOperationId: omitEcho
                    ? nil
                    : echoedOperationId ?? request.uploadOperationId,
                ingestId: "ingest-1",
                state: state,
                archiveId: request.archiveId,
                originId: request.originId,
                formatVersion: request.formatVersion,
                revision: request.revision,
                contentDigest: request.contentDigest,
                rawSHA256: request.rawSHA256,
                byteLength: request.byteLength,
                errorCode: state == .failedTerminal
                    ? "ARCHIVE_IMPORT_FAILED"
                    : state == .failedRetryable ? "ARCHIVE_IMPORT_RETRY" : nil,
                nextAttemptAt: state == .failedRetryable ? nextAttemptAt : nil)
        }

        func counts() -> (Int, Int, Int) { (intentCount, finalizeCount, statusCount) }

        func legacyCount() -> Int { legacyReconciliationCount }

        func operationIds() -> ([String], [String]) {
            (intentOperationIds, finalizeOperationIds)
        }
    }

    private actor FakeTransport: JazzArchiveDirectUploadTransport {
        var failFirst: Bool
        private(set) var fingerprints: [JazzArchiveFileFingerprint] = []

        init(failFirst: Bool = false) { self.failFirst = failFirst }

        func upload(
            file: URL,
            instructions: JazzArchiveOpaqueUploadInstructions
        ) throws -> String {
            fingerprints.append(try JazzArchiveFileIO.fingerprint(file))
            if failFirst {
                failFirst = false
                throw JazzArchiveUploadError.retryable("OFFLINE")
            }
            return "opaque-receipt"
        }

        func values() -> [JazzArchiveFileFingerprint] { fingerprints }
    }

    private func fixture(deliveryRoot sharedDeliveryRoot: URL? = nil) -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jazz-upload-tests-\(UUID().uuidString)")
        let archiveRoot = root.appendingPathComponent("archives", isDirectory: true)
        let deliveryRoot =
            sharedDeliveryRoot
            ?? root.appendingPathComponent("archive-upload", isDirectory: true)
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let actorId = Identifiers.newActorId()
        let sourceId = Identifiers.newSourceId()
        let sessionId = Identifiers.newSessionId()
        let producer = JazzArchiveProducer(
            name: "Jazz Capture", version: "test", platform: "macOS")
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            createdAt: timestamp,
            producer: producer,
            actors: [JazzArchiveActor(
                actorId: actorId,
                kind: .human,
                displayName: "Recorder",
                provenance: JazzArchiveProvenance(factClass: .declared, sources: []))],
            sources: [JazzArchiveSource(
                sourceId: sourceId,
                kind: "macos.native",
                actorId: actorId,
                producer: producer,
                capabilities: ["pointer.capture"],
                provenance: JazzArchiveProvenance(factClass: .observed, sources: []))],
            sessions: [JazzArchiveSessionRef(
                captureId: captureId, legacySessionId: sessionId)])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: sessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: timestamp,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            area: JazzArchiveArea(areaId: "finance", nameSnapshot: "Finance"),
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "consent-v1",
                consentedAt: timestamp,
                modalities: [.pointer],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        return Fixture(
            archiveRoot: archiveRoot,
            deliveryRoot: deliveryRoot,
            archiveId: archiveId,
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            actorId: actorId,
            sourceId: sourceId,
            sessionId: sessionId,
            manifest: manifest,
            session: session)
    }

    private func makeCommitted(_ fixture: Fixture) async throws {
        let store = JazzArchiveDraftStore(root: fixture.archiveRoot)
        _ = try await store.create(manifest: fixture.manifest, session: fixture.session)
        let event = ActivityEvent(
            sessionId: fixture.sessionId,
            eventId: Identifiers.eventId(sessionId: fixture.sessionId, sequence: 0),
            sequence: 0,
            timestamp: timestamp,
            eventType: EventType.sessionStart.rawValue,
            url: "app://session")
        _ = try await store.append(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            records: [ArchiveRecord(
                event: event,
                originId: fixture.originId,
                captureId: fixture.captureId,
                streamId: fixture.streamId,
                streamSequence: 0,
                sourceRefs: [JazzArchiveSourceRef(
                    sourceId: fixture.sourceId, role: "trigger")],
                actorRefs: [JazzArchiveActorRef(
                    actorId: fixture.actorId,
                    role: "performer",
                    basis: .declared)],
                provenance: JazzArchiveProvenance(
                    factClass: .observed, sources: [fixture.sourceId]),
                quality: JazzArchiveQuality(status: .complete),
                privacy: JazzArchivePrivacy(
                    status: .captured, policyVersion: "consent-v1"))])
        _ = try await store.end(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            endedAt: "2026-07-23T10:01:00.000Z")
    }

    private func review(
        _ fixture: Fixture,
        decision: JazzArchiveAssertionDecision
    ) async throws {
        let store = JazzArchiveReviewStore(root: fixture.archiveRoot)
        _ = try await store.append(
            archiveId: fixture.archiveId,
            assertion: JazzArchiveAssertion(
                target: JazzArchiveAssertionTarget(kind: .archive, id: fixture.archiveId),
                decision: decision,
                reason: decision == .reject ? "Not representative" : nil,
                authoredByActorId: fixture.actorId,
                authoredAt: "2026-07-23T10:02:00.000Z",
                baseRevision: 1,
                scope: .archive,
                provenance: JazzArchiveProvenance(factClass: .declared, sources: [])))
    }

    private func scope() throws -> JazzArchiveUploadScope {
        try JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "mac-1")
    }

    private func uploadInstructions(
        transport: String = JazzArchiveHTTPPutGrant.transport,
        method: String = "PUT",
        url: String = "https://objects.example/quarantine/object?signature=opaque",
        headers: [String: JazzArchiveJSONValue]? = [
            "Content-Type": .string("application/zip"),
            "x-amz-checksum-sha256": .string("opaque-checksum"),
        ],
        receiptHeader: String? = "ETag",
        extra: [String: JazzArchiveJSONValue] = [:]
    ) throws -> JazzArchiveOpaqueUploadInstructions {
        var values: [String: JazzArchiveJSONValue] = [
            "method": .string(method),
            "url": .string(url),
        ]
        if let headers { values["headers"] = .object(headers) }
        if let receiptHeader { values["receiptHeader"] = .string(receiptHeader) }
        for (key, value) in extra { values[key] = value }
        return try JazzArchiveOpaqueUploadInstructions(
            transport: transport,
            values: values)
    }

    private func enqueueConfirmed(
        _ fixture: Fixture,
        snapshotAt: String = "2026-07-23T10:03:00.000Z"
    ) async throws -> JazzArchiveUploadItem {
        let queue = JazzArchiveUploadQueue(root: fixture.deliveryRoot)
        return try await JazzArchiveConfirmedDelivery(
            archiveRoot: fixture.archiveRoot,
            queue: queue)
            .enqueueConfirmed(
                archiveId: fixture.archiveId,
                scope: try scope(),
                snapshotAt: snapshotAt)
    }

    private func forcePersistedDeliveryStage(
        _ state: JazzArchiveUploadState,
        fixture: Fixture
    ) throws -> URL {
        let recordURL = fixture.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(fixture.archiveId).json")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        json["state"] = state.rawValue
        json["attempt"] = 1
        json["routeBinding"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Self.routeA))
        json["ingestId"] = "ingest-1"
        if state == .finalizing {
            json["uploadReceipt"] = "opaque-receipt"
        } else {
            json.removeValue(forKey: "uploadReceipt")
        }
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: recordURL, options: .atomic)
        return fixture.deliveryRoot
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent("\(fixture.archiveId).jazz-archive")
    }

    func testDefaultPolicyIsConfirmedArchiveAndLiveCompatibilityIsExplicit() {
        XCTAssertEqual(JazzCaptureDeliveryPolicy.confirmedArchive.rawValue, "confirmedArchive")
        XCTAssertFalse(JazzCaptureDeliveryPolicy.confirmedArchive.usesLiveCompatibilityProjection)
        XCTAssertTrue(JazzCaptureDeliveryPolicy.liveCompatibility.usesLiveCompatibilityProjection)
    }

    func testLocalRetryJitterIsStableAcrossReconstructionAndOperationScoped() throws {
        let anchor = "2026-07-23T10:04:00.000Z"
        let original = JazzArchiveUploadItem(
            uploadOperationId: Self.uploadOperationA,
            archiveId: "ar-019b1876-6f80-7000-8000-000000000011",
            originId: "origin-019b1876-6f80-7000-8000-000000000012",
            captureIds: ["cap-019b1876-6f80-7000-8000-000000000013"],
            revision: 1,
            contentDigest: String(repeating: "a", count: 64),
            rawSHA256: String(repeating: "b", count: 64),
            byteLength: 1,
            scope: try scope())
        let reconstructed = try JSONDecoder().decode(
            JazzArchiveUploadItem.self,
            from: JSONEncoder().encode(original))
        let reconstructedOperation = try XCTUnwrap(reconstructed.uploadOperationId)

        for attempt in [0, 1, 2, 4, 9, 999, Int.max] {
            let first = try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: anchor,
                failedAttempt: attempt,
                uploadOperationId: Self.uploadOperationA)
            XCTAssertEqual(
                try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                    after: anchor,
                    failedAttempt: attempt,
                    uploadOperationId: reconstructedOperation),
                first)
        }

        XCTAssertNotEqual(
            try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: anchor,
                failedAttempt: 1,
                uploadOperationId: Self.uploadOperationA),
            try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: anchor,
                failedAttempt: 1,
                uploadOperationId: Self.uploadOperationB))
        XCTAssertNotEqual(
            try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: anchor,
                failedAttempt: Int.max,
                uploadOperationId: Self.uploadOperationA),
            try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: anchor,
                failedAttempt: Int.max,
                uploadOperationId: Self.uploadOperationB))
    }

    func testLocalRetryJitterPreservesAttemptBucketsBoundsAndHardCap() throws {
        let anchor = "2026-07-23T10:04:00.000Z"
        let baseMilliseconds: [(attempt: Int, delay: Int)] = [
            (0, 2_000),
            (1, 2_000),
            (2, 4_000),
            (4, 16_000),
            (8, 256_000),
            (9, 300_000),
            (999, 300_000),
            (Int.max, 300_000),
        ]
        let anchorDate = try XCTUnwrap(Timestamps.parse(anchor))
        var observed: [Int: Int] = [:]
        for expectation in baseMilliseconds {
            let timestamp = try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: anchor,
                failedAttempt: expectation.attempt,
                uploadOperationId: Self.uploadOperationA)
            let date = try XCTUnwrap(Timestamps.parse(timestamp))
            let delay = Int((date.timeIntervalSince(anchorDate) * 1_000).rounded())
            observed[expectation.attempt] = delay
            XCTAssertGreaterThanOrEqual(
                delay,
                expectation.delay * 3 / 4,
                "attempt \(expectation.attempt)")
            XCTAssertLessThanOrEqual(
                delay,
                expectation.delay,
                "attempt \(expectation.attempt)")
        }

        // Attempt zero has not crossed a network boundary. It intentionally shares the same
        // initial bucket and stable per-operation jitter as the first failed delivery attempt.
        XCTAssertEqual(observed[0], observed[1])
        XCTAssertEqual(observed[9], observed[999])
        XCTAssertEqual(observed[9], observed[Int.max])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(observed[9]), try XCTUnwrap(observed[8]))
        XCTAssertThrowsError(
            try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: anchor,
                failedAttempt: -1,
                uploadOperationId: Self.uploadOperationA))
        XCTAssertThrowsError(
            try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
                after: anchor,
                failedAttempt: 1,
                uploadOperationId: "uop-not-a-durable-uuidv7"))
    }

    func testUploadOperationIdentifiersAreUniqueLowercaseUUIDv7Values() {
        let values = (0..<1_024).map { _ in Identifiers.newUploadOperationId() }
        XCTAssertEqual(Set(values).count, values.count)
        for value in values {
            XCTAssertTrue(value.hasPrefix("uop-"))
            let raw = String(value.dropFirst(4))
            XCTAssertEqual(UUID(uuidString: raw)?.uuidString.lowercased(), raw)
            XCTAssertEqual(Array(raw)[14], "7")
            XCTAssertTrue("89ab".contains(Array(raw)[19]))
        }
    }

    func testUploadQueueRejectsPrefixOnlyNoncanonicalAndNonV7IdentityClaims()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-upload-identity-validation-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.jazz-archive")
        try Data("immutable package bytes".utf8).write(to: source)
        let validArchiveId = Identifiers.newArchiveId()
        let cases = [
            (
                archiveId: "ar-not-a-uuid",
                originId: Identifiers.newOriginId(),
                captureId: Identifiers.newCaptureId()
            ),
            (
                archiveId: validArchiveId,
                originId: "origin-\(UUID().uuidString.lowercased())",
                captureId: Identifiers.newCaptureId()
            ),
            (
                archiveId: validArchiveId,
                originId: Identifiers.newOriginId(),
                captureId: Identifiers.newCaptureId().uppercased()
            ),
        ]
        let queue = JazzArchiveUploadQueue(
            root: root.appendingPathComponent("delivery", isDirectory: true))

        for testCase in cases {
            do {
                _ = try await queue.enqueue(
                    file: source,
                    archiveId: testCase.archiveId,
                    originId: testCase.originId,
                    captureIds: [testCase.captureId],
                    revision: 1,
                    contentDigest: String(repeating: "a", count: 64),
                    scope: try scope())
                XCTFail("accepted a non-canonical UUIDv7 identity claim")
            } catch {
                XCTAssertEqual(
                    error as? JazzArchiveUploadError,
                    .invalidItem(testCase.archiveId))
            }
        }
    }

    func testHTTPPutV1GrantAcceptsOnlyBoundedRawPutInstructions() throws {
        let grant = try JazzArchiveHTTPPutGrant(instructions: uploadInstructions())
        XCTAssertEqual(grant.url.scheme, "https")
        XCTAssertEqual(grant.url.host, "objects.example")
        XCTAssertEqual(grant.headers["Content-Type"], "application/zip")
        XCTAssertEqual(grant.headers["x-amz-checksum-sha256"], "opaque-checksum")
        XCTAssertEqual(grant.receiptHeader, "ETag")
        XCTAssertEqual(
            try JazzArchiveHTTPPutGrant.validateReceipt("\"version-123\""),
            "\"version-123\"")
    }

    func testHTTPPutV1RejectsOtherProfilesMethodsMissingReceiptAndExtraFields() throws {
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(transport: "http-post/v1")))
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(method: "POST")))
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(receiptHeader: nil)))
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(extra: ["expiresAt": .string(timestamp)])))
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(receiptHeader: "bad header")))
    }

    func testOnlyExactFastAPIExtraFieldEnvelopeIsRetryableForMixedRollout() throws {
        let operationId = Identifiers.newUploadOperationId()
        let exact = try JSONSerialization.data(withJSONObject: [
            "detail": [[
                "type": "extra_forbidden",
                "loc": ["body", "uploadOperationId"],
                "msg": "Extra inputs are not permitted",
                "input": operationId,
                "url": "https://errors.pydantic.dev/2.11/v/extra_forbidden",
            ]]
        ])
        XCTAssertTrue(JazzArchiveUploadServerCompatibility.rejectsUploadOperationId(
            statusCode: 422,
            responseBody: exact,
            expectedOperationId: operationId))
        XCTAssertEqual(
            JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode,
            "ARCHIVE_UPLOAD_OPERATION_ID_CONTRACT_NOT_READY")

        let legitimateValidation = try JSONSerialization.data(withJSONObject: [
            "detail": [[
                "type": "string_too_short",
                "loc": ["body", "archiveId"],
                "msg": "String should have at least 1 character",
                "input": "",
            ]]
        ])
        XCTAssertFalse(JazzArchiveUploadServerCompatibility.rejectsUploadOperationId(
            statusCode: 422,
            responseBody: legitimateValidation,
            expectedOperationId: operationId))

        let wrongInput = try JSONSerialization.data(withJSONObject: [
            "detail": [[
                "type": "extra_forbidden",
                "loc": ["body", "uploadOperationId"],
                "msg": "Extra inputs are not permitted",
                "input": Identifiers.newUploadOperationId(),
            ]]
        ])
        XCTAssertFalse(JazzArchiveUploadServerCompatibility.rejectsUploadOperationId(
            statusCode: 422,
            responseBody: wrongInput,
            expectedOperationId: operationId))

        let mixedErrors = try JSONSerialization.data(withJSONObject: [
            "detail": [
                [
                    "type": "extra_forbidden",
                    "loc": ["body", "uploadOperationId"],
                    "msg": "Extra inputs are not permitted",
                    "input": operationId,
                ],
                [
                    "type": "missing",
                    "loc": ["body", "archiveId"],
                    "msg": "Field required",
                ],
            ]
        ])
        XCTAssertFalse(JazzArchiveUploadServerCompatibility.rejectsUploadOperationId(
            statusCode: 422,
            responseBody: mixedErrors,
            expectedOperationId: operationId))
        XCTAssertFalse(JazzArchiveUploadServerCompatibility.rejectsUploadOperationId(
            statusCode: 400,
            responseBody: exact,
            expectedOperationId: operationId))
    }

    func testHTTPPutV1RejectsUnsafeOrUnboundedURLs() throws {
        let invalidURLs = [
            "http://objects.example/object",
            "https://user:secret@objects.example/object",
            "https://objects.example/object#fragment",
            "https://objects.example\\@attacker.example/object",
            " https://objects.example/object",
            "https://objects.example/object\n",
            "https:///missing-host",
            "https://objects.example:0/object",
            "https://objects.example:65536/object",
        ]
        for url in invalidURLs {
            XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
                instructions: uploadInstructions(url: url)), url)
        }
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(
                url: "https://objects.example/" + String(repeating: "a", count: 16_384))))
    }

    func testHTTPPutV1RejectsUnsafeDuplicateOrUnboundedHeaders() throws {
        let forbidden = [
            "Connection", "Content-Length", "Host", "Keep-Alive",
            "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer",
            "Transfer-Encoding", "Upgrade",
        ]
        for name in forbidden {
            XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
                instructions: uploadInstructions(headers: [name: .string("value")])), name)
        }
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(headers: [
                "X-Signed": .string("one"),
                "x-signed": .string("two"),
            ])))
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(headers: ["Bad Header": .string("value")])))
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(headers: ["X-Signed": .string("one\r\ntwo")])))
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(headers: ["X-Signed": .integer(1)])))
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(headers: [
                "X-Signed": .string(String(repeating: "é", count: 4_097))
            ])))

        let tooMany = Dictionary(uniqueKeysWithValues: (0..<33).map {
            ("X-Signed-\($0)", JazzArchiveJSONValue.string("value"))
        })
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(headers: tooMany)))
        let tooLarge = Dictionary(uniqueKeysWithValues: (0..<5).map {
            ("X-Signed-\($0)", JazzArchiveJSONValue.string(String(repeating: "a", count: 7_000)))
        })
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant(
            instructions: uploadInstructions(headers: tooLarge)))
    }

    func testUploadReceiptMustBeCanonicalAndAtMostEightKiBUTF8() {
        for value in ["", " receipt", "receipt ", "line\nbreak", "tab\tvalue"] {
            XCTAssertThrowsError(try JazzArchiveHTTPPutGrant.validateReceipt(value), value)
        }
        XCTAssertThrowsError(try JazzArchiveHTTPPutGrant.validateReceipt(
            String(repeating: "é", count: 4_097)))
        XCTAssertNoThrow(try JazzArchiveHTTPPutGrant.validateReceipt(
            String(repeating: "é", count: 4_096)))
    }

    func testRouteBindingPinsExactEndpointOriginAndEnrollmentIdentity() throws {
        let route = try JazzArchiveUploadRouteBinding(
            ingestEndpoint: "https://ingest.example:8443/jazz/api/archive-ingests/",
            stackURL: "https://connection.example.keboola.com/",
            projectId: "123",
            tokenId: "456",
            scope: try scope(),
            signedAuthority: Self.authorityA)
        XCTAssertEqual(
            route.ingestEndpoint,
            "https://ingest.example:8443/jazz/api/archive-ingests")
        XCTAssertEqual(route.ingestOrigin, "https://ingest.example:8443")
        XCTAssertEqual(route.stackURL, "https://connection.example.keboola.com")
        XCTAssertEqual(route.projectId, "123")
        XCTAssertEqual(route.tokenId, "456")
        XCTAssertEqual(route.signedAuthority, Self.authorityA)
        XCTAssertEqual(
            try JSONDecoder().decode(
                JazzArchiveUploadRouteBinding.self,
                from: JSONEncoder().encode(route)),
            route)

        XCTAssertThrowsError(try JazzArchiveUploadRouteBinding(
            ingestEndpoint: "https://ingest.example/other-route",
            stackURL: "https://connection.example.keboola.com",
            projectId: "123",
            tokenId: "456",
            scope: scope(),
            signedAuthority: Self.authorityA))
    }

    func testTokenAndBundleRotationPreserveOnlyTheSamePinnedDeliveryAuthority() throws {
        let changedStack = try JazzArchiveUploadRouteBinding(
            ingestEndpoint: Self.routeA.ingestEndpoint,
            stackURL: "https://connection.other.keboola.cloud",
            projectId: Self.routeA.projectId,
            tokenId: "789",
            scope: Self.routeA.scope,
            signedAuthority: Self.authorityRotated)
        let changedProject = try JazzArchiveUploadRouteBinding(
            ingestEndpoint: Self.routeA.ingestEndpoint,
            stackURL: Self.routeA.stackURL,
            projectId: "999",
            tokenId: "789",
            scope: Self.routeA.scope,
            signedAuthority: Self.authorityRotated)
        let changedScope = try JazzArchiveUploadRouteBinding(
            ingestEndpoint: Self.routeA.ingestEndpoint,
            stackURL: Self.routeA.stackURL,
            projectId: Self.routeA.projectId,
            tokenId: "789",
            scope: JazzArchiveUploadScope(
                companyId: "acme", areaId: "finance", deviceId: "mac-2"),
            signedAuthority: Self.authorityRotated)

        XCTAssertNotEqual(Self.routeA.tokenId, Self.rotatedTokenRoute.tokenId)
        XCTAssertNotEqual(
            Self.routeA.signedAuthority?.bundleId,
            Self.rotatedTokenRoute.signedAuthority?.bundleId)
        XCTAssertTrue(Self.routeA.hasSameDeliveryAuthority(as: Self.rotatedTokenRoute))
        XCTAssertFalse(Self.routeA.hasSameDeliveryAuthority(as: Self.routeB))
        XCTAssertFalse(Self.routeA.hasSameDeliveryAuthority(as: Self.otherIssuerRoute))
        XCTAssertFalse(Self.routeA.hasSameDeliveryAuthority(as: Self.otherAudienceRoute))
        XCTAssertFalse(Self.routeA.hasSameDeliveryAuthority(as: changedStack))
        XCTAssertFalse(Self.routeA.hasSameDeliveryAuthority(as: changedProject))
        XCTAssertFalse(Self.routeA.hasSameDeliveryAuthority(as: changedScope))
    }

    func testEnrollmentBindingWritesExactDeviceAndAuthoritativeAreaClaims() throws {
        let finance = try JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "dev-42")
        let bound = JazzArchiveCaptureBinding(
            uploadScope: finance,
            selectedAreaId: "sales",
            selectedAreaName: "Sales")
        XCTAssertEqual(
            bound.enrolledDeviceIdentity,
            JazzArchiveExternalIdentity(namespace: "jazz.device", value: "dev-42"))
        XCTAssertEqual(bound.area?.areaId, "finance")
        XCTAssertEqual(bound.area?.nameSnapshot, "finance")

        let general = JazzArchiveCaptureBinding(
            uploadScope: try JazzArchiveUploadScope(
                companyId: "acme", areaId: "general", deviceId: "dev-42"),
            selectedAreaId: "finance",
            selectedAreaName: "Finance")
        XCTAssertEqual(general.area?.areaId, "general")
        XCTAssertEqual(general.area?.nameSnapshot, "General")

        let legacy = JazzArchiveCaptureBinding(
            uploadScope: nil,
            selectedAreaId: nil,
            selectedAreaName: nil)
        XCTAssertNil(legacy.enrolledDeviceIdentity)
        XCTAssertNil(legacy.area)
    }

    func testArchiveClaimsFailClosedBeforeAreaOrDeviceRebinding() throws {
        let value = fixture()
        var manifest = value.manifest
        manifest.enrolledDeviceIdentity = JazzArchiveExternalIdentity(
            namespace: "jazz.device", value: "mac-1")
        XCTAssertNoThrow(try scope().validateArchiveClaims(
            manifest: manifest, sessions: [value.session]))

        XCTAssertThrowsError(try JazzArchiveUploadScope(
            companyId: "acme", areaId: "sales", deviceId: "mac-1")
            .validateArchiveClaims(manifest: manifest, sessions: [value.session])) { error in
                XCTAssertEqual(
                    error as? JazzArchiveUploadError,
                    .scopeClaimMismatch("SCOPE_AREA_MISMATCH"))
            }
        XCTAssertThrowsError(try JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "another-device")
            .validateArchiveClaims(manifest: manifest, sessions: [value.session])) { error in
                XCTAssertEqual(
                    error as? JazzArchiveUploadError,
                    .scopeClaimMismatch("SCOPE_DEVICE_CLAIM_MISMATCH"))
            }
    }

    func testNoPackageOrNetworkIntentBeforeExplicitConfirmation() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let delivery = JazzArchiveConfirmedDelivery(
            archiveRoot: value.archiveRoot, queue: queue)
        do {
            _ = try await delivery.enqueueConfirmed(
                archiveId: value.archiveId,
                scope: try scope(),
                snapshotAt: "2026-07-23T10:03:00.000Z")
            XCTFail("unconfirmed capture must not enqueue")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFinalizationError,
                .archiveNotConfirmed(value.archiveId))
        }
        let queuedItems = try await queue.all()
        XCTAssertEqual(queuedItems, [])
        let control = FakeControlPlane()
        let worker = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: control,
            objectTransport: FakeTransport())
        let next = try await worker.runNext()
        XCTAssertNil(next)
        let counts = await control.counts()
        XCTAssertEqual(counts.0 + counts.1 + counts.2, 0)

    }

    func testRejectedReviewNeverQueuesDelivery() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .reject)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        do {
            _ = try await JazzArchiveConfirmedDelivery(
                archiveRoot: value.archiveRoot, queue: queue)
                .enqueueConfirmed(archiveId: value.archiveId, scope: try scope())
            XCTFail("rejected capture must not enqueue")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFinalizationError,
                .archiveNotConfirmed(value.archiveId))
        }
        let queuedItems = try await queue.all()
        XCTAssertTrue(queuedItems.isEmpty)
    }

    func testOfflineRetryPersistsAutomaticScheduleAndRelaunchUsesExactSamePackageBytes()
        async throws
    {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let queued = try await enqueueConfirmed(value)
        XCTAssertEqual(queued.schemaVersion, 2)
        let uploadOperationId = try XCTUnwrap(queued.uploadOperationId)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let transport = FakeTransport(failFirst: true)
        let firstControl = FakeControlPlane()
        let first = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: firstControl,
            objectTransport: transport,
            now: { "2026-07-23T10:04:00.000Z" })
        let failed = try await first.run(archiveId: value.archiveId)
        XCTAssertEqual(failed.state, .retryable)
        XCTAssertEqual(failed.uploadOperationId, uploadOperationId)
        let expectedRetryAt = try JazzArchiveUploadRetryPolicy.localNextAttemptAt(
            after: "2026-07-23T10:04:00.000Z",
            failedAttempt: 1,
            uploadOperationId: uploadOperationId)
        XCTAssertEqual(failed.nextAttemptAt, expectedRetryAt)
        let retryAt = try XCTUnwrap(Timestamps.parse(failed.nextAttemptAt))
        XCTAssertEqual(
            JazzArchiveUploadRetryPolicy.nextAutomaticFollowUp(
                for: [failed],
                now: try XCTUnwrap(Timestamps.parse("2026-07-23T10:04:00.000Z"))),
            retryAt)
        XCTAssertFalse(failed.canRunAutomatically(
            at: retryAt.addingTimeInterval(-0.001)))
        XCTAssertTrue(failed.canRunAutomatically(at: retryAt))

        // A pass before the durable watermark is a no-op: no extra intent or package read occurs.
        let early = try await first.run(archiveId: value.archiveId)
        XCTAssertEqual(early, failed)
        let earlyOperations = await firstControl.operationIds()
        XCTAssertEqual(earlyOperations.0, [uploadOperationId])
        let earlyUploads = await transport.values()
        XCTAssertEqual(earlyUploads.count, 1)
        let record = try String(
            contentsOf: value.deliveryRoot
                .appendingPathComponent("records", isDirectory: true)
                .appendingPathComponent("\(value.archiveId).json"),
            encoding: .utf8)
        XCTAssertFalse(record.contains("secret-grant-marker"))
        XCTAssertFalse(record.contains("secret-header-marker"))
        XCTAssertTrue(record.contains("\"nextAttemptAt\":\"\(expectedRetryAt)\""))

        // A fresh queue/coordinator instance models process relaunch. No finalizer or mutable draft
        // is consulted: the retry reads the queue-owned immutable ZIP.
        let relaunchedQueue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let relaunchedControl = FakeControlPlane()
        let relaunched = JazzArchiveUploadCoordinator(
            queue: relaunchedQueue,
            credentials: CredentialProvider(),
            controlPlane: relaunchedControl,
            objectTransport: transport,
            now: { "2026-07-23T10:05:00.000Z" })
        let ready = try await relaunched.run(archiveId: value.archiveId)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.uploadOperationId, uploadOperationId)
        XCTAssertNil(ready.nextAttemptAt)
        XCTAssertEqual(ready.attempt, 2)
        let sent = await transport.values()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1])
        XCTAssertEqual(sent[0].sha256, queued.rawSHA256)
        XCTAssertEqual(sent[0].byteLength, queued.byteLength)
        let firstOperations = await firstControl.operationIds()
        let relaunchedOperations = await relaunchedControl.operationIds()
        XCTAssertEqual(firstOperations.0, [uploadOperationId])
        XCTAssertEqual(firstOperations.1, [])
        XCTAssertEqual(relaunchedOperations.0, [uploadOperationId])
        XCTAssertEqual(relaunchedOperations.1, [uploadOperationId])
    }

    func testEveryInFlightStageRejectsChangedPackageBeforeCredentialOrNetwork()
        async throws
    {
        for stage in [
            JazzArchiveUploadState.finalizing,
            .verifying,
            .processing,
        ] {
            let value = fixture()
            defer {
                try? FileManager.default.removeItem(
                    at: value.archiveRoot.deletingLastPathComponent())
            }
            try await makeCommitted(value)
            try await review(value, decision: .confirm)
            _ = try await enqueueConfirmed(value)
            let packageURL = try forcePersistedDeliveryStage(
                stage,
                fixture: value)
            try Data("changed immutable package".utf8)
                .write(to: packageURL, options: .atomic)

            let credentials = CredentialProvider()
            let control = FakeControlPlane(routeBinding: Self.routeA)
            let coordinator = JazzArchiveUploadCoordinator(
                queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
                credentials: credentials,
                controlPlane: control,
                objectTransport: FakeTransport())
            let conflicted = try await coordinator.run(
                archiveId: value.archiveId)

            XCTAssertEqual(conflicted.state, .conflict, "\(stage)")
            XCTAssertEqual(
                conflicted.issue?.code,
                "ARCHIVE_LOCAL_INTEGRITY_CONFLICT",
                "\(stage)")
            let credentialCount = await credentials.count()
            XCTAssertEqual(credentialCount, 0, "\(stage)")
            let counts = await control.counts()
            XCTAssertEqual(counts.0 + counts.1 + counts.2, 0, "\(stage)")
        }
    }

    func testEveryInFlightStageRejectsMissingPackageBeforeCredentialOrNetwork()
        async throws
    {
        for stage in [
            JazzArchiveUploadState.finalizing,
            .verifying,
            .processing,
        ] {
            let value = fixture()
            defer {
                try? FileManager.default.removeItem(
                    at: value.archiveRoot.deletingLastPathComponent())
            }
            try await makeCommitted(value)
            try await review(value, decision: .confirm)
            _ = try await enqueueConfirmed(value)
            let packageURL = try forcePersistedDeliveryStage(
                stage,
                fixture: value)
            try FileManager.default.removeItem(at: packageURL)

            let credentials = CredentialProvider()
            let control = FakeControlPlane(routeBinding: Self.routeA)
            let coordinator = JazzArchiveUploadCoordinator(
                queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
                credentials: credentials,
                controlPlane: control,
                objectTransport: FakeTransport())
            do {
                _ = try await coordinator.run(archiveId: value.archiveId)
                XCTFail("missing \(stage) package must fail closed")
            } catch {
                XCTAssertEqual(
                    error as? JazzArchiveUploadError,
                    .packageMissing(value.archiveId),
                    "\(stage)")
            }
            let credentialCount = await credentials.count()
            XCTAssertEqual(credentialCount, 0, "\(stage)")
            let counts = await control.counts()
            XCTAssertEqual(counts.0 + counts.1 + counts.2, 0, "\(stage)")
        }
    }

    func testMissingFirstPackageDoesNotBlockLaterValidArchiveInSamePass() async throws {
        let missing = fixture()
        let valid = fixture(deliveryRoot: missing.deliveryRoot)
        defer {
            try? FileManager.default.removeItem(
                at: missing.archiveRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(
                at: valid.archiveRoot.deletingLastPathComponent())
        }
        for value in [missing, valid] {
            try await makeCommitted(value)
            try await review(value, decision: .confirm)
        }
        _ = try await enqueueConfirmed(
            missing,
            snapshotAt: "2026-07-23T10:03:00.000Z")
        _ = try await enqueueConfirmed(
            valid,
            snapshotAt: "2026-07-23T10:03:01.000Z")

        let missingPackage = missing.deliveryRoot
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent("\(missing.archiveId).jazz-archive")
        try FileManager.default.removeItem(at: missingPackage)

        let queue = JazzArchiveUploadQueue(root: missing.deliveryRoot)
        let control = FakeControlPlane(routeBinding: Self.routeA)
        let transport = FakeTransport()
        let snapshot = try await queue.all()
        XCTAssertEqual(snapshot.map(\.archiveId), [missing.archiveId, valid.archiveId])

        let failures = try await JazzArchiveUploadPassRunner.drain(snapshot) { item in
            let coordinator = JazzArchiveUploadCoordinator(
                queue: queue,
                credentials: CredentialProvider(),
                controlPlane: control,
                objectTransport: transport,
                now: { "2026-07-23T10:04:00.000Z" })
            _ = try await coordinator.run(archiveId: item.archiveId)
        }

        XCTAssertEqual(failures, [
            JazzArchiveUploadPassFailure(
                archiveId: missing.archiveId,
                message: JazzArchiveUploadError.packageMissing(missing.archiveId).description)
        ])
        let retainedMissing = try await queue.item(archiveId: missing.archiveId)
        let deliveredValid = try await queue.item(archiveId: valid.archiveId)
        XCTAssertEqual(retainedMissing?.state, .queued)
        XCTAssertEqual(deliveredValid?.state, .ready)
        let counts = await control.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 0)
        let uploads = await transport.values()
        XCTAssertEqual(uploads.count, 1)
    }

    func testRelaunchReplaysPersistedCreatingIntentWithSameOperationId() async throws {
        let value = fixture()
        defer {
            try? FileManager.default.removeItem(
                at: value.archiveRoot.deletingLastPathComponent())
        }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let queued = try await enqueueConfirmed(value)
        let operationId = try XCTUnwrap(queued.uploadOperationId)
        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        json["state"] = JazzArchiveUploadState.creatingIntent.rawValue
        json["attempt"] = 1
        json["routeBinding"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Self.routeA))
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: recordURL, options: .atomic)

        // This is the exact durable crash window after beginIntent and before the response is
        // handled. A fresh process must replay the same uop instead of rejecting the self-transition.
        let control = FakeControlPlane(routeBinding: Self.routeA)
        let coordinator = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: CredentialProvider(),
            controlPlane: control,
            objectTransport: FakeTransport())
        let ready = try await coordinator.run(archiveId: value.archiveId)

        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.uploadOperationId, operationId)
        XCTAssertEqual(ready.attempt, 2)
        let operations = await control.operationIds()
        XCTAssertEqual(operations.0, [operationId])
        XCTAssertEqual(operations.1, [operationId])
    }

    func testRouteBindingDirectorySyncFailureBlocksCredentialAndNetworkUntilRetry()
        async throws
    {
        let value = fixture()
        defer {
            try? FileManager.default.removeItem(
                at: value.archiveRoot.deletingLastPathComponent())
        }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let controlledDurability = ControllableFilesystemDurability()
        let queue = JazzArchiveUploadQueue(
            root: value.deliveryRoot,
            durability: controlledDurability.value(),
            leaseProvider: TestArchiveFilesystemLeaseProvider.shared)
        let queued = try await JazzArchiveConfirmedDelivery(
            archiveRoot: value.archiveRoot,
            queue: queue
        ).enqueueConfirmed(
            archiveId: value.archiveId,
            scope: try scope(),
            snapshotAt: "2026-07-23T10:03:00.000Z")
        controlledDurability.armDirectory(
            value.deliveryRoot.appendingPathComponent(
                "records",
                isDirectory: true))
        let credentials = CredentialProvider()
        let control = FakeControlPlane(routeBinding: Self.routeA)
        let worker = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: credentials,
            controlPlane: control,
            objectTransport: FakeTransport())

        do {
            _ = try await worker.run(archiveId: value.archiveId)
            XCTFail("network started before the route-binding directory was durable")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveUploadError,
                .persistenceFailed(value.archiveId))
        }
        let blockedCredentialCount = await credentials.count()
        XCTAssertEqual(blockedCredentialCount, 0)
        let blockedCounts = await control.counts()
        XCTAssertEqual(blockedCounts.0 + blockedCounts.1 + blockedCounts.2, 0)
        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        let interrupted = try JSONDecoder().decode(
            JazzArchiveUploadItem.self,
            from: Data(contentsOf: recordURL))
        XCTAssertEqual(interrupted.routeBinding, Self.routeA)
        XCTAssertEqual(interrupted.uploadOperationId, queued.uploadOperationId)

        let ready = try await worker.run(archiveId: value.archiveId)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.uploadOperationId, queued.uploadOperationId)
        let resumedCredentialCount = await credentials.count()
        XCTAssertGreaterThan(resumedCredentialCount, 0)
        let resumedCounts = await control.counts()
        XCTAssertGreaterThan(resumedCounts.0, 0)
    }

    func testUploadQueueLeaseBlocksIndependentWriterBeforeMutation() async throws {
        let value = fixture()
        defer {
            try? FileManager.default.removeItem(
                at: value.archiveRoot.deletingLastPathComponent())
        }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let provider = TestArchiveFilesystemLeaseProvider.shared
        let queue = JazzArchiveUploadQueue(
            root: value.deliveryRoot,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: provider)
        let lease = try provider.acquire(
            root: value.deliveryRoot,
            fileManager: .default)
        do {
            _ = try await JazzArchiveConfirmedDelivery(
                archiveRoot: value.archiveRoot,
                queue: queue
            ).enqueueConfirmed(
                archiveId: value.archiveId,
                scope: try scope())
            XCTFail("a second process mutated the queue while its root lease was held")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveUploadError,
                .operationInProgress)
        }
        lease.release()
        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))

        let first = try await JazzArchiveConfirmedDelivery(
            archiveRoot: value.archiveRoot,
            queue: queue
        ).enqueueConfirmed(
            archiveId: value.archiveId,
            scope: try scope())
        let relaunchedQueue = JazzArchiveUploadQueue(
            root: value.deliveryRoot,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: provider)
        let second = try await JazzArchiveConfirmedDelivery(
            archiveRoot: value.archiveRoot,
            queue: relaunchedQueue
        ).enqueueConfirmed(
            archiveId: value.archiveId,
            scope: try scope())

        XCTAssertEqual(second.uploadOperationId, first.uploadOperationId)
        XCTAssertEqual(second.rawSHA256, first.rawSHA256)
        let records = try FileManager.default.contentsOfDirectory(
            at: recordURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(records.count, 1)
    }

    func testMixedServerRolloutRetriesSameDurableOperationIdWithoutLegacyFallback()
        async throws
    {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let queued = try await enqueueConfirmed(value)
        let operationId = try XCTUnwrap(queued.uploadOperationId)
        let transport = FakeTransport()
        let legacyReplica = FakeControlPlane(rejectFirstOperationIdAsExtra: true)
        let first = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: CredentialProvider(),
            controlPlane: legacyReplica,
            objectTransport: transport,
            now: { "2026-07-23T10:04:00.000Z" })

        let waiting = try await first.run(archiveId: value.archiveId)
        XCTAssertEqual(waiting.state, .retryable)
        XCTAssertEqual(
            waiting.issue?.code,
            JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode)
        XCTAssertEqual(waiting.uploadOperationId, operationId)
        XCTAssertEqual(waiting.schemaVersion, 2)
        let legacyOperations = await legacyReplica.operationIds()
        XCTAssertEqual(legacyOperations.0, [operationId])
        XCTAssertTrue(legacyOperations.1.isEmpty)
        let firstUploads = await transport.values()
        XCTAssertTrue(firstUploads.isEmpty)

        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        let persisted = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        XCTAssertEqual(persisted["uploadOperationId"] as? String, operationId)
        XCTAssertEqual(persisted["schemaVersion"] as? Int, 2)

        // A fresh coordinator after the server rollout retries the same request identity. There is
        // deliberately no compatibility path that drops uploadOperationId.
        let rolledOutReplica = FakeControlPlane()
        let relaunched = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: CredentialProvider(),
            controlPlane: rolledOutReplica,
            objectTransport: transport,
            now: { "2026-07-23T10:05:00.000Z" })
        let ready = try await relaunched.run(archiveId: value.archiveId)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.uploadOperationId, operationId)
        let rolledOutOperations = await rolledOutReplica.operationIds()
        XCTAssertEqual(rolledOutOperations.0, [operationId])
        XCTAssertEqual(rolledOutOperations.1, [operationId])
        let finalUploads = await transport.values()
        XCTAssertEqual(finalUploads.count, 1)
    }

    func testMissingIntentOrFinalizeEchoRetriesWithoutDroppingDurableOperationId()
        async throws
    {
        for stage in [ControlResponseStage.intent, .finalize] {
            let value = fixture()
            defer { try? FileManager.default.removeItem(
                at: value.archiveRoot.deletingLastPathComponent()) }
            try await makeCommitted(value)
            try await review(value, decision: .confirm)
            let queued = try await enqueueConfirmed(value)
            let operationId = try XCTUnwrap(queued.uploadOperationId)
            let transport = FakeTransport()
            let mixedPool = FakeControlPlane(omitOperationEchoOnceAt: stage)
            let first = JazzArchiveUploadCoordinator(
                queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
                credentials: CredentialProvider(),
                controlPlane: mixedPool,
                objectTransport: transport,
                now: { "2026-07-23T10:04:00.000Z" })

            let waiting = try await first.run(archiveId: value.archiveId)
            XCTAssertEqual(waiting.state, .retryable, "\(stage)")
            XCTAssertEqual(
                waiting.issue?.code,
                JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode)
            XCTAssertEqual(waiting.uploadOperationId, operationId)
            let firstOperations = await mixedPool.operationIds()
            XCTAssertEqual(firstOperations.0, [operationId])
            XCTAssertEqual(
                firstOperations.1,
                stage == .finalize ? [operationId] : [])
            let firstUploads = await transport.values()
            XCTAssertEqual(firstUploads.count, stage == .finalize ? 1 : 0)

            let relaunched = JazzArchiveUploadCoordinator(
                queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
                credentials: CredentialProvider(),
                controlPlane: mixedPool,
                objectTransport: transport,
                now: { "2026-07-23T10:05:00.000Z" })
            let ready = try await relaunched.run(archiveId: value.archiveId)
            XCTAssertEqual(ready.state, .ready)
            XCTAssertEqual(ready.uploadOperationId, operationId)
            let finalOperations = await mixedPool.operationIds()
            XCTAssertEqual(
                finalOperations.0,
                stage == .intent ? [operationId, operationId] : [operationId])
            XCTAssertEqual(
                finalOperations.1,
                stage == .finalize ? [operationId, operationId] : [operationId])
        }
    }

    func testStatusPollWithoutEchoRetriesAcrossRelaunchAndNeverRemintsOperationId()
        async throws
    {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let queued = try await enqueueConfirmed(value)
        let operationId = try XCTUnwrap(queued.uploadOperationId)
        let transport = FakeTransport()
        let mixedPool = FakeControlPlane(
            finalizeState: .validating,
            omitOperationEchoOnceAt: .status)

        let initial = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: CredentialProvider(),
            controlPlane: mixedPool,
            objectTransport: transport,
            now: { "2026-07-23T10:04:00.000Z" })
        let processing = try await initial.run(archiveId: value.archiveId)
        XCTAssertEqual(processing.state, .processing)
        XCTAssertEqual(processing.uploadOperationId, operationId)

        let oldStatusReplica = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: CredentialProvider(),
            controlPlane: mixedPool,
            objectTransport: transport,
            now: { "2026-07-23T10:05:00.000Z" })
        let waiting = try await oldStatusReplica.run(archiveId: value.archiveId)
        XCTAssertEqual(waiting.state, .retryable)
        XCTAssertEqual(waiting.resumeState, .processing)
        XCTAssertEqual(
            waiting.issue?.code,
            JazzArchiveUploadServerCompatibility.operationIdContractNotReadyCode)
        XCTAssertEqual(waiting.uploadOperationId, operationId)

        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        let persisted = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        XCTAssertEqual(persisted["uploadOperationId"] as? String, operationId)

        let newStatusReplica = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: CredentialProvider(),
            controlPlane: mixedPool,
            objectTransport: transport,
            now: { "2026-07-23T10:06:00.000Z" })
        let ready = try await newStatusReplica.run(archiveId: value.archiveId)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.uploadOperationId, operationId)
        let operations = await mixedPool.operationIds()
        XCTAssertEqual(operations.0, [operationId])
        XCTAssertEqual(operations.1, [operationId])
        let uploads = await transport.values()
        XCTAssertEqual(uploads.count, 1)
    }

    func testPinnedRouteSurvivesRelaunchAndSameAuthorityTokenRotationCanResume() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        _ = try await enqueueConfirmed(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)

        let firstControl = FakeControlPlane(routeBinding: Self.routeA)
        let first = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: firstControl,
            objectTransport: FakeTransport(failFirst: true),
            now: { "2026-07-23T10:04:00.000Z" })
        let waiting = try await first.run(archiveId: value.archiveId)
        XCTAssertEqual(waiting.state, .retryable)
        XCTAssertEqual(waiting.routeBinding, Self.routeA)

        let relaunchedQueue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let persistedValue = try await relaunchedQueue.item(archiveId: value.archiveId)
        let persisted = try XCTUnwrap(persistedValue)
        XCTAssertEqual(persisted.routeBinding, Self.routeA)
        XCTAssertEqual(
            persisted.effectiveRouteBinding(currentEnrollment: Self.rotatedTokenRoute),
            Self.routeA)

        // The exact original endpoint remains pinned, while a fresh token from a newer signed
        // bundle under the same authority is allowed to finish the durable intent.
        let rotatedCredential = CredentialProvider()
        let pinnedControl = FakeControlPlane(routeBinding: Self.routeA)
        let afterRotation = JazzArchiveUploadCoordinator(
            queue: relaunchedQueue,
            credentials: rotatedCredential,
            controlPlane: pinnedControl,
            objectTransport: FakeTransport(),
            now: { "2026-07-23T10:05:00.000Z" })
        let ready = try await afterRotation.run(archiveId: value.archiveId)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.routeBinding, Self.routeA)
        let rotatedCredentialCount = await rotatedCredential.count()
        XCTAssertGreaterThan(rotatedCredentialCount, 0)
        let pinnedCounts = await pinnedControl.counts()
        XCTAssertGreaterThan(pinnedCounts.0 + pinnedCounts.1 + pinnedCounts.2, 0)
    }

    func testDifferentRouteCannotReplacePinnedRouteOrReadCredential() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        _ = try await enqueueConfirmed(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        _ = try await queue.bindRoute(
            archiveId: value.archiveId,
            routeBinding: Self.routeA,
            at: "2026-07-23T10:03:30.000Z")

        let credentials = CredentialProvider()
        let otherControl = FakeControlPlane(routeBinding: Self.routeB)
        let worker = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: credentials,
            controlPlane: otherControl,
            objectTransport: FakeTransport(),
            now: { "2026-07-23T10:04:00.000Z" })
        let conflicted = try await worker.run(archiveId: value.archiveId)

        XCTAssertEqual(conflicted.state, .conflict)
        XCTAssertEqual(conflicted.issue?.code, "ARCHIVE_ROUTE_BINDING_CONFLICT")
        XCTAssertEqual(conflicted.routeBinding, Self.routeA)
        let credentialCount = await credentials.count()
        XCTAssertEqual(credentialCount, 0)
        let counts = await otherControl.counts()
        XCTAssertEqual(counts.0 + counts.1 + counts.2, 0)
    }

    func testUnattemptedV1QueueRecordMintsAndPersistsOperationIdBeforeNetwork()
        async throws
    {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        _ = try await enqueueConfirmed(value)

        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        json["schemaVersion"] = 1
        json.removeValue(forKey: "uploadOperationId")
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: recordURL, options: .atomic)

        let migratedValue = try await JazzArchiveUploadQueue(root: value.deliveryRoot)
            .item(archiveId: value.archiveId)
        let migrated = try XCTUnwrap(migratedValue)
        XCTAssertEqual(migrated.schemaVersion, 2)
        let operationId = try XCTUnwrap(migrated.uploadOperationId)
        XCTAssertTrue(operationId.hasPrefix("uop-"))

        let relaunchedValue = try await JazzArchiveUploadQueue(root: value.deliveryRoot)
            .item(archiveId: value.archiveId)
        XCTAssertEqual(relaunchedValue?.uploadOperationId, operationId)
        let persisted = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        XCTAssertEqual(persisted["schemaVersion"] as? Int, 2)
        XCTAssertEqual(persisted["uploadOperationId"] as? String, operationId)
    }

    func testDuplicateDurableOperationIdFailsClosedBeforeDelivery() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        let source = value.archiveRoot.deletingLastPathComponent()
            .appendingPathComponent("duplicate-operation-source.jazz-archive")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("immutable operation collision bytes".utf8).write(to: source)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let first = try await queue.enqueue(
            file: source,
            archiveId: value.archiveId,
            originId: value.originId,
            captureIds: [value.captureId],
            revision: 1,
            contentDigest: String(repeating: "a", count: 64),
            scope: try scope())
        let secondArchiveId = Identifiers.newArchiveId()
        _ = try await queue.enqueue(
            file: source,
            archiveId: secondArchiveId,
            originId: Identifiers.newOriginId(),
            captureIds: [Identifiers.newCaptureId()],
            revision: 1,
            contentDigest: String(repeating: "b", count: 64),
            scope: try scope())

        let secondRecord = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(secondArchiveId).json")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: secondRecord))
                as? [String: Any])
        json["uploadOperationId"] = try XCTUnwrap(first.uploadOperationId)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: secondRecord, options: .atomic)

        do {
            _ = try await JazzArchiveUploadQueue(root: value.deliveryRoot)
                .item(archiveId: secondArchiveId)
            XCTFail("duplicate operation identity must fail closed")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveUploadError,
                .invalidItem(secondArchiveId))
        }
    }

    func testLegacyActiveItemWithoutRouteFailsClosedBeforeCredentialOrNetwork() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        let source = value.archiveRoot.deletingLastPathComponent()
            .appendingPathComponent("legacy-active.jazz-archive")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("legacy immutable bytes".utf8).write(to: source)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        _ = try await queue.enqueue(
            file: source,
            archiveId: value.archiveId,
            originId: value.originId,
            captureIds: [value.captureId],
            revision: 1,
            contentDigest: String(repeating: "a", count: 64),
            scope: try scope())

        // Model a v1 queue record written after beginIntent but before endpoint pinning existed.
        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        json["schemaVersion"] = 1
        json.removeValue(forKey: "uploadOperationId")
        json["state"] = JazzArchiveUploadState.creatingIntent.rawValue
        json["attempt"] = 1
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: recordURL, options: .atomic)

        let credentials = CredentialProvider()
        let control = FakeControlPlane(routeBinding: Self.routeA)
        let worker = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: credentials,
            controlPlane: control,
            objectTransport: FakeTransport())
        let conflicted = try await worker.run(archiveId: value.archiveId)

        XCTAssertEqual(conflicted.state, .conflict)
        XCTAssertEqual(
            conflicted.issue?.code,
            "ARCHIVE_UPLOAD_OPERATION_RECONCILIATION_REQUIRED")
        XCTAssertEqual(conflicted.schemaVersion, 1)
        XCTAssertNil(conflicted.uploadOperationId)
        XCTAssertNil(conflicted.routeBinding)
        let credentialCount = await credentials.count()
        XCTAssertEqual(credentialCount, 0)
        let counts = await control.counts()
        XCTAssertEqual(counts.0 + counts.1 + counts.2, 0)

        do {
            _ = try await worker.reconcileLegacy(archiveId: value.archiveId)
            XCTFail("unknown legacy authority must not be inferred from current settings")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveUploadError,
                .routeBindingMissing(value.archiveId))
        }
        let reconciliationCredentialCount = await credentials.count()
        let legacyReconciliationCount = await control.legacyCount()
        XCTAssertEqual(reconciliationCredentialCount, 0)
        XCTAssertEqual(legacyReconciliationCount, 0)
    }

    func testExplicitLegacyReconciliationAdoptsOnlyServerOperationAcrossLostStages()
        async throws
    {
        let stages: [(JazzArchiveUploadState, Bool, Bool, Int)] = [
            (.creatingIntent, false, false, 1),
            (.uploading, true, false, 1),
            (.finalizing, true, true, 0),
            (.processing, true, false, 0),
        ]
        for (stage, hasIngest, hasReceipt, expectedUploads) in stages {
            let value = fixture()
            defer {
                try? FileManager.default.removeItem(
                    at: value.archiveRoot.deletingLastPathComponent())
            }
            try await makeCommitted(value)
            try await review(value, decision: .confirm)
            _ = try await enqueueConfirmed(value)
            let recordURL = value.deliveryRoot
                .appendingPathComponent("records", isDirectory: true)
                .appendingPathComponent("\(value.archiveId).json")
            var json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                    as? [String: Any])
            json["schemaVersion"] = 1
            json.removeValue(forKey: "uploadOperationId")
            json["state"] = stage.rawValue
            json["attempt"] = 1
            json["routeBinding"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(Self.routeA))
            if hasIngest {
                json["ingestId"] = "ingest-1"
            } else {
                json.removeValue(forKey: "ingestId")
            }
            if hasReceipt {
                json["uploadReceipt"] = "opaque-receipt"
            } else {
                json.removeValue(forKey: "uploadReceipt")
            }
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                .write(to: recordURL, options: .atomic)

            let stableOperationId =
                "uop-018bcfe5-6800-7fff-bfff-ffffffffffff"
            let control = FakeControlPlane(
                legacyReconciliationOperationId: stableOperationId)
            let transport = FakeTransport()
            let coordinator = JazzArchiveUploadCoordinator(
                queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
                credentials: CredentialProvider(),
                controlPlane: control,
                objectTransport: transport)
            let ready = try await coordinator.reconcileLegacy(
                archiveId: value.archiveId)

            XCTAssertEqual(ready.state, .ready, "\(stage)")
            XCTAssertEqual(ready.schemaVersion, 2, "\(stage)")
            XCTAssertEqual(ready.uploadOperationId, stableOperationId, "\(stage)")
            let legacyCount = await control.legacyCount()
            let uploadedValues = await transport.values()
            XCTAssertEqual(legacyCount, 1, "\(stage)")
            XCTAssertEqual(uploadedValues.count, expectedUploads, "\(stage)")
            let persisted = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                    as? [String: Any])
            XCTAssertEqual(
                persisted["uploadOperationId"] as? String,
                stableOperationId,
                "\(stage)")
        }
    }

    func testLegacyActiveRouteWithoutSignedAuthorityFailsClosedBeforeCredentialOrNetwork()
        async throws
    {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        _ = try await enqueueConfirmed(value)

        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        var legacyRoute = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.routeA))
                as? [String: Any])
        legacyRoute["schemaVersion"] = 1
        legacyRoute.removeValue(forKey: "signedAuthority")
        legacyRoute.removeValue(forKey: "authorizationProfile")
        json["routeBinding"] = legacyRoute
        json["state"] = JazzArchiveUploadState.creatingIntent.rawValue
        json["attempt"] = 1
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: recordURL, options: .atomic)

        let credentials = CredentialProvider()
        let control = FakeControlPlane(routeBinding: Self.routeA)
        let worker = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: credentials,
            controlPlane: control,
            objectTransport: FakeTransport())
        let conflicted = try await worker.run(archiveId: value.archiveId)

        XCTAssertEqual(conflicted.state, .conflict)
        XCTAssertEqual(conflicted.issue?.code, "ARCHIVE_ROUTE_BINDING_CONFLICT")
        XCTAssertEqual(conflicted.routeBinding?.schemaVersion, 1)
        XCTAssertFalse(conflicted.routeBinding?.hasSignedAuthority ?? true)
        let credentialCount = await credentials.count()
        XCTAssertEqual(credentialCount, 0)
        let counts = await control.counts()
        XCTAssertEqual(counts.0 + counts.1 + counts.2, 0)
    }

    func testLegacyUnattemptedRouteCanUpgradeToSignedAuthorityBeforeCredentialRead()
        async throws
    {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        _ = try await enqueueConfirmed(value)

        let recordURL = value.deliveryRoot
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(value.archiveId).json")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
        var legacyRoute = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.routeA))
                as? [String: Any])
        legacyRoute["schemaVersion"] = 1
        legacyRoute.removeValue(forKey: "signedAuthority")
        legacyRoute.removeValue(forKey: "authorizationProfile")
        json["routeBinding"] = legacyRoute
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: recordURL, options: .atomic)

        let credentials = CredentialProvider()
        let control = FakeControlPlane(routeBinding: Self.routeA)
        let worker = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: credentials,
            controlPlane: control,
            objectTransport: FakeTransport())
        let ready = try await worker.run(archiveId: value.archiveId)

        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.routeBinding, Self.routeA)
        XCTAssertTrue(ready.routeBinding?.hasSignedAuthority ?? false)
        let credentialCount = await credentials.count()
        XCTAssertGreaterThan(credentialCount, 0)
        let counts = await control.counts()
        XCTAssertGreaterThan(counts.0 + counts.1 + counts.2, 0)
    }

    func testServerRetryWatermarkSurvivesRelaunchAndPreventsEarlyRequests() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        _ = try await enqueueConfirmed(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let retryAt = "2026-07-23T10:10:00.000Z"
        let control = FakeControlPlane(
            finalizeState: .failedRetryable,
            nextAttemptAt: retryAt)
        let first = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: control,
            objectTransport: FakeTransport(),
            now: { "2026-07-23T10:04:00.000Z" })
        let waiting = try await first.run(archiveId: value.archiveId)
        XCTAssertEqual(waiting.state, .retryable)
        XCTAssertEqual(waiting.nextAttemptAt, retryAt)
        XCTAssertFalse(waiting.canRunAutomatically(
            at: try XCTUnwrap(Timestamps.parse("2026-07-23T10:09:59.000Z"))))

        let beforeCounts = await control.counts()
        let stillWaiting = try await first.run(archiveId: value.archiveId)
        XCTAssertEqual(stillWaiting.state, .retryable)
        let afterEarlyCounts = await control.counts()
        XCTAssertEqual(afterEarlyCounts.0, beforeCounts.0)
        XCTAssertEqual(afterEarlyCounts.1, beforeCounts.1)
        XCTAssertEqual(afterEarlyCounts.2, beforeCounts.2)
        let manualEarly = try await queue.retry(
            archiveId: value.archiveId,
            at: "2026-07-23T10:09:59.000Z")
        XCTAssertEqual(manualEarly.state, .retryable)
        XCTAssertEqual(manualEarly.nextAttemptAt, retryAt)

        let afterWatermark = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: control,
            objectTransport: FakeTransport(),
            now: { "2026-07-23T10:10:01.000Z" })
        let ready = try await afterWatermark.run(archiveId: value.archiveId)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertNil(ready.nextAttemptAt)
        let finalCounts = await control.counts()
        XCTAssertEqual(finalCounts.2, beforeCounts.2 + 1)
    }

    func testMismatchedServerOperationEchoConflictsBeforeObjectUpload() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(
            at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let queued = try await enqueueConfirmed(value)
        let transport = FakeTransport()
        let worker = JazzArchiveUploadCoordinator(
            queue: JazzArchiveUploadQueue(root: value.deliveryRoot),
            credentials: CredentialProvider(),
            controlPlane: FakeControlPlane(
                echoedOperationId: Identifiers.newUploadOperationId()),
            objectTransport: transport)

        let conflicted = try await worker.run(archiveId: value.archiveId)
        XCTAssertEqual(conflicted.state, .conflict)
        XCTAssertEqual(
            conflicted.issue?.code,
            "ARCHIVE_RESPONSE_IDENTITY_MISMATCH")
        XCTAssertEqual(conflicted.uploadOperationId, queued.uploadOperationId)
        let uploads = await transport.values()
        XCTAssertTrue(uploads.isEmpty)
    }

    func testTerminalServerFailureIsNotExposedAsRetryable() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        _ = try await enqueueConfirmed(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let worker = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: FakeControlPlane(finalizeState: .failedTerminal),
            objectTransport: FakeTransport(),
            now: { "2026-07-23T10:04:00.000Z" })
        let failed = try await worker.run(archiveId: value.archiveId)
        XCTAssertEqual(failed.state, .failedTerminal)
        XCTAssertTrue(failed.state.isTerminal)
        XCTAssertFalse(failed.canRunAutomatically())
        XCTAssertEqual(failed.issue?.code, "ARCHIVE_IMPORT_FAILED")
        do {
            _ = try await queue.retry(archiveId: value.archiveId)
            XCTFail("terminal server failure must not become a client retry")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveUploadError,
                .invalidTransition(from: .failedTerminal, to: .queued))
        }
    }

    func testExplicitRetryRepairsOnlyPreIntentProducerRevisionConflict() async throws {
        let value = fixture()
        defer {
            try? FileManager.default.removeItem(
                at: value.archiveRoot.deletingLastPathComponent())
        }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let queued = try await enqueueConfirmed(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let worker = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: FakeControlPlane(
                intentError: .conflict("ORIGIN_REVISION_COLLISION")),
            objectTransport: FakeTransport())

        let conflict = try await worker.run(archiveId: value.archiveId)
        XCTAssertEqual(conflict.state, .conflict)
        XCTAssertEqual(conflict.issue?.code, "ORIGIN_REVISION_COLLISION")
        XCTAssertNil(conflict.ingestId)
        XCTAssertNil(conflict.uploadReceipt)

        let retried = try await queue.retry(archiveId: value.archiveId)
        XCTAssertEqual(retried.state, .queued)
        XCTAssertNil(retried.issue)
        XCTAssertEqual(retried.uploadOperationId, queued.uploadOperationId)
        XCTAssertEqual(retried.rawSHA256, queued.rawSHA256)
        XCTAssertEqual(retried.byteLength, queued.byteLength)
    }

    func testSameArchiveIDDifferentBytesIsQuarantinedAsConflict() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let firstURL = value.archiveRoot.deletingLastPathComponent().appendingPathComponent("one.zip")
        let secondURL = value.archiveRoot.deletingLastPathComponent().appendingPathComponent("two.zip")
        try FileManager.default.createDirectory(
            at: value.archiveRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first immutable bytes".utf8).write(to: firstURL)
        try Data("different immutable bytes".utf8).write(to: secondURL)
        let digest = String(repeating: "a", count: 64)
        let first = try await queue.enqueue(
            file: firstURL,
            archiveId: value.archiveId,
            originId: value.originId,
            captureIds: [value.captureId],
            revision: 1,
            contentDigest: digest,
            scope: try scope())
        do {
            _ = try await queue.enqueue(
                file: secondURL,
                archiveId: value.archiveId,
                originId: value.originId,
                captureIds: [value.captureId],
                revision: 1,
                contentDigest: digest,
                scope: try scope())
            XCTFail("expected collision")
        } catch {
            XCTAssertEqual(error as? JazzArchiveUploadError, .archiveCollision(value.archiveId))
        }
        let loadedConflict = try await queue.item(archiveId: value.archiveId)
        let conflict = try XCTUnwrap(loadedConflict)
        XCTAssertEqual(conflict.state, .conflict)
        XCTAssertEqual(conflict.issue?.code, "ARCHIVE_ID_COLLISION")
        let retainedURL = try await queue.packageURL(archiveId: value.archiveId)
        let retainedFingerprint = try JazzArchiveFileIO.fingerprint(retainedURL)
        XCTAssertEqual(retainedFingerprint.sha256, first.rawSHA256)
    }

    func testExpiredCredentialRetainsQueueAndResumesAfterRotation() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let queued = try await enqueueConfirmed(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let expiredControl = FakeControlPlane()
        let expired = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(error: .credentialExpired),
            controlPlane: expiredControl,
            objectTransport: FakeTransport())
        let waiting = try await expired.run(archiveId: value.archiveId)
        XCTAssertEqual(waiting.state, .reconnectRequired)
        XCTAssertEqual(waiting.issue?.code, "ARCHIVE_TOKEN_EXPIRED")
        XCTAssertEqual(waiting.rawSHA256, queued.rawSHA256)
        let expiredCounts = await expiredControl.counts()
        XCTAssertEqual(expiredCounts.0, 0)

        _ = try await queue.retry(archiveId: value.archiveId)
        let resumed = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: FakeControlPlane(),
            objectTransport: FakeTransport())
        let ready = try await resumed.run(archiveId: value.archiveId)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.rawSHA256, queued.rawSHA256)
    }

    func testCancelPreventsNetworkAndKeepsPackage() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        _ = try await enqueueConfirmed(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let cancelled = try await queue.cancel(archiveId: value.archiveId)
        XCTAssertEqual(cancelled.state, .cancelled)
        let control = FakeControlPlane()
        let worker = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: control,
            objectTransport: FakeTransport())
        let afterWorker = try await worker.run(archiveId: value.archiveId)
        XCTAssertEqual(afterWorker.state, .cancelled)
        let counts = await control.counts()
        XCTAssertEqual(counts.0, 0)
        let retainedURL = try await queue.packageURL(archiveId: value.archiveId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
    }

    func testStateMachineRejectsInvalidTransition() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        let source = value.archiveRoot.deletingLastPathComponent().appendingPathComponent("archive.zip")
        try FileManager.default.createDirectory(
            at: value.archiveRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("archive bytes".utf8).write(to: source)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        _ = try await queue.enqueue(
            file: source,
            archiveId: value.archiveId,
            originId: value.originId,
            captureIds: [value.captureId],
            revision: 1,
            contentDigest: String(repeating: "a", count: 64),
            scope: try scope())
        do {
            _ = try await queue.transition(archiveId: value.archiveId, to: .ready)
            XCTFail("queued -> ready must fail")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveUploadError,
                .invalidTransition(from: .queued, to: .ready))
        }
    }

    func testCorrectionAfterFinalizationForksImmutableRevisionBeforeReconfirmation() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let original = try await enqueueConfirmed(value)

        let newArchiveId = Identifiers.newArchiveId()
        let assertionId = Identifiers.newAssertionId()
        let forker = JazzArchiveRevisionForker(root: value.archiveRoot)
        let fork = try await forker.forkCorrection(
            sourceArchiveId: value.archiveId,
            correction: "Use the approved tax code before posting.",
            authoredAt: "2026-07-23T10:04:00.000Z",
            newArchiveId: newArchiveId,
            assertionId: assertionId)
        XCTAssertEqual(fork.archiveId, newArchiveId)
        XCTAssertEqual(fork.revision, 2)
        XCTAssertEqual(fork.supersedesArchiveId, value.archiveId)

        let drafts = JazzArchiveDraftStore(root: value.archiveRoot)
        let revisedManifest = try await drafts.manifest(archiveId: newArchiveId)
        XCTAssertEqual(revisedManifest.revision, 2)
        XCTAssertEqual(revisedManifest.supersedesArchiveId, value.archiveId)
        XCTAssertEqual(revisedManifest.state, .live)
        let revisedSession = try await drafts.session(
            archiveId: newArchiveId, captureId: value.captureId)
        XCTAssertEqual(revisedSession.archiveId, newArchiveId)
        let revisedCommit = try await drafts.captureCommit(
            archiveId: newArchiveId, captureId: value.captureId)
        let oldCommit = try await drafts.captureCommit(
            archiveId: value.archiveId, captureId: value.captureId)
        XCTAssertEqual(revisedCommit.revision, 2)
        XCTAssertEqual(revisedCommit.supersedesCommitId, oldCommit.commitId)
        XCTAssertEqual(revisedCommit.supersedesArchiveId, value.archiveId)
        XCTAssertEqual(revisedCommit.orderedObservationDigest, oldCommit.orderedObservationDigest)
        XCTAssertEqual(revisedCommit.artifactSetDigest, oldCommit.artifactSetDigest)

        let reviews = JazzArchiveReviewStore(root: value.archiveRoot)
        let correctionValue = try await reviews.latestArchiveAssertion(
            archiveId: newArchiveId)
        let correction = try XCTUnwrap(correctionValue)
        XCTAssertEqual(correction.assertionId, assertionId)
        XCTAssertEqual(correction.decision, .correct)

        // Correction alone is not delivery consent.
        let revisedQueue = JazzArchiveUploadQueue(
            root: value.deliveryRoot.appendingPathComponent("revision-2"))
        let revisedDelivery = JazzArchiveConfirmedDelivery(
            archiveRoot: value.archiveRoot, queue: revisedQueue)
        do {
            _ = try await revisedDelivery.enqueueConfirmed(
                archiveId: newArchiveId,
                scope: try self.scope(),
                snapshotAt: "2026-07-23T10:05:00.000Z")
            XCTFail("a corrected revision must be confirmed separately")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFinalizationError,
                .archiveNotConfirmed(newArchiveId))
        }

        _ = try await reviews.append(
            archiveId: newArchiveId,
            assertion: JazzArchiveAssertion(
                target: JazzArchiveAssertionTarget(kind: .archive, id: newArchiveId),
                decision: .confirm,
                authoredByActorId: value.actorId,
                authoredAt: "2026-07-23T10:06:00.000Z",
                baseRevision: 2,
                scope: .archive,
                supersedes: correction.assertionId,
                provenance: JazzArchiveProvenance(factClass: .declared, sources: [])))
        let revised = try await revisedDelivery.enqueueConfirmed(
            archiveId: newArchiveId,
            scope: try scope(),
            snapshotAt: "2026-07-23T10:07:00.000Z")
        XCTAssertEqual(revised.revision, 2)
        XCTAssertNotEqual(revised.archiveId, original.archiveId)
        XCTAssertNotEqual(revised.rawSHA256, original.rawSHA256)
    }

    func testCorrectionForkRetryAfterPublishedDirectoryBarrierReusesDurableIntent()
        async throws
    {
        let value = fixture()
        defer {
            try? FileManager.default.removeItem(
                at: value.archiveRoot.deletingLastPathComponent())
        }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)

        let correction = "Use the approved tax code before posting."
        let authoredAt = "2026-07-23T10:04:00.000Z"
        let newArchiveId = Identifiers.newArchiveId()
        let assertionId = Identifiers.newAssertionId()
        let destination = value.archiveRoot.appendingPathComponent(
            "\(newArchiveId).jazz-archive.draft", isDirectory: true)
        let recorder = CanonicalDurabilityRecorder()
        recorder.failOnce(on: .directory(
            CanonicalDurabilityRecorder.path(destination)))
        let failingForker = JazzArchiveRevisionForker(
            root: value.archiveRoot, durability: recorder.value())

        do {
            _ = try await failingForker.forkCorrection(
                sourceArchiveId: value.archiveId,
                correction: correction,
                authoredAt: authoredAt,
                newArchiveId: newArchiveId,
                assertionId: assertionId)
            XCTFail("fork must fail closed before the published draft is durable")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let retry = JazzArchiveRevisionForker(
            root: value.archiveRoot,
            durability: foundationTestFilesystemDurability())
        let recovered = try await retry.forkCorrection(
            sourceArchiveId: value.archiveId,
            correction: correction)
        XCTAssertEqual(recovered.archiveId, newArchiveId)
        let assertions = try await JazzArchiveReviewStore(
            root: value.archiveRoot
        ).assertions(archiveId: newArchiveId)
        XCTAssertEqual(assertions.map(\.assertionId), [assertionId])

        let repeated = try await JazzArchiveRevisionForker(
            root: value.archiveRoot
        ).forkCorrection(
            sourceArchiveId: value.archiveId,
            correction: correction)
        XCTAssertEqual(repeated, recovered)
        let recoveredDraftIds = await JazzArchiveDraftStore(
            root: value.archiveRoot
        ).draftArchiveIds().filter { $0 != value.archiveId }
        XCTAssertEqual(
            recoveredDraftIds,
            [newArchiveId])
        let intentDirectory = value.archiveRoot.appendingPathComponent(
            ".revision-fork-intents", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: intentDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }.count,
            1,
            "completed intent remains an immutable idempotency record")
    }

    func testCorrectionForkRetryAfterAssertionBarrierReusesExactRevisionAndAssertion()
        async throws
    {
        let value = fixture()
        defer {
            try? FileManager.default.removeItem(
                at: value.archiveRoot.deletingLastPathComponent())
        }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)

        let correction = "Explain the approval before posting."
        let authoredAt = "2026-07-23T10:04:00.000Z"
        let newArchiveId = Identifiers.newArchiveId()
        let assertionId = Identifiers.newAssertionId()
        let assertionURL = value.archiveRoot
            .appendingPathComponent(".review", isDirectory: true)
            .appendingPathComponent(newArchiveId, isDirectory: true)
            .appendingPathComponent("assertions", isDirectory: true)
            .appendingPathComponent("\(assertionId).json")
        let recorder = CanonicalDurabilityRecorder()
        recorder.failOnce(on: .file(
            CanonicalDurabilityRecorder.path(assertionURL)))
        let failingForker = JazzArchiveRevisionForker(
            root: value.archiveRoot, durability: recorder.value())

        do {
            _ = try await failingForker.forkCorrection(
                sourceArchiveId: value.archiveId,
                correction: correction,
                authoredAt: authoredAt,
                newArchiveId: newArchiveId,
                assertionId: assertionId)
            XCTFail("fork must fail closed before the correction is durable")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: assertionURL.path))

        let recovered = try await JazzArchiveRevisionForker(
            root: value.archiveRoot
        ).forkCorrection(
            sourceArchiveId: value.archiveId,
            correction: correction)
        XCTAssertEqual(recovered.archiveId, newArchiveId)
        XCTAssertEqual(recovered.revision, 2)
        let assertions = try await JazzArchiveReviewStore(
            root: value.archiveRoot
        ).assertions(archiveId: newArchiveId)
        XCTAssertEqual(assertions.count, 1)
        XCTAssertEqual(assertions.first?.assertionId, assertionId)
        let recoveredDraftIds = await JazzArchiveDraftStore(
            root: value.archiveRoot
        ).draftArchiveIds().filter { $0 != value.archiveId }
        XCTAssertEqual(
            recoveredDraftIds,
            [newArchiveId])
    }
}
