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

    /// Release an exact pre-start claim. The server requires the same secret proof used to acquire
    /// the claim; this is deliberately not a generic reconciliation operation.
    func cancel(
        scope: GuidedExecutionScope,
        claimId: String,
        cancellationRequestId: String,
        claimProof: String,
        reason: String
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

extension GuidedExecutionTransport {
    /// Existing non-network adapters fail closed until they explicitly implement proof-bound
    /// cancellation. A default implementation keeps the transport boundary source-compatible
    /// without pretending that dropping local state releases a server claim.
    public func cancel(
        scope: GuidedExecutionScope,
        claimId: String,
        cancellationRequestId: String,
        claimProof: String,
        reason: String
    ) async throws -> Data {
        throw GuidedExecutionError.lifecycleStateConflict("cancel unsupported")
    }
}

public enum GuidedReconciliationMode: String, Codable, Equatable, Sendable {
    case required
    case unknown
    case receipt
}

/// Canonical endpoint binding for the scoped guided-execution bearer. A Keychain value without this
/// envelope is deliberately not treated as a credential: a token may never silently move to a
/// different governance origin or base path.
public struct GuidedExecutionCredentialEnvelope: Codable, Equatable, Sendable {
    public var format: String
    public var version: Int
    public var endpoint: String
    public var token: String

    public init(endpoint: String, token: String) {
        self.format = "dev.jazz.guided-execution-credential"
        self.version = 1
        self.endpoint = endpoint
        self.token = token
    }
}

public enum GuidedExecutionEndpointBinding {
    /// Normalize only HTTPS base URLs which cannot carry credentials, query input, or fragments.
    /// Host casing, the default HTTPS port, and trailing path slashes do not create a new binding.
    public static func normalize(_ rawValue: String) -> URL? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, var components = URLComponents(string: raw),
            components.scheme?.lowercased() == "https",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        return components.url
    }

    public static func encodeCredential(token: String, endpoint: URL) throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let normalized = normalize(endpoint.absoluteString) else {
            throw GuidedExecutionError.invalidField("guided execution credential")
        }
        let data = try JSONEncoder().encode(
            GuidedExecutionCredentialEnvelope(
                endpoint: normalized.absoluteString,
                token: trimmed))
        return String(decoding: data, as: UTF8.self)
    }

    /// Return a token only when the stored envelope is current and bound to this exact normalized
    /// endpoint. Legacy plaintext values and malformed envelopes fail closed.
    public static func token(storedValue: String, matching endpoint: URL) -> String? {
        guard let normalized = normalize(endpoint.absoluteString),
            let data = storedValue.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(
                GuidedExecutionCredentialEnvelope.self, from: data),
            envelope.format == "dev.jazz.guided-execution-credential",
            envelope.version == 1,
            !envelope.token.isEmpty,
            let storedEndpoint = normalize(envelope.endpoint),
            storedEndpoint.absoluteString == normalized.absoluteString
        else { return nil }
        return envelope.token
    }

    public static func boundEndpoint(storedValue: String) -> URL? {
        guard let data = storedValue.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(
                GuidedExecutionCredentialEnvelope.self, from: data),
            envelope.format == "dev.jazz.guided-execution-credential",
            envelope.version == 1,
            !envelope.token.isEmpty
        else { return nil }
        return normalize(envelope.endpoint)
    }
}

