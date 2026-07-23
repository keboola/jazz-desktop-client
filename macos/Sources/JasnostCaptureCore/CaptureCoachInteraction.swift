import Foundation

/// Client-side audit event for Capture Coach. Semantic assessment and prompt selection remain
/// server concerns; this payload records only control data the client received and what the user
/// actually saw or did.
public struct CaptureCoachInteraction: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var interactionId: String
    public var interactionType: CaptureCoachInteractionType
    public var occurredAt: String
    public var promptId: String?
    public var labelId: String?
    public var assessmentRef: CaptureCoachAssessmentRef?
    public var localBaselineRef: CaptureCoachLocalBaselineRef?
    public var inputWatermark: CaptureCoachInputWatermark?
    public var promptSnapshot: CaptureCoachPromptSnapshot?
    public var answer: CaptureCoachAnswer?
    public var dispositionReason: CaptureCoachDispositionReason?
    public var mutedUntil: String?
    public var extensions: [String: JazzArchiveJSONValue]?

    public init(
        schemaVersion: Int = CaptureCoachInteraction.currentSchemaVersion,
        interactionId: String = Identifiers.newCoachInteractionId(),
        interactionType: CaptureCoachInteractionType,
        occurredAt: String = Timestamps.iso8601(),
        promptId: String? = nil,
        labelId: String? = nil,
        assessmentRef: CaptureCoachAssessmentRef? = nil,
        localBaselineRef: CaptureCoachLocalBaselineRef? = nil,
        inputWatermark: CaptureCoachInputWatermark? = nil,
        promptSnapshot: CaptureCoachPromptSnapshot? = nil,
        answer: CaptureCoachAnswer? = nil,
        dispositionReason: CaptureCoachDispositionReason? = nil,
        mutedUntil: String? = nil,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.interactionId = interactionId
        self.interactionType = interactionType
        self.occurredAt = occurredAt
        self.promptId = promptId
        self.labelId = labelId
        self.assessmentRef = assessmentRef
        self.localBaselineRef = localBaselineRef
        self.inputWatermark = inputWatermark
        self.promptSnapshot = promptSnapshot
        self.answer = answer
        self.dispositionReason = dispositionReason
        self.mutedUntil = mutedUntil
        self.extensions = extensions
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CaptureCoachContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try CaptureCoachContractValidation.uuidV7(interactionId, prefix: "coach")
        guard Timestamps.parse(occurredAt) != nil else {
            throw CaptureCoachContractError.invalidField("occurredAt")
        }
        if let promptId {
            try CaptureCoachContractValidation.uuidV7(promptId, prefix: "prompt")
        }
        if let labelId {
            try CaptureCoachContractValidation.uuidV7(labelId, prefix: "l")
        }
        try assessmentRef?.validate()
        try localBaselineRef?.validate()
        try inputWatermark?.validate()
        try promptSnapshot?.validate()
        try answer?.validate()
        if let mutedUntil, Timestamps.parse(mutedUntil) == nil {
            throw CaptureCoachContractError.invalidField("mutedUntil")
        }

        if interactionType.isPromptScoped {
            guard promptId != nil, inputWatermark != nil,
                (assessmentRef != nil) != (localBaselineRef != nil)
            else {
                throw CaptureCoachContractError.invalidField("prompt context")
            }
        }
        if interactionType == .received || interactionType == .shown {
            guard promptSnapshot != nil else {
                throw CaptureCoachContractError.invalidField("promptSnapshot")
            }
        }
        if interactionType == .answered, answer == nil {
            throw CaptureCoachContractError.invalidField("answer")
        }
        if interactionType == .suppressed || interactionType == .unavailable {
            guard dispositionReason != nil else {
                throw CaptureCoachContractError.invalidField("dispositionReason")
            }
        }
    }
}

public enum CaptureCoachInteractionType: String, Codable, CaseIterable, Equatable, Sendable {
    case received
    case shown
    case answered
    case dismissed
    case muted
    case resumed
    case finishAnyway = "finish_anyway"
    case suppressed
    case unavailable

    fileprivate var isPromptScoped: Bool {
        switch self {
        case .received, .shown, .answered, .dismissed, .suppressed: return true
        case .muted, .resumed, .finishAnyway, .unavailable: return false
        }
    }
}

/// Pins a deterministic, evidence-agnostic question plan that can run entirely offline. Unlike
/// ``CaptureCoachAssessmentRef`` it makes no claim that captured narration or screen evidence was
/// semantically evaluated.
public struct CaptureCoachLocalBaselineRef: Codable, Equatable, Sendable {
    public var planId: String
    public var planVersion: String
    public var planDigest: String

    public init(planId: String, planVersion: String, planDigest: String) {
        self.planId = planId
        self.planVersion = planVersion
        self.planDigest = planDigest
    }

