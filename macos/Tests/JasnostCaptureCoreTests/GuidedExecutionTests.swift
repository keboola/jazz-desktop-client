import Foundation
import XCTest

@testable import JasnostCaptureCore

final class GuidedExecutionTests: XCTestCase {
    func testLaunchPacketImporterAcceptsProductionEnvelopeAndRejectsUnknownFields() throws {
        let fixture = try loadFixture()

        let source = try JSONDecoder().decode(
            JazzArchiveJSONValue.self, from: fixtureData())
        guard case var .object(root) = source else {
            return XCTFail("fixture root is not an object")
        }
        root["protocol"] = .string("dev.jazz.guided-execution-launch")
        root.removeValue(forKey: "evidencePlayback")
        root.removeValue(forKey: "expectedPermit")
        guard case let .object(decision)? = root["decision"],
            case let .object(request)? = decision["request"],
            case let .object(fixtureRuntime)? = root["runtime"],
            let observedAt = fixtureRuntime["observedAt"],
            let operatorId = request["operatorId"],
            let capabilities = request["capabilities"],
            let preconditions = request["preconditions"],
            let locatorResolution = request["locatorResolution"],
            let applicationObservations = request["applicationObservations"],
            let businessObjectInputs = request["businessObjectInputs"]
        else {
            return XCTFail("fixture does not contain a complete launch seed")
        }
        root["runtime"] = .object([
            "observedAt": observedAt,
            "operatorId": operatorId,
            "capabilities": capabilities,
            "preconditions": preconditions,
            "locatorResolution": locatorResolution,
            "applicationObservations": applicationObservations,
            "businessObjectInputs": businessObjectInputs,
        ])

        let launchData = try JazzArchiveCanonicalJSON.encode(
            JazzArchiveJSONValue.object(root))
        let packet = try GuidedExecutionLaunchPacketImporter.decode(launchData)
        XCTAssertEqual(packet.approvedRunbook, fixture.approvedRunbook)
        XCTAssertEqual(packet.decisionDocument.decision, fixture.decision)
        XCTAssertEqual(packet.priorReceipts, fixture.priorReceipts)
        XCTAssertEqual(
            packet.runtime.locatorResolution,
            try XCTUnwrap(fixture.decision.request.locatorResolution))
        XCTAssertNil(packet.runtime.userConfirmation)
        let refreshObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    GuidedReplayRefreshRuntime(
                        requestedAt: fixture.runtime.observedAt,
                        capabilities: fixture.runtime.capabilities,
                        locatorResolution: fixture.runtime.locatorResolution,
                        applicationObservations:
                            fixture.runtime.applicationObservations)))
                as? [String: Any])
        XCTAssertEqual(
            Set(refreshObject.keys),
            Set([
                "requestedAt",
                "capabilities",
                "locatorResolution",
                "applicationObservations",
            ]))
        XCTAssertEqual(refreshObject["requestedAt"] as? String, fixture.runtime.observedAt)
        XCTAssertNil(refreshObject["businessObjectInputs"])
        XCTAssertNil(refreshObject["operatorId"])
        XCTAssertNil(refreshObject["userConfirmation"])

        root["unexpected"] = .string("must fail closed")
        XCTAssertThrowsError(
            try GuidedExecutionLaunchPacketImporter.decode(
                JazzArchiveCanonicalJSON.encode(
                    JazzArchiveJSONValue.object(root)))
        ) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .invalidField("guided execution launch shape"))
        }
    }

    func testCurrentProcessExecutionAndPolicyAuthorityDecodeWithoutSemanticLoss() throws {
        let executionReference = try JSONDecoder().decode(
            GuidedProcessExecutionReference.self,
            from: Data(
                """
                {
                  "executionId": "pex_018f89e7-de91-7040-94d1-9f00244c7636",
                  "bindingId": "peb_11111111111111111111111111111111",
                  "bindingContentDigest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
                  "businessTransactionKey": "btx_3333333333333333333333333333333333333333333333333333333333333333"
                }
                """.utf8))
        XCTAssertEqual(
            executionReference.executionId,
            "pex_018f89e7-de91-7040-94d1-9f00244c7636")
        XCTAssertEqual(
            executionReference.businessTransactionKey,
            "btx_3333333333333333333333333333333333333333333333333333333333333333")

        let authority = try JSONDecoder().decode(
            GuidedReconciliationAuthority.self,
            from: Data(
                """
                {
                  "principalId": "process-owner",
                  "action": "replay.reconcile",
                  "scope": {
                    "companyId": "company",
                    "areaId": "finance",
                    "processId": "invoice"
                  },
                  "policyId": "policy-reconciliation",
                  "revision": "7",
                  "policyDigest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
                  "policySource": "governance-policy-store",
                  "resolvedAt": "2026-07-23T12:00:00Z",
                  "validFrom": "2026-07-23T11:00:00Z",
                  "validUntil": "2026-07-23T13:00:00Z",
                  "evidence": [{"kind": "assertion", "ref": "policy-reconciliation:7"}],
                  "authorityDigest": "sha256:5555555555555555555555555555555555555555555555555555555555555555"
                }
                """.utf8))
        XCTAssertNil(authority.authorizationSource)
        XCTAssertEqual(authority.policyId, "policy-reconciliation")
        XCTAssertEqual(authority.revision, "7")
        XCTAssertEqual(authority.validUntil, "2026-07-23T13:00:00Z")
    }

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

    func testStartAcceptsFreshContentAddressedAuthorityForSameImmutableOperation() throws {
        let fixture = try loadFixture()
        let proof = String(repeating: "fresh-start-authority-proof-", count: 2)
        let documents = try lifecycleDocuments(
            fixture,
            proof: proof,
            freshStartAuthority: true)
        let authority = documents.start.startReceipt.authorityDecision

        XCTAssertNotEqual(authority.decisionId, documents.decision.decision.decisionId)
        XCTAssertNotEqual(
            authority.contentDigest,
            documents.decision.decision.contentDigest)
        XCTAssertGreaterThan(
            try XCTUnwrap(Timestamps.parse(authority.evaluatedAt)),
            try XCTUnwrap(Timestamps.parse(documents.decision.decision.evaluatedAt)))
        XCTAssertNoThrow(
            try GuidedExecutionValidator.validateStartReceipt(
                documents.start,
                for: documents.decision,
                claimDocument: documents.claim,
                expectedRequestId: "desktop-start-request-stable"))
        let permit = try GuidedExecutionValidator.authorizeStart(
            decisionDocument: documents.decision,
            claimDocument: documents.claim,
            startReceiptDocument: documents.start,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        XCTAssertEqual(permit.decisionId, documents.decision.decision.decisionId)
        XCTAssertEqual(
            permit.decisionContentDigest,
            documents.decision.decision.contentDigest)

        // Readdress both nested and outer artifacts to model a server-shaped, internally valid
        // response whose fresh authority changes one immutable operation field.
        var startObject = try JSONSerialization.jsonObject(
            with: documents.start.rawData) as! [String: Any]
        var forgedAuthority = startObject["authorityDecision"] as! [String: Any]
        forgedAuthority["logicalOperationKey"] = "forged-logical-operation"
        let readdressedAuthority = try addressedArtifact(
            forgedAuthority.filter {
                !["decisionId", "contentDigest"].contains($0.key)
            },
            idField: "decisionId",
            prefix: "grd_")
        startObject["authorityDecision"] = try JSONSerialization.jsonObject(
            with: readdressedAuthority)
        let readdressedStart = try addressedArtifact(
            startObject.filter {
                !["startReceiptId", "contentDigest"].contains($0.key)
            },
            idField: "startReceiptId",
            prefix: "ges_")
        let forgedDocument = try GuidedExecutionStartReceiptDocument(
            serverData: readdressedStart)
        XCTAssertThrowsError(
            try GuidedExecutionValidator.validateStartReceipt(
                forgedDocument,
                for: documents.decision,
                claimDocument: documents.claim,
                expectedRequestId: "desktop-start-request-stable")
        ) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .startReceiptBindingMismatch)
        }

        for field in ["locator", "businessObject", "capability"] {
            let tamperedData = try readdressStart(
                documents.start.rawData
            ) { request in
                switch field {
                case "locator":
                    var locator = request["locatorResolution"] as! [String: Any]
                    locator["locatorId"] = "loc_server-retargeted"
                    request["locatorResolution"] = locator
                case "businessObject":
                    var inputs = request["businessObjectInputs"] as! [[String: Any]]
                    inputs[0]["externalId"] = "server-retargeted-object"
                    request["businessObjectInputs"] = inputs
                default:
                    var capabilities = request["capabilities"] as! [[String: Any]]
                    capabilities[0]["version"] = "server-retargeted-version"
                    request["capabilities"] = capabilities
                }
            }
            let tamperedDocument = try GuidedExecutionStartReceiptDocument(
                serverData: tamperedData)
            XCTAssertThrowsError(
                try GuidedExecutionValidator.validateStartReceipt(
                    tamperedDocument,
                    for: documents.decision,
                    claimDocument: documents.claim,
                    expectedRequestId: "desktop-start-request-stable"),
                "fresh START authority changed \(field)"
            ) {
                XCTAssertEqual(
                    $0 as? GuidedExecutionError,
                    .startReceiptBindingMismatch)
            }
        }
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

        var boundaryExpired = fixture.runtime
        boundaryExpired.observedAt = "2026-07-23T09:01:50.000000Z"
        XCTAssertThrowsError(try authorize(fixture, runtime: boundaryExpired)) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .staleObservation("decision.evaluatedAt"))
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

    func testTrustedRuntimePinsRejectCanonicallyEquivalentUnicodeSubstitution() throws {
        let fixture = try loadFixture()

        var externalIdDecision = fixture.decision
        var externalIdRuntime = fixture.runtime
        externalIdDecision.trustedAnchorPins[0].object.externalId = "INV-café"
        externalIdRuntime.businessObjectInputs[0].externalId = "INV-cafe\u{301}"
        XCTAssertThrowsError(try authorize(
            fixture,
            decision: externalIdDecision,
            runtime: externalIdRuntime)
        ) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .businessObjectUnverified("invoice"))
        }

        var applicationDecision = fixture.decision
        var applicationRuntime = fixture.runtime
        applicationDecision.trustedRuntimeContext
            .applicationObservations[0].evidence[0].ref = "runtime:café"
        applicationRuntime.applicationObservations[0].evidence[0].ref =
            "runtime:cafe\u{301}"
        XCTAssertThrowsError(try authorize(
            fixture,
            decision: applicationDecision,
            runtime: applicationRuntime)
        ) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .incompatibleApplication("com.acme.erp"))
        }

        var locatorDecision = fixture.decision
        var locatorRuntime = fixture.runtime
        locatorDecision.trustedRuntimeContext
            .locatorResolution?.evidence[0].ref = "runtime:café"
        locatorRuntime.locatorResolution.evidence[0].ref = "runtime:cafe\u{301}"
        XCTAssertThrowsError(try authorize(
            fixture,
            decision: locatorDecision,
            runtime: locatorRuntime)
        ) {
            XCTAssertEqual(
                $0 as? GuidedExecutionError,
                .ambiguousLocator)
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

    func testAggregateApprovalMirrorsCurrentHeadsQuorumAndSelectionOrder() throws {
        let fixture = try loadFixture()
        let aggregate = aggregateApprovalDecision(fixture)

        let prepared = try GuidedExecutionValidator.prepare(
            decision: aggregate,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        XCTAssertEqual(prepared.decisionId, aggregate.decisionId)

        var perExecution = aggregate
        perExecution.authorizedStep!.approval.policy = .perExecution
        for index in perExecution.request.approvals.indices {
            perExecution.request.approvals[index].approvalScopeKey =
                "execution:finance-manager"
        }
        // A per-execution approval may have been recorded against an earlier step. Its current
        // authority is the exact execution:<approverRole> scope, not a forged current step ID.
        perExecution.request.approvals[0].stepId =
            "rbs_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        XCTAssertNoThrow(try GuidedExecutionValidator.prepare(
            decision: perExecution,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts))

        var reversedSelection = aggregate
        reversedSelection.approvalEvaluation!.selectedApprovalIds.reverse()
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: reversedSelection,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var missingCurrentHead = aggregate
        missingCurrentHead.approvalEvaluation!.currentHeadPins.removeLast()
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: missingCurrentHead,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }
    }

    func testAggregateApprovalFailsClosedOnPartialAuthorityVetoAndAmbiguousHead() throws {
        let fixture = try loadFixture()
        let aggregate = aggregateApprovalDecision(fixture)

        var missingEvaluation = aggregate
        missingEvaluation.approvalEvaluation = nil
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: missingEvaluation,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var vetoed = aggregate
        vetoed.request.approvals[1].decision = .denied
        vetoed.approvalEvaluation!.currentHeadPins[1].decision = .denied
        vetoed.approvalEvaluation!.selectedApprovalIds = [
            vetoed.request.approvals[0].approvalId
        ]
        vetoed.approvalEvaluation!.vetoApprovalIds = [
            vetoed.request.approvals[1].approvalId
        ]
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: vetoed,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var ambiguous = aggregate
        var duplicateHead = ambiguous.request.approvals[0]
        duplicateHead.approvalId = "gra_cccccccccccccccccccccccccccccccc"
        ambiguous.request.approvals.append(duplicateHead)
        var duplicateState = ambiguous.trustedApprovalStates[0]
        duplicateState.approvalId = duplicateHead.approvalId
        ambiguous.trustedApprovalStates.append(duplicateState)
        ambiguous.approvalEvaluation!.currentHeadPins.insert(
            GuidedApprovalHeadPin(
                approverId: duplicateHead.approverId,
                approvalId: duplicateHead.approvalId,
                decision: .approved),
            at: 1)
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: ambiguous,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }
    }

    func testAggregateApprovalRejectsWrongSemanticsScopePolicyAndExpiry() throws {
        let fixture = try loadFixture()
        let aggregate = aggregateApprovalDecision(fixture)

        var wrongSemantics = aggregate
        wrongSemantics.trustedApprovalPolicy!.aggregation!.denySemantics = "denyIgnored"
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: wrongSemantics,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var wrongScope = aggregate
        wrongScope.request.approvals[0].approvalScopeKey =
            "execution:\(wrongScope.request.executionId)"
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: wrongScope,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var stalePolicy = aggregate
        stalePolicy.request.approvals[0].approvalPolicy.revision = "old"
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: stalePolicy,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
            XCTAssertEqual($0 as? GuidedExecutionError, .approvalMissing)
        }

        var expired = aggregate
        expired.request.approvals[1].expiresAt = "2026-07-23T08:59:59Z"
        XCTAssertThrowsError(try GuidedExecutionValidator.prepare(
            decision: expired,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)) {
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

        var currentHandoff = fixture.priorReceipts[0]
        currentHandoff.handoffOutcome.nextAssigneeId = "substitute-bob"
        currentHandoff.handoffOutcome.eligibleRole = "backup-operator"
        XCTAssertThrowsError(try authorize(fixture, priorReceipts: [currentHandoff])) {
            XCTAssertEqual($0 as? GuidedExecutionError, .startReceiptRequired)
        }

        var wrongAssignee = currentHandoff
        wrongAssignee.handoffOutcome.nextAssigneeId = "different-operator"
        XCTAssertThrowsError(try authorize(fixture, priorReceipts: [wrongAssignee])) {
            XCTAssertEqual($0 as? GuidedExecutionError, .handoffNotAccepted)
        }

        var priorOperatorCannotIgnoreAssignment = currentHandoff
        priorOperatorCannotIgnoreAssignment.operatorId = "substitute-bob"
        priorOperatorCannotIgnoreAssignment.handoffOutcome.nextAssigneeId =
            "different-operator"
        XCTAssertThrowsError(
            try authorize(
                fixture,
                priorReceipts: [priorOperatorCannotIgnoreAssignment])
        ) {
            XCTAssertEqual($0 as? GuidedExecutionError, .handoffNotAccepted)
        }

        var partialAssignment = currentHandoff
        partialAssignment.handoffOutcome.eligibleRole = nil
        XCTAssertThrowsError(try authorize(fixture, priorReceipts: [partialAssignment])) {
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

        var currentReceipt = receipts[0] as! [String: Any]
        var currentHandoff = currentReceipt["handoffOutcome"] as! [String: Any]
        currentHandoff["nextAssigneeId"] = "substitute-bob"
        currentHandoff["eligibleRole"] = "backup-operator"
        currentReceipt["handoffOutcome"] = currentHandoff
        let currentReceiptData = try JSONSerialization.data(
            withJSONObject: currentReceipt)
        let currentTypedReceipt = try JSONDecoder().decode(
            GuidedExecutionReceipt.self,
            from: currentReceiptData)
        XCTAssertEqual(
            currentTypedReceipt.handoffOutcome.nextAssigneeId,
            "substitute-bob")
        XCTAssertEqual(
            currentTypedReceipt.handoffOutcome.eligibleRole,
            "backup-operator")
        let roundTrippedReceiptData = try JSONEncoder().encode(currentTypedReceipt)
        let roundTrippedReceipt = try JSONDecoder().decode(
            GuidedExecutionReceipt.self,
            from: roundTrippedReceiptData)
        XCTAssertEqual(
            roundTrippedReceipt.handoffOutcome,
            currentTypedReceipt.handoffOutcome)

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
        proof: String,
        freshStartAuthority: Bool = false
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
        let authorityDecision: [String: Any]
        if freshStartAuthority {
            var authorityMaterial = decisionObject.filter {
                !["decisionId", "contentDigest"].contains($0.key)
            }
            authorityMaterial["evaluatedAt"] = "2026-07-23T08:59:59.500000Z"
            var trusted = authorityMaterial["trustedRuntimeContext"] as! [String: Any]
            trusted["resolvedAt"] = "2026-07-23T08:59:59.500000Z"
            authorityMaterial["trustedRuntimeContext"] = trusted
            let authorityData = try addressedArtifact(
                authorityMaterial,
                idField: "decisionId",
                prefix: "grd_")
            authorityDecision = try JSONSerialization.jsonObject(
                with: authorityData) as! [String: Any]
        } else {
            authorityDecision = decisionObject
        }
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
                "authorityDecision": authorityDecision,
            ],
            idField: "startReceiptId",
            prefix: "ges_")
        return (
            try GuidedReplayDecisionDocument(serverData: decisionData),
            try GuidedExecutionClaimDocument(serverData: claimData),
            try GuidedExecutionStartReceiptDocument(serverData: startData))
    }

    private func aggregateApprovalDecision(
        _ fixture: GuidedExecutionFixture
    ) -> GuidedReplayDecision {
        var decision = fixture.decision
        var policy = decision.request.approvals[0].approvalPolicy
        policy.aggregation = GuidedApprovalAggregation(
            approverIds: ["finance-manager-carol", "finance-manager-dana"],
            requiredApprovals: 2,
            denySemantics: "anyDenyVeto")

        var carol = decision.request.approvals[0]
        carol.approvalPolicy = policy
        var dana = carol
        dana.approvalId = "gra_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        dana.approverId = "finance-manager-dana"
        dana.decidedAt = "2026-07-23T08:58:30.000000Z"
        decision.request.approvals = [carol, dana]

        let carolState = decision.trustedApprovalStates[0]
        var danaState = carolState
        danaState.approvalId = dana.approvalId
        decision.trustedApprovalStates = [carolState, danaState]
        decision.trustedApprovalPolicy = policy
        decision.approvalEvaluation = GuidedApprovalEvaluation(
            currentHeadPins: [
                GuidedApprovalHeadPin(
                    approverId: carol.approverId,
                    approvalId: carol.approvalId,
                    decision: carol.decision),
                GuidedApprovalHeadPin(
                    approverId: dana.approverId,
                    approvalId: dana.approvalId,
                    decision: dana.decision),
            ],
            selectedApprovalIds: [carol.approvalId, dana.approvalId].sorted(),
            vetoApprovalIds: [])
        return decision
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

    private func readdressStart(
        _ source: Data,
        mutateAuthorityRequest: (inout [String: Any]) -> Void
    ) throws -> Data {
        var start = try JSONSerialization.jsonObject(with: source) as! [String: Any]
        var authority = start["authorityDecision"] as! [String: Any]
        var request = authority["request"] as! [String: Any]
        mutateAuthorityRequest(&request)
        authority["request"] = request
        authority["requestDigest"] = try canonicalDigest(request)

        let contextKeys = [
            "capabilities",
            "preconditions",
            "applicationObservations",
            "businessObjectInputs",
            "locatorResolution",
        ]
        let context = Dictionary(
            uniqueKeysWithValues: contextKeys.compactMap { key in
                request[key].map { (key, $0) }
            })
        var trusted = authority["trustedRuntimeContext"] as! [String: Any]
        trusted["requestContextDigest"] = try canonicalDigest(context)
        authority["trustedRuntimeContext"] = trusted
        let authorityData = try addressedArtifact(
            authority.filter {
                !["decisionId", "contentDigest"].contains($0.key)
            },
            idField: "decisionId",
            prefix: "grd_")
        start["authorityDecision"] = try JSONSerialization.jsonObject(
            with: authorityData)
        return try addressedArtifact(
            start.filter {
                !["startReceiptId", "contentDigest"].contains($0.key)
            },
            idField: "startReceiptId",
            prefix: "ges_")
    }

    private func canonicalDigest(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        let json = try JSONDecoder().decode(
            JazzArchiveJSONValue.self,
            from: data)
        return "sha256:"
            + JazzArchiveDigest.sha256Hex(
                try JazzArchiveCanonicalJSON.encode(json))
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
