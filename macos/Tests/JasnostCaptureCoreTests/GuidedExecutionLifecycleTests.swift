import Foundation
import XCTest

@testable import JasnostCaptureCore

final class GuidedExecutionLifecycleTests: XCTestCase {
    func testConcurrentClaimHasOneNetworkWinnerAndCrashRecoveryNeverReissuesPermit() async throws {
        let fixture = try loadFixture()
        let decisionData = try decisionBytes()
        let transport = FakeGuidedExecutionTransport(decisionData: decisionData)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attemptURL = root.appendingPathComponent("attempt.json")
        let journalURL = root.appendingPathComponent("receipts.ndjson")
        let store = GuidedExecutionAttemptStore(url: attemptURL)
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(url: journalURL),
            replayHostId: "desktop-host-a")

        let prepared = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        XCTAssertEqual(prepared.decisionId, fixture.decision.decisionId)
        let newlyPreparedRecord = try await store.load()
        XCTAssertEqual(newlyPreparedRecord?.version, 2)

        let proof = String(repeating: "concurrent-claim-proof-", count: 2)
        let first = Task { try await host.claim(claimProof: proof) }
        await Task.yield()
        let second = Task { try await host.claim(claimProof: proof) }
        var successes = 0
        var failures: [Error] = []
        for task in [first, second] {
            do {
                _ = try await task.value
                successes += 1
            } catch {
                failures.append(error)
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(failures.count, 1)
        let claimCalls = await transport.claimCalls()
        XCTAssertEqual(claimCalls, 1)

        let loadedBeforeStart = try await store.load()
        let beforeStart = try XCTUnwrap(loadedBeforeStart)
        let stableStartRequest = beforeStart.requestIDs.startRequestId
        XCTAssertEqual(beforeStart.claimProof, proof)
        XCTAssertFalse(
            String(
                decoding: try XCTUnwrap(beforeStart.claimServerData),
                as: UTF8.self
            ).contains(proof))

        // A relaunched process reads the exact durable proof and does not mint or POST a new claim.
        let relaunchedBeforeStart = GuidedExecutionHost(
            transport: transport,
            attemptStore: GuidedExecutionAttemptStore(url: attemptURL),
            receiptJournal: GuidedExecutionReceiptJournal(url: journalURL),
            replayHostId: "desktop-host-a")
        _ = try await relaunchedBeforeStart.claim()
        let permit = try await relaunchedBeforeStart.start(
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        XCTAssertEqual(permit.startReceiptId.hasPrefix("ges_"), true)
        let loadedAfterStart = try await store.load()
        XCTAssertEqual(loadedAfterStart?.requestIDs.startRequestId, stableStartRequest)

        let persisted = try Data(contentsOf: attemptURL)
        XCTAssertTrue(String(decoding: persisted, as: UTF8.self).contains(proof))
        XCTAssertTrue(
            String(decoding: persisted, as: UTF8.self).contains(
                try guidedClaimProofDigest(proof)))

        // Durable recovery never manufactures a second permit after START.
        let recoveredHost = GuidedExecutionHost(
            transport: transport,
            attemptStore: GuidedExecutionAttemptStore(url: attemptURL),
            receiptJournal: GuidedExecutionReceiptJournal(url: journalURL),
            replayHostId: "desktop-host-a")
        do {
            _ = try await recoveredHost.start(
                approvedRunbook: fixture.approvedRunbook,
                runtime: fixture.runtime,
                priorReceipts: fixture.priorReceipts)
            XCTFail("a committed start was presented twice")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .lifecycleStateConflict("started"))
        }
        let recovery = try await recoveredHost.recover()
        XCTAssertEqual(recovery, .reconciliationRequired)
        let recoveredRecord = try await store.load()
        XCTAssertTrue(
            String(
                decoding: try XCTUnwrap(recoveredRecord?.lifecycleServerData),
                as: UTF8.self
            ).contains("futureLifecycleAuthority"))
        let startCalls = await transport.startCalls()
        XCTAssertEqual(startCalls, 1)
    }

    func testClaimAndStartTamperingFailsContentAddressAndBinding() throws {
        let fixture = try loadFixture()
        let proof = String(repeating: "tamper-proof-", count: 3)
        let claimData = try makeClaim(
            decisionData: decisionBytes(),
            requestId: "claim-request",
            proof: proof,
            hostId: "host-a")
        var claimObject = try JSONSerialization.jsonObject(with: claimData) as! [String: Any]
        claimObject["replayHostId"] = "host-b"
        XCTAssertThrowsError(
            try GuidedExecutionClaimDocument(
                serverData: JSONSerialization.data(withJSONObject: claimObject))) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .contentAddressMismatch("claim.contentDigest"))
        }

