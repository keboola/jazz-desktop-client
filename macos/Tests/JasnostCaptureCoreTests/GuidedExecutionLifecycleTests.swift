import Foundation
import XCTest

@testable import JasnostCaptureCore

final class GuidedExecutionLifecycleTests: XCTestCase {
    func testExactDecisionRecoveryIsNotPersistedBeforeLiveValidation() async throws {
        let fixture = try loadFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-decision-recovery-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let store = GuidedExecutionAttemptStore(
            url: root.appendingPathComponent("attempt.json"))
        let host = GuidedExecutionHost(
            transport: FakeGuidedExecutionTransport(
                decisionData: try decisionBytes()),
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-recovery")

        let recovered = try await host.recoverDecision(
            scope: fixture.approvedRunbook.scope,
            decisionId: fixture.decision.decisionId)
        XCTAssertEqual(recovered.decision, fixture.decision)
        let beforeValidation = try await store.load()
        XCTAssertNil(beforeValidation)

        var expiredRuntime = fixture.runtime
        expiredRuntime.observedAt = "2026-07-23T09:01:50.000000Z"
        do {
            _ = try await host.persistPrepared(
                recovered,
                approvedRunbook: fixture.approvedRunbook,
                runtime: expiredRuntime,
                priorReceipts: fixture.priorReceipts)
            XCTFail("expired authority was persisted before refresh")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .staleObservation("decision.evaluatedAt"))
        }
        let afterRejectedValidation = try await store.load()
        XCTAssertNil(afterRejectedValidation)

        let prepared = try await host.persistPrepared(
            recovered,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        XCTAssertEqual(prepared.decisionId, fixture.decision.decisionId)
        let afterValidation = try await store.load()
        XCTAssertEqual(
            afterValidation?.decisionServerData,
            recovered.rawData)
    }

    func testRefreshResponseIsExactlyBoundToFrozenRequestAndPredecessor() throws {
        let fixture = try loadFixture()
        let predecessor = try refreshPredecessor()
        var runtimeSeed = fixture.runtime
        runtimeSeed.userConfirmation = nil
        let runtime = refreshedNativeRuntime(from: runtimeSeed)
        let intent = try GuidedExecutionRefreshIntent(
            refreshRequestId: "grq_019b1876-6f80-7000-8000-000000000042",
            scope: fixture.approvedRunbook.scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: runtime)
        let successor = try makeRefreshSuccessor(
            predecessorData: predecessor.rawData,
            runtime: runtime,
            status: .ready)
        let validData = try makeRefreshResponse(
            intent: intent,
            successorData: successor)
        let valid = try GuidedExecutionRefreshResponseDocument(serverData: validData)
        XCTAssertNoThrow(try valid.validate(intent: intent, predecessor: predecessor))

        var envelope = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        for (field, replacement) in [
            (
                "refreshRequestId",
                "grq_019b1876-6f80-7000-8000-000000000043"
            ),
            (
                "refreshRequestDigest",
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            ),
            ("predecessorDecisionId", "grd_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            (
                "predecessorDecisionContentDigest",
                "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            ),
        ] {
            var tampered = envelope
            tampered[field] = replacement
            let document = try GuidedExecutionRefreshResponseDocument(
                serverData: JSONSerialization.data(withJSONObject: tampered))
            XCTAssertThrowsError(
                try document.validate(intent: intent, predecessor: predecessor)
            ) {
                XCTAssertEqual($0 as? GuidedExecutionError, .refreshBindingMismatch)
            }
        }

        var differentRuntime = runtime
        differentRuntime.requestedAt = "2026-07-23T09:01:01.000000Z"
        differentRuntime.locatorResolution.resolvedAt = differentRuntime.requestedAt
        for index in differentRuntime.applicationObservations.indices {
            differentRuntime.applicationObservations[index].observedAt =
                differentRuntime.requestedAt
        }
        envelope["decision"] = try JSONSerialization.jsonObject(
            with: makeRefreshSuccessor(
                predecessorData: predecessor.rawData,
                runtime: differentRuntime,
                status: .ready))
        let wrongRuntime = try GuidedExecutionRefreshResponseDocument(
            serverData: JSONSerialization.data(withJSONObject: envelope))
        XCTAssertThrowsError(
            try wrongRuntime.validate(intent: intent, predecessor: predecessor)
        ) {
            XCTAssertEqual($0 as? GuidedExecutionError, .refreshBindingMismatch)
        }
    }

    func testRefreshCanonicalizesRuntimeBeforeDigestAndAcceptsServerOrder() throws {
        let fixture = try loadFixture()
        var secondApplication = try XCTUnwrap(
            fixture.runtime.applicationObservations.first)
        secondApplication.applicationId = "com.acme.accounting"
        secondApplication.environment = "staging"
        let predecessor = try refreshPredecessor(
            additionalApplication: secondApplication)
        var runtimeSeed = fixture.runtime
        runtimeSeed.userConfirmation = nil
        runtimeSeed.applicationObservations.append(secondApplication)
        var canonicalInput = refreshedNativeRuntime(from: runtimeSeed)
        let composedCapabilityId = "unicode-é"
        let decomposedCapabilityId = "unicode-e\u{301}"
        canonicalInput.capabilities.append(GuidedCapability(
            id: composedCapabilityId,
            version: "1"))
        canonicalInput.capabilities.append(GuidedCapability(
            id: decomposedCapabilityId,
            version: "1"))
        canonicalInput.locatorResolution.evidence[0].confidence = 0.9
        canonicalInput.locatorResolution.evidence.append(GuidedEvidenceReference(
            kind: .event,
            ref: "runtime:locator:ax-tree",
            confidence: 0.7))
        canonicalInput.locatorResolution.evidence.append(GuidedEvidenceReference(
            kind: .assertion,
            ref: "runtime:účet/Δ",
            confidence: 1.0))
        let composedEvidenceRef = "runtime:café"
        let decomposedEvidenceRef = "runtime:cafe\u{301}"
        canonicalInput.locatorResolution.evidence.append(GuidedEvidenceReference(
            kind: .assertion,
            ref: composedEvidenceRef,
            confidence: 0.5))
        canonicalInput.locatorResolution.evidence.append(GuidedEvidenceReference(
            kind: .assertion,
            ref: decomposedEvidenceRef,
            confidence: 0.4))
        for index in canonicalInput.applicationObservations.indices {
            canonicalInput.applicationObservations[index].evidence[0].confidence = 0.8
            canonicalInput.applicationObservations[index].evidence.append(
                GuidedEvidenceReference(
                    kind: .screenshot,
                    ref: "runtime:application:\(index)",
                    confidence: 0.6))
        }
        canonicalInput = try canonicalInput.canonicalized()

        let pythonStripBoundary = "\u{001C}\u{2007}\u{3000}"
        var reversedInput = canonicalInput
        reversedInput.capabilities.reverse()
        for index in reversedInput.capabilities.indices {
            reversedInput.capabilities[index].id =
                "\(pythonStripBoundary)\(reversedInput.capabilities[index].id)\(pythonStripBoundary)"
            reversedInput.capabilities[index].version =
                "\n\(reversedInput.capabilities[index].version)\t"
        }
        reversedInput.applicationObservations.reverse()
        reversedInput.requestedAt =
            "\(pythonStripBoundary)2026-07-23T11:01:00.0000007+02:00\(pythonStripBoundary)"
        reversedInput.locatorResolution.stepId =
            " \(reversedInput.locatorResolution.stepId) "
        reversedInput.locatorResolution.locatorId =
            " \(reversedInput.locatorResolution.locatorId) "
        reversedInput.locatorResolution.applicationId =
            " \(reversedInput.locatorResolution.applicationId) "
        reversedInput.locatorResolution.resolvedAt =
            "2026-07-23T11:01:00.0000007+02:00"
        var lowerLocatorEvidence = reversedInput.locatorResolution.evidence[0]
        lowerLocatorEvidence.confidence = 0.1
        reversedInput.locatorResolution.evidence.append(lowerLocatorEvidence)
        reversedInput.locatorResolution.evidence.reverse()
        for index in reversedInput.locatorResolution.evidence.indices {
            reversedInput.locatorResolution.evidence[index].ref =
                " \(reversedInput.locatorResolution.evidence[index].ref) "
        }
        for index in reversedInput.applicationObservations.indices {
            reversedInput.applicationObservations[index].applicationId =
                " \(reversedInput.applicationObservations[index].applicationId) "
            reversedInput.applicationObservations[index].observedVersion =
                " \(reversedInput.applicationObservations[index].observedVersion) "
            reversedInput.applicationObservations[index].environment =
                reversedInput.applicationObservations[index].environment.map {
                    " \($0) "
                }
            reversedInput.applicationObservations[index].matchedVersionConstraint =
                " \(reversedInput.applicationObservations[index].matchedVersionConstraint) "
            reversedInput.applicationObservations[index].resolver.id =
                " \(reversedInput.applicationObservations[index].resolver.id) "
            reversedInput.applicationObservations[index].resolver.version =
                " \(reversedInput.applicationObservations[index].resolver.version) "
            reversedInput.applicationObservations[index].observedAt =
                "2026-07-23T11:01:00.0000007+02:00"
            var lowerEvidence =
                reversedInput.applicationObservations[index].evidence[0]
            lowerEvidence.confidence = 0.1
            reversedInput.applicationObservations[index].evidence.append(
                lowerEvidence)
            reversedInput.applicationObservations[index].evidence.reverse()
            for evidenceIndex in
                reversedInput.applicationObservations[index].evidence.indices
            {
                reversedInput.applicationObservations[index]
                    .evidence[evidenceIndex].ref =
                    " \(reversedInput.applicationObservations[index].evidence[evidenceIndex].ref) "
            }
        }
        let requestId = "grq_019b1876-6f80-7000-8000-000000000048"

        let canonicalIntent = try GuidedExecutionRefreshIntent(
            refreshRequestId: requestId,
            scope: fixture.approvedRunbook.scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: canonicalInput)
        let reversedIntent = try GuidedExecutionRefreshIntent(
            refreshRequestId: requestId,
            scope: fixture.approvedRunbook.scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: reversedInput)

        XCTAssertEqual(reversedIntent.runtime, canonicalIntent.runtime)
        XCTAssertEqual(
            reversedIntent.refreshRequestDigest,
            canonicalIntent.refreshRequestDigest)
        XCTAssertEqual(
            canonicalIntent.refreshRequestDigest,
            "sha256:9c8b1e71ea0f66e54a835a44ae57a40c18b95900de359b8756ad58340e6cf820")
        var internalWhitespaceInput = canonicalInput
        let internalWhitespaceId = "runtime\u{2007}capability"
        internalWhitespaceInput.capabilities.append(
            GuidedCapability(id: internalWhitespaceId, version: "1"))
        let internalWhitespaceRuntime = try internalWhitespaceInput.canonicalized()
        XCTAssertTrue(internalWhitespaceRuntime.capabilities.contains {
            Data($0.id.utf8) == Data(internalWhitespaceId.utf8)
        })
        XCTAssertEqual(
            reversedIntent.runtime.requestedAt,
            "2026-07-23T09:01:00.000000Z")
        XCTAssertEqual(
            reversedIntent.runtime.locatorResolution.evidence.first(where: {
                $0.ref == "runtime:účet/Δ"
            })?.confidence,
            1.0)
        let unicodeCapabilityIds = reversedIntent.runtime.capabilities
            .map { Data($0.id.utf8) }
            .filter {
                $0 == Data(composedCapabilityId.utf8)
                    || $0 == Data(decomposedCapabilityId.utf8)
            }
        XCTAssertEqual(unicodeCapabilityIds, [
            Data(decomposedCapabilityId.utf8),
            Data(composedCapabilityId.utf8),
        ])
        let unicodeEvidenceRefs = reversedIntent.runtime.locatorResolution.evidence
            .map { Data($0.ref.utf8) }
            .filter {
                $0 == Data(composedEvidenceRef.utf8)
                    || $0 == Data(decomposedEvidenceRef.utf8)
            }
        XCTAssertEqual(unicodeEvidenceRefs, [
            Data(decomposedEvidenceRef.utf8),
            Data(composedEvidenceRef.utf8),
        ])
        let response = try GuidedExecutionRefreshResponseDocument(
            serverData: makeRefreshResponse(
                intent: reversedIntent,
                successorData: makeRefreshSuccessor(
                    predecessorData: predecessor.rawData,
                    runtime: canonicalIntent.runtime,
                    status: .ready)))
        XCTAssertNoThrow(
            try response.validate(
                intent: reversedIntent,
                predecessor: predecessor))

        var unicodeTamperedRuntime = canonicalIntent.runtime
        let composedUniqueRef = "runtime:účet/Δ"
        let decomposedUniqueRef = "runtime:u\u{301}čet/Δ"
        let unicodeEvidenceIndex = try XCTUnwrap(
            unicodeTamperedRuntime.locatorResolution.evidence.firstIndex {
                Data($0.ref.utf8) == Data(composedUniqueRef.utf8)
            })
        unicodeTamperedRuntime.locatorResolution.evidence[unicodeEvidenceIndex].ref =
            decomposedUniqueRef
        let unicodeTamperedResponse = try GuidedExecutionRefreshResponseDocument(
            serverData: makeRefreshResponse(
                intent: reversedIntent,
                successorData: makeRefreshSuccessor(
                    predecessorData: predecessor.rawData,
                    runtime: unicodeTamperedRuntime,
                    status: .ready)))
        XCTAssertThrowsError(
            try unicodeTamperedResponse.validate(
                intent: reversedIntent,
                predecessor: predecessor)
        ) {
            XCTAssertEqual($0 as? GuidedExecutionError, .refreshBindingMismatch)
        }

        var duplicateCapabilityRuntime = reversedInput
        duplicateCapabilityRuntime.capabilities.append(
            duplicateCapabilityRuntime.capabilities[0])
        XCTAssertThrowsError(try GuidedExecutionRefreshIntent(
            refreshRequestId: "grq_019b1876-6f80-7000-8000-000000000049",
            scope: fixture.approvedRunbook.scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: duplicateCapabilityRuntime))

        var lowercaseZuluRuntime = canonicalInput
        lowercaseZuluRuntime.requestedAt = "2026-07-23T09:01:00z"
        XCTAssertThrowsError(try lowercaseZuluRuntime.canonicalized())

        for invalidRequestId in [
            "grq_019b1876-6f80-4000-8000-000000000048",
            "grq_019B1876-6f80-7000-8000-000000000048",
            "grq_019b1876-6f80-7000-8000-000000000048-extra",
        ] {
            XCTAssertThrowsError(try GuidedExecutionRefreshIntent(
                refreshRequestId: invalidRequestId,
                scope: fixture.approvedRunbook.scope,
                operatorId: predecessor.decision.request.operatorId,
                predecessor: predecessor,
                runtime: canonicalInput)
            ) {
                XCTAssertEqual(
                    $0 as? GuidedExecutionError,
                    .invalidField("refreshRequestId"))
            }
        }

        var recoveredObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(canonicalIntent))
                as? [String: Any])
        recoveredObject["refreshRequestId"] =
            "grq_019b1876-6f80-4000-8000-000000000048"
        let recoveredInvalidIntent = try JSONDecoder().decode(
            GuidedExecutionRefreshIntent.self,
            from: JSONSerialization.data(withJSONObject: recoveredObject))
        XCTAssertThrowsError(
            try recoveredInvalidIntent.validate(predecessor: predecessor)
        ) {
            XCTAssertEqual($0 as? GuidedExecutionError, .refreshBindingMismatch)
        }
    }

