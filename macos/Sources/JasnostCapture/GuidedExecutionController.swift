import Foundation
import JasnostCaptureCore
import Security

/// macOS host for server-authorized human guidance. It deliberately exposes an instruction and a
/// semantic highlight target only; it never posts CGEvents, types captured text, presses an AX
/// element, or falls back to coordinates. The operator performs the action and the server returns
/// the immutable receipt that is appended through ``acceptServerReceipt(_:journal:)``.
@MainActor
final class GuidedExecutionController: ObservableObject {
    @Published private(set) var prepared: GuidedPreparedReplay?
    @Published private(set) var claim: GuidedExecutionClaim?
    @Published private(set) var permit: GuidedActionPermit?
    @Published private(set) var recovery: GuidedExecutionRecovery?
    @Published private(set) var status = ""
    private var host: GuidedExecutionHost?
    /// Ephemeral convenience copy. The host atomically stores the raw proof only in the active
    /// permission-restricted lifecycle journal before CLAIM; server artifacts retain its digest.
    private var claimProof: String?

    init(host: GuidedExecutionHost? = nil) {
        self.host = host
    }

    func configure(host: GuidedExecutionHost) {
        self.host = host
    }

    /// Admit an already returned PREPARE response for compatibility/testing. This never produces
    /// a permit or reveals executable action authority.
    func prepare(
        decision: GuidedReplayDecision,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) {
        do {
            prepared = try GuidedExecutionValidator.prepare(
                decision: decision,
                approvedRunbook: approvedRunbook,
                runtime: runtime,
                priorReceipts: priorReceipts)
            permit = nil
            recovery = nil
            status = "Prepared. A server claim and start receipt are still required."
        } catch {
            prepared = nil
            permit = nil
            recovery = nil
            status = "Guided execution blocked: \(error)"
        }
    }

    func prepareWithServer(
        request: GuidedReplayRequest,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) async {
        guard let host else {
            status = "Guided execution blocked: no server host is configured."
            return
        }
        do {
            prepared = try await host.prepare(
                request: request,
                approvedRunbook: approvedRunbook,
                runtime: runtime,
                priorReceipts: priorReceipts)
            permit = nil
            recovery = nil
            status = "Prepared. Acquire the exclusive pre-start claim."
        } catch {
            prepared = nil
            permit = nil
            recovery = nil
            status = "Guided execution blocked: \(error)"
        }
    }

    func acceptServerPreparation(
        _ document: GuidedReplayDecisionDocument,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) async throws {
        guard let host else {
            let error = GuidedExecutionError.lifecycleStateConflict(
                "no server host configured")
            status = "Guided execution blocked: \(error)"
            throw error
        }
        do {
            prepared = try await host.persistPrepared(
                document,
                approvedRunbook: approvedRunbook,
                runtime: runtime,
                priorReceipts: priorReceipts)
            permit = nil
            recovery = nil
            status = "Prepared. Acquire the exclusive pre-start claim."
        } catch {
            prepared = nil
            permit = nil
            recovery = nil
            status = "Guided execution blocked: \(error)"
            throw error
        }
    }

    func claimPreparedStep() async {
        guard let host, prepared != nil else {
            status = "Claim blocked: no prepared step is available."
            return
        }
        do {
            // Reuse the ephemeral copy when available. The host atomically persists the same raw
            // secret before sending CLAIM, so relaunch recovery never mints a different proof.
            let proof = try claimProof ?? Self.makeClaimProof()
            claimProof = proof
            let document = try await host.claim(claimProof: proof)
            claim = document.claim
            recovery = nil
            status = "Claim acquired. The step is still not authorized to act."
        } catch {
            claim = nil
            recovery = nil
            status =
                "Claim not admitted: \(error). An exact in-process retry keeps the same request ID and proof."
        }
    }

    /// Resume an uncertain or already persisted CLAIM after relaunch. The host reads the exact raw
    /// proof and caller-stable request identity from the active local journal; no new proof or
    /// request ID is minted.
    func resumeDurableClaim() async {
        guard let host else {
            status = "Claim recovery blocked: no server host is configured."
            return
        }
        do {
            let document = try await host.claim()
            claim = document.claim
            permit = nil
            recovery = .claimed
            status = "The exact durable claim was recovered. START is still required."
        } catch {
            claim = nil
            permit = nil
            status = "Durable claim recovery failed closed: \(error)"
        }
    }

    func startClaimedStep(
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) async -> GuidedActionPermit? {
        guard let host else {
            permit = nil
            status = "Start blocked: no server host is configured."
            return nil
        }
        do {
            let candidate = try await host.start(
                claimProof: claimProof,
                approvedRunbook: approvedRunbook,
                runtime: runtime,
                priorReceipts: priorReceipts)
            // Do not publish the instruction yet. The production workspace must resolve the exact
            // live AX target once more after this network boundary.
            permit = nil
            status = "Server start committed. Revalidating the live semantic target."
            return candidate
        } catch {
            permit = nil
            status = "Start blocked: \(error)"
            return nil
        }
    }

    /// The sole presentation gate for a START candidate. Callers may invoke it only after a fresh
    /// post-response semantic resolution; until then SwiftUI cannot observe the instruction.
    func revealStartedStep(_ candidate: GuidedActionPermit) {
        permit = candidate
        status = "Server start committed. Ready for the explicit operator action."
    }