/// Builds the discriminated reconciliation request without allowing receipt recovery to inherit the
/// idempotency field used by the `required` and `unknown` variants.
public enum GuidedExecutionWirePayload {
    public static func reconciliation(
        scope: GuidedExecutionScope,
        claimReconciliationRequestId: String,
        mode: GuidedReconciliationMode,
        reason: String,
        evidence: [GuidedEvidenceReference],
        receiptRequestId: String?,
        result: JazzArchiveJSONValue?
    ) throws -> JazzArchiveJSONValue {
        guard !scope.companyId.isEmpty, !scope.areaId.isEmpty, !scope.processId.isEmpty,
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !evidence.isEmpty
        else { throw GuidedExecutionError.invalidField("reconciliation request") }
        var body: [String: JazzArchiveJSONValue] = [
            "companyId": .string(scope.companyId),
            "areaId": .string(scope.areaId),
            "processId": .string(scope.processId),
            "mode": .string(mode.rawValue),
            "reason": .string(reason),
            "evidence": try JSONDecoder().decode(
                JazzArchiveJSONValue.self,
                from: JSONEncoder().encode(evidence)),
        ]
        switch mode {
        case .required, .unknown:
            guard !claimReconciliationRequestId.isEmpty,
                receiptRequestId == nil, result == nil
            else { throw GuidedExecutionError.invalidField("reconciliation request variant") }
            body["reconciliationRequestId"] = .string(claimReconciliationRequestId)
        case .receipt:
            guard let receiptRequestId, !receiptRequestId.isEmpty, let result else {
                throw GuidedExecutionError.invalidField("receipt reconciliation request")
            }
            body["receiptRequestId"] = .string(receiptRequestId)
            body["result"] = result
        }
        return .object(body)
    }
}

public enum GuidedExecutionLocalPhase: String, Codable, Equatable, Sendable {
    case prepared
    case claiming
    case claimed
    case cancelling
    case expired
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
    public var cancellationRequestId: String?
    public var receiptRequestId: String
    public var reconciliationRequestId: String
    /// A later UNKNOWN reconciliation must not reuse the request identity that first marked the
    /// started attempt as reconciliation-required.
    public var followupReconciliationRequestId: String?

    public init(
        claimRequestId: String,
        startRequestId: String,
        cancellationRequestId: String? = nil,
        receiptRequestId: String,
        reconciliationRequestId: String,
        followupReconciliationRequestId: String? = nil
    ) {
        self.claimRequestId = claimRequestId
        self.startRequestId = startRequestId
        self.cancellationRequestId = cancellationRequestId
        self.receiptRequestId = receiptRequestId
        self.reconciliationRequestId = reconciliationRequestId
        self.followupReconciliationRequestId = followupReconciliationRequestId
    }

    public static func make() -> Self {
        func requestId(_ operation: String) -> String {
            "desktop-\(operation)-\(Identifiers.newUUIDv7().uuidString.lowercased())"
        }
        return Self(
            claimRequestId: requestId("claim"),
            startRequestId: requestId("start"),
            cancellationRequestId: requestId("cancel"),
            receiptRequestId: requestId("receipt"),
            reconciliationRequestId: requestId("reconcile-required-or-unknown"),
            followupReconciliationRequestId: requestId("reconcile-followup"))
    }
}

/// Exact, non-secret request material frozen before a reconciliation crosses the network
/// boundary. It makes caller-stable request IDs meaningful across retries and relaunch recovery.
public struct GuidedExecutionReconciliationIntent: Codable, Equatable, Sendable {
    public var mode: GuidedReconciliationMode
    public var reason: String
    public var evidence: [GuidedEvidenceReference]
    public var receiptRequestId: String?
    public var result: JazzArchiveJSONValue?

    public init(
        mode: GuidedReconciliationMode,
        reason: String,
        evidence: [GuidedEvidenceReference],
        receiptRequestId: String?,
        result: JazzArchiveJSONValue?
    ) {
        self.mode = mode
        self.reason = reason
        self.evidence = evidence
        self.receiptRequestId = receiptRequestId
        self.result = result
    }
}

