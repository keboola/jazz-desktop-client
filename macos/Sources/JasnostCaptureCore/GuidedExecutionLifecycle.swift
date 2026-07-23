import Foundation

/// Transport boundary shared by the native client, tests and a future remote-meeting host. Server
/// artifacts stay as bytes until their normative content addresses have been checked.
public protocol GuidedExecutionTransport: Sendable {
    func prepare(
        scope: GuidedExecutionScope,
        request: GuidedReplayRequest
    ) async throws -> Data

    func claim(
        scope: GuidedExecutionScope,
        decisionId: String,
        claimRequestId: String,
        claimProof: String,
        replayHostId: String
    ) async throws -> Data

    func start(
        scope: GuidedExecutionScope,
        claimId: String,
        startRequestId: String,
        claimProof: String
    ) async throws -> Data

    func lifecycle(
        scope: GuidedExecutionScope,
        claimId: String
    ) async throws -> Data

    func recordReceipt(
        scope: GuidedExecutionScope,
        decisionId: String,
        claimId: String,
        startReceiptId: String,
        receiptRequestId: String,
        claimProof: String,
        result: JazzArchiveJSONValue
    ) async throws -> Data

    func reconcile(
        scope: GuidedExecutionScope,
        claimId: String,
        reconciliationRequestId: String,
        mode: GuidedReconciliationMode,
        reason: String,
        evidence: [GuidedEvidenceReference],
        receiptRequestId: String?,
        result: JazzArchiveJSONValue?
    ) async throws -> Data
}

public enum GuidedReconciliationMode: String, Codable, Equatable, Sendable {
    case required
    case unknown
    case receipt
}

public enum GuidedExecutionLocalPhase: String, Codable, Equatable, Sendable {
    case prepared
    case claiming
    case claimed
    case starting
    case started
    case receipting
    case receipted
    case reconciling
    case reconciled
}

public struct GuidedExecutionRequestIDs: Codable, Equatable, Sendable {
    public var claimRequestId: String
    public var startRequestId: String
    public var receiptRequestId: String
    public var reconciliationRequestId: String

    public init(
        claimRequestId: String,
        startRequestId: String,
        receiptRequestId: String,
        reconciliationRequestId: String
    ) {
        self.claimRequestId = claimRequestId
        self.startRequestId = startRequestId
        self.receiptRequestId = receiptRequestId
        self.reconciliationRequestId = reconciliationRequestId
    }

    public static func make() -> Self {
        func requestId(_ operation: String) -> String {
            "desktop-\(operation)-\(Identifiers.newUUIDv7().uuidString.lowercased())"
        }
        return Self(
            claimRequestId: requestId("claim"),
            startRequestId: requestId("start"),
            receiptRequestId: requestId("receipt"),
            reconciliationRequestId: requestId("reconcile"))
    }
}

/// Crash-recoverable local attempt state. The claim proof cannot be represented by this type:
/// only its digest is persisted. Server responses are retained byte-for-byte.
public struct GuidedExecutionAttemptRecord: Codable, Equatable, Sendable {
    public var format: String
    public var version: Int
    public var replayHostId: String
    public var requestIDs: GuidedExecutionRequestIDs
    public var phase: GuidedExecutionLocalPhase
    public var claimProofDigest: String?
    public var decisionServerData: Data
    public var claimServerData: Data?
    public var startReceiptServerData: Data?
    public var executionReceiptServerData: Data?
    public var reconciliationServerData: Data?
    public var lifecycleServerData: Data?
    public var updatedAt: String

    public init(
        replayHostId: String,
        requestIDs: GuidedExecutionRequestIDs,
        decisionServerData: Data,
        updatedAt: String
    ) {
        self.format = "dev.jazz.guided-execution-attempt"
        self.version = 1
        self.replayHostId = replayHostId
        self.requestIDs = requestIDs
        self.phase = .prepared
        self.claimProofDigest = nil
        self.decisionServerData = decisionServerData
        self.claimServerData = nil
        self.startReceiptServerData = nil
        self.executionReceiptServerData = nil
        self.reconciliationServerData = nil
        self.lifecycleServerData = nil
        self.updatedAt = updatedAt
    }
}