    /// Release a claim only through the server's proof-bound pre-start cancellation transition.
    /// Clearing the local proof is deferred until the immutable cancellation response validates.
    func cancelClaim(reason: String) async {
        guard let host, claim != nil, permit == nil else {
            status =
                "Cancellation blocked: an exact pre-start claim is required."
            return
        }
        do {
            let outcome = try await host.cancel(claimProof: claimProof, reason: reason)
            guard outcome == .cancelled else {
                status = "Cancellation blocked: the server did not cancel the exact claim."
                return
            }
            permit = nil
            claim = nil
            self.claimProof = nil
            recovery = outcome
            status = "Pre-start claim cancelled by the server. No action was exposed."
        } catch {
            status = "Cancellation rejected: \(error)"
        }
    }

    func recordResult(_ result: JazzArchiveJSONValue) async {
        guard let host, let permit else {
            status = "Receipt blocked: the exact start permit is unavailable."
            return
        }
        do {
            _ = try await host.recordReceipt(
                permit: permit, claimProof: claimProof, result: result)
            self.permit = nil
            self.claimProof = nil
            recovery = .receipted
            status = "Execution receipt verified and appended."
        } catch {
            status = "Receipt rejected: \(error)"
        }
    }

    func reconcileAfterCrash(
        mode: GuidedReconciliationMode,
        reason: String,
        evidence: [GuidedEvidenceReference],
        result: JazzArchiveJSONValue? = nil
    ) async {
        guard let host else {
            status = "Reconciliation blocked: no server host is configured."
            return
        }
        do {
            let recovery = try await host.reconcile(
                mode: mode, reason: reason, evidence: evidence, result: result)
            permit = nil
            claimProof = nil
            self.recovery = recovery
            status = "Execution reconciled: \(recovery)."
        } catch {
            status = "Reconciliation rejected: \(error)"
        }
    }

    func recoverServerLifecycle() async {
        guard let host else {
            status = "Recovery blocked: no server host is configured."
            return
        }
        do {
            let recovery = try await host.recover()
            permit = nil
            if recovery == .claimed {
                let recoveredClaim = try await host.claim()
                claim = recoveredClaim.claim
            } else {
                claim = nil
                claimProof = nil
            }
            self.recovery = recovery
            status =
                recovery == .reconciliationRequired
                ? "Server start exists; reconciliation is required before any retry."
                : "Recovered server lifecycle: \(recovery)."
        } catch {
            status = "Lifecycle recovery failed closed: \(error)"
        }
    }

    func stop() {
        permit = nil
        claimProof = nil
        recovery = .reconciliationRequired
        status =
            "Guided execution stopped. A started claim remains server-owned and must be reconciled."
    }

    /// Fail closed after local semantic drift or when an unclaimed prepared step is abandoned.
    /// This never releases a claim; callers must use ``cancelClaim(reason:)`` once CLAIM exists.
    func invalidatePrepared(reason: String) {
        guard claim == nil else {
            status = "Guided execution remains claimed; cancel it on the server before resetting."
            return
        }
        prepared = nil
        permit = nil
        claimProof = nil
        recovery = nil
        status = "Guided execution blocked: \(reason)"
    }

    /// Clear only after the durable attempt store has moved a server-terminal or never-claimed
    /// record into history. This is presentation cleanup, not an authority transition.
    func resetAfterSafeRetirement(status: String) {
        prepared = nil
        claim = nil
        permit = nil
        claimProof = nil
        recovery = nil
        self.status = status
    }

    func acceptServerReceipt(
        _ receipt: GuidedExecutionReceipt,
        journal: GuidedExecutionReceiptJournal
    ) async {
        guard let permit else {
            status = "Receipt rejected: it is not bound to the active permit."
            return
        }
        do {
            let document = try GuidedExecutionReceiptDocument(receipt: receipt)
            try GuidedExecutionValidator.validateReceipt(document, for: permit)
            let appended = try await journal.append(document)
            self.permit = nil
            claimProof = nil
            recovery = .receipted
            status = appended ? "Execution receipt appended." : "Execution receipt already present."
        } catch {
            status = "Receipt rejected: \(error)"
        }
    }

    /// Admit the original server payload so unknown/drifted fields cannot disappear before the
    /// append-only journal sees them. Typed receipt ingress remains useful for tests and trusted
    /// in-process construction; network adapters should call this overload.
    func acceptServerReceipt(
        _ serverData: Data,
        journal: GuidedExecutionReceiptJournal
    ) async {
        do {
            let document = try GuidedExecutionReceiptDocument(serverData: serverData)
            guard let permit else {
                status = "Receipt rejected: it is not bound to the active permit."
                return
            }
            try GuidedExecutionValidator.validateReceipt(document, for: permit)
            let appended = try await journal.append(document)
            self.permit = nil
            claimProof = nil
            recovery = .receipted
            status = appended ? "Execution receipt appended." : "Execution receipt already present."
        } catch {
            status = "Receipt rejected: \(error)"
        }
    }

    private static func makeClaimProof() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GuidedExecutionError.claimProofUnavailable
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Read-only playback surface model. Consumers may synchronize visual/audio evidence using these
/// refs, but this type has no path to the guided execution controller and cannot inject input.
@MainActor
final class EvidencePlaybackController: ObservableObject {
    @Published private(set) var items: [EvidencePlaybackItem] = []
    @Published private(set) var currentIndex: Int?

    func load(_ items: [EvidencePlaybackItem]) throws {
        try EvidencePlaybackValidator.validate(items)
        self.items = items
        currentIndex = items.isEmpty ? nil : 0
    }

    func seek(to index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }
}
