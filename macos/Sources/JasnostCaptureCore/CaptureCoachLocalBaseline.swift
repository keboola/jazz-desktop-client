import Foundation

public struct CaptureCoachLocalBaselineTemplate: Codable, Equatable, Sendable {
    public var slot: CaptureCoachSemanticSlot
    public var text: String

    public init(slot: CaptureCoachSemanticSlot, text: String) {
        self.slot = slot
        self.text = text
    }
}

/// A deterministic, evidence-agnostic fallback that can nudge a narrator while the client is
/// offline. It deliberately does not inspect events, audio, transcripts, or answers. The digest
/// pins the exact questions and timing policy so downstream can distinguish this checklist from a
/// server-owned semantic assessment.
public struct CaptureCoachLocalBaselinePlan: Equatable, Sendable {
    public static let current = CaptureCoachLocalBaselinePlan(
        planId: "capture-coach-local-baseline",
        planVersion: "1.0.0",
        initialDelaySeconds: 20,
        cadenceSeconds: 45,
        templates: [
            CaptureCoachLocalBaselineTemplate(
                slot: .intent,
                text: "What business outcome are you trying to achieve here?"),
            CaptureCoachLocalBaselineTemplate(
                slot: .inputOrObject,
                text: "Which business item or input are you working with?"),
            CaptureCoachLocalBaselineTemplate(
                slot: .decisionRule,
                text: "What rule tells you which option or next step to choose?"),
            CaptureCoachLocalBaselineTemplate(
                slot: .expectedOutput,
                text: "What should this work produce when it is complete?"),
            CaptureCoachLocalBaselineTemplate(
                slot: .success,
                text: "How do you verify that this step succeeded?"),
            CaptureCoachLocalBaselineTemplate(
                slot: .exception,
                text: "What exception would make you handle this differently?"),
            CaptureCoachLocalBaselineTemplate(
                slot: .handoff,
                text: "Who or what receives the result next, and in what state?"),
        ])

    public var planId: String
    public var planVersion: String
    public var initialDelaySeconds: TimeInterval
    public var cadenceSeconds: TimeInterval
    public var templates: [CaptureCoachLocalBaselineTemplate]

    public init(
        planId: String,
        planVersion: String,
        initialDelaySeconds: TimeInterval,
        cadenceSeconds: TimeInterval,
        templates: [CaptureCoachLocalBaselineTemplate]
    ) {
        self.planId = planId
        self.planVersion = planVersion
        self.initialDelaySeconds = initialDelaySeconds
        self.cadenceSeconds = cadenceSeconds
        self.templates = templates
    }

    public var reference: CaptureCoachLocalBaselineRef {
        CaptureCoachLocalBaselineRef(
            planId: planId,
            planVersion: planVersion,
            planDigest: JazzArchiveDigest.sha256Hex(canonicalDigestMaterial()))
    }

    public func validate() throws {
        guard !planId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !planVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            initialDelaySeconds.isFinite,
            initialDelaySeconds >= 0,
            initialDelaySeconds.rounded() == initialDelaySeconds,
            cadenceSeconds.isFinite,
            cadenceSeconds > 0,
            cadenceSeconds.rounded() == cadenceSeconds,
            !templates.isEmpty,
            Set(templates.map(\.slot)).count == templates.count,
            templates.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw CaptureCoachContractError.invalidField("local baseline plan") }
        try reference.validateForPlan()
    }

    public func prompt(
        at index: Int,
        labelId: String,
        inputWatermark: CaptureCoachInputWatermark,
        responseModes: [CaptureCoachResponseMode]
    ) throws -> CaptureCoachPrompt? {
        try validate()
        guard templates.indices.contains(index) else { return nil }
        let template = templates[index]
        let prompt = CaptureCoachPrompt(
            promptId: Identifiers.newCoachPromptId(),
            labelId: labelId,
            localBaselineRef: reference,
            inputWatermark: inputWatermark,
            snapshot: CaptureCoachPromptSnapshot(
                text: template.text,
                slot: template.slot,
                policyVersion: "local-baseline/\(planVersion)",
                responseModes: responseModes))
        try prompt.validate(for: inputWatermark.captureId)
        return prompt
    }

    private struct DigestMaterial: Encodable {
        var cadenceSeconds: Int
        var initialDelaySeconds: Int
        var planId: String
        var planVersion: String
        var templates: [CaptureCoachLocalBaselineTemplate]
    }

    private func canonicalDigestMaterial() -> Data {
        precondition(initialDelaySeconds.rounded() == initialDelaySeconds)
        precondition(cadenceSeconds.rounded() == cadenceSeconds)
        let material = DigestMaterial(
            cadenceSeconds: Int(cadenceSeconds),
            initialDelaySeconds: Int(initialDelaySeconds),
            planId: planId,
            planVersion: planVersion,
            templates: templates)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(material)
    }
}

extension CaptureCoachLocalBaselineRef {
    fileprivate func validateForPlan() throws {
        guard planDigest.count == 64,
            planDigest.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw CaptureCoachContractError.invalidField("localBaselineRef.planDigest") }
    }
}
