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
        let permit = try await host.start(
            claimProof: proof,
            approvedRunbook: fixture.approvedRunbook,
            runtime: fixture.runtime,
            priorReceipts: fixture.priorReceipts)
        XCTAssertEqual(permit.startReceiptId.hasPrefix("ges_"), true)
        let loadedAfterStart = try await store.load()
        XCTAssertEqual(loadedAfterStart?.requestIDs.startRequestId, stableStartRequest)

        let persisted = try Data(contentsOf: attemptURL)
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(proof))
        XCTAssertTrue(
            String(decoding: persisted, as: UTF8.self).contains(
                try guidedClaimProofDigest(proof)))

        // A new process has no bearer proof and must not manufacture the permit again.
        let recoveredHost = GuidedExecutionHost(
            transport: transport,
            attemptStore: GuidedExecutionAttemptStore(url: attemptURL),
            receiptJournal: GuidedExecutionReceiptJournal(url: journalURL),
            replayHostId: "desktop-host-a")
        do {
            _ = try await recoveredHost.start(
                claimProof: proof,
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

    func testGuidedReplaySchemaIsPinnedToServerParityDigest() throws {
        let schema = contractRoot().appendingPathComponent(
            "execution/schema/guided-replay.schema.json")
        let data = try Data(contentsOf: schema)
        XCTAssertEqual(
            JazzArchiveDigest.sha256Hex(data),
            "800ff6b1df1d819ce0ada95146d0c2fc1d6c1af9991292adb36644847f163cf7")
        let siblingServer = contractRoot().deletingLastPathComponent()
            .appendingPathComponent("jasnost/packages/schema/guided-replay.schema.json")
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

private enum FakeGuidedError: Error {
    case unsupported
}

private actor FakeGuidedExecutionTransport: GuidedExecutionTransport {
    private let decisionData: Data
    private var claimData: Data?
    private var startData: Data?
    private var claimCallCount = 0
    private var startCallCount = 0

    init(decisionData: Data) {
        self.decisionData = decisionData
    }

    func claimCalls() -> Int { claimCallCount }
    func startCalls() -> Int { startCallCount }

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
        return data
    }

    func lifecycle(
        scope: GuidedExecutionScope,
        claimId: String
    ) async throws -> Data {
        guard let claimData, let startData else { throw FakeGuidedError.unsupported }
        return try JSONSerialization.data(withJSONObject: [
            "claim": try JSONSerialization.jsonObject(with: claimData),
            "lifecycleState": "started",
            "leaseExpired": false,
            "startReceipt": try JSONSerialization.jsonObject(with: startData),
            "latestReconciliation": NSNull(),
            "receipt": NSNull(),
            "futureLifecycleAuthority": ["preserved": true],
        ])
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
        throw FakeGuidedError.unsupported
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
