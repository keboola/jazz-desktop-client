import Foundation

/// Losslessly admitted server launch material. The envelope is only a portable handoff carrier:
/// the desktop re-prepares its decision with the configured server before CLAIM, and the runtime
/// seed is revalidated against live OS state before a human is guided to the target.
public struct GuidedExecutionLaunchPacket: Equatable, Sendable {
    public let approvedRunbook: GuidedApprovedRunbookPin
    public let decisionDocument: GuidedReplayDecisionDocument
    public let priorReceipts: [GuidedExecutionReceipt]
    public let runtime: GuidedRuntimeSnapshot

    public init(
        approvedRunbook: GuidedApprovedRunbookPin,
        decisionDocument: GuidedReplayDecisionDocument,
        priorReceipts: [GuidedExecutionReceipt],
        runtime: GuidedRuntimeSnapshot
    ) {
        self.approvedRunbook = approvedRunbook
        self.decisionDocument = decisionDocument
        self.priorReceipts = priorReceipts
        self.runtime = runtime
    }
}

/// Strictly admits the production server-to-desktop envelope. Conformance fixtures are not a
/// production launch authority; unknown fields, alternate protocols, and versions fail closed.
public enum GuidedExecutionLaunchPacketImporter {
    private static let productionProtocol = "dev.jazz.guided-execution-launch"
    private static let commonKeys: Set<String> = [
        "protocol",
        "protocolVersion",
        "approvedRunbook",
        "decision",
        "priorReceipts",
        "runtime",
    ]

    public static func decode(_ data: Data) throws -> GuidedExecutionLaunchPacket {
        let value = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: data)
        guard case let .object(root) = value else {
            throw GuidedExecutionError.invalidField("guided execution launch root")
        }
        guard case let .string(protocolName)? = root["protocol"],
            protocolName == productionProtocol,
            integer(root["protocolVersion"]) == 1
        else {
            throw GuidedExecutionError.invalidField("guided execution launch protocol")
        }
        guard Set(root.keys) == commonKeys else {
            throw GuidedExecutionError.invalidField("guided execution launch shape")
        }

        let approved: GuidedApprovedRunbookPin = try typed(
            root["approvedRunbook"], "approvedRunbook")
        guard let decisionValue = root["decision"] else {
            throw GuidedExecutionError.invalidField("guided execution launch decision")
        }
        let decisionDocument = try GuidedReplayDecisionDocument(
            serverData: JazzArchiveCanonicalJSON.encode(decisionValue))
        guard case let .array(receiptValues)? = root["priorReceipts"] else {
            throw GuidedExecutionError.invalidField("guided execution launch priorReceipts")
        }
        let receiptDocuments = try receiptValues.map {
            try GuidedExecutionReceiptDocument(
                serverData: JazzArchiveCanonicalJSON.encode($0))
        }
        let runtime: GuidedRuntimeSnapshot = try typed(root["runtime"], "runtime")
        let decision = decisionDocument.decision
        guard approved.status == .approved,
            approved.runbookId == decision.runbook.runbookId,
            approved.runbookVersionId == decision.runbook.runbookVersionId,
            approved.contentDigest == decision.runbook.contentDigest,
            approved.version == decision.runbook.version,
            approved.scope == decision.runbook.scope,
            decision.status == .ready,
            decision.authorizedStep != nil
        else {
            throw GuidedExecutionError.invalidField(
                "guided execution launch approved RunbookVersion pin")
        }
        guard runtime.operatorId == decision.request.operatorId,
            runtime.capabilities == decision.request.capabilities,
            runtime.preconditions == decision.request.preconditions,
            runtime.locatorResolution == decision.request.locatorResolution,
            runtime.applicationObservations == decision.request.applicationObservations,
            runtime.businessObjectInputs == decision.request.businessObjectInputs
        else {
            throw GuidedExecutionError.invalidField(
                "guided execution launch runtime/request binding")
        }
        return GuidedExecutionLaunchPacket(
            approvedRunbook: approved,
            decisionDocument: decisionDocument,
            priorReceipts: receiptDocuments.map(\.receipt),
            runtime: runtime)
    }

    private static func typed<T: Decodable>(
        _ value: JazzArchiveJSONValue?,
        _ field: String
    ) throws -> T {
        guard let value else {
            throw GuidedExecutionError.invalidField("guided execution launch \(field)")
        }
        do {
            return try JSONDecoder().decode(
                T.self, from: JazzArchiveCanonicalJSON.encode(value))
        } catch {
            throw GuidedExecutionError.invalidField("guided execution launch \(field)")
        }
    }

    private static func integer(_ value: JazzArchiveJSONValue?) -> Int? {
        switch value {
        case let .integer(number): return Int(exactly: number)
        case let .unsignedInteger(number): return Int(exactly: number)
        default: return nil
        }
    }
}