public actor GuidedExecutionAttemptStore {
    private let url: URL
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public func load() throws -> GuidedExecutionAttemptRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let record = try JSONDecoder().decode(GuidedExecutionAttemptRecord.self, from: data)
        try validate(record)
        return record
    }

    @discardableResult
    public func persistPrepared(
        _ document: GuidedReplayDecisionDocument,
        replayHostId: String
    ) throws -> GuidedExecutionAttemptRecord {
        if let existing = try load() {
            let prior = try GuidedReplayDecisionDocument(serverData: existing.decisionServerData)
            guard prior.canonicalData == document.canonicalData,
                existing.replayHostId == replayHostId
            else {
                throw GuidedExecutionError.requestIdentityConflict(
                    existing.requestIDs.claimRequestId)
            }
            return existing
        }
        guard !replayHostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GuidedExecutionError.invalidField("replayHostId")
        }
        let record = GuidedExecutionAttemptRecord(
            replayHostId: replayHostId,
            requestIDs: .make(),
            decisionServerData: document.rawData,
            updatedAt: Timestamps.iso8601(now()))
        try write(record)
        return record
    }

    public func markClaiming(proofDigest: String) throws -> GuidedExecutionAttemptRecord {
        try mutate { record in
            guard record.phase == .prepared || record.phase == .claiming else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            if let existing = record.claimProofDigest, existing != proofDigest {
                throw GuidedExecutionError.claimProofMismatch
            }
            record.claimProofDigest = proofDigest
            record.phase = .claiming
        }
    }

    public func saveClaim(_ document: GuidedExecutionClaimDocument) throws {
        _ = try mutate { record in
            guard record.phase == .claiming || record.phase == .claimed else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            if let existing = record.claimServerData {
                let prior = try GuidedExecutionClaimDocument(serverData: existing)
                guard prior.canonicalData == document.canonicalData else {
                    throw GuidedExecutionError.requestIdentityConflict(
                        record.requestIDs.claimRequestId)
                }
            } else {
                record.claimServerData = document.rawData
            }
            record.phase = .claimed
        }
    }

    public func markStarting() throws -> GuidedExecutionAttemptRecord {
        try mutate { record in
            guard record.phase == .claimed || record.phase == .starting else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            record.phase = .starting
        }
    }

    public func saveStart(_ document: GuidedExecutionStartReceiptDocument) throws {
        _ = try mutate { record in
            guard record.phase == .starting || record.phase == .started else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            if let existing = record.startReceiptServerData {
                let prior = try GuidedExecutionStartReceiptDocument(serverData: existing)
                guard prior.canonicalData == document.canonicalData else {
                    throw GuidedExecutionError.requestIdentityConflict(
                        record.requestIDs.startRequestId)
                }
            } else {
                record.startReceiptServerData = document.rawData
            }
            record.phase = .started
        }
    }

    public func markReceipting() throws -> GuidedExecutionAttemptRecord {
        try mutate { record in
            guard record.phase == .started || record.phase == .receipting else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            record.phase = .receipting
        }
    }

    public func saveReceipt(_ document: GuidedExecutionReceiptDocument) throws {
        _ = try mutate { record in
            guard record.phase == .receipting || record.phase == .receipted
                || record.phase == .reconciling
            else { throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue) }
            if let existing = record.executionReceiptServerData {
                let prior = try GuidedExecutionReceiptDocument(serverData: existing)
                guard prior.canonicalData == document.canonicalData else {
                    throw GuidedExecutionError.requestIdentityConflict(
                        record.requestIDs.receiptRequestId)
                }
            } else {
                record.executionReceiptServerData = document.rawData
            }
            record.phase = .receipted
        }
    }

    public func markReconciling() throws -> GuidedExecutionAttemptRecord {
        try mutate { record in
            guard record.phase == .started || record.phase == .reconciling else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            record.phase = .reconciling
        }
    }

    public func saveReconciliation(
        _ document: GuidedExecutionReconciliationDocument
    ) throws {
        _ = try mutate { record in
            guard record.phase == .reconciling || record.phase == .reconciled
                || record.phase == .starting || record.phase == .claimed
            else { throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue) }
            if let existing = record.reconciliationServerData {
                let prior = try GuidedExecutionReconciliationDocument(serverData: existing)
                guard prior.canonicalData == document.canonicalData else {
                    throw GuidedExecutionError.requestIdentityConflict(
                        record.requestIDs.reconciliationRequestId)
                }
            } else {
                record.reconciliationServerData = document.rawData
            }
            record.phase = .reconciled
        }
    }

    /// Admit authoritative GET reconciliation after a crash. It never creates a permit.
    public func reconcileFromServer(
        _ document: GuidedReplayClaimLifecycleDocument
    ) throws {
        guard var record = try load(),
            let localClaimData = record.claimServerData
        else { throw GuidedExecutionError.lifecycleStateConflict("missing local claim") }
        let localClaim = try GuidedExecutionClaimDocument(serverData: localClaimData)
        guard localClaim.canonicalData == document.claimDocument.canonicalData else {
            throw GuidedExecutionError.claimBindingMismatch
        }
        if let start = document.startReceiptDocument {
            record.startReceiptServerData = start.rawData
            record.phase = .started
        }
        if let reconciliation = document.reconciliationDocument {
            record.reconciliationServerData = reconciliation.rawData
            record.phase = .reconciled
        }
        if let receipt = document.receiptDocument {
            record.executionReceiptServerData = receipt.rawData
            record.phase = .receipted
        }
        record.lifecycleServerData = document.rawData
        record.updatedAt = Timestamps.iso8601(now())
        try write(record)
    }

    private func mutate(
        _ body: (inout GuidedExecutionAttemptRecord) throws -> Void
    ) throws -> GuidedExecutionAttemptRecord {
        guard var record = try load() else {
            throw GuidedExecutionError.lifecycleStateConflict("missing")
        }
        try body(&record)
        record.updatedAt = Timestamps.iso8601(now())
        try write(record)
        return record
    }

    private func validate(_ record: GuidedExecutionAttemptRecord) throws {
        guard record.format == "dev.jazz.guided-execution-attempt", record.version == 1,
            !record.replayHostId.isEmpty,
            Timestamps.parse(record.updatedAt) != nil
        else { throw GuidedExecutionError.invalidField("local lifecycle record") }
        for value in [
            record.requestIDs.claimRequestId,
            record.requestIDs.startRequestId,
            record.requestIDs.receiptRequestId,
            record.requestIDs.reconciliationRequestId,
        ] where value.isEmpty {
            throw GuidedExecutionError.invalidField("local request id")
        }
        if let digest = record.claimProofDigest {
            try validateProofDigest(digest)
        }
        _ = try GuidedReplayDecisionDocument(serverData: record.decisionServerData)
        if let data = record.claimServerData {
            _ = try GuidedExecutionClaimDocument(serverData: data)
        }
        if let data = record.startReceiptServerData {
            _ = try GuidedExecutionStartReceiptDocument(serverData: data)
        }
        if let data = record.executionReceiptServerData {
            _ = try GuidedExecutionReceiptDocument(serverData: data)
        }
        if let data = record.reconciliationServerData {
            _ = try GuidedExecutionReconciliationDocument(serverData: data)
        }
        if let data = record.lifecycleServerData {
            _ = try GuidedReplayClaimLifecycleDocument(serverData: data)
        }
    }

    private func write(_ record: GuidedExecutionAttemptRecord) throws {
        try validate(record)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JazzArchiveCanonicalJSON.encode(record)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path)
        } catch let error as GuidedExecutionError {
            throw error
        } catch {
            throw GuidedExecutionError.lifecycleWriteFailed
        }
    }
}

