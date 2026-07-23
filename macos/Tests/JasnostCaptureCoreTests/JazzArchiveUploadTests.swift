import Foundation
import XCTest

@testable import JasnostCaptureCore

final class JazzArchiveUploadTests: XCTestCase {
    private let timestamp = "2026-07-23T10:00:00.000Z"

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

        init(error: JazzArchiveUploadError? = nil) { self.error = error }

        func credential() throws -> JazzArchiveScopedDeviceCredential {
            if let error { throw error }
            return try JazzArchiveScopedDeviceCredential(
                "8625-123456-scoped-device-token-value")
        }
    }

    private actor FakeControlPlane: JazzArchiveUploadControlPlane {
        private(set) var intentCount = 0
        private(set) var finalizeCount = 0
        private(set) var statusCount = 0
        var finalizeState: JazzArchiveRemoteState = .ready
        let nextAttemptAt: String?

        init(
            finalizeState: JazzArchiveRemoteState = .ready,
            nextAttemptAt: String? = nil
        ) {
            self.finalizeState = finalizeState
            self.nextAttemptAt = nextAttemptAt
        }

        func createIntent(
            _ request: JazzArchiveUploadIntentRequest,
            credential: JazzArchiveScopedDeviceCredential
        ) throws -> JazzArchiveUploadIntentResponse {
            XCTAssertEqual(credential.description, "<redacted scoped device credential>")
            intentCount += 1
            return JazzArchiveUploadIntentResponse(
                status: status(request, state: .created),
                upload: try JazzArchiveOpaqueUploadInstructions(
                    transport: "fake",
                    values: ["grant": .string("ephemeral-not-persisted")]))
        }

        func finalize(
            ingestId: String,
            scope: JazzArchiveUploadScope,
            uploadReceipt: String,
            credential: JazzArchiveScopedDeviceCredential
        ) throws -> JazzArchiveRemoteStatus {
            finalizeCount += 1
            guard let lastRequest else {
                throw JazzArchiveUploadError.invalidServerResponse("MISSING_INTENT")
            }
            XCTAssertEqual(ingestId, "ingest-1")
            XCTAssertEqual(uploadReceipt, "opaque-receipt")
            return status(lastRequest, state: finalizeState)
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
            return status(lastRequest, state: .ready)
        }

        private var lastRequest: JazzArchiveUploadIntentRequest?

        private func status(
            _ request: JazzArchiveUploadIntentRequest,
            state: JazzArchiveRemoteState
        ) -> JazzArchiveRemoteStatus {
            lastRequest = request
            return JazzArchiveRemoteStatus(
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

    private func fixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jazz-upload-tests-\(UUID().uuidString)")
        let archiveRoot = root.appendingPathComponent("archives", isDirectory: true)
        let deliveryRoot = root.appendingPathComponent("archive-upload", isDirectory: true)
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

    private func enqueueConfirmed(_ fixture: Fixture) async throws -> JazzArchiveUploadItem {
        let queue = JazzArchiveUploadQueue(root: fixture.deliveryRoot)
        return try await JazzArchiveConfirmedDelivery(
            archiveRoot: fixture.archiveRoot,
            queue: queue)
            .enqueueConfirmed(
                archiveId: fixture.archiveId,
                scope: try scope(),
                snapshotAt: "2026-07-23T10:03:00.000Z")
    }

    func testDefaultPolicyIsConfirmedArchiveAndLiveCompatibilityIsExplicit() {
        XCTAssertEqual(JazzCaptureDeliveryPolicy.confirmedArchive.rawValue, "confirmedArchive")
        XCTAssertFalse(JazzCaptureDeliveryPolicy.confirmedArchive.usesLiveCompatibilityProjection)
        XCTAssertTrue(JazzCaptureDeliveryPolicy.liveCompatibility.usesLiveCompatibilityProjection)
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

    func testRelaunchRetryUploadsTheExactSamePackageBytes() async throws {
        let value = fixture()
        defer { try? FileManager.default.removeItem(at: value.archiveRoot.deletingLastPathComponent()) }
        try await makeCommitted(value)
        try await review(value, decision: .confirm)
        let queued = try await enqueueConfirmed(value)
        let queue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let transport = FakeTransport(failFirst: true)
        let first = JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: CredentialProvider(),
            controlPlane: FakeControlPlane(),
            objectTransport: transport,
            now: { "2026-07-23T10:04:00.000Z" })
        let failed = try await first.run(archiveId: value.archiveId)
        XCTAssertEqual(failed.state, .retryable)

        // A fresh queue/coordinator instance models process relaunch. No finalizer or mutable draft
        // is consulted: the retry reads the queue-owned immutable ZIP.
        let relaunchedQueue = JazzArchiveUploadQueue(root: value.deliveryRoot)
        let relaunched = JazzArchiveUploadCoordinator(
            queue: relaunchedQueue,
            credentials: CredentialProvider(),
            controlPlane: FakeControlPlane(),
            objectTransport: transport,
            now: { "2026-07-23T10:05:00.000Z" })
        let ready = try await relaunched.run(archiveId: value.archiveId)
        XCTAssertEqual(ready.state, .ready)
        let sent = await transport.values()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1])
        XCTAssertEqual(sent[0].sha256, queued.rawSHA256)
        XCTAssertEqual(sent[0].byteLength, queued.byteLength)
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
}