        let startData = try makeStart(
            decisionData: decisionBytes(),
            claimData: claimData,
            requestId: "start-request")
        var startObject = try JSONSerialization.jsonObject(with: startData) as! [String: Any]
        var authority = startObject["authorityDecision"] as! [String: Any]
        authority["logicalOperationKey"] = "forged-operation"
        startObject["authorityDecision"] = authority
        let readdressed = try address(
            startObject.filter { !["startReceiptId", "contentDigest"].contains($0.key) },
            idField: "startReceiptId",
            prefix: "ges_")
        XCTAssertThrowsError(try GuidedExecutionStartReceiptDocument(serverData: readdressed)) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .contentAddressMismatch("decision.contentDigest"))
        }

        // A valid start for another host is content-addressed but cannot bind to this exact claim.
        let decisionDocument = try GuidedReplayDecisionDocument(serverData: decisionBytes())
        let claimDocument = try GuidedExecutionClaimDocument(serverData: claimData)
        let validStart = try GuidedExecutionStartReceiptDocument(serverData: startData)
        XCTAssertNoThrow(try GuidedExecutionValidator.validateStartReceipt(
            validStart,
            for: decisionDocument,
            claimDocument: claimDocument,
            expectedRequestId: "start-request"))
        XCTAssertEqual(fixture.decision.decisionId, decisionDocument.decision.decisionId)
    }

    func testStopBeforeStartUsesStableProofBoundCancellationAndStopAfterStartCannotCancel()
        async throws
    {
        let fixture = try loadFixture()
        let transport = FakeGuidedExecutionTransport(decisionData: try decisionBytes())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GuidedExecutionAttemptStore(
            url: root.appendingPathComponent("attempt.json"))
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-cancel")
        _ = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let proof = String(repeating: "cancel-before-start-proof-", count: 2)
        _ = try await host.claim(claimProof: proof)
        let claimedRecord = try await store.load()
        let cancellationRequestId = try XCTUnwrap(
            claimedRecord?.requestIDs.cancellationRequestId)
        XCTAssertNotEqual(
            cancellationRequestId,
            claimedRecord?.requestIDs.reconciliationRequestId)

        let cancellationReason = "Operator stopped before acting"
        await transport.failNextCancel()
        do {
            _ = try await host.cancel(
                claimProof: proof, reason: cancellationReason)
            XCTFail("the injected ambiguous cancellation must fail")
        } catch {
            XCTAssertEqual(error as? FakeGuidedError, .unsupported)
        }
        let cancellingRecord = try await store.load()
        XCTAssertEqual(cancellingRecord?.phase, .cancelling)
        XCTAssertEqual(cancellingRecord?.cancellationReason, cancellationReason)
        let recoveredClaim = try await host.recover()
        XCTAssertEqual(recoveredClaim, .claimed)
        let claimedAgain = try await store.load()
        XCTAssertEqual(claimedAgain?.phase, .claimed)
        XCTAssertEqual(claimedAgain?.cancellationReason, cancellationReason)
        do {
            _ = try await host.cancel(
                claimProof: proof, reason: "Changed input under the same request ID")
            XCTFail("changed cancellation input must collide before another network request")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .requestIdentityConflict(cancellationRequestId))
        }
        let cancelled = try await host.cancel(
            claimProof: proof, reason: cancellationReason)
        XCTAssertEqual(cancelled, .cancelled)
        let retried = try await host.cancel(
            claimProof: proof, reason: cancellationReason)
        XCTAssertEqual(retried, .cancelled)
        do {
            _ = try await host.cancel(
                claimProof: proof, reason: "Changed input under the same request ID")
            XCTFail("changed cancellation input must collide")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .requestIdentityConflict(cancellationRequestId))
        }
        let firstCancelCalls = await transport.cancelCalls()
        let cancellationRequestIDs = await transport.cancellationRequestIDs()
        let cancelledRecord = try await store.load()
        XCTAssertEqual(firstCancelCalls, 2)
        XCTAssertEqual(
            cancellationRequestIDs,
            [cancellationRequestId, cancellationRequestId])
        XCTAssertEqual(cancelledRecord?.phase, .reconciled)
        let archivedAttempt = try await store.retireWhenSafe()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedAttempt.path))
        XCTAssertFalse(
            String(
                decoding: try Data(contentsOf: archivedAttempt),
                as: UTF8.self
            ).contains(proof))
        let activeAfterRetirement = try await store.load()
        XCTAssertNil(activeAfterRetirement)

        let secondRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-cancel-after-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let secondStore = GuidedExecutionAttemptStore(
            url: secondRoot.appendingPathComponent("attempt.json"))
        let secondHost = GuidedExecutionHost(
            transport: transport,
            attemptStore: secondStore,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: secondRoot.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-started")
        _ = try await secondHost.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let secondProof = String(repeating: "started-proof-", count: 3)
        _ = try await secondHost.claim(claimProof: secondProof)
        _ = try await secondHost.start(
            claimProof: secondProof,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        do {
            _ = try await secondHost.cancel(
                claimProof: secondProof, reason: "Too late to release")
            XCTFail("START must make pre-start cancellation impossible")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .lifecycleStateConflict(GuidedExecutionLocalPhase.started.rawValue))
        }
        do {
            _ = try await secondStore.retireWhenSafe()
            XCTFail("a started attempt must remain in the active recovery slot")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .lifecycleStateConflict(GuidedExecutionLocalPhase.started.rawValue))
        }
        let finalCancelCalls = await transport.cancelCalls()
        XCTAssertEqual(finalCancelCalls, 2)
    }

    func testReceiptAndReconciliationRetryInputsAreFrozenBeforeNetwork() async throws {
        let fixture = try loadFixture()
        let receiptTransport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let receiptRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-receipt-intent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: receiptRoot) }
        let receiptStore = GuidedExecutionAttemptStore(
            url: receiptRoot.appendingPathComponent("attempt.json"))
        let receiptHost = GuidedExecutionHost(
            transport: receiptTransport,
            attemptStore: receiptStore,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: receiptRoot.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-receipt-intent")
        _ = try await receiptHost.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let receiptProof = String(repeating: "receipt-intent-proof-", count: 2)
        _ = try await receiptHost.claim(claimProof: receiptProof)
        let permit = try await receiptHost.start(
            claimProof: receiptProof,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let firstResult = JazzArchiveJSONValue.object([
            "status": .string("succeeded"),
            "attempt": .integer(1),
        ])
        do {
            _ = try await receiptHost.recordReceipt(
                permit: permit,
                claimProof: receiptProof,
                result: firstResult)
            XCTFail("the fake receipt boundary must fail after persisting its intent")
        } catch {
            XCTAssertEqual(error as? FakeGuidedError, .unsupported)
        }
        let receiptRecord = try await receiptStore.load()
        let receiptRequestId = try XCTUnwrap(
            receiptRecord?.requestIDs.receiptRequestId)
        XCTAssertEqual(receiptRecord?.phase, .receipting)
        XCTAssertEqual(receiptRecord?.receiptResult, firstResult)
        do {
            _ = try await receiptHost.recordReceipt(
                permit: permit,
                claimProof: receiptProof,
                result: .object([
                    "status": .string("succeeded"),
                    "attempt": .integer(2),
                ]))
            XCTFail("changed result must collide before a second network request")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .requestIdentityConflict(receiptRequestId))
        }
        let receiptCalls = await receiptTransport.receiptCalls()
        XCTAssertEqual(receiptCalls, 1)

        let reconcileTransport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let reconcileRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-reconcile-intent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: reconcileRoot) }
        let reconcileStore = GuidedExecutionAttemptStore(
            url: reconcileRoot.appendingPathComponent("attempt.json"))
        let reconcileHost = GuidedExecutionHost(
            transport: reconcileTransport,
            attemptStore: reconcileStore,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: reconcileRoot.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-reconcile-intent")
        _ = try await reconcileHost.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let reconcileProof = String(repeating: "reconcile-intent-proof-", count: 2)
        _ = try await reconcileHost.claim(claimProof: reconcileProof)
        _ = try await reconcileHost.start(
            claimProof: reconcileProof,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let evidence = [
            GuidedEvidenceReference(
                kind: .assertion,
                ref: "desktop-reconciliation:stable",
                confidence: nil)
        ]
        await reconcileTransport.failNextReconcile()
        do {
            _ = try await reconcileHost.reconcile(
                mode: .unknown,
                reason: "Outcome cannot be verified",
                evidence: evidence)
            XCTFail("the fake reconciliation boundary must fail after persisting its intent")
        } catch {
            XCTAssertEqual(error as? FakeGuidedError, .unsupported)
        }
        let reconcileRecord = try await reconcileStore.load()
        let reconciliationRequestId = try XCTUnwrap(
            reconcileRecord?.requestIDs.reconciliationRequestId)
        XCTAssertEqual(reconcileRecord?.phase, .reconciling)
        XCTAssertEqual(reconcileRecord?.reconciliationIntent?.evidence, evidence)
        do {
            _ = try await reconcileHost.reconcile(
                mode: .unknown,
                reason: "Changed reason",
                evidence: evidence)
            XCTFail("changed reconciliation input must collide locally")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .requestIdentityConflict(reconciliationRequestId))
        }
        let reconcileCalls = await reconcileTransport.reconcileCalls()
        XCTAssertEqual(reconcileCalls, 1)
    }

    func testReceiptReconciliationWireVariantOmitsClaimReconciliationRequestId() throws {
        let scope = GuidedExecutionScope(
            companyId: "company-a", areaId: "area-a", processId: "process-a")
        let evidence = [
            GuidedEvidenceReference(
                kind: .assertion, ref: "desktop:completion-proof", confidence: nil)
        ]
        let result = JazzArchiveJSONValue.object([
            "status": .string("succeeded")
        ])
        let receipt = try GuidedExecutionWirePayload.reconciliation(
            scope: scope,
            claimReconciliationRequestId: "must-not-cross-the-wire",
            mode: .receipt,
            reason: "Recovered exact completion",
            evidence: evidence,
            receiptRequestId: "receipt-request-a",
            result: result)
        guard case let .object(receiptObject) = receipt else {
            return XCTFail("receipt payload is not an object")
        }
        XCTAssertNil(receiptObject["reconciliationRequestId"])
        XCTAssertEqual(receiptObject["receiptRequestId"], .string("receipt-request-a"))
        XCTAssertEqual(receiptObject["result"], result)

        let unknown = try GuidedExecutionWirePayload.reconciliation(
            scope: scope,
            claimReconciliationRequestId: "reconcile-request-a",
            mode: .unknown,
            reason: "Outcome remains unknown",
            evidence: evidence,
            receiptRequestId: nil,
            result: nil)
        guard case let .object(unknownObject) = unknown else {
            return XCTFail("unknown payload is not an object")
        }
        XCTAssertEqual(
            unknownObject["reconciliationRequestId"], .string("reconcile-request-a"))
        XCTAssertNil(unknownObject["receiptRequestId"])
        XCTAssertNil(unknownObject["result"])
    }

    func testGuidedCredentialIsBoundToNormalizedExactEndpoint() throws {
        let endpoint = try XCTUnwrap(
            GuidedExecutionEndpointBinding.normalize(
                " https://EXAMPLE.com:443/governance/// "))
        XCTAssertEqual(endpoint.absoluteString, "https://example.com/governance")
        let stored = try GuidedExecutionEndpointBinding.encodeCredential(
            token: "scoped-secret", endpoint: endpoint)
        XCTAssertEqual(
            GuidedExecutionEndpointBinding.token(
                storedValue: stored,
                matching: try XCTUnwrap(
                    GuidedExecutionEndpointBinding.normalize(
                        "https://example.com/governance/"))),
            "scoped-secret")
        XCTAssertNil(
            GuidedExecutionEndpointBinding.token(
                storedValue: stored,
                matching: try XCTUnwrap(
                    GuidedExecutionEndpointBinding.normalize(
                        "https://other.example/governance"))))
        XCTAssertNil(
            GuidedExecutionEndpointBinding.token(
                storedValue: "legacy-plaintext-secret", matching: endpoint))
        XCTAssertNil(GuidedExecutionEndpointBinding.normalize("http://example.com/governance"))
        XCTAssertNil(
            GuidedExecutionEndpointBinding.normalize(
                "https://example.com/governance?token=forbidden"))
    }

    func testReconciliationRequiredCanAdvanceWithDistinctAppendOnlyRequest() async throws {
        let fixture = try loadFixture()
        let transport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-reconcile-followup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attemptURL = root.appendingPathComponent("attempt.json")
        let store = GuidedExecutionAttemptStore(url: attemptURL)
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-reconcile-followup")
        _ = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let proof = String(repeating: "reconcile-followup-proof-", count: 2)
        _ = try await host.claim(claimProof: proof)
        _ = try await host.start(
            claimProof: proof,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let evidence = [
            GuidedEvidenceReference(
                kind: .assertion,
                ref: "operator:current-state-check",
                confidence: nil)
        ]

        let required = try await host.reconcile(
            mode: .required,
            reason: "The direct result channel was lost.",
            evidence: evidence)
        XCTAssertEqual(required, .reconciliationRequired)
        let loadedAfterRequired = try await store.load()
        let afterRequired = try XCTUnwrap(loadedAfterRequired)
        XCTAssertEqual(afterRequired.phase, .started)
        XCTAssertNil(afterRequired.claimProof)
        XCTAssertNotEqual(
            afterRequired.requestIDs.reconciliationRequestId,
            afterRequired.requestIDs.followupReconciliationRequestId)
        let firstRequestId = afterRequired.requestIDs.reconciliationRequestId
        let firstReconciliation = try GuidedExecutionReconciliationDocument(
            serverData: XCTUnwrap(afterRequired.reconciliationServerData))
        XCTAssertEqual(
            firstReconciliation.reconciliation.resolution,
            .reconciliationRequired)

        // Exact retry is answered from the durable server artifact and sends no second request.
        let requiredRetry = try await host.reconcile(
            mode: .required,
            reason: "The direct result channel was lost.",
            evidence: evidence)
        XCTAssertEqual(requiredRetry, .reconciliationRequired)
        let callsAfterRequired = await transport.reconcileCalls()
        XCTAssertEqual(callsAfterRequired, 1)

        let unresolved = try await host.reconcile(
            mode: .unknown,
            reason: "Trusted current state remains inconclusive.",
            evidence: evidence)
        XCTAssertEqual(unresolved, .unresolved)
        let loadedAfterUnknown = try await store.load()
        let afterUnknown = try XCTUnwrap(loadedAfterUnknown)
        XCTAssertEqual(afterUnknown.phase, .reconciled)
        XCTAssertNil(afterUnknown.claimProof)
        let finalReconciliation = try GuidedExecutionReconciliationDocument(
            serverData: XCTUnwrap(afterUnknown.reconciliationServerData))
        XCTAssertEqual(finalReconciliation.reconciliation.resolution, .unknown)
        XCTAssertEqual(
            finalReconciliation.reconciliation.supersedesReconciliationId,
            firstReconciliation.reconciliation.reconciliationId)
        let reconciliationRequestIDs = await transport.reconciliationRequestIDs()
        XCTAssertEqual(
            reconciliationRequestIDs,
            [
                firstRequestId,
                try XCTUnwrap(
                    afterUnknown.requestIDs.followupReconciliationRequestId),
            ])

        // The final exact retry is also local and the raw proof never enters history.
        let unknownRetry = try await host.reconcile(
            mode: .unknown,
            reason: "Trusted current state remains inconclusive.",
            evidence: evidence)
        XCTAssertEqual(unknownRetry, .unresolved)
        let callsAfterUnknown = await transport.reconcileCalls()
        XCTAssertEqual(callsAfterUnknown, 2)
        let archived = try await store.retireWhenSafe()
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: archived), as: UTF8.self)
                .contains(proof))
    }

    func testExpiredPreStartClaimErasesDurableProofAndCanRetire() async throws {
        let fixture = try loadFixture()
        let transport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-expired-claim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GuidedExecutionAttemptStore(
            url: root.appendingPathComponent("attempt.json"))
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-expired")
        _ = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let proof = String(repeating: "expired-proof-", count: 3)
        _ = try await host.claim(claimProof: proof)
        await transport.expireClaim()

        let recovery = try await host.recover()
        XCTAssertEqual(recovery, .expired)
        let expired = try await store.load()
        XCTAssertEqual(expired?.phase, .expired)
        XCTAssertNil(expired?.claimProof)
        XCTAssertNotNil(expired?.claimProofDigest)
        let archived = try await store.retireWhenSafe()
        XCTAssertFalse(
            String(
                decoding: try Data(contentsOf: archived),
                as: UTF8.self
            ).contains(proof))
    }

    func testLegacyV1ClaimWithoutRawProofUsesGetOnlyAndWaitsForServerExpiry()
        async throws
    {
        let fixture = try loadFixture()
        let transport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-v1-claimed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attemptURL = root.appendingPathComponent("attempt.json")
        let store = GuidedExecutionAttemptStore(url: attemptURL)
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-v1-claimed")
        _ = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let proof = String(repeating: "legacy-claimed-proof-", count: 2)
        _ = try await host.claim(claimProof: proof)
        try rewriteAttemptAsLegacyV1(at: attemptURL)

        let legacy = try await store.load()
        XCTAssertEqual(legacy?.version, 1)
        XCTAssertEqual(legacy?.phase, .claimed)
        XCTAssertNil(legacy?.claimProof)
        XCTAssertNotNil(legacy?.claimProofDigest)

        let recovered = try await host.recover()
        XCTAssertEqual(recovered, .claimedWithoutProof)
        do {
            _ = try await host.start(
                approvedRunbook: fixture.approvedRunbook,
                runtime: fixture.runtime,
                priorReceipts: fixture.priorReceipts)
            XCTFail("legacy recovery must not START without the exact raw proof")
        } catch {
            XCTAssertEqual(error as? GuidedExecutionError, .claimProofUnavailable)
        }
        do {
            _ = try await host.cancel(reason: "Cannot prove this legacy claim")
            XCTFail("legacy recovery must not cancel without the exact raw proof")
        } catch {
            XCTAssertEqual(error as? GuidedExecutionError, .claimProofUnavailable)
        }
        let startCalls = await transport.startCalls()
        let cancelCalls = await transport.cancelCalls()
        XCTAssertEqual(startCalls, 0)
        XCTAssertEqual(cancelCalls, 0)

        await transport.expireClaim()
        let expiredRecovery = try await host.recover()
        let expiredRecord = try await store.load()
        XCTAssertEqual(expiredRecovery, .expired)
        XCTAssertEqual(expiredRecord?.phase, .expired)
        let archived = try await store.retireWhenSafe()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
    }

    func testLegacyV1StartedAttemptCannotRetryReceiptButCanReconcileWithoutProof()
        async throws
    {
        let fixture = try loadFixture()
        let transport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-v1-started-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attemptURL = root.appendingPathComponent("attempt.json")
        let store = GuidedExecutionAttemptStore(url: attemptURL)
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-v1-started")
        _ = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let proof = String(repeating: "legacy-started-proof-", count: 2)
        _ = try await host.claim(claimProof: proof)
        let permit = try await host.start(
            claimProof: proof,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let result = JazzArchiveJSONValue.object([
            "status": .string("succeeded")
        ])
        do {
            _ = try await host.recordReceipt(
                permit: permit,
                claimProof: proof,
                result: result)
            XCTFail("the fake receipt boundary must leave a durable ambiguous intent")
        } catch {
            XCTAssertEqual(error as? FakeGuidedError, .unsupported)
        }
        let receiptingRecord = try await store.load()
        XCTAssertEqual(receiptingRecord?.phase, .receipting)
        try rewriteAttemptAsLegacyV1(at: attemptURL)

        let legacy = try await store.load()
        XCTAssertEqual(legacy?.version, 1)
        XCTAssertEqual(legacy?.phase, .receipting)
        XCTAssertNil(legacy?.claimProof)
        XCTAssertNil(legacy?.receiptResult)
        let startedRecovery = try await host.recover()
        let recoveredStartedRecord = try await store.load()
        XCTAssertEqual(startedRecovery, .reconciliationRequired)
        XCTAssertEqual(recoveredStartedRecord?.phase, .started)

        let receiptCallsBeforeRetry = await transport.receiptCalls()
        do {
            _ = try await host.recordReceipt(permit: permit, result: result)
            XCTFail("a v1 direct receipt retry must not proceed without the raw proof")
        } catch {
            XCTAssertEqual(error as? GuidedExecutionError, .claimProofUnavailable)
        }
        let receiptCallsAfterRetry = await transport.receiptCalls()
        XCTAssertEqual(receiptCallsAfterRetry, receiptCallsBeforeRetry)

        let evidence = [
            GuidedEvidenceReference(
                kind: .assertion,
                ref: "operator:legacy-current-state",
                confidence: nil)
        ]
        let reconciled = try await host.reconcile(
            mode: .unknown,
            reason: "Legacy started outcome cannot be proven",
            evidence: evidence)
        let reconciledRecord = try await store.load()
        XCTAssertEqual(reconciled, .unresolved)
        XCTAssertEqual(reconciledRecord?.phase, .reconciled)
    }

    func testLegacyV1ReconcilingWithoutFrozenIntentCanUseGetRecovery() async throws {
        let fixture = try loadFixture()
        let transport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-v1-reconciling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attemptURL = root.appendingPathComponent("attempt.json")
        let store = GuidedExecutionAttemptStore(url: attemptURL)
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-v1-reconciling")
        _ = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let proof = String(repeating: "legacy-reconcile-proof-", count: 2)
        _ = try await host.claim(claimProof: proof)
        _ = try await host.start(
            claimProof: proof,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let evidence = [
            GuidedEvidenceReference(
                kind: .assertion,
                ref: "operator:legacy-reconciliation",
                confidence: nil)
        ]
        await transport.failNextReconcile()
        do {
            _ = try await host.reconcile(
                mode: .unknown,
                reason: "Outcome remains unknown",
                evidence: evidence)
            XCTFail("the fake boundary must leave reconciling intent in flight")
        } catch {
            XCTAssertEqual(error as? FakeGuidedError, .unsupported)
        }
        let reconcilingRecord = try await store.load()
        XCTAssertEqual(reconcilingRecord?.phase, .reconciling)
        try rewriteAttemptAsLegacyV1(at: attemptURL)
        let legacyReconcilingRecord = try await store.load()
        XCTAssertNil(legacyReconcilingRecord?.reconciliationIntent)

        let recovery = try await host.recover()
        let recoveredRecord = try await store.load()
        XCTAssertEqual(recovery, .reconciliationRequired)
        XCTAssertEqual(recoveredRecord?.phase, .started)
        let unresolved = try await host.reconcile(
            mode: .unknown,
            reason: "Outcome remains unknown",
            evidence: evidence)
        XCTAssertEqual(unresolved, .unresolved)
    }

    func testLostStartResponseNeverRotatesProofOrExpiresStartedClaim() async throws {
        let fixture = try loadFixture()
        let transport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-lost-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GuidedExecutionAttemptStore(
            url: root.appendingPathComponent("attempt.json"))
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-lost-start")
        _ = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let proof = String(repeating: "lost-start-proof-", count: 3)
        _ = try await host.claim(claimProof: proof)
        await transport.loseNextStartResponse()
        do {
            _ = try await host.start(
                approvedRunbook: fixture.approvedRunbook,
                runtime: fixture.runtime,
                priorReceipts: fixture.priorReceipts)
            XCTFail("the fake must lose the response after committing START")
        } catch {
            XCTAssertEqual(error as? FakeGuidedError, .unsupported)
        }
        let uncertain = try await store.load()
        XCTAssertEqual(uncertain?.phase, .starting)
        XCTAssertEqual(uncertain?.claimProof, proof)
        XCTAssertNil(uncertain?.startReceiptServerData)

        // Even if the pre-start lease time has elapsed, the server's committed START wins.
        await transport.expireClaim()
        let relaunched = GuidedExecutionHost(
            transport: transport,
            attemptStore: GuidedExecutionAttemptStore(
                url: root.appendingPathComponent("attempt.json")),
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-lost-start")
        let recovery = try await relaunched.recover()
        XCTAssertEqual(recovery, .reconciliationRequired)
        let recovered = try await store.load()
        XCTAssertEqual(recovered?.phase, .started)
        XCTAssertEqual(recovered?.claimProof, proof)
        XCTAssertNotNil(recovered?.startReceiptServerData)
        do {
            _ = try await relaunched.start(
                approvedRunbook: fixture.approvedRunbook,
                runtime: fixture.runtime,
                priorReceipts: fixture.priorReceipts)
            XCTFail("recovery must never expose the already committed START again")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .lifecycleStateConflict("started"))
        }
        let startCalls = await transport.startCalls()
        XCTAssertEqual(startCalls, 1)
        do {
            _ = try await store.retireWhenSafe()
            XCTFail("a recovered STARTED attempt must remain active for reconciliation")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .lifecycleStateConflict(GuidedExecutionLocalPhase.started.rawValue))
        }
    }

    func testGuidedReplaySchemaIsPinnedToServerParityDigest() throws {
        let schema = contractRoot().appendingPathComponent(
            "execution/schema/guided-replay.schema.json")
        let data = try Data(contentsOf: schema)
        XCTAssertEqual(
            JazzArchiveDigest.sha256Hex(data),
            "2b5303d63dfc51e3e814795cc7bc14cca8ac97da98902c1ef6f5def432486653")
        let siblingServer = contractRoot().deletingLastPathComponent()
            .appendingPathComponent("jasnost/packages/schema/guided-replay.schema.json")
        if FileManager.default.fileExists(atPath: siblingServer.path) {
            XCTAssertEqual(data, try Data(contentsOf: siblingServer))
        }
    }

    func testProcessExecutionSchemaIsPinnedToServerParityDigest() throws {
        let schema = contractRoot().appendingPathComponent(
            "execution/schema/process-execution.schema.json")
        let data = try Data(contentsOf: schema)
        XCTAssertEqual(
            JazzArchiveDigest.sha256Hex(data),
            "90c859227e7cf5de0076cf6a96af27494e35fc8488aa0fb40278f7bfeb77ade1")
        let siblingServer = contractRoot().deletingLastPathComponent()
            .appendingPathComponent("jasnost/packages/schema/process-execution.schema.json")
        if FileManager.default.fileExists(atPath: siblingServer.path) {
            XCTAssertEqual(data, try Data(contentsOf: siblingServer))
        }
    }

    private func loadFixture() throws -> GuidedExecutionFixture {
        try JSONDecoder().decode(GuidedExecutionFixture.self, from: fixtureData())
    }

    private func decisionBytes() throws -> Data {
        let root = try JSONSerialization.jsonObject(with: fixtureData()) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: root["decision"]!)
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: contractRoot().appendingPathComponent(
            "execution/fixtures/01-second-user-handoff.json"))
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