    func testRefreshAcceptsFreshRuntimeOutcomesButKeepsImmutableTargetIdentity() throws {
        let fixture = try loadFixture()
        let predecessor = try refreshPredecessor()
        var runtimeSeed = fixture.runtime
        runtimeSeed.userConfirmation = nil

        var blockedRuntime = refreshedNativeRuntime(from: runtimeSeed)
        blockedRuntime.requestedAt = "2026-07-23T09:01:02.000000Z"
        blockedRuntime.capabilities = []
        blockedRuntime.locatorResolution.matchCount = 0
        blockedRuntime.locatorResolution.resolvedAt = blockedRuntime.requestedAt
        for index in blockedRuntime.applicationObservations.indices {
            blockedRuntime.applicationObservations[index].observedVersion = "99.0"
            blockedRuntime.applicationObservations[index].matchedVersionConstraint =
                "fresh-observation-did-not-match"
            blockedRuntime.applicationObservations[index].compatibility = .incompatible
            blockedRuntime.applicationObservations[index].resolver.version = "2"
            blockedRuntime.applicationObservations[index].observedAt =
                blockedRuntime.requestedAt
        }
        let blockedIntent = try GuidedExecutionRefreshIntent(
            refreshRequestId: "grq_019b1876-6f80-7000-8000-000000000044",
            scope: fixture.approvedRunbook.scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: blockedRuntime)
        let blocked = try GuidedExecutionRefreshResponseDocument(
            serverData: makeRefreshResponse(
                intent: blockedIntent,
                successorData: makeRefreshSuccessor(
                    predecessorData: predecessor.rawData,
                    runtime: blockedRuntime,
                    status: .blocked)))
        XCTAssertNoThrow(
            try blocked.validate(intent: blockedIntent, predecessor: predecessor))

        var missingApplicationRuntime = blockedRuntime
        missingApplicationRuntime.requestedAt = "2026-07-23T09:01:03.000000Z"
        missingApplicationRuntime.locatorResolution.resolvedAt =
            missingApplicationRuntime.requestedAt
        missingApplicationRuntime.applicationObservations = []
        let missingApplicationIntent = try GuidedExecutionRefreshIntent(
            refreshRequestId: "grq_019b1876-6f80-7000-8000-000000000045",
            scope: fixture.approvedRunbook.scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: missingApplicationRuntime)
        let missingApplication = try GuidedExecutionRefreshResponseDocument(
            serverData: makeRefreshResponse(
                intent: missingApplicationIntent,
                successorData: makeRefreshSuccessor(
                    predecessorData: predecessor.rawData,
                    runtime: missingApplicationRuntime,
                    status: .blocked)))
        XCTAssertNoThrow(
            try missingApplication.validate(
                intent: missingApplicationIntent,
                predecessor: predecessor))

        var readyRuntime = refreshedNativeRuntime(from: runtimeSeed)
        readyRuntime.requestedAt = "2026-07-23T09:01:04.000000Z"
        readyRuntime.locatorResolution.resolvedAt = readyRuntime.requestedAt
        for index in readyRuntime.applicationObservations.indices {
            readyRuntime.applicationObservations[index].observedVersion = "5.9"
            readyRuntime.applicationObservations[index].observedAt =
                readyRuntime.requestedAt
        }
        let readyIntent = try GuidedExecutionRefreshIntent(
            refreshRequestId: "grq_019b1876-6f80-7000-8000-000000000046",
            scope: fixture.approvedRunbook.scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: readyRuntime)
        let ready = try GuidedExecutionRefreshResponseDocument(
            serverData: makeRefreshResponse(
                intent: readyIntent,
                successorData: makeRefreshSuccessor(
                    predecessorData: predecessor.rawData,
                    runtime: readyRuntime,
                    status: .ready)))
        XCTAssertNoThrow(
            try ready.validate(intent: readyIntent, predecessor: predecessor))

        var differentTargetRuntime = blockedRuntime
        differentTargetRuntime.locatorResolution.locatorId += "-other"
        let differentTargetIntent = try GuidedExecutionRefreshIntent(
            refreshRequestId: "grq_019b1876-6f80-7000-8000-000000000047",
            scope: fixture.approvedRunbook.scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: differentTargetRuntime)
        let differentTarget = try GuidedExecutionRefreshResponseDocument(
            serverData: makeRefreshResponse(
                intent: differentTargetIntent,
                successorData: makeRefreshSuccessor(
                    predecessorData: predecessor.rawData,
                    runtime: differentTargetRuntime,
                    status: .blocked)))
        XCTAssertThrowsError(
            try differentTarget.validate(
                intent: differentTargetIntent,
                predecessor: predecessor)
        ) {
            XCTAssertEqual($0 as? GuidedExecutionError, .refreshBindingMismatch)
        }
    }

