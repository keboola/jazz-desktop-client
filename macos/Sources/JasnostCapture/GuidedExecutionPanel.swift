import AppKit
import Combine
import Foundation
import JasnostCaptureCore
import SwiftUI

@MainActor
final class GuidedExecutionWorkspace: ObservableObject {
    let controller = GuidedExecutionController()

    @Published private(set) var configurationStatus = "Checking server configuration…"
    @Published private(set) var configurationReady = false
    @Published private(set) var packetLoaded = false
    @Published private(set) var packetSummary = ""
    @Published private(set) var activeDecisionId: String?
    @Published private(set) var activeStepId: String?
    @Published private(set) var targetStatus = ""
    @Published private(set) var localPhase: GuidedExecutionLocalPhase?
    @Published private(set) var localReconciliationResolution:
        GuidedExecutionReconciliationResolution?
    @Published private(set) var isWorking = false
    @Published var operatorConfirmed = false
    @Published var completionConfirmed = false
    @Published var cancellationReason = "Operator stopped before performing the action"
    @Published var reconciliationReason = ""
    @Published var reconciliationEvidenceJSON =
        """
        [
          {
            "kind": "assertion",
            "ref": "REQUIRED_EVIDENCE"
          }
        ]
        """
    @Published var completionJSON = "" {
        didSet { persistCompletionDraftIfNeeded() }
    }

    private let root: URL
    private let attemptStore: GuidedExecutionAttemptStore
    private let receiptJournal: GuidedExecutionReceiptJournal
    private let launchPacketURL: URL
    private let completionDraftURL: URL
    private let highlight = HighlightOverlay()
    private var packet: GuidedExecutionLaunchPacket?
    private var authoritativeDocument: GuidedReplayDecisionDocument?
    private var runtime: GuidedRuntimeSnapshot?
    private var host: GuidedExecutionHost?
    private var controllerChange: AnyCancellable?
    private var suppressDraftWrite = false
    private var submittedCompletion: JazzArchiveJSONValue?
    private var submittedReconciliation: GuidedExecutionReconciliationIntent?