/// Crash-recoverable local attempt state. The raw claim proof exists only in this active,
/// permission-restricted local journal so an uncertain CLAIM can be retried byte-for-byte after
/// relaunch. Server artifacts retain only its digest, and terminal transitions erase the raw proof
/// before this record may move to history.
public struct GuidedExecutionAttemptRecord: Codable, Equatable, Sendable {
    public var format: String
    public var version: Int
    public var replayHostId: String
    public var requestIDs: GuidedExecutionRequestIDs
    public var phase: GuidedExecutionLocalPhase
    public var claimProof: String?
    public var claimProofDigest: String?
    /// Frozen before the first cancellation request is sent. A transport ambiguity may only retry
    /// the same reason under the caller-stable reconciliation request ID.
    public var cancellationReason: String?
    public var receiptResult: JazzArchiveJSONValue?
    public var reconciliationIntent: GuidedExecutionReconciliationIntent?
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
        self.version = 2
        self.replayHostId = replayHostId
        self.requestIDs = requestIDs
        self.phase = .prepared
        self.claimProof = nil
        self.claimProofDigest = nil
        self.cancellationReason = nil
        self.receiptResult = nil
        self.reconciliationIntent = nil
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

    public func markClaiming(claimProof: String) throws -> GuidedExecutionAttemptRecord {
        let proofDigest = try guidedClaimProofDigest(claimProof)
        return try mutate { record in
            guard record.phase == .prepared || record.phase == .claiming else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            if let existing = record.claimProof, existing != claimProof {
                throw GuidedExecutionError.claimProofMismatch
            }
            if let existing = record.claimProofDigest, existing != proofDigest {
                throw GuidedExecutionError.claimProofMismatch
            }
            record.claimProof = claimProof
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

    public func markCancelling(reason: String) throws -> GuidedExecutionAttemptRecord {
        try mutate { record in
            guard record.phase == .claimed || record.phase == .cancelling,
                record.startReceiptServerData == nil
            else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            if let existing = record.cancellationReason, existing != reason {
                guard let requestId = record.requestIDs.cancellationRequestId else {
                    throw GuidedExecutionError.invalidField(
                        "local cancellation request id")
                }
                throw GuidedExecutionError.requestIdentityConflict(
                    requestId)
            }
            guard record.requestIDs.cancellationRequestId != nil else {
                throw GuidedExecutionError.invalidField("local cancellation request id")
            }
            record.cancellationReason = reason
            record.phase = .cancelling
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

    public func markReceipting(result: JazzArchiveJSONValue) throws
        -> GuidedExecutionAttemptRecord
    {
        try mutate { record in
            guard record.phase == .started || record.phase == .receipting else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            if let existing = record.receiptResult, existing != result {
                throw GuidedExecutionError.requestIdentityConflict(
                    record.requestIDs.receiptRequestId)
            }
            record.receiptResult = result
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
            record.claimProof = nil
            record.phase = .receipted
        }
    }

    public func markReconciling(
        intent: GuidedExecutionReconciliationIntent
    ) throws -> GuidedExecutionAttemptRecord {
        try mutate { record in
            guard record.phase == .started || record.phase == .reconciling else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            if let existing = record.reconciliationIntent, existing != intent {
                let prior = try record.reconciliationServerData.map {
                    try GuidedExecutionReconciliationDocument(serverData: $0)
                }
                guard prior?.reconciliation.resolution == .reconciliationRequired,
                    intent.mode != .required
                else {
                    throw GuidedExecutionError.requestIdentityConflict(
                        record.requestIDs.reconciliationRequestId)
                }
            }
            record.reconciliationIntent = intent
            record.phase = .reconciling
        }
    }

    public func saveReconciliation(
        _ document: GuidedExecutionReconciliationDocument
    ) throws {
        _ = try mutate { record in
            guard record.phase == .reconciling || record.phase == .reconciled
                || record.phase == .starting || record.phase == .claimed
                || record.phase == .cancelling
            else { throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue) }
            if let existing = record.reconciliationServerData {
                let prior = try GuidedExecutionReconciliationDocument(serverData: existing)
                if prior.canonicalData != document.canonicalData {
                    guard prior.reconciliation.resolution == .reconciliationRequired,
                        document.reconciliation.supersedesReconciliationId
                            == prior.reconciliation.reconciliationId,
                        document.reconciliation.claimId == prior.reconciliation.claimId,
                        document.reconciliation.decisionId == prior.reconciliation.decisionId,
                        document.reconciliation.startReceiptId
                            == prior.reconciliation.startReceiptId,
                        document.reconciliation.resolution == .unknown,
                        document.reconciliation.reconciliationRequestId
                            == record.requestIDs.followupReconciliationRequestId
                    else {
                        throw GuidedExecutionError.requestIdentityConflict(
                            record.requestIDs.followupReconciliationRequestId
                                ?? record.requestIDs.reconciliationRequestId)
                    }
                    record.reconciliationServerData = document.rawData
                }
            } else {
                record.reconciliationServerData = document.rawData
            }
            record.claimProof = nil
            record.phase =
                document.reconciliation.resolution == .reconciliationRequired
                ? .started : .reconciled
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
        // Normalize ambiguous in-flight local phases from the server's validated lifecycle. In
        // particular, a failed `/cancel` must not leave START visible until GET says the claim is
        // still active.
        switch document.lifecycle.lifecycleState {
        case .claimed:
            record.phase = .claimed
        case .expired:
            // The retained lifecycle bytes, not this phase value, prove terminal expiry.
            record.phase = .expired
            record.claimProof = nil
        case .cancelled:
            record.phase = .reconciled
            record.claimProof = nil
        case .started, .reconciliationRequired:
            record.phase = .started
            if document.reconciliationDocument != nil {
                record.claimProof = nil
            }
        case .unresolved:
            record.phase = .reconciled
            record.claimProof = nil
        case .receipted, .reconciled:
            record.phase = .receipted
            record.claimProof = nil
        }
        record.lifecycleServerData = document.rawData
        record.updatedAt = Timestamps.iso8601(now())
        try write(record)
    }

    /// Move a locally finished or never-claimed attempt into immutable history so a later server
    /// decision can use the active slot. Claiming/started attempts are never retired by local
    /// judgment. An expired/cancelled server lifecycle is accepted only from the losslessly
    /// retained authoritative GET response.
    @discardableResult
    public func retireWhenSafe() throws -> URL {
        guard let record = try load() else {
            throw GuidedExecutionError.lifecycleStateConflict("missing")
        }
        var safe = [.prepared, .receipted].contains(record.phase)
        if record.phase == .reconciled, let data = record.reconciliationServerData {
            let reconciliation = try GuidedExecutionReconciliationDocument(serverData: data)
            safe = [.cancelledBeforeStart, .unknown].contains(
                reconciliation.reconciliation.resolution)
        }
        if !safe, let lifecycleData = record.lifecycleServerData {
            let lifecycle = try GuidedReplayClaimLifecycleDocument(serverData: lifecycleData)
            safe = [.expired, .cancelled, .unresolved, .receipted, .reconciled].contains(
                lifecycle.lifecycle.lifecycleState)
        }
        guard safe else {
            throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
        }
        guard record.claimProof == nil else {
            throw GuidedExecutionError.lifecycleStateConflict("active claim proof")
        }
        let decision = try GuidedReplayDecisionDocument(serverData: record.decisionServerData)
        let historyRoot = url.deletingLastPathComponent()
            .appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent(decision.decision.decisionId, isDirectory: true)
        let destination = historyRoot.appendingPathComponent(
            "attempt-\(Identifiers.newUUIDv7().uuidString.lowercased()).json")
        do {
            try FileManager.default.createDirectory(
                at: historyRoot, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: destination.path)
            return destination
        } catch {
            throw GuidedExecutionError.lifecycleWriteFailed
        }
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
        guard record.format == "dev.jazz.guided-execution-attempt",
            [1, 2].contains(record.version),
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
        if let cancellationRequestId = record.requestIDs.cancellationRequestId,
            cancellationRequestId.isEmpty
        {
            throw GuidedExecutionError.invalidField("local cancellation request id")
        }
        if let followupRequestId = record.requestIDs.followupReconciliationRequestId,
            followupRequestId.isEmpty
        {
            throw GuidedExecutionError.invalidField("local follow-up reconciliation request id")
        }
        if record.version == 2,
            record.requestIDs.cancellationRequestId == nil
        {
            throw GuidedExecutionError.invalidField("local cancellation request id")
        }
        if record.version == 2,
            record.requestIDs.followupReconciliationRequestId == nil
        {
            throw GuidedExecutionError.invalidField(
                "local follow-up reconciliation request id")
        }
        if let digest = record.claimProofDigest {
            try validateProofDigest(digest)
        }
        if let proof = record.claimProof {
            guard try guidedClaimProofDigest(proof) == record.claimProofDigest else {
                throw GuidedExecutionError.claimProofMismatch
            }
        }
        let activeClaimPhases: [GuidedExecutionLocalPhase] = [
            .claiming, .claimed, .cancelling, .starting, .started, .receipting, .reconciling,
        ]
        if record.version == 1, activeClaimPhases.contains(record.phase),
            record.claimProofDigest == nil
        {
            throw GuidedExecutionError.invalidField("active claim proof digest")
        }
        if record.version == 2,
            [.claiming, .claimed, .cancelling, .starting, .receipting].contains(record.phase),
            record.claimProof == nil
        {
            throw GuidedExecutionError.invalidField("active claim proof")
        }
        if record.phase == .prepared, record.claimProof != nil {
            throw GuidedExecutionError.invalidField("premature claim proof")
        }
        if let reason = record.cancellationReason,
            reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw GuidedExecutionError.invalidField("cancellation reason")
        }
        if record.version == 2, record.phase == .cancelling,
            record.cancellationReason == nil
        {
            throw GuidedExecutionError.invalidField("cancellation intent")
        }
        if record.version == 2, record.phase == .receipting,
            record.receiptResult == nil
        {
            throw GuidedExecutionError.invalidField("receipt intent")
        }
        if let intent = record.reconciliationIntent {
            guard !intent.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !intent.evidence.isEmpty,
                (intent.mode == .receipt) == (intent.receiptRequestId != nil),
                (intent.mode == .receipt) == (intent.result != nil)
            else {
                throw GuidedExecutionError.invalidField("reconciliation intent")
            }
        }
        if record.version == 2, record.phase == .reconciling,
            record.reconciliationIntent == nil
        {
            throw GuidedExecutionError.invalidField("reconciliation intent")
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
    /// A legacy v1 record retained the claim binding but not the raw proof. GET recovery is safe,
    /// while START, cancellation and direct receipt retry remain impossible until the server
    /// reports expiry or another authoritative transition.
    case claimedWithoutProof
    case expired
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

    public func claim(claimProof suppliedProof: String? = nil) async throws
        -> GuidedExecutionClaimDocument
    {
        try enter("claim")
        defer { leave("claim") }
        var record = try await requireRecord()
        let claimProof = try resolveClaimProof(record: record, supplied: suppliedProof)
        let proofDigest = try guidedClaimProofDigest(claimProof)
        if record.phase == .claimed, let data = record.claimServerData {
            guard record.claimProofDigest == proofDigest else {
                throw GuidedExecutionError.claimProofMismatch
            }
            return try GuidedExecutionClaimDocument(serverData: data)
        }
        // This atomic local write includes the raw proof and all request identity before the first
        // network byte is sent. An uncertain response is therefore exactly retryable on relaunch.
        record = try await attemptStore.markClaiming(claimProof: claimProof)
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
        claimProof suppliedProof: String? = nil,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) async throws -> GuidedActionPermit {
        try enter("start")
        defer { leave("start") }
        var record = try await requireRecord()
        let claimProof = try resolveClaimProof(record: record, supplied: suppliedProof)
        let proofDigest = try guidedClaimProofDigest(claimProof)
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

    /// Cancel a claim which has not crossed START using its own caller-stable request identity.
    /// Cancellation and later post-START reconciliation never share an idempotency key.
    public func cancel(claimProof suppliedProof: String? = nil, reason: String) async throws
        -> GuidedExecutionRecovery
    {
        try enter("cancel")
        defer { leave("cancel") }
        var record = try await requireRecord()
        let claimProof = try resolveClaimProof(record: record, supplied: suppliedProof)
        let proofDigest = try guidedClaimProofDigest(claimProof)
        guard record.claimProofDigest == proofDigest else {
            throw GuidedExecutionError.claimProofMismatch
        }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            throw GuidedExecutionError.invalidField("cancellation reason")
        }
        guard let cancellationRequestId = record.requestIDs.cancellationRequestId else {
            throw GuidedExecutionError.invalidField("local cancellation request id")
        }
        if record.phase == .reconciled, let data = record.reconciliationServerData {
            let existing = try GuidedExecutionReconciliationDocument(serverData: data)
            guard existing.reconciliation.resolution == .cancelledBeforeStart else {
                throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
            }
            guard existing.reconciliation.reason == trimmedReason else {
                throw GuidedExecutionError.requestIdentityConflict(
                    cancellationRequestId)
            }
            guard existing.reconciliation.reconciliationRequestId == cancellationRequestId else {
                throw GuidedExecutionError.claimBindingMismatch
            }
            return .cancelled
        }
        guard record.phase == .claimed || record.phase == .cancelling,
            record.startReceiptServerData == nil,
            let claimData = record.claimServerData
        else {
            throw GuidedExecutionError.lifecycleStateConflict(record.phase.rawValue)
        }
        record = try await attemptStore.markCancelling(reason: trimmedReason)
        let decision = try GuidedReplayDecisionDocument(serverData: record.decisionServerData)
        let claim = try GuidedExecutionClaimDocument(serverData: claimData)
        let bytes = try await transport.cancel(
            scope: decision.decision.runbook.scope,
            claimId: claim.claim.claimId,
            cancellationRequestId: cancellationRequestId,
            claimProof: claimProof,
            reason: trimmedReason)
        let cancellation = try GuidedExecutionReconciliationDocument(serverData: bytes)
        let artifact = cancellation.reconciliation
        guard artifact.reconciliationRequestId == cancellationRequestId,
            artifact.claimId == claim.claim.claimId,
            artifact.claimContentDigest == claim.claim.contentDigest,
            artifact.startReceiptId == nil,
            artifact.startReceiptContentDigest == nil,
            artifact.decisionId == decision.decision.decisionId,
            artifact.decisionContentDigest == decision.decision.contentDigest,
            artifact.runbook == decision.decision.runbook,
            artifact.executionId == claim.claim.executionId,
            artifact.variantRef == claim.claim.variantRef,
            artifact.stepId == claim.claim.stepId,
            artifact.logicalOperationKey == claim.claim.logicalOperationKey,
            artifact.attemptNumber == claim.claim.attemptNumber,
            artifact.resolution == .cancelledBeforeStart,
            artifact.authoritySnapshot == nil,
            artifact.trustedReconciliation == nil
        else { throw GuidedExecutionError.claimBindingMismatch }
        try await attemptStore.saveReconciliation(cancellation)
        return .cancelled
    }

    public func recordReceipt(
        permit: GuidedActionPermit,
        claimProof suppliedProof: String? = nil,
        result: JazzArchiveJSONValue
    ) async throws -> GuidedExecutionReceiptDocument {
        try enter("receipt")
        defer { leave("receipt") }
        var record = try await requireRecord()
        let claimProof = try resolveClaimProof(record: record, supplied: suppliedProof)
        let proofDigest = try guidedClaimProofDigest(claimProof)
        guard record.claimProofDigest == proofDigest else {
            throw GuidedExecutionError.claimProofMismatch
        }
        record = try await attemptStore.markReceipting(result: result)
        guard let frozenResult = record.receiptResult else {
            throw GuidedExecutionError.lifecycleStateConflict("receipt intent missing")
        }
        let bytes = try await transport.recordReceipt(
            scope: try scope(record),
            decisionId: permit.decisionId,
            claimId: permit.claimId,
            startReceiptId: permit.startReceiptId,
            receiptRequestId: record.requestIDs.receiptRequestId,
            claimProof: claimProof,
            result: frozenResult)
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
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty, !evidence.isEmpty else {
            throw GuidedExecutionError.invalidField("reconciliation intent")
        }
        let pendingRecord = try await requireRecord()
        let intent = GuidedExecutionReconciliationIntent(
            mode: mode,
            reason: trimmedReason,
            evidence: evidence,
            receiptRequestId: mode == .receipt
                ? pendingRecord.requestIDs.receiptRequestId : nil,
            result: result)
        if let priorData = pendingRecord.reconciliationServerData {
            let prior = try GuidedExecutionReconciliationDocument(serverData: priorData)
            if prior.reconciliation.resolution == .reconciliationRequired, mode == .required {
                guard pendingRecord.reconciliationIntent == intent,
                    prior.reconciliation.reconciliationRequestId
                        == pendingRecord.requestIDs.reconciliationRequestId
                else {
                    throw GuidedExecutionError.requestIdentityConflict(
                        pendingRecord.requestIDs.reconciliationRequestId)
                }
                return .reconciliationRequired
            }
            if prior.reconciliation.resolution == .unknown {
                guard pendingRecord.reconciliationIntent == intent else {
                    throw GuidedExecutionError.lifecycleStateConflict(
                        pendingRecord.phase.rawValue)
                }
                return .unresolved
            }
        }
        let record = try await attemptStore.markReconciling(intent: intent)
        guard let frozen = record.reconciliationIntent else {
            throw GuidedExecutionError.lifecycleStateConflict("reconciliation intent missing")
        }
        guard let claimData = record.claimServerData else {
            throw GuidedExecutionError.lifecycleStateConflict("claim missing")
        }
        let claim = try GuidedExecutionClaimDocument(serverData: claimData)
        let priorReconciliation = try record.reconciliationServerData.map {
            try GuidedExecutionReconciliationDocument(serverData: $0)
        }
        let reconciliationRequestId: String
        if priorReconciliation?.reconciliation.resolution == .reconciliationRequired,
            frozen.mode == .unknown
        {
            guard let followup = record.requestIDs.followupReconciliationRequestId else {
                throw GuidedExecutionError.invalidField(
                    "local follow-up reconciliation request id")
            }
            reconciliationRequestId = followup
        } else {
            reconciliationRequestId = record.requestIDs.reconciliationRequestId
        }
        let bytes = try await transport.reconcile(
            scope: try scope(record),
            claimId: claim.claim.claimId,
            reconciliationRequestId: reconciliationRequestId,
            mode: frozen.mode,
            reason: frozen.reason,
            evidence: frozen.evidence,
            receiptRequestId: frozen.receiptRequestId,
            result: frozen.result)
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
        case .claimed:
            return record.claimProof == nil ? .claimedWithoutProof : .claimed
        case .expired: return .expired
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

    private func resolveClaimProof(
        record: GuidedExecutionAttemptRecord,
        supplied: String?
    ) throws -> String {
        guard let proof = supplied ?? record.claimProof else {
            throw GuidedExecutionError.claimProofUnavailable
        }
        let digest = try guidedClaimProofDigest(proof)
        if let durableProof = record.claimProof, durableProof != proof {
            throw GuidedExecutionError.claimProofMismatch
        }
        if let durableDigest = record.claimProofDigest, durableDigest != digest {
            throw GuidedExecutionError.claimProofMismatch
        }
        return proof
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