    func testLostRefreshResponseRelaunchRetriesFrozenIntentAndCommitsSuccessor()
        async throws
    {
        let fixture = try loadFixture()
        let predecessor = try refreshPredecessor(
            canonicalProcessExecution: true)
        let executionId = predecessor.decision.request.executionId
        let priorReceipts = fixture.priorReceipts.map { source in
            var receipt = source
            receipt.executionId = executionId
            return receipt
        }
        var runtimeSeed = fixture.runtime
        runtimeSeed.userConfirmation = nil
        let refreshRuntime = refreshedNativeRuntime(from: runtimeSeed)
        let transport = FakeGuidedExecutionTransport(
            decisionData: predecessor.rawData,
            refreshStatus: .ready)
        await transport.loseNextRefreshResponse()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-refresh-restart-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let attemptURL = root.appendingPathComponent("attempt.json")
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: GuidedExecutionAttemptStore(url: attemptURL),
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-refresh")

        do {
            _ = try await host.refreshDecision(
                predecessor: predecessor,
                approvedRunbook: fixture.approvedRunbook,
                runtimeSeed: runtimeSeed,
                priorReceipts: priorReceipts,
                runtime: refreshRuntime)
            XCTFail("the fake must lose the first committed refresh response")
        } catch {
            XCTAssertEqual(error as? FakeGuidedError, .unsupported)
        }
        let uncertainStore = GuidedExecutionAttemptStore(url: attemptURL)
        let uncertainRecord = try await uncertainStore.load()
        let uncertain = try XCTUnwrap(uncertainRecord)
        XCTAssertEqual(uncertain.version, 3)
        XCTAssertEqual(uncertain.phase, .refreshing)
        XCTAssertNotNil(uncertain.approvedRunbook)
        XCTAssertNotNil(uncertain.runtimeSeed)
        XCTAssertNotNil(uncertain.priorReceipts)
        XCTAssertNil(uncertain.refreshResponseServerData)
        let frozenRequestId = try XCTUnwrap(uncertain.refreshIntent?.refreshRequestId)

        let relaunched = GuidedExecutionHost(
            transport: transport,
            attemptStore: GuidedExecutionAttemptStore(url: attemptURL),
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-refresh")
        let recovered = try await relaunched.resumeRefresh()
        XCTAssertEqual(recovered.decisionDocument.decision.status, .ready)
        let requestIDs = await transport.refreshRequestIDs()
        XCTAssertEqual(requestIDs, [frozenRequestId, frozenRequestId])
        let runtimes = await transport.refreshRuntimes()
        XCTAssertEqual(runtimes, [refreshRuntime, refreshRuntime])

        let committedRecord = try await uncertainStore.load()
        let committed = try XCTUnwrap(committedRecord)
        XCTAssertEqual(committed.phase, .prepared)
        XCTAssertEqual(
            committed.decisionServerData,
            recovered.decisionDocument.rawData)
        XCTAssertEqual(
            committed.refreshResponseServerData,
            recovered.rawData)
        XCTAssertEqual(
            committed.runtimeSeed,
            try GuidedRuntimeSnapshot(
                replayRequest: recovered.decisionDocument.decision.request))

        var revalidatedRuntime = try XCTUnwrap(committed.runtimeSeed)
        let refreshedStepId = try XCTUnwrap(
            recovered.decisionDocument.decision.authorizedStep?.stepId)
        revalidatedRuntime.userConfirmation = GuidedUserConfirmation(
            confirmed: true,
            confirmedAt: revalidatedRuntime.observedAt,
            operatorId: recovered.decisionDocument.decision.request.operatorId,
            decisionId: recovered.decisionDocument.decision.decisionId,
            stepId: refreshedStepId)
        let revalidatedPreparation = try await relaunched.persistPrepared(
            recovered.decisionDocument,
            approvedRunbook: fixture.approvedRunbook,
            runtime: revalidatedRuntime,
            priorReceipts: priorReceipts)
        XCTAssertEqual(
            revalidatedPreparation.decisionId,
            recovered.decisionDocument.decision.decisionId)
        let recoveredClaim = try await relaunched.claim(
            claimProof: String(repeating: "recovered-refresh-proof-", count: 2))
        XCTAssertEqual(
            recoveredClaim.claim.decisionId,
            recovered.decisionDocument.decision.decisionId)
        let claimedRecord = try await uncertainStore.load()
        XCTAssertEqual(claimedRecord?.phase, .claimed)
    }

    func testBlockedRefreshIsDurableFailClosedAndSafelyRetirable() async throws {
        let fixture = try loadFixture()
        let predecessor = try refreshPredecessor()
        var runtimeSeed = fixture.runtime
        runtimeSeed.userConfirmation = nil
        let refreshRuntime = refreshedNativeRuntime(from: runtimeSeed)
        let transport = FakeGuidedExecutionTransport(
            decisionData: predecessor.rawData,
            refreshStatus: .blocked)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-refresh-blocked-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let store = GuidedExecutionAttemptStore(
            url: root.appendingPathComponent("attempt.json"))
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: store,
            receiptJournal: GuidedExecutionReceiptJournal(
                url: root.appendingPathComponent("receipts.ndjson")),
            replayHostId: "desktop-host-refresh-blocked")

        let response = try await host.refreshDecision(
            predecessor: predecessor,
            approvedRunbook: fixture.approvedRunbook,
            runtimeSeed: runtimeSeed,
            priorReceipts: fixture.priorReceipts,
            runtime: refreshRuntime)
        XCTAssertEqual(response.decisionDocument.decision.status, .blocked)
        let blockedRecord = try await store.load()
        let blocked = try XCTUnwrap(blockedRecord)
        XCTAssertEqual(blocked.phase, .refreshFailed)
        XCTAssertEqual(blocked.decisionServerData, predecessor.rawData)
        XCTAssertEqual(blocked.refreshResponseServerData, response.rawData)

        do {
            _ = try await host.claim(
                claimProof: String(repeating: "blocked-refresh-proof-", count: 2))
            XCTFail("BLOCKED refresh must never enter CLAIM")
        } catch {
            XCTAssertEqual(
                error as? GuidedExecutionError,
                .lifecycleStateConflict(GuidedExecutionLocalPhase.refreshFailed.rawValue))
        }
        let claimCalls = await transport.claimCalls()
        XCTAssertEqual(claimCalls, 0)
        let archived = try await store.retireWhenSafe()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
    }

