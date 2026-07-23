import Foundation
import XCTest

@testable import JasnostCaptureCore

final class GuidedExecutionTests: XCTestCase {
    func testSecondUserHandoffNeedsExactStartBeforeSemanticPermit() throws {
        let fixture = try loadFixture()
        let proof = String(repeating: "claim-proof-", count: 4)
        let documents = try lifecycleDocuments(fixture, proof: proof)

        XCTAssertThrowsError(try GuidedExecutionValidator.authorize(
            decision: documents.decision.decision,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .startReceiptRequired)
        }

        let permit = try GuidedExecutionValidator.authorizeStart(
            decisionDocument: documents.decision,
            claimDocument: documents.claim,
            startReceiptDocument: documents.start,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        XCTAssertEqual(fixture.priorReceipts.first?.operatorId, "process-owner-alice")
        XCTAssertEqual(permit.operatorId, "substitute-bob")
        XCTAssertEqual(permit.claimId, documents.claim.claim.claimId)
        XCTAssertEqual(permit.startReceiptId, documents.start.startReceipt.startReceiptId)
        XCTAssertEqual(fixture.priorReceipts.first?.handoffOutcome.state, .accepted)
        XCTAssertNotEqual(permit.semanticLocator.kind, .coordinate)
        XCTAssertEqual(permit.semanticLocator.usage, .execution)
        XCTAssertEqual(permit.sideEffectClass, .irreversible)
        XCTAssertEqual(permit.actorRole, "backup-operator")
        XCTAssertEqual(permit.expectedOutcome, "Invoice INV-42 is posted exactly once.")
    }

    func testExactRunbookDigestAndServerChecksFailClosed() throws {
        let fixture = try loadFixture()

        var wrongPin = fixture.approvedRunbook
        wrongPin.contentDigest = "sha256:" + String(repeating: "9", count: 64)
        XCTAssertThrowsError(try authorize(fixture, approvedRunbook: wrongPin)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .runbookPinMismatch)
        }

        var failed = fixture.decision
        failed.checks[0].status = .fail
        XCTAssertThrowsError(try authorize(fixture, decision: failed)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .failedServerCheck("approved"))
        }