    init(root: URL) {
        self.root = root
        self.attemptStore = GuidedExecutionAttemptStore(
            url: root.appendingPathComponent("active-attempt.json"))
        self.receiptJournal = GuidedExecutionReceiptJournal(
            url: root.appendingPathComponent("execution-receipts.ndjson"))
        self.launchPacketURL = root.appendingPathComponent("active-launch-packet.json")
        self.completionDraftURL = root.appendingPathComponent("active-completion-draft.json")
        if let recovered = try? String(
            contentsOf: completionDraftURL, encoding: .utf8)
        {
            completionJSON = recovered
        }
        controllerChange = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var decision: GuidedReplayDecision? {
        authoritativeDocument?.decision ?? packet?.decisionDocument.decision
    }

    var permit: GuidedActionPermit? { controller.permit }

    var preflightSummary: [String] {
        guard let decision, let step = decision.authorizedStep else { return [] }
        var lines = step.applicationConstraints.constraints.map {
            "Application \($0.applicationId) \($0.versionConstraint)"
        }
        lines += step.requiredCapabilities.filter(\.required).map {
            "Capability \($0.id)@\($0.version)"
        }
        lines += step.preconditions.filter(\.required).map {
            "Precondition: \($0.description)"
        }
        lines += (packet?.runtime.businessObjectInputs ?? []).map {
            "Business object \($0.role): \($0.objectType) \($0.externalId) · \($0.freshness.status.rawValue)"
        }
        lines.append(
            "Side-effect class \(step.sideEffectClass.rawValue); approval policy \(step.approval.policy.rawValue)"
        )
        return lines
    }

    var completionSummary: [String] {
        guard let step = decision?.authorizedStep else { return [] }
        var lines = step.postconditions.filter(\.required).map {
            "Postcondition: \($0.description)"
        }
        lines += step.completionProof.map {
            "Proof \($0.kind): \($0.description)"
        }
        lines.append("Expected outcome: \(step.expectedOutcome)")
        return lines
    }

    var canPrepare: Bool {
        configurationReady && packet != nil
            && (localPhase == nil || localPhase == .prepared)
            && operatorConfirmed && !isWorking
    }

    var canStartClaimedStep: Bool {
        configurationReady && packet != nil && authoritativeDocument != nil
            && operatorConfirmed && !isWorking
    }

    var needsRecovery: Bool {
        guard let localPhase else { return false }
        if localPhase == .reconciled {
            return localReconciliationResolution == .reconciliationRequired
        }
        return ![.prepared, .refreshFailed, .expired, .receipted].contains(localPhase)
    }

    var showsRecoverySurface: Bool {
        guard let localPhase else { return false }
        if localPhase == .cancelling
            || ([.claiming, .starting, .started, .receipting, .reconciling].contains(localPhase)
                && controller.permit == nil)
        {
            return true
        }
        return controller.prepared == nil && controller.claim == nil
            && controller.permit == nil
    }

    var hasReconciliationEvidence: Bool {
        !reconciliationEvidenceJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !reconciliationEvidenceJSON.contains("REQUIRED_EVIDENCE")
    }

    func appear() async {
        await restoreLaunchPacket()
        await configure()
        await refreshLocalPhase()
    }

    func configure() async {
        isWorking = true
        defer { isWorking = false }
        guard let packet else {
            host = nil
            configurationReady = false
            configurationStatus =
                "Import a guided-execution launch packet before configuring replay."
            return
        }
        do {
            let configured = try await configuredHost(for: packet)
            applyConfiguredHost(configured.host, status: configured.status)
        } catch {
            host = nil
            configurationReady = false
            configurationStatus = "Guided execution unavailable: \(error)"
        }
    }

    func importPacket(from url: URL) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let sourceData = try Data(contentsOf: url)
            let imported = try GuidedExecutionLaunchPacketImporter.decode(sourceData)
            if let existing = try await attemptStore.load() {
                let existingDocument = try GuidedReplayDecisionDocument(
                    serverData: existing.decisionServerData)
                guard existingDocument.canonicalData
                    == imported.decisionDocument.canonicalData
                else {
                    throw GuidedExecutionError.lifecycleStateConflict(
                        "another durable attempt is active")
                }
            }
            let configured = try await configuredHost(for: imported)
            try persistLaunchPacket(sourceData)
            install(imported)
            applyConfiguredHost(configured.host, status: configured.status)
        } catch {
            packet = nil
            authoritativeDocument = nil
            runtime = nil
            host = nil
            configurationReady = false
            configurationStatus = "Guided execution unavailable: \(error)"
            packetLoaded = false
            packetSummary = ""
            targetStatus = "Launch packet blocked: \(error)"
        }
        await refreshLocalPhase()
    }

    func prepare() async {
        guard let packet, let host, configurationReady else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let recoveredAuthority = authoritativeDocument,
                recoveredAuthority.canonicalData
                    != packet.decisionDocument.canonicalData
            {
                let seed = try runtime
                    ?? GuidedRuntimeSnapshot(
                        replayRequest: recoveredAuthority.decision.request)
                let (revalidatedRuntime, _) =
                    try GuidedExecutionRuntimeResolver.revalidateTarget(
                        decision: recoveredAuthority.decision,
                        runtime: seed,
                        configuredOperatorId: configuredOperatorId,
                        operatorConfirmed: operatorConfirmed)
                try await controller.acceptServerPreparation(
                    recoveredAuthority,
                    approvedRunbook: packet.approvedRunbook,
                    runtime: revalidatedRuntime,
                    priorReceipts: packet.priorReceipts)
                guard controller.prepared != nil else {
                    throw GuidedExecutionError.lifecycleStateConflict(
                        "recovered server preparation was not persisted")
                }
                runtime = revalidatedRuntime
                activeDecisionId = recoveredAuthority.decision.decisionId
                activeStepId = recoveredAuthority.decision.authorizedStep?.stepId
                targetStatus =
                    "Recovered refresh authority was revalidated against the live target and explicitly reconfirmed. No action is exposed."
                await refreshLocalPhase()
                return
            }
            let (freshRuntime, _) = try GuidedExecutionRuntimeResolver.revalidateTarget(
                decision: packet.decisionDocument.decision,
                runtime: packet.runtime,
                configuredOperatorId: configuredOperatorId,
                operatorConfirmed: operatorConfirmed)
            targetStatus =
                "Semantic target and reviewed application match locally. Recovering exact PREPARE…"
            let recovered = try await host.recoverDecision(
                scope: packet.approvedRunbook.scope,
                decisionId: packet.decisionDocument.decision.decisionId)
            guard recovered.canonicalData == packet.decisionDocument.canonicalData else {
                throw GuidedExecutionError.contentAddressMismatch(
                    "imported decision differs from configured server")
            }

            var authoritative = recovered
            var preparedRuntime = freshRuntime
            do {
                try await controller.acceptServerPreparation(
                    recovered,
                    approvedRunbook: packet.approvedRunbook,
                    runtime: freshRuntime,
                    priorReceipts: packet.priorReceipts)
            } catch let error as GuidedExecutionError {
                guard case .staleObservation = error else { throw error }
                targetStatus =
                    "Imported PREPARE expired. Requesting atomic refresh from current native and server authority…"
                let (refreshRuntime, _) =
                    try GuidedExecutionRuntimeResolver.observeTargetForRefresh(
                        decision: recovered.decision,
                        runtime: freshRuntime,
                        configuredOperatorId: configuredOperatorId,
                        operatorConfirmed: operatorConfirmed)
                let refreshResponse = try await host.refreshDecision(
                    predecessor: recovered,
                    approvedRunbook: packet.approvedRunbook,
                    runtimeSeed: freshRuntime,
                    priorReceipts: packet.priorReceipts,
                    runtime: refreshRuntime)
                let refreshed = refreshResponse.decisionDocument
                guard refreshed.decision.status == .ready else {
                    throw GuidedExecutionError.decisionNotReady
                }
                let refreshedSeed = try GuidedRuntimeSnapshot(
                    replayRequest: refreshed.decision.request)
                let (refreshedRuntime, _) =
                    try GuidedExecutionRuntimeResolver.revalidateTarget(
                        decision: refreshed.decision,
                        runtime: refreshedSeed,
                        configuredOperatorId: configuredOperatorId,
                        operatorConfirmed: operatorConfirmed)
                try await controller.acceptServerPreparation(
                    refreshed,
                    approvedRunbook: packet.approvedRunbook,
                    runtime: refreshedRuntime,
                    priorReceipts: packet.priorReceipts)
                authoritative = refreshed
                preparedRuntime = refreshedRuntime
            }
            guard controller.prepared != nil else {
                throw GuidedExecutionError.lifecycleStateConflict(
                    "server preparation was not persisted")
            }
            let (revalidatedRuntime, _) =
                try GuidedExecutionRuntimeResolver.revalidateTarget(
                    decision: authoritative.decision,
                    runtime: preparedRuntime,
                    configuredOperatorId: configuredOperatorId,
                    operatorConfirmed: operatorConfirmed)
            authoritativeDocument = authoritative
            runtime = revalidatedRuntime
            activeDecisionId = authoritative.decision.decisionId
            activeStepId = authoritative.decision.authorizedStep?.stepId
            targetStatus =
                recovered.decision.decisionId == authoritative.decision.decisionId
                ? "Exact PREPARE is current and the semantic target resolves once. No action is exposed."
                : "Expired PREPARE was atomically refreshed and the semantic target resolves once. No action is exposed."
        } catch {
            controller.invalidatePrepared(reason: "\(error)")
            targetStatus = "PREPARE blocked: \(error)"
        }
        await refreshLocalPhase()
    }

    func claim() async {
        guard let document = authoritativeDocument, var currentRuntime = runtime else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            (currentRuntime, _) = try GuidedExecutionRuntimeResolver.revalidateTarget(
                decision: document.decision,
                runtime: currentRuntime,
                configuredOperatorId: configuredOperatorId,
                operatorConfirmed: operatorConfirmed)
            runtime = currentRuntime
            await controller.claimPreparedStep()
            targetStatus =
                controller.claim == nil
                ? "CLAIM blocked. No action is exposed."
                : "Exclusive claim acquired. START is still required before the instruction is visible."
        } catch {
            targetStatus = "CLAIM blocked by semantic revalidation: \(error)"
        }
        await refreshLocalPhase()
    }

    func start() async {
        guard let document = authoritativeDocument, let packet else {
            targetStatus =
                "START recovery is blocked because the exact launch packet or authoritative decision is unavailable."
            return
        }
        guard operatorConfirmed else {
            targetStatus =
                "Reconfirm the current operator, application, business object, and preconditions before START."
            return
        }
        var currentRuntime = runtime ?? packet.runtime
        isWorking = true
        defer { isWorking = false }
        do {
            (currentRuntime, _) = try GuidedExecutionRuntimeResolver.revalidateTarget(
                decision: document.decision,
                runtime: currentRuntime,
                configuredOperatorId: configuredOperatorId,
                operatorConfirmed: operatorConfirmed)
            runtime = currentRuntime
            guard
                let candidate = await controller.startClaimedStep(
                approvedRunbook: packet.approvedRunbook,
                runtime: currentRuntime,
                priorReceipts: packet.priorReceipts)
            else {
                targetStatus =
                    "START did not return an exact action permit. The instruction remains hidden."
                await refreshLocalPhase()
                if localPhase == .starting || localPhase == .started {
                    controller.stop()
                    targetStatus =
                        "START may already be committed. The instruction remains hidden; recover the authoritative lifecycle and reconcile before any retry."
                }
                return
            }
            // START is now committed server-side, but the instruction is still unpublished. Resolve
            // the live AX tree again after the await so an app/window/element change during the
            // network round trip can never inherit the pre-request frame.
            do {
                let target: GuidedResolvedDesktopTarget
                (currentRuntime, target) =
                    try GuidedExecutionRuntimeResolver.revalidateTarget(
                        decision: document.decision,
                        runtime: currentRuntime,
                        configuredOperatorId: configuredOperatorId,
                        operatorConfirmed: operatorConfirmed)
                guard candidate.semanticLocator.locatorId
                    == currentRuntime.locatorResolution.locatorId
                else {
                    throw GuidedExecutionDesktopError.invalidLaunchPacket(
                        "post-START locator binding")
                }
                runtime = currentRuntime
                controller.revealStartedStep(candidate)
                highlight.flash(axFrame: target.frame)
                targetStatus =
                    "START committed. \(target.applicationName): \(target.elementDescription) is highlighted; act manually."
                completionJSON = try Self.completionTemplate(
                    decision: document.decision, permit: candidate)
            } catch {
                controller.stop()
                targetStatus =
                    "START committed but post-response semantic revalidation failed. The instruction remains hidden and reconciliation is required: \(error)"
                await refreshLocalPhase()
                return
            }
        } catch {
            targetStatus = "START blocked by immediate semantic revalidation: \(error)"
        }
        await refreshLocalPhase()
    }

    func highlightTargetAgain() {
        guard let document = authoritativeDocument, let currentRuntime = runtime,
            controller.permit != nil
        else { return }
        do {
            let (_, target) = try GuidedExecutionRuntimeResolver.revalidateTarget(
                decision: document.decision,
                runtime: currentRuntime,
                configuredOperatorId: configuredOperatorId,
                operatorConfirmed: operatorConfirmed)
            highlight.flash(axFrame: target.frame)
            targetStatus =
                "\(target.applicationName): \(target.elementDescription) still resolves exactly once."
        } catch {
            controller.stop()
            targetStatus =
                "The semantic target drifted after START. Do not retry; reconcile this started attempt: \(error)"
        }
    }

    func submitCompletion() async {
        guard completionConfirmed, let permit = controller.permit, let currentRuntime = runtime
        else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try GuidedExecutionRuntimeResolver.revalidateApplication(
                applicationId: currentRuntime.locatorResolution.applicationId,
                runtime: currentRuntime)
            let result = try frozenCompletion(
                exactStartedAt: permit.startedAt, source: completionJSON)
            await controller.recordResult(result)
            guard controller.permit == nil, controller.recovery == .receipted else {
                await refreshLocalPhase()
                return
            }
            let archived = try await attemptStore.retireWhenSafe()
            try archiveAttemptSidecars(nextTo: archived)
            resetAfterRetirement(
                "Execution receipt verified, appended, and the exact attempt was archived.")
        } catch {
            targetStatus = "Completion blocked: \(error)"
        }
        await refreshLocalPhase()
    }

    func stopOrCancel() async {
        isWorking = true
        defer { isWorking = false }
        if controller.permit != nil {
            controller.stop()
            targetStatus =
                "This attempt crossed START. It was not made retryable; submit recovered evidence or record an unknown outcome."
        } else if controller.claim != nil {
            await controller.cancelClaim(reason: cancellationReason)
            if controller.recovery == .cancelled {
                do {
                    let archived = try await attemptStore.retireWhenSafe()
                    try archiveAttemptSidecars(nextTo: archived)
                    resetAfterRetirement(
                        "The server cancelled the pre-start claim; its exact attempt was archived.")
                } catch {
                    targetStatus = "Cancellation is server-terminal but local archival failed: \(error)"
                }
            }
        } else if controller.prepared != nil {
            do {
                let archived = try await attemptStore.retireWhenSafe()
                try archiveAttemptSidecars(nextTo: archived)
                controller.resetAfterSafeRetirement(
                    status: "Unclaimed PREPARE was archived. No server claim existed.")
                resetPacket()
            } catch {
                targetStatus = "Could not archive the unclaimed PREPARE: \(error)"
            }
        }
        await refreshLocalPhase()
    }

    func recoverLifecycle() async {
        isWorking = true
        defer { isWorking = false }
        if localPhase == .refreshing {
            do {
                guard let host else {
                    throw GuidedExecutionError.lifecycleStateConflict(
                        "no server host configured")
                }
                let response = try await host.resumeRefresh()
                if response.decisionDocument.decision.status == .blocked {
                    targetStatus =
                        "The server rejected the refreshed authority. No claim or action can be created; archive this safe attempt."
                } else {
                    let document = response.decisionDocument
                    let seed = try GuidedRuntimeSnapshot(
                        replayRequest: document.decision.request)
                    authoritativeDocument = document
                    runtime = seed
                    activeDecisionId = document.decision.decisionId
                    activeStepId = document.decision.authorizedStep?.stepId
                    operatorConfirmed = false
                    targetStatus =
                        "The exact refresh response was recovered. Explicitly reconfirm the operator and live context, then PREPARE this recovered authority before claiming."
                }
            } catch {
                targetStatus = "Exact refresh recovery failed closed: \(error)"
            }
        } else if localPhase == .claiming {
            await controller.resumeDurableClaim()
        } else {
            await controller.recoverServerLifecycle()
        }
        await refreshLocalPhase()
        if controller.recovery == .claimed {
            targetStatus =
                "The exact claim was recovered. Reconfirm the live operator and context; START will resolve the semantic target both before and after the server response."
        }
        if [.expired, .cancelled, .unresolved, .receipted].contains(controller.recovery) {
            do {
                let archived = try await attemptStore.retireWhenSafe()
                try archiveAttemptSidecars(nextTo: archived)
                resetAfterRetirement(
                    "Authoritative terminal lifecycle recovered and the exact attempt was archived.")
            } catch {
                targetStatus = "Lifecycle recovered, but local archival failed: \(error)"
            }
        }
    }

    func reconcileUnknown() async {
        await reconcile(mode: .unknown, result: nil)
    }

    func reconcileWithCompletion() async {
        do {
            let record = try await attemptStore.load()
            let start = try GuidedRequiredValue.unwrap(record?.startReceiptServerData)
            let startDocument = try GuidedExecutionStartReceiptDocument(serverData: start)
            let result = try frozenCompletion(
                exactStartedAt: startDocument.startReceipt.startedAt,
                source: completionJSON)
            await reconcile(mode: .receipt, result: result)
        } catch {
            targetStatus = "Recovered completion blocked: \(error)"
        }
    }

    func retireSafeAttempt() async {
        do {
            let archived = try await attemptStore.retireWhenSafe()
            try archiveAttemptSidecars(nextTo: archived)
            resetAfterRetirement("The safe local attempt was moved to immutable history.")
        } catch {
            targetStatus = "This attempt cannot be retired safely: \(error)"
        }
        await refreshLocalPhase()
    }

    private func reconcile(
        mode: GuidedReconciliationMode,
        result: JazzArchiveJSONValue?
    ) async {
        let reason = reconciliationReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            targetStatus = "A reconciliation reason is required."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let intent: GuidedExecutionReconciliationIntent
            if let frozen = submittedReconciliation {
                guard frozen.mode == mode, frozen.reason == reason, frozen.result == result else {
                    targetStatus =
                        "This caller-stable reconciliation request already has different frozen input. Recover the authoritative server lifecycle."
                    return
                }
                intent = frozen
            } else {
                let evidence = try reconciliationEvidence()
                let record = try await attemptStore.load()
                intent = GuidedExecutionReconciliationIntent(
                    mode: mode,
                    reason: reason,
                    evidence: evidence,
                    receiptRequestId: mode == .receipt
                        ? record?.requestIDs.receiptRequestId : nil,
                    result: result)
                submittedReconciliation = intent
            }
            await controller.reconcileAfterCrash(
                mode: intent.mode,
                reason: intent.reason,
                evidence: intent.evidence,
                result: intent.result)
            guard [.unresolved, .receipted].contains(controller.recovery) else {
                await refreshLocalPhase()
                return
            }
            let archived = try await attemptStore.retireWhenSafe()
            try archiveAttemptSidecars(nextTo: archived)
            let outcome =
                controller.recovery == .receipted
                ? "Recovered execution receipt was verified and appended."
                : "The server recorded the outcome as unresolved; no retry authority was created."
            resetAfterRetirement(outcome)
        } catch {
            targetStatus = "Reconciliation blocked: \(error)"
        }
        await refreshLocalPhase()
    }

    private func refreshLocalPhase() async {
        do {
            let record = try await attemptStore.load()
            localPhase = record?.phase
            if submittedCompletion == nil {
                submittedCompletion =
                    record?.receiptResult ?? record?.reconciliationIntent?.result
            }
            if submittedReconciliation == nil,
                let intent = record?.reconciliationIntent
            {
                submittedReconciliation = intent
                reconciliationReason = intent.reason
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                reconciliationEvidenceJSON = String(
                    decoding: try encoder.encode(intent.evidence),
                    as: UTF8.self)
            }
            if let data = record?.reconciliationServerData {
                localReconciliationResolution =
                    try GuidedExecutionReconciliationDocument(serverData: data)
                    .reconciliation.resolution
            } else {
                localReconciliationResolution = nil
            }
            if let record {
                let recovered = try GuidedReplayDecisionDocument(
                    serverData: record.decisionServerData)
                let decisionChanged =
                    authoritativeDocument?.canonicalData != recovered.canonicalData
                if authoritativeDocument == nil || decisionChanged {
                    authoritativeDocument = recovered
                }
                activeDecisionId = recovered.decision.decisionId
                activeStepId = recovered.decision.authorizedStep?.stepId
                if record.version == 3,
                    let approvedRunbook = record.approvedRunbook,
                    let priorReceipts = record.priorReceipts,
                    let runtimeSeed = record.runtimeSeed
                {
                    // The active journal is the recovery unit after PREPARE. Reconstruct the
                    // launch context even when its portable import sidecar is absent or points at
                    // the predecessor of a successfully refreshed decision.
                    packet = GuidedExecutionLaunchPacket(
                        approvedRunbook: approvedRunbook,
                        decisionDocument: recovered,
                        priorReceipts: priorReceipts,
                        runtime: runtimeSeed)
                    packetLoaded = true
                    packetSummary =
                        "\(recovered.decision.runbook.runbookVersionId) · "
                        + "\(recovered.decision.request.executionId)"
                    if runtime == nil || decisionChanged {
                        runtime = runtimeSeed
                    }
                }
            }
        } catch {
            localPhase = nil
            localReconciliationResolution = nil
            targetStatus = "The durable guided attempt is unreadable and was preserved: \(error)"
        }
    }

    private func restoreLaunchPacket() async {
        guard packet == nil, FileManager.default.fileExists(atPath: launchPacketURL.path) else {
            return
        }
        do {
            let sourceData = try Data(contentsOf: launchPacketURL)
            let imported = try GuidedExecutionLaunchPacketImporter.decode(sourceData)
            var recoveredAuthority: GuidedReplayDecisionDocument?
            var recoveredRuntime: GuidedRuntimeSnapshot?
            if let existing = try await attemptStore.load() {
                let existingDocument = try GuidedReplayDecisionDocument(
                    serverData: existing.decisionServerData)
                if existingDocument.canonicalData
                    != imported.decisionDocument.canonicalData
                {
                    guard let predecessorData =
                            existing.refreshPredecessorServerData,
                        let responseData = existing.refreshResponseServerData
                    else {
                        throw GuidedExecutionError.lifecycleStateConflict(
                            "saved launch packet belongs to another attempt")
                    }
                    let predecessor = try GuidedReplayDecisionDocument(
                        serverData: predecessorData)
                    let response = try GuidedExecutionRefreshResponseDocument(
                        serverData: responseData)
                    guard predecessor.canonicalData
                            == imported.decisionDocument.canonicalData,
                        response.decisionDocument.canonicalData
                            == existingDocument.canonicalData
                    else {
                        throw GuidedExecutionError.lifecycleStateConflict(
                            "saved launch packet does not bind the refreshed attempt")
                    }
                    recoveredAuthority = existingDocument
                    recoveredRuntime = existing.runtimeSeed
                }
            }
            install(imported)
            if let recoveredAuthority {
                authoritativeDocument = recoveredAuthority
                runtime = recoveredRuntime
                activeDecisionId = recoveredAuthority.decision.decisionId
                activeStepId = recoveredAuthority.decision.authorizedStep?.stepId
                targetStatus =
                    "Recovered the exact launch predecessor and its bound refreshed authority. Reconfirm live conditions and PREPARE before continuing."
            } else {
                targetStatus =
                    "Recovered the exact local launch packet. Reconfirm live conditions before continuing."
            }
        } catch {
            targetStatus =
                "Saved launch material is unreadable or mismatched and was preserved: \(error)"
        }
    }

    private func install(_ imported: GuidedExecutionLaunchPacket) {
        packet = imported
        authoritativeDocument = nil
        runtime = nil
        operatorConfirmed = false
        completionConfirmed = false
        activeDecisionId = imported.decisionDocument.decision.decisionId
        activeStepId = imported.decisionDocument.decision.authorizedStep?.stepId
        packetSummary =
            "\(imported.decisionDocument.decision.runbook.runbookVersionId) · "
            + "\(imported.decisionDocument.decision.request.executionId)"
        packetLoaded = true
        targetStatus =
            "Server launch material admitted losslessly. The exact reviewed instruction remains unavailable to this execution host until START."
    }

    private func configuredHost(
        for packet: GuidedExecutionLaunchPacket
    ) async throws -> (host: GuidedExecutionHost, status: String) {
        let settings = AgentSettings.shared
        let signedEnvelope = try SignedDeviceCredentialKeychain.vault.envelope()
        let client: GuidedExecutionHTTPClient
        let status: String

        switch try packet.transportMode() {
        case let .deviceBound(handoff):
            guard let signedEnvelope else {
                throw GuidedExecutionDesktopError.invalidLaunchPacket(
                    "device-bound replay requires completed device enrollment")
            }
            guard !handoff.isExpired() else {
                throw GuidedExecutionDesktopError.invalidLaunchPacket(
                    "desktop handoff expired; download a fresh packet")
            }
            let localOperator = settings.userEmail.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !localOperator.isEmpty, localOperator == handoff.operatorId else {
                throw GuidedExecutionDesktopError.operatorMismatch
            }
            let pinnedRoute = signedEnvelope.routeBinding
            let endpoint = try GuidedExecutionDeviceRouteBinding.validate(
                handoff: handoff,
                uploadRoute: pinnedRoute)
            _ = try signedEnvelope.archiveCredential(for: pinnedRoute)
            client = try GuidedExecutionHTTPClient(
                baseURL: endpoint,
                deviceId: pinnedRoute.scope.deviceId,
                replayCapability: handoff.capability,
                credential: {
                    try SignedDeviceCredentialKeychain.vault.archiveCredential(
                        for: pinnedRoute)
                })
            status =
                "Device-bound replay is pinned to this enrolled Mac, the signed server route, "
                + "and the currently configured authorized operator."
        case .legacy:
            #if !DEBUG
                throw GuidedExecutionDesktopError.invalidLaunchPacket(
                    "legacy v1 replay is disabled in release builds")
            #else
            guard signedEnvelope == nil else {
                throw GuidedExecutionDesktopError.invalidLaunchPacket(
                    "legacy v1 replay is disabled while the client is enrolled")
            }
            let rawEndpoint = settings.guidedExecutionURL.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard let endpoint = GuidedExecutionEndpointBinding.normalize(rawEndpoint) else {
                throw GuidedExecutionHTTPError.invalidEndpoint
            }
            guard let storedCredential =
                    (try? Keychain.get(account: Keychain.Account.guidedExecutionToken)) ?? nil
            else {
                throw GuidedExecutionHTTPError.missingCredential
            }
            guard
                GuidedExecutionEndpointBinding.token(
                    storedValue: storedCredential, matching: endpoint) != nil
            else { throw GuidedExecutionHTTPError.credentialEndpointMismatch }
            client = try GuidedExecutionHTTPClient(
                baseURL: endpoint,
                credential: {
                    guard
                        let stored =
                            (try? Keychain.get(
                                account: Keychain.Account.guidedExecutionToken)) ?? nil
                    else { return nil }
                    return GuidedExecutionEndpointBinding.token(
                        storedValue: stored, matching: endpoint)
                })
            status =
                "Legacy local/development v1 replay uses the manually bound HTTPS credential."
            #endif
        }

        let identityRoot = root.deletingLastPathComponent()
            .appendingPathComponent("archives", isDirectory: true)
        let installation = try await CaptureIdentityStore(
            root: identityRoot,
            durability: JazzArchiveFilesystemPlatform.durability,
            leaseProvider: CaptureIdentityStorePlatform.leaseProvider
        ).loadOrCreate()
        return (
            GuidedExecutionHost(
                transport: client,
                attemptStore: attemptStore,
                receiptJournal: receiptJournal,
                replayHostId: "macos-\(installation.installation.originId)"),
            status)
    }

    private func applyConfiguredHost(_ configuredHost: GuidedExecutionHost, status: String) {
        host = configuredHost
        controller.configure(host: configuredHost)
        configurationReady = true
        configurationStatus = status
    }

    private func persistLaunchPacket(_ data: Data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: launchPacketURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: launchPacketURL.path)
    }

    private var configuredOperatorId: String {
        return AgentSettings.shared.userEmail.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    private func completionValue(
        exactStartedAt: String,
        source: String
    ) throws -> JazzArchiveJSONValue {
        guard completionConfirmed else {
            throw GuidedExecutionDesktopError.explicitConfirmationRequired
        }
        guard !source.contains("REQUIRED_EVIDENCE"),
            !source.contains("REQUIRED_BRANCH"),
            !source.contains("REQUIRED_ASSIGNEE")
        else { throw GuidedExecutionDesktopError.completionEvidenceRequired }
        guard let data = source.data(using: .utf8),
            case .object(var result) = try JSONDecoder().decode(
                JazzArchiveJSONValue.self, from: data)
        else {
            throw GuidedExecutionDesktopError.invalidLaunchPacket("completion JSON")
        }
        result["startedAt"] = .string(exactStartedAt)
        result["completedAt"] = .string(Timestamps.iso8601())
        return .object(result)
    }

    private func frozenCompletion(
        exactStartedAt: String,
        source: String
    ) throws -> JazzArchiveJSONValue {
        if let submittedCompletion {
            return submittedCompletion
        }
        let result = try completionValue(
            exactStartedAt: exactStartedAt, source: source)
        submittedCompletion = result
        return result
    }

    private func reconciliationEvidence() throws -> [GuidedEvidenceReference] {
        guard hasReconciliationEvidence,
            let data = reconciliationEvidenceJSON.data(using: .utf8)
        else { throw GuidedExecutionDesktopError.completionEvidenceRequired }
        let evidence = try JSONDecoder().decode(
            [GuidedEvidenceReference].self, from: data)
        guard !evidence.isEmpty,
            evidence.allSatisfy({
                !$0.ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else { throw GuidedExecutionDesktopError.completionEvidenceRequired }
        return evidence
    }

    private func resetAfterRetirement(_ status: String) {
        controller.resetAfterSafeRetirement(status: status)
        targetStatus = status
        resetPacket()
    }

    private func resetPacket() {
        packet = nil
        authoritativeDocument = nil
        runtime = nil
        packetLoaded = false
        packetSummary = ""
        activeDecisionId = nil
        activeStepId = nil
        operatorConfirmed = false
        completionConfirmed = false
        submittedCompletion = nil
        submittedReconciliation = nil
        reconciliationReason = ""
        reconciliationEvidenceJSON =
            """
            [
              {
                "kind": "assertion",
                "ref": "REQUIRED_EVIDENCE"
              }
            ]
            """
        suppressDraftWrite = true
        completionJSON = ""
        suppressDraftWrite = false
        highlight.hide()
    }

    private func persistCompletionDraftIfNeeded() {
        guard !suppressDraftWrite, !completionJSON.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            try Data(completionJSON.utf8).write(to: completionDraftURL, options: .atomic)
        } catch {
            targetStatus =
                "Completion evidence is still in memory, but its durable draft could not be updated: \(error)"
        }
    }

    private func archiveAttemptSidecars(nextTo attemptURL: URL) throws {
        let historyRoot = attemptURL.deletingLastPathComponent()
        for (source, prefix) in [
            (launchPacketURL, "launch-packet"),
            (completionDraftURL, "completion-input"),
        ] where FileManager.default.fileExists(atPath: source.path) {
            let destination = historyRoot.appendingPathComponent(
                "\(prefix)-\(Identifiers.newUUIDv7().uuidString.lowercased()).json")
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                throw GuidedExecutionError.lifecycleWriteFailed
            }
        }
    }

    private static func completionTemplate(
        decision: GuidedReplayDecision,
        permit: GuidedActionPermit
    ) throws -> String {
        guard let step = decision.authorizedStep else {
            throw GuidedExecutionDesktopError.invalidLaunchPacket("authorizedStep")
        }
        let now = Timestamps.iso8601()
        let evidence: [[String: Any]] = [
            ["kind": "assertion", "ref": "REQUIRED_EVIDENCE"]
        ]
        let proofs: [[String: Any]] = step.completionProof.map {
            [
                "kind": $0.kind,
                "description": $0.description,
                "proofRef": "REQUIRED_EVIDENCE",
                "assertedBy": permit.operatorId,
                "assertedAt": now,
                "evidence": evidence,
            ]
        }
        let postconditions: [[String: Any]] = step.postconditions.filter(\.required).map {
            [
                "conditionId": $0.conditionId,
                "satisfied": true,
                "evidence": evidence,
            ]
        }
        let branch: [String: Any]
        if step.controlFlow.mode == .decision {
            branch = [
                "state": "selected",
                "branchId": "REQUIRED_BRANCH",
                "outcome": "REQUIRED_BRANCH",
                "evidence": evidence,
            ]
        } else {
            branch = ["state": "notApplicable", "evidence": []]
        }
        let handoff: [String: Any]
        if step.handoff.mode == .transfer {
            handoff = [
                "state": "accepted",
                "recipientRole": step.handoff.recipientRole ?? "",
                "nextAssigneeId": "REQUIRED_ASSIGNEE",
                "eligibleRole": step.handoff.recipientRole ?? "",
                "conditionsMet": step.handoff.acceptanceConditions,
                "evidence": evidence,
            ]
        } else {
            handoff = [
                "state": "notApplicable",
                "conditionsMet": [],
                "evidence": [],
            ]
        }
        let object: [String: Any] = [
            "status": "succeeded",
            "startedAt": permit.startedAt,
            "completedAt": now,
            "proofs": proofs,
            "postconditions": postconditions,
            "branchDecision": branch,
            "handoffOutcome": handoff,
            "sideEffects": [
                [
                    "classification": step.sideEffectClass.rawValue,
                    "outcome": "observed",
                    "description": step.expectedOutcome,
                    "evidence": evidence,
                ]
            ],
            "interventions": [],
            "result": [
                "state": "completed",
                "summary": step.expectedOutcome,
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ object: Any) throws -> T {
        try JSONDecoder().decode(
            T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// Small optional unwrap helper which does not pull XCTest into the executable target.
private enum GuidedRequiredValue {
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else {
            throw GuidedExecutionError.lifecycleStateConflict("missing start receipt")
        }
        return value
    }
}

struct GuidedExecutionView: View {
    @StateObject var workspace: GuidedExecutionWorkspace
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                configuration
                recovery
                launch
                lifecycle
                status
            }
            .padding(18)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 680)
        .task { await workspace.appear() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Guided execution", systemImage: "person.crop.circle.badge.checkmark")
                .font(.title2.weight(.semibold))
            Text(
                "This is not evidence playback. Jazz only reveals one server-authorized instruction "
                    + "after PREPARE, an exclusive CLAIM, and the exact START receipt. You perform "
                    + "the action manually; Jazz never injects clicks, keys, or coordinates."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var configuration: some View {
        GroupBox("Server boundary") {
            HStack(alignment: .top) {
                Image(
                    systemName: workspace.configurationReady
                        ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .foregroundStyle(workspace.configurationReady ? .green : .orange)
                Text(workspace.configurationStatus)
                    .font(.callout)
                Spacer()
                Button("Reload") {
                    Task { await workspace.configure() }
                }
                Button("Settings…", action: onOpenSettings)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var recovery: some View {
        if workspace.showsRecoverySurface, let phase = workspace.localPhase {
            GroupBox("Durable attempt recovery") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local phase: \(phase.rawValue)")
                        .font(.system(.callout, design: .monospaced))
                    if workspace.needsRecovery {
                        Text(
                            recoveryGuidance(for: phase)
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        Button("Recover authoritative lifecycle") {
                            Task { await workspace.recoverLifecycle() }
                        }
                        .disabled(workspace.isWorking)
                    } else {
                        Button("Archive safe attempt locally") {
                            Task { await workspace.retireSafeAttempt() }
                        }
                        .disabled(workspace.isWorking)
                    }
                }
                .padding(4)
            }
        }
    }

    private var launch: some View {
        GroupBox("Server-issued launch material") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Import guided execution JSON…") { importPacket() }
                        .disabled(workspace.isWorking)
                    if workspace.packetLoaded {
                        Text(workspace.packetSummary)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(
                    "The packet carries the exact approved RunbookVersion pin, content-addressed "
                        + "decision, runtime/anchor context, and prior receipts. Its evidence timeline "
                        + "is deliberately not connected to this execution surface."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if !workspace.preflightSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Confirm against the live system:")
                            .font(.caption.weight(.semibold))
                        ForEach(
                            Array(workspace.preflightSummary.enumerated()),
                            id: \.offset
                        ) { _, item in
                            Label(item, systemImage: "checklist")
                                .font(.caption)
                        }
                    }
                }
                Toggle(
                    "I am the named operator and confirm the current app, business object, and preconditions",
                    isOn: $workspace.operatorConfirmed)
                if let decisionId = workspace.activeDecisionId,
                    let stepId = workspace.activeStepId
                {
                    Text("Decision \(decisionId) · step \(stepId)")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
                Button("PREPARE with server") {
                    Task { await workspace.prepare() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!workspace.canPrepare)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var lifecycle: some View {
        if workspace.controller.prepared != nil, workspace.controller.claim == nil,
            workspace.controller.permit == nil
        {
            GroupBox("Prepared — no action authority") {
                HStack {
                    Button("CLAIM this step exclusively") {
                        Task { await workspace.claim() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.isWorking)
                    Button("Stop before claim") {
                        Task { await workspace.stopOrCancel() }
                    }
                    .disabled(workspace.isWorking)
                }
                .padding(4)
            }
        }
        if workspace.controller.claim != nil, workspace.controller.permit == nil,
            workspace.localPhase == .claimed
        {
            GroupBox("Claimed — exact instruction not yet revealed") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Cancellation reason", text: $workspace.cancellationReason)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("START and reveal one manual action") {
                            Task { await workspace.start() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!workspace.canStartClaimedStep)
                        Button("Cancel claim on server") {
                            Task { await workspace.stopOrCancel() }
                        }
                        .disabled(
                            workspace.isWorking
                                || workspace.cancellationReason.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty)
                    }
                    if !workspace.operatorConfirmed {
                        Text(
                            "A recovered claim cannot START until you explicitly reconfirm the live operator and context above."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(4)
            }
        }
        if let permit = workspace.permit {
            GroupBox("Started — operator action") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Server START receipt verified", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(permit.instruction)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text("Expected outcome: \(permit.expectedOutcome)")
                    Text(
                        "Actor: \(permit.actorRole) · side effect: \(permit.sideEffectClass.rawValue)"
                    )
                    .font(.caption.monospaced())
                    HStack {
                        Button("Highlight semantic target again") {
                            workspace.highlightTargetAgain()
                        }
                        Button("Stop — outcome needs reconciliation") {
                            Task { await workspace.stopOrCancel() }
                        }
                    }
                    Divider()
                    completionEditor
                    Button("Submit exact completion to server") {
                        Task { await workspace.submitCompletion() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        workspace.isWorking || !workspace.completionConfirmed
                            || workspace.completionJSON.isEmpty)
                }
                .padding(4)
            }
        } else if workspace.controller.recovery == .reconciliationRequired
            || workspace.localPhase == .started || workspace.localPhase == .reconciling
        {
            GroupBox("Started attempt — reconciliation only") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "A server START exists. This surface will not recreate the permit or retry the action."
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    TextField("What is known about the outcome?", text: $workspace.reconciliationReason)
                        .textFieldStyle(.roundedBorder)
                    Text(
                        "Current-state evidence references (not replay coordinates or an invented local proof):"
                    )
                    .font(.caption)
                    TextEditor(text: $workspace.reconciliationEvidenceJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 90)
                        .border(.separator)
                    completionEditor
                    HStack {
                        Button("Submit recovered completion evidence") {
                            Task { await workspace.reconcileWithCompletion() }
                        }
                        .disabled(
                            workspace.isWorking || !workspace.completionConfirmed
                                || workspace.completionJSON.isEmpty
                                || !workspace.hasReconciliationEvidence)
                        Button("Record outcome as unknown") {
                            Task { await workspace.reconcileUnknown() }
                        }
                        .disabled(
                            workspace.isWorking
                                || workspace.reconciliationReason.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                                || !workspace.hasReconciliationEvidence)
                    }
                }
                .padding(4)
            }
        }
    }

    private var completionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(
                Array(workspace.completionSummary.enumerated()),
                id: \.offset
            ) { _, requirement in
                Label(requirement, systemImage: "checkmark.circle")
                    .font(.caption)
            }
            Text(
                "Structured completion evidence (server validates exact postconditions, side effect, "
                    + "branch/handoff, and connector/object proof):"
            )
            .font(.caption)
            TextEditor(text: $workspace.completionJSON)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 180)
                .border(.separator)
            Toggle(
                "I verified every required postcondition and evidence reference after the action",
                isOn: $workspace.completionConfirmed)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !workspace.controller.status.isEmpty {
                Text(workspace.controller.status)
                    .font(.callout)
            }
            if !workspace.targetStatus.isEmpty {
                Text(workspace.targetStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recoveryGuidance(for phase: GuidedExecutionLocalPhase) -> String {
        switch phase {
        case .refreshing:
            return
                "The refresh response may have been lost. Retry the exact frozen request identity and native observations; do not create a new PREPARE."
        case .claiming:
            return
                "CLAIM may have crossed the network boundary. Retry the exact durable proof and caller-stable request identity; no new claim is minted."
        case .cancelling:
            return
                "Cancellation crossed an uncertain network boundary. Read the exact server lifecycle before START can be offered again."
        default:
            return
                "Read the exact claim lifecycle from the server. Recovery never reissues an action permit."
        }
    }

    private func importPacket() {
        let panel = NSOpenPanel()
        panel.title = "Import server-issued guided execution JSON"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await workspace.importPacket(from: url) }
    }
}