private func rewriteAttemptAsLegacyV1(at url: URL) throws {
    var record = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)) as! [String: Any]
    record["version"] = 1
    record.removeValue(forKey: "claimProof")
    record.removeValue(forKey: "cancellationReason")
    record.removeValue(forKey: "receiptResult")
    record.removeValue(forKey: "reconciliationIntent")
    var requestIDs = record["requestIDs"] as! [String: Any]
    requestIDs.removeValue(forKey: "cancellationRequestId")
    requestIDs.removeValue(forKey: "followupReconciliationRequestId")
    record["requestIDs"] = requestIDs
    try JSONSerialization.data(withJSONObject: record).write(
        to: url,
        options: [.atomic])
}

private enum FakeGuidedError: Error, Equatable {
    case unsupported
}

private actor FakeGuidedExecutionTransport: GuidedExecutionTransport {
    private let decisionData: Data
    private var claimData: Data?
    private var startData: Data?
    private var cancellationData: Data?
    private var reconciliationData: Data?
    private var claimExpired = false
    private var startResponseFailuresRemaining = 0
    private var claimCallCount = 0
    private var startCallCount = 0
    private var cancelCallCount = 0
    private var cancelFailuresRemaining = 0
    private var reconcileFailuresRemaining = 0
    private var cancellationRequestIdValues: [String] = []
    private var receiptCallCount = 0
    private var reconcileCallCount = 0
    private var reconciliationRequestIdValues: [String] = []

    init(decisionData: Data) {
        self.decisionData = decisionData
    }

    func claimCalls() -> Int { claimCallCount }
    func startCalls() -> Int { startCallCount }
    func cancelCalls() -> Int { cancelCallCount }
    func cancellationRequestIDs() -> [String] { cancellationRequestIdValues }
    func failNextCancel() { cancelFailuresRemaining += 1 }
    func failNextReconcile() { reconcileFailuresRemaining += 1 }
    func receiptCalls() -> Int { receiptCallCount }
    func reconcileCalls() -> Int { reconcileCallCount }
    func reconciliationRequestIDs() -> [String] { reconciliationRequestIdValues }
    func expireClaim() { claimExpired = true }
    func loseNextStartResponse() { startResponseFailuresRemaining += 1 }

    func prepare(
        scope: GuidedExecutionScope,
        request: GuidedReplayRequest
    ) async throws -> Data {
        decisionData
    }

    func claim(
        scope: GuidedExecutionScope,
        decisionId: String,
        claimRequestId: String,
        claimProof: String,
        replayHostId: String
    ) async throws -> Data {
        claimCallCount += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        let data = try makeClaim(
            decisionData: decisionData,
            requestId: claimRequestId,
            proof: claimProof,
            hostId: replayHostId)
        claimData = data
        return data
    }

    func start(
        scope: GuidedExecutionScope,
        claimId: String,
        startRequestId: String,
        claimProof: String
    ) async throws -> Data {
        startCallCount += 1
        guard let claimData else { throw FakeGuidedError.unsupported }
        let data = try makeStart(
            decisionData: decisionData,
            claimData: claimData,
            requestId: startRequestId)
        startData = data
        if startResponseFailuresRemaining > 0 {
            startResponseFailuresRemaining -= 1
            throw FakeGuidedError.unsupported
        }
        return data
    }

    func lifecycle(
        scope: GuidedExecutionScope,
        claimId: String
    ) async throws -> Data {
        guard let claimData else { throw FakeGuidedError.unsupported }
        if let startData {
            if let reconciliationData {
                let reconciliation =
                    try JSONDecoder().decode(
                        GuidedExecutionReconciliation.self,
                        from: reconciliationData)
                return try JSONSerialization.data(withJSONObject: [
                    "claim": try JSONSerialization.jsonObject(with: claimData),
                    "lifecycleState":
                        reconciliation.resolution == .unknown
                        ? "unresolved" : "reconciliation_required",
                    "leaseExpired": claimExpired,
                    "startReceipt": try JSONSerialization.jsonObject(with: startData),
                    "latestReconciliation": try JSONSerialization.jsonObject(
                        with: reconciliationData),
                    "receipt": NSNull(),
                ])
            }
            return try JSONSerialization.data(withJSONObject: [
                "claim": try JSONSerialization.jsonObject(with: claimData),
                "lifecycleState": "started",
                "leaseExpired": claimExpired,
                "startReceipt": try JSONSerialization.jsonObject(with: startData),
                "latestReconciliation": NSNull(),
                "receipt": NSNull(),
                "futureLifecycleAuthority": ["preserved": true],
            ])
        }
        if let cancellationData {
            return try JSONSerialization.data(withJSONObject: [
                "claim": try JSONSerialization.jsonObject(with: claimData),
                "lifecycleState": "cancelled",
                "leaseExpired": false,
                "startReceipt": NSNull(),
                "latestReconciliation": try JSONSerialization.jsonObject(
                    with: cancellationData),
                "receipt": NSNull(),
            ])
        }
        return try JSONSerialization.data(withJSONObject: [
            "claim": try JSONSerialization.jsonObject(with: claimData),
            "lifecycleState": claimExpired ? "expired" : "claimed",
            "leaseExpired": claimExpired,
            "startReceipt": NSNull(),
            "latestReconciliation": NSNull(),
            "receipt": NSNull(),
        ])
    }

    func cancel(
        scope: GuidedExecutionScope,
        claimId: String,
        cancellationRequestId: String,
        claimProof: String,
        reason: String
    ) async throws -> Data {
        cancelCallCount += 1
        cancellationRequestIdValues.append(cancellationRequestId)
        if cancelFailuresRemaining > 0 {
            cancelFailuresRemaining -= 1
            throw FakeGuidedError.unsupported
        }
        guard let claimData else { throw FakeGuidedError.unsupported }
        let data = try makeCancellation(
            decisionData: decisionData,
            claimData: claimData,
            requestId: cancellationRequestId,
            reason: reason)
        cancellationData = data
        return data
    }

    func recordReceipt(
        scope: GuidedExecutionScope,
        decisionId: String,
        claimId: String,
        startReceiptId: String,
        receiptRequestId: String,
        claimProof: String,
        result: JazzArchiveJSONValue
    ) async throws -> Data {
        receiptCallCount += 1
        throw FakeGuidedError.unsupported
    }

    func reconcile(
        scope: GuidedExecutionScope,
        claimId: String,
        reconciliationRequestId: String,
        mode: GuidedReconciliationMode,
        reason: String,
        evidence: [GuidedEvidenceReference],
        receiptRequestId: String?,
        result: JazzArchiveJSONValue?
    ) async throws -> Data {
        reconcileCallCount += 1
        reconciliationRequestIdValues.append(reconciliationRequestId)
        if reconcileFailuresRemaining > 0 {
            reconcileFailuresRemaining -= 1
            throw FakeGuidedError.unsupported
        }
        guard let claimData, let startData, mode != .receipt else {
            throw FakeGuidedError.unsupported
        }
        let previous = try reconciliationData.map {
            try JSONDecoder().decode(
                GuidedExecutionReconciliation.self,
                from: $0)
        }
        let data = try makeStartedReconciliation(
            decisionData: decisionData,
            claimData: claimData,
            startData: startData,
            requestId: reconciliationRequestId,
            mode: mode,
            reason: reason,
            submittedEvidence: evidence,
            supersedes: previous)
        reconciliationData = data
        return data
    }
}