    fileprivate func validate() throws {
        guard !planId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !planVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CaptureCoachContractError.invalidField("localBaselineRef") }
        try CaptureCoachContractValidation.sha256(
            planDigest, field: "localBaselineRef.planDigest")
    }
}

public struct CaptureCoachAssessmentRef: Codable, Equatable, Sendable {
    public var assessmentId: String
    public var revision: Int
    public var inputDigest: String

    public init(assessmentId: String, revision: Int, inputDigest: String) {
        self.assessmentId = assessmentId
        self.revision = revision
        self.inputDigest = inputDigest
    }

    fileprivate func validate() throws {
        try CaptureCoachContractValidation.uuidV7(assessmentId, prefix: "cqa")
        guard revision >= 1 else {
            throw CaptureCoachContractError.invalidField("assessmentRef.revision")
        }
        try CaptureCoachContractValidation.sha256(
            inputDigest, field: "assessmentRef.inputDigest")
    }
}

public struct CaptureCoachInputWatermark: Codable, Equatable, Sendable {
    public var captureId: String
    public var streams: [CaptureCoachStreamWatermark]
    public var captureCommitId: String?

    public init(
        captureId: String,
        streams: [CaptureCoachStreamWatermark],
        captureCommitId: String? = nil
    ) {
        self.captureId = captureId
        self.streams = streams
        self.captureCommitId = captureCommitId
    }

    fileprivate func validate() throws {
        try CaptureCoachContractValidation.uuidV7(captureId, prefix: "cap")
        guard !streams.isEmpty else {
            throw CaptureCoachContractError.invalidField("inputWatermark.streams")
        }
        guard Set(streams.map(\.streamId)).count == streams.count else {
            throw CaptureCoachContractError.invalidField("inputWatermark.streams")
        }
        for stream in streams { try stream.validate() }
        if let captureCommitId {
            try CaptureCoachContractValidation.uuidV7(captureCommitId, prefix: "cmt")
        }
    }
}

public struct CaptureCoachStreamWatermark: Codable, Equatable, Sendable {
    public var streamId: String
    public var throughSequence: Int

    public init(streamId: String, throughSequence: Int) {
        self.streamId = streamId
        self.throughSequence = throughSequence
    }

    fileprivate func validate() throws {
        try CaptureCoachContractValidation.uuidV7(streamId, prefix: "stream")
        guard throughSequence >= 0 else {
            throw CaptureCoachContractError.invalidField(
                "inputWatermark.streams.throughSequence")
        }
    }
}

public enum CaptureCoachSemanticSlot: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case intent
    case inputOrObject = "input_or_object"
    case decisionRule = "decision_rule"
    case expectedOutput = "expected_output"
    case success
    case exception
    case handoff
}

public enum CaptureCoachResponseMode: String, Codable, CaseIterable, Equatable, Sendable {
    case typedText = "typed_text"
    case spoken
}

public struct CaptureCoachPromptSnapshot: Codable, Equatable, Sendable {
    public var text: String
    public var slot: CaptureCoachSemanticSlot
    public var policyVersion: String
    public var responseModes: [CaptureCoachResponseMode]

    public init(
        text: String,
        slot: CaptureCoachSemanticSlot,
        policyVersion: String,
        responseModes: [CaptureCoachResponseMode]
    ) {
        self.text = text
        self.slot = slot
        self.policyVersion = policyVersion
        self.responseModes = responseModes
    }

    fileprivate func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !policyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !responseModes.isEmpty,
            Set(responseModes).count == responseModes.count
        else { throw CaptureCoachContractError.invalidField("promptSnapshot") }
    }
}

public struct CaptureCoachAnswer: Codable, Equatable, Sendable {
    public var mode: CaptureCoachResponseMode
    public var text: String?
    public var narrationArtifactId: String?

    public init(
        mode: CaptureCoachResponseMode,
        text: String? = nil,
        narrationArtifactId: String? = nil
    ) {
        self.mode = mode
        self.text = text
        self.narrationArtifactId = narrationArtifactId
    }

    fileprivate func validate() throws {
        switch mode {
        case .typedText:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                narrationArtifactId == nil
            else {
                throw CaptureCoachContractError.invalidField("answer.text")
            }
        case .spoken:
            guard let narrationArtifactId, text == nil else {
                throw CaptureCoachContractError.invalidField("answer.narrationArtifactId")
            }
            try CaptureCoachContractValidation.uuidV7(narrationArtifactId, prefix: "art")
        }
    }
}

/// Stable identity reserved when a label's microphone actually starts. A spoken Coach answer is
/// materialized only after the journal confirms that this exact canonical artifact was persisted.
public struct CaptureCoachNarrationReservation: Equatable, Sendable {
    public var labelId: String
    public var artifactId: String