public enum GuidedExecutionRecovery: Equatable, Sendable {
    case claimed
    case cancelled
    case reconciliationRequired
    case unresolved
    case receipted
}

/// Serial host for PREPARE → CLAIM → START. Actor reentrancy is guarded explicitly so concurrent
/// UI tasks cannot issue duplicate network calls while an await is in flight.
public actor GuidedExecutionHost {
    private let transport: any GuidedExecutionTransport
    private let attemptStore: GuidedExecutionAttemptStore
    private let receiptJournal: GuidedExecutionReceiptJournal
    private let replayHostId: String
    private var inFlight: Set<String> = []

    public init(
        transport: any GuidedExecutionTransport,
        attemptStore: GuidedExecutionAttemptStore,
        receiptJournal: GuidedExecutionReceiptJournal,
        replayHostId: String
    ) {
        self.transport = transport
        self.attemptStore = attemptStore
        self.receiptJournal = receiptJournal
        self.replayHostId = replayHostId
    }

    public func prepare(
        request: GuidedReplayRequest,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) async throws -> GuidedPreparedReplay {
        try enter("prepare")
        defer { leave("prepare") }
        let bytes = try await transport.prepare(scope: request.scope, request: request)
        let document = try GuidedReplayDecisionDocument(serverData: bytes)
        let prepared = try GuidedExecutionValidator.prepare(
            decision: document.decision,
            approvedRunbook: approvedRunbook,
            runtime: runtime,
            priorReceipts: priorReceipts)
        _ = try await attemptStore.persistPrepared(document, replayHostId: replayHostId)
        return prepared
    }

    public func claim(claimProof: String) async throws -> GuidedExecutionClaimDocument {
        try enter("claim")
        defer { leave("claim") }
        let proofDigest = try guidedClaimProofDigest(claimProof)
        var record = try await requireRecord()
        if record.phase == .claimed, let data = record.claimServerData {
            guard record.claimProofDigest == proofDigest else {
                throw GuidedExecutionError.claimProofMismatch
            }
            return try GuidedExecutionClaimDocument(serverData: data)
        }
        record = try await attemptStore.markClaiming(proofDigest: proofDigest)
        let decision = try GuidedReplayDecisionDocument(serverData: record.decisionServerData)
        let bytes = try await transport.claim(
            scope: decision.decision.runbook.scope,
            decisionId: decision.decision.decisionId,
            claimRequestId: record.requestIDs.claimRequestId,
            claimProof: claimProof,
            replayHostId: replayHostId)
        let claim = try GuidedExecutionClaimDocument(serverData: bytes)
        try GuidedExecutionValidator.validateClaim(
            claim,
            for: decision,
            expectedRequestId: record.requestIDs.claimRequestId,
            expectedProofDigest: proofDigest,
            replayHostId: replayHostId)
        try await attemptStore.saveClaim(claim)
        return claim
    }

    public func start(
        claimProof: String,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) async throws -> GuidedActionPermit {
        try enter("start")
        defer { leave("start") }
        let proofDigest = try guidedClaimProofDigest(claimProof)
        var record = try await requireRecord()
        guard record.claimProofDigest == proofDigest else {
            throw GuidedExecutionError.claimProofMismatch
        }
        guard record.startReceiptServerData == nil else {
            throw GuidedExecutionError.lifecycleStateConflict("started")
        }
        record = try await attemptStore.markStarting()
        let decision = try GuidedReplayDecisionDocument(serverData: record.decisionServerData)
        guard let claimData = record.claimServerData else {
            throw GuidedExecutionError.lifecycleStateConflict("claim missing")
        }
        let claim = try GuidedExecutionClaimDocument(serverData: claimData)
        let bytes = try await transport.start(
            scope: decision.decision.runbook.scope,
            claimId: claim.claim.claimId,
            startRequestId: record.requestIDs.startRequestId,
            claimProof: claimProof)
        let start = try GuidedExecutionStartReceiptDocument(serverData: bytes)
        try GuidedExecutionValidator.validateStartReceipt(
            start,
            for: decision,
            claimDocument: claim,
            expectedRequestId: record.requestIDs.startRequestId)
        // Persist the committed server boundary before exposing any executable instruction.
        try await attemptStore.saveStart(start)
        return try GuidedExecutionValidator.authorizeStart(
            decisionDocument: decision,
            claimDocument: claim,
            startReceiptDocument: start,
            approvedRunbook: approvedRunbook,
            runtime: runtime,
            priorReceipts: priorReceipts)
    }

    public func recordReceipt(
        permit: GuidedActionPermit,
        claimProof: String,
        result: JazzArchiveJSONValue
    ) async throws -> GuidedExecutionReceiptDocument {
        try enter("receipt")
        defer { leave("receipt") }
        let proofDigest = try guidedClaimProofDigest(claimProof)
        var record = try await requireRecord()
        guard record.claimProofDigest == proofDigest else {
            throw GuidedExecutionError.claimProofMismatch
        }
        record = try await attemptStore.markReceipting()
        let bytes = try await transport.recordReceipt(
            scope: try scope(record),
            decisionId: permit.decisionId,
            claimId: permit.claimId,
            startReceiptId: permit.startReceiptId,
            receiptRequestId: record.requestIDs.receiptRequestId,
            claimProof: claimProof,
            result: result)
        let receipt = try GuidedExecutionReceiptDocument(serverData: bytes)
        try GuidedExecutionValidator.validateReceipt(receipt, for: permit)
        _ = try await receiptJournal.append(receipt)
        try await attemptStore.saveReceipt(receipt)
        return receipt
    }

    public func reconcile(
        mode: GuidedReconciliationMode,
        reason: String,
        evidence: [GuidedEvidenceReference],
        result: JazzArchiveJSONValue? = nil
    ) async throws -> GuidedExecutionRecovery {
        try enter("reconcile")
        defer { leave("reconcile") }
        let record = try await attemptStore.markReconciling()
        guard let claimData = record.claimServerData else {
            throw GuidedExecutionError.lifecycleStateConflict("claim missing")
        }
        let claim = try GuidedExecutionClaimDocument(serverData: claimData)
        let bytes = try await transport.reconcile(
            scope: try scope(record),
            claimId: claim.claim.claimId,
            reconciliationRequestId: record.requestIDs.reconciliationRequestId,
            mode: mode,
            reason: reason,
            evidence: evidence,
            receiptRequestId: mode == .receipt ? record.requestIDs.receiptRequestId : nil,
            result: result)
        let type = try artifactType(bytes)
        if type == "executionReceipt" {
            let receipt = try GuidedExecutionReceiptDocument(serverData: bytes)
            _ = try await receiptJournal.append(receipt)
            try await attemptStore.saveReceipt(receipt)
            return .receipted
        }
        guard type == "executionReconciliation" else {
            throw GuidedExecutionError.invalidField("reconcile response")
        }
        let reconciliation = try GuidedExecutionReconciliationDocument(serverData: bytes)
        guard reconciliation.reconciliation.claimId == claim.claim.claimId else {
            throw GuidedExecutionError.claimBindingMismatch
        }
        try await attemptStore.saveReconciliation(reconciliation)
        return reconciliation.reconciliation.resolution == .unknown
            ? .unresolved : .reconciliationRequired
    }

    /// Reconcile a crash from authoritative server state. This method never returns a permit,
    /// preventing a previously presented action from being presented twice.
    public func recover() async throws -> GuidedExecutionRecovery {
        try enter("recover")
        defer { leave("recover") }
        let record = try await requireRecord()
        guard let claimData = record.claimServerData else {
            throw GuidedExecutionError.lifecycleStateConflict("claim missing")
        }
        let claim = try GuidedExecutionClaimDocument(serverData: claimData)
        let bytes = try await transport.lifecycle(
            scope: try scope(record), claimId: claim.claim.claimId)
        let lifecycle = try GuidedReplayClaimLifecycleDocument(serverData: bytes)
        try await attemptStore.reconcileFromServer(lifecycle)
        if let receipt = lifecycle.receiptDocument {
            _ = try await receiptJournal.append(receipt)
        }
        switch lifecycle.lifecycle.lifecycleState {
        case .claimed, .expired: return .claimed
        case .cancelled: return .cancelled
        case .started, .reconciliationRequired: return .reconciliationRequired
        case .unresolved: return .unresolved
        case .receipted, .reconciled: return .receipted
        }
    }

    private func requireRecord() async throws -> GuidedExecutionAttemptRecord {
        guard let record = try await attemptStore.load() else {
            throw GuidedExecutionError.lifecycleStateConflict("missing")
        }
        return record
    }

    private func scope(_ record: GuidedExecutionAttemptRecord) throws -> GuidedExecutionScope {
        try GuidedReplayDecisionDocument(serverData: record.decisionServerData).decision.runbook.scope
    }

    private func enter(_ operation: String) throws {
        guard inFlight.insert(operation).inserted else {
            throw GuidedExecutionError.lifecycleStateConflict("\(operation) in flight")
        }
    }

    private func leave(_ operation: String) {
        inFlight.remove(operation)
    }

    private func artifactType(_ data: Data) throws -> String {
        let value = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: data)
        guard case let .object(object) = value,
            case let .string(type)? = object["artifactType"]
        else { throw GuidedExecutionError.invalidField("artifactType") }
        return type
    }
}

public func guidedClaimProofDigest(_ proof: String) throws -> String {
    guard proof.count >= 32, !proof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GuidedExecutionError.invalidField("claimProof")
    }
    return "sha256:" + JazzArchiveDigest.sha256Hex(Data(proof.utf8))
}

private func validateProofDigest(_ digest: String) throws {
    guard digest.count == 71, digest.hasPrefix("sha256:"),
        digest.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw GuidedExecutionError.invalidField("claimProofDigest") }
}