        var draft = fixture.approvedRunbook
        draft.status = .proposed
        XCTAssertThrowsError(try authorize(fixture, approvedRunbook: draft)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .runbookNotApproved)
        }
    }

    func testCoordinateAmbiguityAndStaleResolutionHaveNoFallback() throws {
        let fixture = try loadFixture()

        var coordinate = fixture.runtime
        coordinate.locatorResolution.kind = .coordinate
        coordinate.locatorResolution.locatorId = "rbl_55555555555555555555555555555552"
        var coordinateDecision = fixture.decision
        coordinateDecision.trustedRuntimeContext.locatorResolution = coordinate.locatorResolution
        XCTAssertThrowsError(try authorize(
            fixture, decision: coordinateDecision, runtime: coordinate)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .unsafeLocator)
        }

        var ambiguous = fixture.runtime
        ambiguous.locatorResolution.matchCount = 2
        var ambiguousDecision = fixture.decision
        ambiguousDecision.trustedRuntimeContext.locatorResolution = ambiguous.locatorResolution
        XCTAssertThrowsError(try authorize(
            fixture, decision: ambiguousDecision, runtime: ambiguous)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .ambiguousLocator)
        }

        var stale = fixture.runtime
        stale.locatorResolution.resolvedAt = "2026-07-23T08:00:00Z"
        var staleDecision = fixture.decision
        staleDecision.trustedRuntimeContext.locatorResolution = stale.locatorResolution
        XCTAssertThrowsError(try authorize(fixture, decision: staleDecision, runtime: stale)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .staleObservation("locatorResolution"))
        }
    }

    func testCapabilitiesPreconditionsApplicationsAndBusinessObjectsAreRevalidated() throws {
        let fixture = try loadFixture()

        var noCapability = fixture.runtime
        noCapability.capabilities.removeAll { $0.id == "macos.accessibility.semantic" }
        XCTAssertThrowsError(try authorize(fixture, runtime: noCapability)) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .missingCapability("macos.accessibility.semantic"))
        }

        var failedPrecondition = fixture.runtime
        failedPrecondition.preconditions[0].satisfied = false
        XCTAssertThrowsError(try authorize(fixture, runtime: failedPrecondition)) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .preconditionFailed("invoice-draft-open"))
        }

        var incompatible = fixture.runtime
        incompatible.applicationObservations[0].compatibility = .incompatible
        XCTAssertThrowsError(try authorize(fixture, runtime: incompatible)) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .incompatibleApplication("com.acme.erp"))
        }

        var staleObject = fixture.runtime
        staleObject.businessObjectInputs[0].freshness.status = .stale
        XCTAssertThrowsError(try authorize(fixture, runtime: staleObject)) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .businessObjectUnverified("invoice"))
        }
    }

    func testIrreversibleSideEffectNeedsBoundApprovalAndFreshOperatorConfirmation() throws {
        let fixture = try loadFixture()

        var noApproval = fixture.decision
        noApproval.request.approvals = []
        XCTAssertThrowsError(try authorize(fixture, decision: noApproval)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var wrongDigest = fixture.decision
        wrongDigest.request.approvals[0].boundRunbookContentDigest =
            "sha256:" + String(repeating: "7", count: 64)
        XCTAssertThrowsError(try authorize(fixture, decision: wrongDigest)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var noConfirmation = fixture.runtime
        noConfirmation.userConfirmation = nil
        XCTAssertThrowsError(try authorize(fixture, runtime: noConfirmation)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .userConfirmationMissing)
        }

        var notYetValid = fixture.decision
        notYetValid.request.approvals[0].approvalPolicy.validFrom =
            "2026-07-24T00:00:00.000000Z"
        XCTAssertThrowsError(try authorize(fixture, decision: notYetValid)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var expiredPolicy = fixture.decision
        expiredPolicy.request.approvals[0].approvalPolicy.validUntil =
            "2026-07-23T08:30:00.000000Z"
        XCTAssertThrowsError(try authorize(fixture, decision: expiredPolicy)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var mismatchedPolicyRole = fixture.decision
        mismatchedPolicyRole.request.approvals[0].approvalPolicy.approverRole =
            "different-approver"
        XCTAssertThrowsError(try authorize(fixture, decision: mismatchedPolicyRole)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }
    }

    func testResumeIdempotencyAndHandoffDoNotRepeatSideEffects() throws {
        let fixture = try loadFixture()

        var alreadyDone = fixture.priorReceipts[0]
        alreadyDone.receiptId = "ger_12121212121212121212121212121212"
        alreadyDone.stepId = fixture.decision.authorizedStep!.stepId
        alreadyDone.idempotencyKey = fixture.decision.request.idempotencyKey
        alreadyDone.logicalOperationKey = fixture.decision.logicalOperationKey
        XCTAssertThrowsError(try authorize(fixture, priorReceipts: [alreadyDone])) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .alreadyCompleted(fixture.decision.request.idempotencyKey))
        }

        var keyCollision = fixture.priorReceipts[0]
        keyCollision.receiptId = "ger_13131313131313131313131313131313"
        keyCollision.idempotencyKey = fixture.decision.request.idempotencyKey
        keyCollision.logicalOperationKey = fixture.decision.logicalOperationKey
        XCTAssertThrowsError(try authorize(fixture, priorReceipts: [keyCollision])) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .idempotencyConflict(fixture.decision.request.idempotencyKey))
        }

        var rejectedHandoff = fixture.priorReceipts[0]
        rejectedHandoff.handoffOutcome.state = .rejected
        XCTAssertThrowsError(try authorize(fixture, priorReceipts: [rejectedHandoff])) {
            XCTAssertEqual($0 as? GuidedExecutionError, .handoffNotAccepted)
        }
    }

    func testReceiptJournalIsAppendOnlyAndIdempotent() async throws {
        let fixture = try loadFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-receipts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = GuidedExecutionReceiptJournal(
            url: root.appendingPathComponent("receipts.ndjson"))
        let receipt = fixture.priorReceipts[0]

        let appended = try await journal.append(receipt)
        let appendedAgain = try await journal.append(receipt)
        let initialReceipts = try await journal.receipts()
        XCTAssertTrue(appended)
        XCTAssertFalse(appendedAgain)
        XCTAssertEqual(initialReceipts, [receipt])

        var conflict = receipt
        conflict.operatorId = "forged-operator"
        do {
            _ = try await journal.append(conflict)
            XCTFail("different content reused a receipt identity")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .contentAddressMismatch("receipt.contentDigest"))
        }
        let finalReceipts = try await journal.receipts()
        XCTAssertEqual(finalReceipts, [receipt])
    }

    func testEvidencePlaybackIsReadOnlyAndKeepsExplicitGaps() throws {
        let fixture = try loadFixture()
        try EvidencePlaybackValidator.validate(fixture.evidencePlayback)
        XCTAssertEqual(fixture.evidencePlayback.map(\.kind), [
            .label, .screenshot, .narration, .transcript, .gap, .coachInteraction,
        ])
        XCTAssertEqual(
            fixture.evidencePlayback.first(where: { $0.kind == .gap })?.gapReason,
            "screen capture intentionally paused")

        var invalid = fixture.evidencePlayback
        invalid[4].gapReason = nil
        XCTAssertThrowsError(try EvidencePlaybackValidator.validate(invalid))
    }

    func testServerDecisionAndReceiptDecodeWithoutSemanticLoss() async throws {
        let root = try JSONSerialization.jsonObject(with: fixtureData()) as! [String: Any]
        let decisionData = try JSONSerialization.data(withJSONObject: root["decision"]!)
        let decisionDocument = try GuidedReplayDecisionDocument(serverData: decisionData)
        XCTAssertEqual(
            try JSONDecoder().decode(JazzArchiveJSONValue.self, from: decisionData),
            try JSONDecoder().decode(
                JazzArchiveJSONValue.self, from: decisionDocument.canonicalData))

        let receipts = root["priorReceipts"] as! [Any]
        let receiptData = try JSONSerialization.data(withJSONObject: receipts[0])
        let receiptDocument = try GuidedExecutionReceiptDocument(serverData: receiptData)
        XCTAssertEqual(
            try JSONDecoder().decode(JazzArchiveJSONValue.self, from: receiptData),
            try JSONDecoder().decode(
                JazzArchiveJSONValue.self, from: receiptDocument.canonicalData))

        let journalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-lossless-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let journal = GuidedExecutionReceiptJournal(
            url: journalRoot.appendingPathComponent("receipts.ndjson"))
        let appended = try await journal.appendServerReceipt(receiptData)
        let storedDocuments = try await journal.documents()
        XCTAssertTrue(appended)
        XCTAssertEqual(storedDocuments.map(\.canonicalData), [receiptDocument.canonicalData])

        var drifted = root["decision"] as! [String: Any]
        drifted["futureServerAuthority"] = ["mustNotDisappear": true]
        var driftedMaterial = drifted
        driftedMaterial.removeValue(forKey: "decisionId")
        driftedMaterial.removeValue(forKey: "contentDigest")
        let driftedMaterialData = try JSONSerialization.data(withJSONObject: driftedMaterial)
        let driftedJSON = try JSONDecoder().decode(
            JazzArchiveJSONValue.self, from: driftedMaterialData)
        let driftedDigest = "sha256:" + JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(driftedJSON))
        drifted["contentDigest"] = driftedDigest
        drifted["decisionId"] = "grd_" + String(driftedDigest.dropFirst(7).prefix(32))
        let driftedData = try JSONSerialization.data(withJSONObject: drifted)
        let driftedDocument = try GuidedReplayDecisionDocument(serverData: driftedData)
        XCTAssertEqual(driftedDocument.rawData, driftedData)
        let retained = try JSONDecoder().decode(
            JazzArchiveJSONValue.self, from: driftedDocument.canonicalData)
        guard case let .object(retainedObject) = retained else {
            return XCTFail("canonical server decision is not an object")
        }
        XCTAssertEqual(
            retainedObject["futureServerAuthority"],
            .object(["mustNotDisappear": .bool(true)]))
    }

    private func authorize(
        _ fixture: GuidedExecutionFixture,
        decision: GuidedReplayDecision? = nil,
        approvedRunbook: GuidedApprovedRunbookPin? = nil,
        runtime: GuidedRuntimeSnapshot? = nil,
        priorReceipts: [GuidedExecutionReceipt]? = nil
    ) throws -> GuidedActionPermit {
        try GuidedExecutionValidator.authorize(
            decision: decision ?? fixture.decision,
            approvedRunbook: approvedRunbook ?? fixture.approvedRunbook,
            runtime: runtime ?? fixture.runtime,
            priorReceipts: priorReceipts ?? fixture.priorReceipts)
    }

    private func lifecycleDocuments(
        _ fixture: GuidedExecutionFixture,
        proof: String
    ) throws -> (
        decision: GuidedReplayDecisionDocument,
        claim: GuidedExecutionClaimDocument,
        start: GuidedExecutionStartReceiptDocument
    ) {
        let root = try JSONSerialization.jsonObject(with: fixtureData()) as! [String: Any]
        let decisionObject = root["decision"] as! [String: Any]
        let decisionData = try JSONSerialization.data(withJSONObject: decisionObject)
        let step = decisionObject["authorizedStep"] as! [String: Any]
        let request = decisionObject["request"] as! [String: Any]
        let claimData = try addressedArtifact(
            [
                "artifactType": "executionClaim",
                "schemaVersion": "1",
                "claimRequestId": "desktop-claim-request-stable",
                "claimProofDigest": try guidedClaimProofDigest(proof),
                "decisionId": decisionObject["decisionId"]!,
                "decisionContentDigest": decisionObject["contentDigest"]!,
                "runbook": decisionObject["runbook"]!,
                "executionId": request["executionId"]!,
                "variantRef": step["variantRef"]!,
                "stepId": step["stepId"]!,
                "logicalOperationKey": decisionObject["logicalOperationKey"]!,
                "attemptNumber": decisionObject["attemptNumber"]!,
                "operatorId": request["operatorId"]!,
                "replayHostId": "macos-test-host",
                "claimedAt": "2026-07-23T08:59:55Z",
                "leaseExpiresAt": "2026-07-23T09:00:20Z",
                "state": "claimed",
            ],
            idField: "claimId",
            prefix: "gec_")
        let claim = try JSONSerialization.jsonObject(with: claimData) as! [String: Any]
        let startData = try addressedArtifact(
            [
                "artifactType": "executionStartReceipt",
                "schemaVersion": "1",
                "startRequestId": "desktop-start-request-stable",
                "claimId": claim["claimId"]!,
                "claimContentDigest": claim["contentDigest"]!,
                "decisionId": decisionObject["decisionId"]!,
                "decisionContentDigest": decisionObject["contentDigest"]!,
                "runbook": decisionObject["runbook"]!,
                "executionId": request["executionId"]!,
                "variantRef": step["variantRef"]!,
                "stepId": step["stepId"]!,
                "logicalOperationKey": decisionObject["logicalOperationKey"]!,
                "attemptNumber": decisionObject["attemptNumber"]!,
                "operatorId": request["operatorId"]!,
                "replayHostId": "macos-test-host",
                "startedAt": "2026-07-23T09:00:00Z",
                "authorityDecision": decisionObject,
            ],
            idField: "startReceiptId",
            prefix: "ges_")
        return (
            try GuidedReplayDecisionDocument(serverData: decisionData),
            try GuidedExecutionClaimDocument(serverData: claimData),
            try GuidedExecutionStartReceiptDocument(serverData: startData))
    }

    private func addressedArtifact(
        _ material: [String: Any],
        idField: String,
        prefix: String
    ) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: material)
        let value = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: data)
        let digest = "sha256:" + JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(value))
        var artifact = material
        artifact["contentDigest"] = digest
        artifact[idField] = prefix + String(digest.dropFirst(7).prefix(32))
        return try JSONSerialization.data(withJSONObject: artifact)
    }

    private func loadFixture() throws -> GuidedExecutionFixture {
        try JSONDecoder().decode(GuidedExecutionFixture.self, from: fixtureData())
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
