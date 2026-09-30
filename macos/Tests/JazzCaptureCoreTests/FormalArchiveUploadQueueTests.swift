import Foundation
import XCTest

@testable import JazzCaptureCore

/// Replays of the formal/archive-upload-queue TLA+ counterexamples against the real
/// `JazzArchiveUploadQueue` and `JazzArchiveUploadCoordinator`. Each test asserts the SAFE
/// behaviour; reproduced bugs are wrapped in `XCTExpectFailure`, so a fix turns the test red
/// until the wrapper is removed. All findings replayed here are fixed now, so every test is a
/// plain guard. See formal/archive-upload-queue/README.md.
///
/// The user's Cancel is injected at the exact `await` gap the model found:
/// - inside a fake control-plane / credential call (the coordinator is suspended on it), or
/// - inside the coordinator's `now()` clock, which is evaluated as the argument of the next
///   queue call, i.e. after the previous queue call returned and before the next one runs. The
///   clock blocks (bounded) until a detached task has run the real `queue.cancel`; the queue
///   actor is idle at that point, so this is the interleaving an app-side Cancel task gets.
final class FormalArchiveUploadQueueTests: XCTestCase {
    private static let authority = try! JazzArchiveSignedEnrollmentAuthority(
        issuer: "https://issuer.example",
        audience: "jazz-desktop",
        bundleId: "jdb_00000000000000000000000000000001",
        generation: 1,
        envelopeDigest: String(repeating: "a", count: 64))
    private static let route = try! JazzArchiveUploadRouteBinding(
        ingestEndpoint: "https://ingest-a.example/api/archive-ingests",
        stackURL: "https://connection.example.keboola.com",
        projectId: "123",
        tokenId: "456",
        scope: JazzArchiveUploadScope(
            companyId: "acme", areaId: "finance", deviceId: "mac-1"),
        signedAuthority: authority)
    private static let t0 = "2026-07-23T10:04:00.000Z"
    private static let t1 = "2026-07-23T11:04:00.000Z"

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("formal-archive-upload-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - fakes

    /// The coordinator's clock. Optionally runs one async action (a Cancel) synchronously on
    /// the Nth call, or on the first call after the object PUT returned.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: String
        private var calls = 0
        private var fireOnCall: Int?
        private var fireAfterUpload = false
        private var uploadReturned = false
        private var action: (@Sendable () async -> Void)?
        private(set) var fired = false
        private(set) var timedOut = false

        init(_ time: String) { self.time = time }

        func set(time: String) {
            lock.lock()
            self.time = time
            lock.unlock()
        }

        /// Fire `action` on the `call`-th `now()` from here on.
        func arm(onCall call: Int, _ action: @escaping @Sendable () async -> Void) {
            lock.lock()
            calls = 0
            fireOnCall = call
            self.action = action
            lock.unlock()
        }

        /// Fire `action` on the first `now()` after `uploadDidReturn()`.
        func armAfterUpload(_ action: @escaping @Sendable () async -> Void) {
            lock.lock()
            fireAfterUpload = true
            self.action = action
            lock.unlock()
        }

        func uploadDidReturn() {
            lock.lock()
            uploadReturned = true
            lock.unlock()
        }

        func now() -> String {
            lock.lock()
            calls += 1
            var pending: (@Sendable () async -> Void)?
            if !fired, let action,
                calls == fireOnCall || (fireAfterUpload && uploadReturned)
            {
                fired = true
                pending = action
            }
            let value = time
            lock.unlock()
            if let pending {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await pending()
                    done.signal()
                }
                if done.wait(timeout: .now() + 10) == .timedOut {
                    lock.lock()
                    timedOut = true
                    lock.unlock()
                }
            }
            return value
        }
    }

    private actor Credentials: JazzArchiveCredentialProvider {
        private var calls = 0
        private let onCall: Int
        private let action: (@Sendable () async -> Void)?
        private let failure: JazzArchiveUploadError?

        init(
            onCall: Int = 0,
            action: (@Sendable () async -> Void)? = nil,
            failure: JazzArchiveUploadError? = nil
        ) {
            self.onCall = onCall
            self.action = action
            self.failure = failure
        }

        func credential(
            for routeBinding: JazzArchiveUploadRouteBinding
        ) async throws -> JazzArchiveScopedDeviceCredential {
            calls += 1
            if calls == onCall, let action { await action() }
            if let failure { throw failure }
            return try JazzArchiveScopedDeviceCredential("8625-123456-scoped-device-token-value")
        }
    }

    private actor ControlPlane: JazzArchiveUploadControlPlane {
        nonisolated let routeBinding = FormalArchiveUploadQueueTests.route
        private let intentState: JazzArchiveRemoteState
        private let finalizeState: JazzArchiveRemoteState
        private var finalizeFailures: Int
        private let onIntent: (@Sendable () async -> Void)?
        private let onFinalize: (@Sendable () async -> Void)?
        private var lastRequest: JazzArchiveUploadIntentRequest?
        private(set) var intentCount = 0
        private(set) var finalizeCount = 0

        init(
            intentState: JazzArchiveRemoteState = .created,
            finalizeState: JazzArchiveRemoteState = .ready,
            finalizeFailures: Int = 0,
            onIntent: (@Sendable () async -> Void)? = nil,
            onFinalize: (@Sendable () async -> Void)? = nil
        ) {
            self.intentState = intentState
            self.finalizeState = finalizeState
            self.finalizeFailures = finalizeFailures
            self.onIntent = onIntent
            self.onFinalize = onFinalize
        }

        func createIntent(
            _ request: JazzArchiveUploadIntentRequest,
            credential: JazzArchiveScopedDeviceCredential
        ) async throws -> JazzArchiveUploadIntentResponse {
            intentCount += 1
            lastRequest = request
            if let onIntent { await onIntent() }
            var upload: JazzArchiveOpaqueUploadInstructions?
            if intentState == .created {
                upload = try JazzArchiveOpaqueUploadInstructions(
                    transport: JazzArchiveHTTPPutGrant.transport,
                    values: [
                        "method": .string("PUT"),
                        "url": .string("https://objects.example/quarantine/object"),
                        "receiptHeader": .string("ETag"),
                    ])
            }
            return JazzArchiveUploadIntentResponse(
                status: status(request, intentState), upload: upload)
        }

        func reconcileLegacyIntent(
            _ request: JazzArchiveLegacyUploadReconciliationRequest,
            credential: JazzArchiveScopedDeviceCredential
        ) async throws -> JazzArchiveUploadIntentResponse {
            throw JazzArchiveUploadError.invalidServerResponse("UNUSED")
        }

        func finalize(
            ingestId: String,
            uploadOperationId: String,
            scope: JazzArchiveUploadScope,
            uploadReceipt: String,
            credential: JazzArchiveScopedDeviceCredential
        ) async throws -> JazzArchiveRemoteStatus {
            finalizeCount += 1
            guard let lastRequest else {
                throw JazzArchiveUploadError.invalidServerResponse("MISSING_INTENT")
            }
            if finalizeFailures > 0 {
                finalizeFailures -= 1
                throw URLError(.notConnectedToInternet)
            }
            if let onFinalize { await onFinalize() }
            return status(lastRequest, finalizeState)
        }

        func status(
            ingestId: String,
            scope: JazzArchiveUploadScope,
            credential: JazzArchiveScopedDeviceCredential
        ) async throws -> JazzArchiveRemoteStatus {
            guard let lastRequest else {
                throw JazzArchiveUploadError.invalidServerResponse("MISSING_INTENT")
            }
            return status(lastRequest, .ready)
        }

        private func status(
            _ request: JazzArchiveUploadIntentRequest,
            _ state: JazzArchiveRemoteState
        ) -> JazzArchiveRemoteStatus {
            JazzArchiveRemoteStatus(
                uploadOperationId: request.uploadOperationId,
                ingestId: "ingest-1",
                state: state,
                archiveId: request.archiveId,
                originId: request.originId,
                formatVersion: request.formatVersion,
                revision: request.revision,
                contentDigest: request.contentDigest,
                rawSHA256: request.rawSHA256,
                byteLength: request.byteLength,
                errorCode: state == .failedTerminal ? "ARCHIVE_IMPORT_FAILED" : nil)
        }
    }

    private actor Transport: JazzArchiveDirectUploadTransport {
        private let clock: Clock?
        private(set) var uploads = 0

        init(clock: Clock? = nil) { self.clock = clock }

        func upload(
            file: URL,
            instructions: JazzArchiveOpaqueUploadInstructions
        ) async throws -> String {
            uploads += 1
            clock?.uploadDidReturn()
            return "opaque-receipt"
        }
    }

    // MARK: - helpers

    private func enqueue() async throws -> (JazzArchiveUploadQueue, String) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("archive.zip")
        try Data("archive bytes".utf8).write(to: source)
        let queue = JazzArchiveUploadQueue(
            root: root.appendingPathComponent("archive-upload", isDirectory: true))
        let archiveId = Identifiers.newArchiveId()
        let item = try await queue.enqueue(
            file: source,
            archiveId: archiveId,
            originId: Identifiers.newOriginId(),
            captureIds: [Identifiers.newCaptureId()],
            revision: 1,
            contentDigest: String(repeating: "a", count: 64),
            scope: Self.route.scope,
            queuedAt: "2026-07-23T10:03:00.000Z")
        XCTAssertEqual(item.state, .queued)
        return (queue, archiveId)
    }

    private func coordinator(
        _ queue: JazzArchiveUploadQueue,
        control: ControlPlane,
        transport: Transport = Transport(),
        credentials: Credentials = Credentials(),
        clock: Clock
    ) -> JazzArchiveUploadCoordinator {
        JazzArchiveUploadCoordinator(
            queue: queue,
            credentials: credentials,
            controlPlane: control,
            objectTransport: transport,
            now: { clock.now() })
    }

    private func cancelAction(
        _ queue: JazzArchiveUploadQueue, _ archiveId: String
    ) -> @Sendable () async -> Void {
        { _ = try? await queue.cancel(archiveId: archiveId) }
    }

    private func state(
        _ queue: JazzArchiveUploadQueue, _ archiveId: String
    ) async throws -> JazzArchiveUploadState? {
        try await queue.item(archiveId: archiveId)?.state
    }

    // MARK: - finding A: the coordinator overwrites the user's Cancel

    /// A1 (model CancelSticky / NoReadyAfterCancel, op beginIntent). Cancel lands between
    /// `bindRoute` and `beginIntent`. Before the fix isAllowed(cancelled -> creatingIntent) was
    /// true, so the whole upload ran and the archive ended `ready`. Now `cancelled` may only go
    /// to `queued` (the user's Retry), so beginIntent is refused and nothing is sent.
    func testA1CancelBeforeBeginIntentStaysCancelled() async throws {
        let (queue, archiveId) = try await enqueue()
        let clock = Clock(Self.t0)
        // now() #1 = canRunAutomatically (:2085), #2 = bindRoute (:2094), #3 = beginIntent.
        clock.arm(onCall: 3, cancelAction(queue, archiveId))
        let control = ControlPlane()
        let transport = Transport()
        _ = try? await coordinator(
            queue, control: control, transport: transport, clock: clock
        ).run(archiveId: archiveId)
        XCTAssertTrue(clock.fired)
        XCTAssertFalse(clock.timedOut)
        let finalState = try await state(queue, archiveId)
        let intents = await control.intentCount
        let uploads = await transport.uploads

        XCTAssertEqual(finalState, .cancelled)
        XCTAssertEqual(intents, 0)
        XCTAssertEqual(uploads, 0)
    }

    /// A2 (op setIntent, createIntent default branch :2226-2238). Cancel while the intent
    /// request is in flight; the server answers `ready` for this operation. setIntent writes
    /// cancelled -> processing, then applyTerminal processing -> ready (fixed: setIntent is now
    /// refused for a cancelled record).
    func testA2CancelDuringCreateIntentIsNotOverwrittenByTheResponse() async throws {
        let (queue, archiveId) = try await enqueue()
        let control = ControlPlane(
            intentState: .ready, onIntent: cancelAction(queue, archiveId))
        _ = try? await coordinator(queue, control: control, clock: Clock(Self.t0))
            .run(archiveId: archiveId)
        let finalState = try await state(queue, archiveId)

        XCTAssertEqual(finalState, .cancelled)
    }

    /// A3 (op setUploadReceipt). Cancel lands between the `state == .uploading` check (:2222)
    /// and `setUploadReceipt` (:2225). isAllowed(cancelled -> finalizing) was true, so the
    /// cancelled upload was finalized and ended `ready` (fixed: setUploadReceipt is refused).
    func testA3CancelAfterUploadCheckIsNotFinalized() async throws {
        let (queue, archiveId) = try await enqueue()
        let clock = Clock(Self.t0)
        // The first now() after the PUT returns is the argument of setUploadReceipt.
        clock.armAfterUpload(cancelAction(queue, archiveId))
        let control = ControlPlane()
        _ = try? await coordinator(
            queue, control: control, transport: Transport(clock: clock), clock: clock
        ).run(archiveId: archiveId)
        XCTAssertTrue(clock.fired)
        XCTAssertFalse(clock.timedOut)
        let finalState = try await state(queue, archiveId)
        let finalizes = await control.finalizeCount

        XCTAssertEqual(finalState, .cancelled)
        XCTAssertEqual(finalizes, 0)
    }

    /// A4 (op coordinatorRetry). A finalize failed, so the record is retryable/resume
    /// finalizing. On the next pass Cancel lands between `bindRoute` and the coordinator's own
    /// resume. Before the fix that resume was the user-facing `queue.retry`, which accepted
    /// cancelled and returned it to `queued`; the coordinator then sent finalize anyway. It now
    /// uses `resumeRetryable`, which accepts only `retryable`.
    func testA4CoordinatorResumeDoesNotUncancel() async throws {
        let (queue, archiveId) = try await enqueue()
        let clock = Clock(Self.t0)
        let control = ControlPlane(finalizeFailures: 1)
        let worker = coordinator(queue, control: control, clock: clock)
        let first = try await worker.run(archiveId: archiveId)
        XCTAssertEqual(first.state, .retryable)
        XCTAssertEqual(first.resumeState, .finalizing)
        let finalizesBefore = await control.finalizeCount

        clock.set(time: Self.t1)  // past the local nextAttemptAt
        // now() #1 = canRunAutomatically, #2 = bindRoute, #3 = queue.resumeRetryable.
        clock.arm(onCall: 3, cancelAction(queue, archiveId))
        _ = try? await worker.run(archiveId: archiveId)
        XCTAssertTrue(clock.fired)
        XCTAssertFalse(clock.timedOut)
        let finalState = try await state(queue, archiveId)
        let finalizesAfter = await control.finalizeCount

        XCTAssertEqual(finalState, .cancelled)
        XCTAssertEqual(finalizesAfter, finalizesBefore)
    }

    /// A5 (op setIntent via apply :2281). Cancel while finalize is in flight; the server
    /// answers `uploaded`. setIntent wrote cancelled -> verifying and later polls reached ready
    /// (fixed: setIntent is refused for a cancelled record).
    func testA5CancelDuringFinalizeIsNotOverwrittenByTheResponse() async throws {
        let (queue, archiveId) = try await enqueue()
        let control = ControlPlane(
            finalizeState: .uploaded, onFinalize: cancelAction(queue, archiveId))
        _ = try? await coordinator(queue, control: control, clock: Clock(Self.t0))
            .run(archiveId: archiveId)
        let finalState = try await state(queue, archiveId)

        XCTAssertEqual(finalState, .cancelled)
    }

    /// A6 (op applyTerminal). Same as A5 but the server answers failed_terminal:
    /// applyTerminal wrote cancelled -> failedTerminal, which also removed the user's Retry
    /// (fixed: applyTerminal now returns a cancelled record unchanged for every answer).
    func testA6CancelDuringFinalizeIsNotReplacedByTerminalFailure() async throws {
        let (queue, archiveId) = try await enqueue()
        let control = ControlPlane(
            finalizeState: .failedTerminal, onFinalize: cancelAction(queue, archiveId))
        _ = try? await coordinator(queue, control: control, clock: Clock(Self.t0))
            .run(archiveId: archiveId)
        let finalState = try await state(queue, archiveId)

        XCTAssertEqual(finalState, .cancelled)
    }

    // MARK: - finding C: no state re-check before finalize

    /// C (model NoFinalizeAfterCancel). Cancel is durably recorded after setUploadReceipt,
    /// while the coordinator reads the credential for finalize (:2248). finalize(_:) did not
    /// re-read the record, so the finalize request was sent for a cancelled delivery. Fixed:
    /// the coordinator re-reads the record right before each request (`changedSinceRead`).
    func testCNoFinalizeRequestAfterCancelIsRecorded() async throws {
        let (queue, archiveId) = try await enqueue()
        let control = ControlPlane()
        // credential #1 = createIntent, #2 = finalize.
        let credentials = Credentials(onCall: 2, action: cancelAction(queue, archiveId))
        _ = try? await coordinator(
            queue, control: control, credentials: credentials, clock: Clock(Self.t0)
        ).run(archiveId: archiveId)
        let finalState = try await state(queue, archiveId)
        XCTAssertEqual(finalState, .cancelled)
        let finalizes = await control.finalizeCount
        XCTAssertEqual(finalizes, 0)
    }

    /// C, intent stage: Cancel lands while the credential for createIntent is read (after
    /// beginIntent). The re-read before the request sees `cancelled` and sends nothing.
    func testCNoIntentRequestAfterCancelIsRecorded() async throws {
        let (queue, archiveId) = try await enqueue()
        let control = ControlPlane()
        let credentials = Credentials(onCall: 1, action: cancelAction(queue, archiveId))
        _ = try? await coordinator(
            queue, control: control, credentials: credentials, clock: Clock(Self.t0)
        ).run(archiveId: archiveId)
        let finalState = try await state(queue, archiveId)
        XCTAssertEqual(finalState, .cancelled)
        let intents = await control.intentCount
        XCTAssertEqual(intents, 0)
    }

    // MARK: - finding B: a nudge during a pass is not dropped

    /// B (model NoStrandedRunnable / EventuallySettles). Before the fix `nudge()` was dropped
    /// while a pass ran and the pass end did not re-arm for a re-queued record. The gate the
    /// app's `ArchiveUploadManager` now uses remembers the request and runs one more pass.
    func testBNudgeDuringAPassRunsOneMorePass() {
        var gate = JazzArchiveUploadPassGate()
        XCTAssertTrue(gate.request())  // idle: start a pass
        XCTAssertFalse(gate.request())  // Retry during the pass: remembered
        XCTAssertFalse(gate.request())  // coalesced
        XCTAssertTrue(gate.passDidEnd())  // exactly one more pass
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.passDidEnd())  // nothing pending: idle again
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.request())
    }

    // MARK: - finding T1: isTerminal and isAllowed disagree

    /// T1 (table check T1_TerminalAbsorbing). `cancelled.isTerminal` is true, but before the fix
    /// the public `transition(archiveId:to:)` moved it on to creatingIntent. Only the user's
    /// Retry (cancelled -> queued) may leave cancelled now.
    func testT1CancelledIsTerminalInTheTransitionTable() async throws {
        let (queue, archiveId) = try await enqueue()
        let cancelled = try await queue.cancel(archiveId: archiveId)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertTrue(cancelled.state.isTerminal)
        let moved = try? await queue.transition(archiveId: archiveId, to: .creatingIntent)

        XCTAssertNil(moved)
        // The user's explicit Retry is the one way out.
        let retried = try await queue.retry(archiveId: archiveId)
        XCTAssertEqual(retried.state, .queued)
    }

    // MARK: - reconnect resume after a credential import

    /// A record that needs a new credential: the credential read in createIntent fails, so
    /// `handle` marks it reconnectRequired.
    private func reconnectRequired() async throws -> (JazzArchiveUploadQueue, String) {
        let (queue, archiveId) = try await enqueue()
        let item = try await coordinator(
            queue,
            control: ControlPlane(),
            credentials: Credentials(failure: .credentialUnavailable),
            clock: Clock(Self.t0)
        ).run(archiveId: archiveId)
        XCTAssertEqual(item.state, .reconnectRequired)
        return (queue, archiveId)
    }

    /// `ArchiveUploadManager.reconnectAndRetry` resumes the records of a snapshot. A Cancel that
    /// landed after the snapshot must not be undone, as the user-facing `retry` would do.
    func testReconnectResumeDoesNotUncancel() async throws {
        let (queue, archiveId) = try await reconnectRequired()
        _ = try await queue.cancel(archiveId: archiveId)
        let resumed = try? await queue.resumeReconnectRequired(archiveId: archiveId)
        XCTAssertNil(resumed)
        let finalState = try await state(queue, archiveId)
        XCTAssertEqual(finalState, .cancelled)
    }

    func testReconnectResumeRequeuesAStillReconnectRequiredRecord() async throws {
        let (queue, archiveId) = try await reconnectRequired()
        let resumed = try await queue.resumeReconnectRequired(archiveId: archiveId)
        XCTAssertEqual(resumed.state, .queued)
    }
}