private func makeClaim(
    decisionData: Data,
    requestId: String,
    proof: String,
    hostId: String
) throws -> Data {
    let decision = try JSONSerialization.jsonObject(with: decisionData) as! [String: Any]
    let request = decision["request"] as! [String: Any]
    let step = decision["authorizedStep"] as! [String: Any]
    return try address(
        [
            "artifactType": "executionClaim",
            "schemaVersion": "1",
            "claimRequestId": requestId,
            "claimProofDigest": try guidedClaimProofDigest(proof),
            "decisionId": decision["decisionId"]!,
            "decisionContentDigest": decision["contentDigest"]!,
            "runbook": decision["runbook"]!,
            "executionId": request["executionId"]!,
            "variantRef": step["variantRef"]!,
            "stepId": step["stepId"]!,
            "logicalOperationKey": decision["logicalOperationKey"]!,
            "attemptNumber": decision["attemptNumber"]!,
            "operatorId": request["operatorId"]!,
            "replayHostId": hostId,
            "claimedAt": "2026-07-23T08:59:55Z",
            "leaseExpiresAt": "2026-07-23T09:00:20Z",
            "state": "claimed",
        ],
        idField: "claimId",
        prefix: "gec_")
}

private func makeStart(
    decisionData: Data,
    claimData: Data,
    requestId: String
) throws -> Data {
    let decision = try JSONSerialization.jsonObject(with: decisionData) as! [String: Any]
    let request = decision["request"] as! [String: Any]
    let step = decision["authorizedStep"] as! [String: Any]
    let claim = try JSONSerialization.jsonObject(with: claimData) as! [String: Any]
    return try address(
        [
            "artifactType": "executionStartReceipt",
            "schemaVersion": "1",
            "startRequestId": requestId,
            "claimId": claim["claimId"]!,
            "claimContentDigest": claim["contentDigest"]!,
            "decisionId": decision["decisionId"]!,
            "decisionContentDigest": decision["contentDigest"]!,
            "runbook": decision["runbook"]!,
            "executionId": request["executionId"]!,
            "variantRef": step["variantRef"]!,
            "stepId": step["stepId"]!,
            "logicalOperationKey": decision["logicalOperationKey"]!,
            "attemptNumber": decision["attemptNumber"]!,
            "operatorId": request["operatorId"]!,
            "replayHostId": claim["replayHostId"]!,
            "startedAt": "2026-07-23T09:00:00Z",
            "authorityDecision": decision,
        ],
        idField: "startReceiptId",
        prefix: "ges_")
}

