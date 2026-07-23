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
    @Published private(set) var status = ""
    private var host: GuidedExecutionHost?
    /// High-entropy bearer proof is memory-only. A process restart deliberately loses it and must
    /// use authoritative lifecycle reconciliation rather than replaying an action.
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
            status = "Prepared. A server claim and start receipt are still required."
        } catch {
            prepared = nil
            permit = nil
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
            status = "Prepared. Acquire the exclusive pre-start claim."
        } catch {
            prepared = nil
            permit = nil
            status = "Guided execution blocked: \(error)"
        }
    }

    func claimPreparedStep() async {
        guard let host, prepared != nil else {
            status = "Claim blocked: no prepared step is available."
            return
        }
        do {
            let proof = try Self.makeClaimProof()
            let document = try await host.claim(claimProof: proof)
            claimProof = proof
            claim = document.claim
            status = "Claim acquired. The step is still not authorized to act."
        } catch {
            claimProof = nil
            claim = nil
            status = "Claim blocked: \(error)"
        }
    }

    func startClaimedStep(
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) async {
        guard let host, let claimProof else {
            permit = nil
            status = "Start blocked: the memory-only claim proof is unavailable."
            return
        }
        do {
            permit = try await host.start(
                claimProof: claimProof,
                approvedRunbook: approvedRunbook,
                runtime: runtime,
                priorReceipts: priorReceipts)
            status = "Server start committed. Ready for the explicit operator action."
        } catch {
            permit = nil
            status = "Start blocked: \(error)"
        }
    }

    func recordResult(_ result: JazzArchiveJSONValue) async {
        guard let host, let permit, let claimProof else {
            status = "Receipt blocked: the exact start permit or claim proof is unavailable."
            return
        }
        do {
            _ = try await host.recordReceipt(
                permit: permit, claimProof: claimProof, result: result)
            self.permit = nil
            self.claimProof = nil
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
            claimProof = nil
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
        status =
            "Guided execution stopped. A started claim remains server-owned and must be reconciled."
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