    func testVersionThreeAttemptCanStartAfterRelaunchWithoutLaunchSidecar()
        async throws
    {
        let fixture = try loadFixture()
        let transport = FakeGuidedExecutionTransport(
            decisionData: try decisionBytes())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guided-self-contained-restart-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let attemptURL = root.appendingPathComponent("attempt.json")
        let journalURL = root.appendingPathComponent("receipts.ndjson")
        let host = GuidedExecutionHost(
            transport: transport,
            attemptStore: GuidedExecutionAttemptStore(url: attemptURL),
            receiptJournal: GuidedExecutionReceiptJournal(url: journalURL),
            replayHostId: "desktop-host-self-contained")
        _ = try await host.prepare(
            request: fixture.decision.request,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        let proof = String(repeating: "self-contained-proof-", count: 2)
        _ = try await host.claim(claimProof: proof)

        let relaunched = GuidedExecutionHost(
            transport: transport,
            attemptStore: GuidedExecutionAttemptStore(url: attemptURL),
            receiptJournal: GuidedExecutionReceiptJournal(url: journalURL),
            replayHostId: "desktop-host-self-contained")
        let permit = try await relaunched.start()
        XCTAssertEqual(permit.decisionId, fixture.decision.decisionId)
        let startCalls = await transport.startCalls()
        XCTAssertEqual(startCalls, 1)
    }

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
        XCTAssertEqual(newlyPreparedRecord?.version, 3)

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
            "6dfa4e97282f63d62132f224e812999ee22c32b600110f83b4abf2e0aff06929")
        let siblingServer = contractRoot().deletingLastPathComponent()
            .appendingPathComponent("jasnost/packages/schema/guided-replay.schema.json")
        if FileManager.default.fileExists(atPath: siblingServer.path) {
            XCTAssertEqual(data, try Data(contentsOf: siblingServer))
        }
    }

    func testGuidedDecisionPreservesExactGovernedSkillAuthority() throws {
        var decision = try JSONSerialization.jsonObject(
            with: decisionBytes()) as! [String: Any]
        decision["governedSkillRef"] = [
            "skillId": "gsk_11111111111111111111111111111111",
            "contentDigest":
                "sha256:2222222222222222222222222222222222222222222222222222222222222222",
            "executionSpecDigest":
                "sha256:3333333333333333333333333333333333333333333333333333333333333333",
        ]

        let document = try GuidedReplayDecisionDocument(
            serverData: addressDecision(decision))

        XCTAssertEqual(
            document.decision.governedSkillRef,
            GuidedGovernedSkillReference(
                skillId: "gsk_11111111111111111111111111111111",
                contentDigest:
                    "sha256:2222222222222222222222222222222222222222222222222222222222222222",
                executionSpecDigest:
                    "sha256:3333333333333333333333333333333333333333333333333333333333333333"))

        let fixture = try loadFixture()
        for invalidSkillId in [
            "gsk_A1111111111111111111111111111111",
            "gsk_z1111111111111111111111111111111",
        ] {
            var invalidDecision = decision
            invalidDecision["governedSkillRef"] = [
                "skillId": invalidSkillId,
                "contentDigest":
                    "sha256:2222222222222222222222222222222222222222222222222222222222222222",
                "executionSpecDigest":
                    "sha256:3333333333333333333333333333333333333333333333333333333333333333",
            ]
            let invalidDocument = try GuidedReplayDecisionDocument(
                serverData: addressDecision(invalidDecision))
            XCTAssertThrowsError(
                try GuidedExecutionValidator.authorize(
                    decision: invalidDocument.decision,
                    approvedRunbook: fixture.approvedRunbook,
                    runtime: fixture.runtime,
                    priorReceipts: fixture.priorReceipts)
            ) { error in
                XCTAssertEqual(
                    error as? GuidedExecutionError,
                    .invalidField("decision.governedSkillRef.skillId"))
            }
        }
    }

    func testProcessExecutionSchemaIsPinnedToServerParityDigest() throws {
        let schema = contractRoot().appendingPathComponent(
            "execution/schema/process-execution.schema.json")
        let data = try Data(contentsOf: schema)
        XCTAssertEqual(
            JazzArchiveDigest.sha256Hex(data),
            "4b3e2916c6d3f2368e9d23ee900e38475ab65fbeab8b5139a918aa556a5b12bd")
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

    private func refreshPredecessor(
        additionalApplication: GuidedApplicationObservation? = nil,
        canonicalProcessExecution: Bool = false
    ) throws -> GuidedReplayDecisionDocument {
        var decision = try JSONSerialization.jsonObject(
            with: decisionBytes()) as! [String: Any]
        var request = decision["request"] as! [String: Any]
        let executionId =
            canonicalProcessExecution
            ? "pex_018f89e7-de91-7040-94d1-9f00244c7636"
            : request["executionId"]!
        if canonicalProcessExecution {
            request["executionId"] = executionId
            var approvals = request["approvals"] as! [[String: Any]]
            for index in approvals.indices {
                approvals[index]["executionId"] = executionId
            }
            request["approvals"] = approvals
        }
        request["processExecution"] = [
            "executionId": executionId,
            "bindingId": "peb_11111111111111111111111111111111",
            "bindingContentDigest":
                "sha256:2222222222222222222222222222222222222222222222222222222222222222",
            "businessTransactionKey":
                "btx_3333333333333333333333333333333333333333333333333333333333333333",
        ]
        if let additionalApplication {
            var applications = request["applicationObservations"] as! [Any]
            applications.append(try jsonFoundationValue(additionalApplication))
            request["applicationObservations"] = applications
            var trusted = decision["trustedRuntimeContext"] as! [String: Any]
            var trustedApplications = trusted["applicationObservations"] as! [Any]
            trustedApplications.append(try jsonFoundationValue(additionalApplication))
            trusted["applicationObservations"] = trustedApplications
            decision["trustedRuntimeContext"] = trusted
        }
        decision["request"] = request
        return try GuidedReplayDecisionDocument(
            serverData: addressDecision(decision))
    }

    private func refreshedNativeRuntime(
        from runtime: GuidedRuntimeSnapshot
    ) -> GuidedReplayRefreshRuntime {
        let requestedAt = "2026-07-23T09:01:00.000000Z"
        var locator = runtime.locatorResolution
        locator.resolvedAt = requestedAt
        var applications = runtime.applicationObservations
        for index in applications.indices {
            applications[index].observedAt = requestedAt
        }
        return GuidedReplayRefreshRuntime(
            requestedAt: requestedAt,
            capabilities: runtime.capabilities,
            locatorResolution: locator,
            applicationObservations: applications)
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
    private var decisionData: Data
    private let refreshStatus: GuidedReplayDecisionStatus?
    private var refreshResponseData: Data?
    private var claimData: Data?
    private var startData: Data?
    private var cancellationData: Data?
    private var reconciliationData: Data?
    private var claimExpired = false
    private var startResponseFailuresRemaining = 0
    private var refreshResponseFailuresRemaining = 0
    private var claimCallCount = 0
    private var startCallCount = 0
    private var cancelCallCount = 0
    private var cancelFailuresRemaining = 0
    private var reconcileFailuresRemaining = 0
    private var cancellationRequestIdValues: [String] = []
    private var receiptCallCount = 0
    private var reconcileCallCount = 0
    private var reconciliationRequestIdValues: [String] = []
    private var refreshRequestIdValues: [String] = []
    private var refreshRuntimeValues: [GuidedReplayRefreshRuntime] = []

    init(
        decisionData: Data,
        refreshStatus: GuidedReplayDecisionStatus? = nil
    ) {
        self.decisionData = decisionData
        self.refreshStatus = refreshStatus
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
    func loseNextRefreshResponse() { refreshResponseFailuresRemaining += 1 }
    func refreshRequestIDs() -> [String] { refreshRequestIdValues }
    func refreshRuntimes() -> [GuidedReplayRefreshRuntime] { refreshRuntimeValues }

    func decision(
        scope: GuidedExecutionScope,
        decisionId: String
    ) async throws -> Data {
        decisionData
    }

    func prepare(
        scope: GuidedExecutionScope,
        request: GuidedReplayRequest
    ) async throws -> Data {
        decisionData
    }

    func refresh(
        scope: GuidedExecutionScope,
        decisionId: String,
        refreshRequestId: String,
        runtime: GuidedReplayRefreshRuntime
    ) async throws -> Data {
        refreshRequestIdValues.append(refreshRequestId)
        refreshRuntimeValues.append(runtime)
        if let refreshResponseData {
            return refreshResponseData
        }
        guard let refreshStatus else { return decisionData }
        let predecessor = try GuidedReplayDecisionDocument(serverData: decisionData)
        let intent = try GuidedExecutionRefreshIntent(
            refreshRequestId: refreshRequestId,
            scope: scope,
            operatorId: predecessor.decision.request.operatorId,
            predecessor: predecessor,
            runtime: runtime)
        let successor = try makeRefreshSuccessor(
            predecessorData: decisionData,
            runtime: runtime,
            status: refreshStatus)
        let response = try makeRefreshResponse(
            intent: intent,
            successorData: successor)
        refreshResponseData = response
        decisionData = successor
        if refreshResponseFailuresRemaining > 0 {
            refreshResponseFailuresRemaining -= 1
            throw FakeGuidedError.unsupported
        }
        return response
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

private func makeRefreshSuccessor(
    predecessorData: Data,
    runtime: GuidedReplayRefreshRuntime,
    status: GuidedReplayDecisionStatus
) throws -> Data {
    var decision = try JSONSerialization.jsonObject(
        with: predecessorData) as! [String: Any]
    var request = decision["request"] as! [String: Any]
    request["requestedAt"] = runtime.requestedAt
    request["capabilities"] = try jsonFoundationValue(runtime.capabilities)
    request["locatorResolution"] = try jsonFoundationValue(runtime.locatorResolution)
    request["applicationObservations"] =
        try jsonFoundationValue(runtime.applicationObservations)
    decision["request"] = request
    decision["evaluatedAt"] = runtime.requestedAt
    decision["status"] = status.rawValue
    var trusted = decision["trustedRuntimeContext"] as! [String: Any]
    trusted["resolvedAt"] = runtime.requestedAt
    trusted["locatorResolution"] = request["locatorResolution"]
    trusted["applicationObservations"] = request["applicationObservations"]
    decision["trustedRuntimeContext"] = trusted
    return try addressDecision(decision)
}

private func makeRefreshResponse(
    intent: GuidedExecutionRefreshIntent,
    successorData: Data
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "protocol": "dev.jazz.guided-execution-refresh",
        "protocolVersion": 1,
        "refreshRequestId": intent.refreshRequestId,
        "refreshRequestDigest": intent.refreshRequestDigest,
        "predecessorDecisionId": intent.predecessorDecisionId,
        "predecessorDecisionContentDigest":
            intent.predecessorDecisionContentDigest,
        "decision": try JSONSerialization.jsonObject(with: successorData),
    ])
}

private func addressDecision(_ source: [String: Any]) throws -> Data {
    var decision = source
    let request = decision["request"] as! [String: Any]
    decision["requestDigest"] = try canonicalDigest(request)
    let context = Dictionary(
        uniqueKeysWithValues: [
            "capabilities",
            "preconditions",
            "applicationObservations",
            "businessObjectInputs",
            "locatorResolution",
        ].compactMap { key in request[key].map { (key, $0) } })
    var trusted = decision["trustedRuntimeContext"] as! [String: Any]
    trusted["requestContextDigest"] = try canonicalDigest(context)
    decision["trustedRuntimeContext"] = trusted
    decision.removeValue(forKey: "decisionId")
    decision.removeValue(forKey: "contentDigest")
    let digest = try canonicalDigest(decision)
    decision["contentDigest"] = digest
    decision["decisionId"] = "grd_" + String(digest.dropFirst(7).prefix(32))
    return try JSONSerialization.data(withJSONObject: decision)
}

private func canonicalDigest(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value)
    let json = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: data)
    return "sha256:"
        + JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(json))
}

private func jsonFoundationValue<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
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