private func makeCancellation(
    decisionData: Data,
    claimData: Data,
    requestId: String,
    reason: String
) throws -> Data {
    let decision = try JSONSerialization.jsonObject(with: decisionData) as! [String: Any]
    let claim = try JSONSerialization.jsonObject(with: claimData) as! [String: Any]
    return try address(
        [
            "artifactType": "executionReconciliation",
            "schemaVersion": "1",
            "reconciliationRequestId": requestId,
            "claimId": claim["claimId"]!,
            "claimContentDigest": claim["contentDigest"]!,
            "decisionId": decision["decisionId"]!,
            "decisionContentDigest": decision["contentDigest"]!,
            "runbook": decision["runbook"]!,
            "executionId": claim["executionId"]!,
            "variantRef": claim["variantRef"]!,
            "stepId": claim["stepId"]!,
            "logicalOperationKey": claim["logicalOperationKey"]!,
            "attemptNumber": claim["attemptNumber"]!,
            "resolution": "cancelledBeforeStart",
            "reason": reason,
            "resolvedBy": claim["operatorId"]!,
            "resolvedAt": "2026-07-23T08:59:57Z",
            "evidence": [],
        ],
        idField: "reconciliationId",
        prefix: "gerc_")
}

private func makeStartedReconciliation(
    decisionData: Data,
    claimData: Data,
    startData: Data,
    requestId: String,
    mode: GuidedReconciliationMode,
    reason: String,
    submittedEvidence: [GuidedEvidenceReference],
    supersedes: GuidedExecutionReconciliation?
) throws -> Data {
    let decision = try JSONSerialization.jsonObject(with: decisionData) as! [String: Any]
    let claim = try JSONSerialization.jsonObject(with: claimData) as! [String: Any]
    let start = try JSONSerialization.jsonObject(with: startData) as! [String: Any]
    let submitted = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(submittedEvidence))
    let resolution = mode == .unknown ? "unknown" : "reconciliationRequired"
    var material: [String: Any] = [
        "artifactType": "executionReconciliation",
        "schemaVersion": "1",
        "reconciliationRequestId": requestId,
        "claimId": claim["claimId"]!,
        "claimContentDigest": claim["contentDigest"]!,
        "startReceiptId": start["startReceiptId"]!,
        "startReceiptContentDigest": start["contentDigest"]!,
        "decisionId": decision["decisionId"]!,
        "decisionContentDigest": decision["contentDigest"]!,
        "runbook": decision["runbook"]!,
        "executionId": claim["executionId"]!,
        "variantRef": claim["variantRef"]!,
        "stepId": claim["stepId"]!,
        "logicalOperationKey": claim["logicalOperationKey"]!,
        "attemptNumber": claim["attemptNumber"]!,
        "resolution": resolution,
        "reason": reason,
        "resolvedBy": "process-owner",
        "resolvedAt": "2026-07-23T09:01:00Z",
        "evidence": [
            ["kind": "assertion", "ref": "server:trusted-reconciliation"]
        ],
        "submittedEvidence": submitted,
        "requestInputDigest":
            "sha256:6666666666666666666666666666666666666666666666666666666666666666",
        "authoritySnapshot": [
            "principalId": "process-owner",
            "action": "replay.reconcile",
            "scope": (decision["runbook"] as! [String: Any])["scope"]!,
            "authorizationSource": "test-process-policy",
            "resolvedAt": "2026-07-23T09:01:00Z",
            "evidence": [
                ["kind": "assertion", "ref": "policy:process-owner"]
            ],
            "authorityDigest":
                "sha256:7777777777777777777777777777777777777777777777777777777777777777",
        ],
    ]
    if let supersedes {
        material["supersedesReconciliationId"] = supersedes.reconciliationId
    }
    if mode == .unknown {
        material["trustedReconciliation"] = [
            "resolver": ["id": "trusted-reconciliation", "version": "1"],
            "resolvedAt": "2026-07-23T09:01:00Z",
            "decisionId": decision["decisionId"]!,
            "resolution": "unknown",
            "observationDigest":
                "sha256:8888888888888888888888888888888888888888888888888888888888888888",
            "evidence": [
                ["kind": "assertion", "ref": "connector:current-state"]
            ],
        ]
    }
    return try address(material, idField: "reconciliationId", prefix: "gerc_")
}

private func address(
    _ material: [String: Any],
    idField: String,
    prefix: String
) throws -> Data {
    let source = try JSONSerialization.data(withJSONObject: material)
    let value = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: source)
    let digest = "sha256:" + JazzArchiveDigest.sha256Hex(
        try JazzArchiveCanonicalJSON.encode(value))
    var artifact = material
    artifact["contentDigest"] = digest
    artifact[idField] = prefix + String(digest.dropFirst(7).prefix(32))
    return try JSONSerialization.data(withJSONObject: artifact)
}