    public init(labelId: String, artifactId: String) throws {
        try CaptureCoachContractValidation.uuidV7(labelId, prefix: "l")
        try CaptureCoachContractValidation.uuidV7(artifactId, prefix: "art")
        self.labelId = labelId
        self.artifactId = artifactId
    }

    public func spokenAnswer(persistedArtifactId: String?) throws -> CaptureCoachAnswer {
        guard persistedArtifactId == artifactId else {
            throw CaptureCoachSpokenAnswerError.narrationArtifactUnavailable(artifactId)
        }
        let answer = CaptureCoachAnswer(mode: .spoken, narrationArtifactId: artifactId)
        try answer.validate()
        return answer
    }
}

public enum CaptureCoachSpokenAnswerError: Error, Equatable, CustomStringConvertible {
    case labelNotOpen
    case microphoneNotRecording
    case modeNotOffered
    case narrationArtifactUnavailable(String)

    public var description: String {
        switch self {
        case .labelNotOpen: "Open a label before answering aloud"
        case .microphoneNotRecording: "The microphone is not recording this label"
        case .modeNotOffered: "This Coach prompt does not accept a spoken answer"
        case let .narrationArtifactUnavailable(id):
            "Narration artifact was not persisted: \(id)"
        }
    }
}

public enum CaptureCoachDispositionReason: String, Codable, CaseIterable, Equatable, Sendable {
    case duplicate
    case staleWatermark = "stale_watermark"
    case closedLabel = "closed_label"
    case committedCapture = "committed_capture"
    case offline
    case coachUnavailable = "coach_unavailable"
    case rateLimited = "rate_limited"
    case userAction = "user_action"
    case unsupportedVersion = "unsupported_version"
}

public enum CaptureCoachContractError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case invalidField(String)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Unsupported Capture Coach schema version: \(version)"
        case let .invalidField(field):
            "Invalid Capture Coach field: \(field)"
        }
    }
}

private enum CaptureCoachContractValidation {
    static func uuidV7(_ value: String, prefix: String) throws {
        let marker = prefix + "-"
        guard value.hasPrefix(marker) else {
            throw CaptureCoachContractError.invalidField(prefix)
        }
        let raw = String(value.dropFirst(marker.count))
        guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else {
            throw CaptureCoachContractError.invalidField(prefix)
        }
        let chars = Array(raw)
        guard chars.count == 36, chars[14] == "7", "89ab".contains(chars[19]) else {
            throw CaptureCoachContractError.invalidField(prefix)
        }
    }

    static func sha256(_ value: String, field: String) throws {
        guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw CaptureCoachContractError.invalidField(field) }
    }
}

extension JazzArchiveContract {
    public static let captureCoachInteraction = JazzArchiveContract(
        recordType: "jazz.coach-interaction",
        schemaId: "https://jasnost.dev/schema/coach-interaction.schema.json",
        schemaVersion: 1)
}

extension ArchiveRecord where Payload == CaptureCoachInteraction {
    public static let coachRecordType = "jazz.coach-interaction"
    public static let coachPayloadSchema =
        "https://jasnost.dev/schema/coach-interaction.schema.json"

    public init(
        interaction: CaptureCoachInteraction,
        observationId: String = Identifiers.newObservationId(),
        originId: String,
        captureId: String,
        streamId: String,
        streamSequence: Int,
        capturedAt: String? = nil,
        sourceRefs: [JazzArchiveSourceRef],
        actorRefs: [JazzArchiveActorRef],
        provenance: JazzArchiveProvenance,
        quality: JazzArchiveQuality,
        privacy: JazzArchivePrivacy,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        self.init(
            observationId: observationId,
            recordType: Self.coachRecordType,
            payloadSchema: Self.coachPayloadSchema,
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            streamSequence: streamSequence,
            capturedAt: capturedAt ?? interaction.occurredAt,
            occurredAt: interaction.occurredAt,
            sourceRefs: sourceRefs,
            actorRefs: actorRefs,
            labelRefs: interaction.labelId.map { [$0] } ?? [],
            payload: interaction,
            provenance: provenance,
            quality: quality,
            privacy: privacy,
            extensions: extensions)
    }

    public func validate(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        try validateEnvelope(manifest: manifest, session: session)
        guard recordType == Self.coachRecordType, payloadSchema == Self.coachPayloadSchema else {
            throw CaptureCoachContractError.invalidField("record contract")
        }
        try payload.validate()
        guard payload.inputWatermark?.captureId == nil
                || payload.inputWatermark?.captureId == captureId
        else { throw CaptureCoachContractError.invalidField("inputWatermark.captureId") }
        if let labelId = payload.labelId, !labelRefs.contains(labelId) {
            throw CaptureCoachContractError.invalidField("labelRefs")
        }
    }
}
