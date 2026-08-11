import Foundation

struct CaptureCoachReviewCanonicalLabel {
    let labelId: String
    let captureId: String
    let declarationText: String
    let processName: String?
    let startStreamSequence: Int
}

/// A structural, offline review of what Capture Coach displayed and whether the user recorded a
/// typed or spoken response. It never evaluates whether an answer is correct, complete, relevant,
/// or consistent with the captured process.
public struct CaptureCoachReviewSummary: Equatable, Sendable {
    public let labels: [CaptureCoachReviewLabelSummary]
    public let slots: [CaptureCoachReviewSlotSummary]
    public let presentedPromptCount: Int
    public let finishAnywayObserved: Bool
    public let muteState: CaptureCoachReviewMuteState
    public let mutedUntil: String?

    public var shownSlots: [CaptureCoachSemanticSlot] {
        slots.map(\.slot)
    }

    public var answeredSlots: [CaptureCoachSemanticSlot] {
        slots.filter { $0.state == .answered }.map(\.slot)
    }

    public var unansweredSlots: [CaptureCoachSemanticSlot] {
        slots.filter { $0.state == .unanswered }.map(\.slot)
    }

    /// An `unavailable` audit record only says that the optional server-side Coach was absent. It
    /// is not a review interaction and must not manufacture an explanation checklist.
    public var hasReviewActivity: Bool {
        presentedPromptCount > 0
            || finishAnywayObserved
            || muteState != .neverMuted
    }

    /// Capture confirmation is a human decision. This checklist is advisory in every state.
    public var allowsConfirmation: Bool { true }

    /// Production reducer for canonical archive evidence. `canonicalLabels` and
    /// `humanActorIds` must come from the same verified archive snapshot as `canonicalRecords`;
    /// without that registry a prompt answer cannot be treated as human process evidence.
    public init(
        canonicalRecords: [JazzArchiveRecord],
        canonicalLabels: [JazzArchiveLabel],
        humanActorIds: Set<String>
    ) throws {
        try self.init(
            canonicalRecords: canonicalRecords,
            canonicalLabelRegistry: canonicalLabels.map {
                CaptureCoachReviewCanonicalLabel(
                    labelId: $0.labelId,
                    captureId: $0.captureId,
                    declarationText: $0.declaration.text,
                    processName: $0.processBinding?.nameSnapshot,
                    startStreamSequence:
                        $0.interval.startStreamSequence)
            },
            humanActorIds: humanActorIds)
    }

    init(
        canonicalRecords: [JazzArchiveRecord],
        canonicalLabelRegistry: [CaptureCoachReviewCanonicalLabel],
        humanActorIds: Set<String>
    ) throws {
        var captureByLabelId: [String: String] = [:]
        for label in canonicalLabelRegistry {
            guard captureByLabelId.updateValue(
                label.captureId,
                forKey: label.labelId) == nil
            else {
                throw CaptureCoachReviewSummaryError.duplicateCanonicalLabel(
                    label.labelId)
            }
        }
        let labelDescriptors = canonicalLabelRegistry.sorted {
            if $0.startStreamSequence != $1.startStreamSequence
            {
                return $0.startStreamSequence < $1.startStreamSequence
            }
            return Data($0.labelId.utf8).lexicographicallyPrecedes(
                Data($1.labelId.utf8))
        }.map {
            CaptureCoachReviewLabelDescriptor(
                labelId: $0.labelId,
                declarationText: $0.declarationText,
                processName: $0.processName)
        }

        var orderedInteractions: [CaptureCoachReviewOrderedInteraction] = []
        var previousCoachPosition: CaptureCoachReviewCanonicalPosition?
        var expectedCaptureId: String?
        for record in canonicalRecords
        where record.recordType == ArchiveRecord<CaptureCoachInteraction>.coachRecordType {
            let interaction = try record.coachInteractionRecord().payload
            try interaction.validate()

            let position = CaptureCoachReviewCanonicalPosition(
                streamId: record.streamId,
                streamSequence: record.streamSequence)
            guard record.streamSequence >= 0,
                previousCoachPosition.map({ $0 < position }) ?? true
            else {
                throw CaptureCoachReviewSummaryError.invalidCanonicalOrder(
                    record.observationId)
            }
            previousCoachPosition = position

            if let expectedCaptureId {
                guard record.captureId == expectedCaptureId else {
                    throw CaptureCoachReviewSummaryError.captureBindingMismatch(
                        record.observationId)
                }
            } else {
                expectedCaptureId = record.captureId
            }
            if let watermarkCaptureId = interaction.inputWatermark?.captureId,
                watermarkCaptureId != record.captureId
            {
                throw CaptureCoachReviewSummaryError.captureBindingMismatch(
                    record.observationId)
            }
            if let labelId = interaction.labelId, record.labelRefs != [labelId] {
                throw CaptureCoachReviewSummaryError.outerLabelBindingMismatch(
                    record.observationId)
            }
            if let labelId = interaction.labelId {
                guard captureByLabelId[labelId] == record.captureId else {
                    throw CaptureCoachReviewSummaryError.missingCanonicalLabel(
                        labelId)
                }
                if interaction.interactionType == .answered {
                    guard record.provenance.factClass == .declared,
                        record.actorRefs.count == 1,
                        record.actorRefs[0].role == "respondent",
                        humanActorIds.contains(record.actorRefs[0].actorId)
                    else {
                        throw CaptureCoachReviewSummaryError.invalidAnswerEnvelope(
                            record.observationId)
                    }
                }
            }

            orderedInteractions.append(CaptureCoachReviewOrderedInteraction(
                interaction: interaction,
                streamId: record.streamId,
                streamSequence: record.streamSequence))
        }
        try self.init(
            orderedInteractions: orderedInteractions,
            labelDescriptors: labelDescriptors)
    }

    public init(interactions: [CaptureCoachInteraction]) throws {
        let ordered = interactions.enumerated().map {
            CaptureCoachReviewOrderedInteraction(
                interaction: $0.element,
                streamId: nil,
                streamSequence: $0.offset)
        }
        var seenLabels = Set<Data>()
        let descriptors = interactions.compactMap { interaction
            -> CaptureCoachReviewLabelDescriptor? in
            guard let labelId = interaction.labelId,
                seenLabels.insert(Data(labelId.utf8)).inserted
            else { return nil }
            return CaptureCoachReviewLabelDescriptor(
                labelId: labelId,
                declarationText: nil,
                processName: nil)
        }
        try self.init(
            orderedInteractions: ordered,
            labelDescriptors: descriptors)
    }

    private init(
        orderedInteractions: [CaptureCoachReviewOrderedInteraction],
        labelDescriptors: [CaptureCoachReviewLabelDescriptor]
    ) throws {
        var shownOrder: [CaptureCoachReviewShownPrompt] = []
        var shownByPromptId: [String: CaptureCoachReviewShownPrompt] = [:]
        var knownByPromptId: [String: CaptureCoachReviewKnownPrompt] = [:]
        var answeredPromptIds = Set<String>()
        var answerModesByPromptId: [String: Set<CaptureCoachResponseMode>] = [:]
        var finishAnywayObserved = false
        var muteState = CaptureCoachReviewMuteState.neverMuted
        var mutedUntil: String?
        var expectedCaptureId: String?
        var presentedPromptCount = 0

        for ordered in orderedInteractions {
            let interaction = ordered.interaction
            try interaction.validate()
            if interaction.interactionType == .shown {
                presentedPromptCount += 1
            }
            if let captureId = interaction.inputWatermark?.captureId {
                if let expectedCaptureId {
                    guard captureId == expectedCaptureId else {
                        throw CaptureCoachReviewSummaryError.captureBindingMismatch(
                            interaction.interactionId)
                    }
                } else {
                    expectedCaptureId = captureId
                }
            }

            // Version 1 allowed prompt-scoped records without a process label. Preserve those as
            // raw evidence, but do not let them make a process-specific review look answered.
            if interaction.promptId != nil, interaction.labelId == nil {
                continue
            }

            switch interaction.interactionType {
            case .shown:
                guard let promptId = interaction.promptId,
                    let snapshot = interaction.promptSnapshot,
                    let context = CaptureCoachReviewPromptContext(interaction)
                else { continue }
                try Self.registerKnownPrompt(
                    promptId: promptId,
                    context: context,
                    snapshot: snapshot,
                    streamId: ordered.streamId,
                    knownByPromptId: &knownByPromptId)
                let shown = CaptureCoachReviewShownPrompt(
                    promptId: promptId,
                    context: context,
                    snapshot: snapshot,
                    streamId: ordered.streamId,
                    streamSequence: ordered.streamSequence)
                if let existing = shownByPromptId[promptId] {
                    guard existing.identityEquals(shown) else {
                        throw CaptureCoachReviewSummaryError.conflictingShownPrompt(promptId)
                    }
                } else {
                    shownByPromptId[promptId] = shown
                    shownOrder.append(shown)
                }
            case .answered:
                guard let promptId = interaction.promptId,
                    let context = CaptureCoachReviewPromptContext(interaction)
                else { continue }
                guard let shown = shownByPromptId[promptId] else {
                    throw CaptureCoachReviewSummaryError.answerBeforeShown(promptId)
                }
                guard shown.context.exactlyEquals(context),
                    captureCoachReviewOptionalTextExactlyEqual(
                        shown.streamId,
                        ordered.streamId),
                    ordered.streamSequence > shown.streamSequence
                else {
                    throw CaptureCoachReviewSummaryError.answerContextMismatch(promptId)
                }
                guard let answer = interaction.answer,
                    shown.snapshot.responseModes.contains(answer.mode),
                    Self.hasRecordedAnswerEvidence(answer)
                else { continue }
                answeredPromptIds.insert(promptId)
                answerModesByPromptId[promptId, default: []].insert(answer.mode)
            case .received, .dismissed, .suppressed:
                guard let promptId = interaction.promptId,
                    let context = CaptureCoachReviewPromptContext(interaction)
                else { continue }
                try Self.registerKnownPrompt(
                    promptId: promptId,
                    context: context,
                    snapshot: interaction.promptSnapshot,
                    streamId: ordered.streamId,
                    knownByPromptId: &knownByPromptId)
            case .muted:
                muteState = .muted
                mutedUntil = interaction.mutedUntil
            case .resumed:
                muteState = .resumed
                mutedUntil = nil
            case .finishAnyway:
                finishAnywayObserved = true
            case .unavailable:
                break
            }
        }

        self.labels = labelDescriptors.map { descriptor in
            var slotOrder: [CaptureCoachSemanticSlot] = []
            var promptIdsBySlot: [CaptureCoachSemanticSlot: [String]] = [:]
            for shown in shownOrder
            where captureCoachReviewTextExactlyEqual(
                shown.context.labelId,
                descriptor.labelId)
            {
                if promptIdsBySlot[shown.snapshot.slot] == nil {
                    slotOrder.append(shown.snapshot.slot)
                }
                promptIdsBySlot[shown.snapshot.slot, default: []].append(
                    shown.promptId)
            }
            let labelSlots = slotOrder.map { slot in
                let promptIds = promptIdsBySlot[slot] ?? []
                let answeredIds = promptIds.filter(answeredPromptIds.contains)
                let modes = CaptureCoachResponseMode.allCases.filter { mode in
                    answeredIds.contains {
                        answerModesByPromptId[$0]?.contains(mode) == true
                    }
                }
                return CaptureCoachReviewSlotSummary(
                    labelId: descriptor.labelId,
                    slot: slot,
                    shownPromptCount: promptIds.count,
                    answeredPromptCount: answeredIds.count,
                    recordedAnswerModes: modes,
                    state: !promptIds.isEmpty
                        && answeredIds.count == promptIds.count
                        ? .answered : .unanswered)
            }
            return CaptureCoachReviewLabelSummary(
                labelId: descriptor.labelId,
                declarationText: descriptor.declarationText,
                processName: descriptor.processName,
                slots: labelSlots)
        }
        self.slots = labels.flatMap(\.slots)
        self.presentedPromptCount = presentedPromptCount
        self.finishAnywayObserved = finishAnywayObserved
        self.muteState = muteState
        self.mutedUntil = mutedUntil
    }

    private static func registerKnownPrompt(
        promptId: String,
        context: CaptureCoachReviewPromptContext,
        snapshot: CaptureCoachPromptSnapshot?,
        streamId: String?,
        knownByPromptId: inout [String: CaptureCoachReviewKnownPrompt]
    ) throws {
        if var existing = knownByPromptId[promptId] {
            guard existing.context.exactlyEquals(context),
                captureCoachReviewOptionalTextExactlyEqual(
                    existing.streamId,
                    streamId)
            else {
                throw CaptureCoachReviewSummaryError.conflictingPromptContext(promptId)
            }
            if let snapshot {
                if let existingSnapshot = existing.snapshot {
                    guard captureCoachReviewEncodedExactlyEqual(
                        existingSnapshot,
                        snapshot)
                    else {
                        throw CaptureCoachReviewSummaryError.conflictingShownPrompt(promptId)
                    }
                } else {
                    existing.snapshot = snapshot
                    knownByPromptId[promptId] = existing
                }
            }
        } else {
            knownByPromptId[promptId] = CaptureCoachReviewKnownPrompt(
                context: context,
                snapshot: snapshot,
                streamId: streamId)
        }
    }

    private static func hasRecordedAnswerEvidence(_ answer: CaptureCoachAnswer) -> Bool {
        switch answer.mode {
        case .typedText:
            return answer.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .spoken:
            return answer.narrationArtifactId?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}

private struct CaptureCoachReviewOrderedInteraction {
    let interaction: CaptureCoachInteraction
    let streamId: String?
    let streamSequence: Int
}

private struct CaptureCoachReviewLabelDescriptor {
    let labelId: String
    let declarationText: String?
    let processName: String?
}

private struct CaptureCoachReviewCanonicalPosition: Comparable {
    let streamId: String
    let streamSequence: Int

    static func < (
        lhs: CaptureCoachReviewCanonicalPosition,
        rhs: CaptureCoachReviewCanonicalPosition
    ) -> Bool {
        if lhs.streamId != rhs.streamId { return lhs.streamId < rhs.streamId }
        return lhs.streamSequence < rhs.streamSequence
    }
}

private struct CaptureCoachReviewPromptContext {
    let labelId: String
    let assessmentRef: CaptureCoachAssessmentRef?
    let localBaselineRef: CaptureCoachLocalBaselineRef?
    let inputWatermark: CaptureCoachInputWatermark

    init?(_ interaction: CaptureCoachInteraction) {
        guard let labelId = interaction.labelId,
            let inputWatermark = interaction.inputWatermark
        else { return nil }
        self.labelId = labelId
        self.assessmentRef = interaction.assessmentRef
        self.localBaselineRef = interaction.localBaselineRef
        self.inputWatermark = inputWatermark
    }

    func exactlyEquals(_ other: Self) -> Bool {
        captureCoachReviewTextExactlyEqual(labelId, other.labelId)
            && captureCoachReviewEncodedExactlyEqual(
                assessmentRef,
                other.assessmentRef)
            && captureCoachReviewEncodedExactlyEqual(
                localBaselineRef,
                other.localBaselineRef)
            && captureCoachReviewEncodedExactlyEqual(
                inputWatermark,
                other.inputWatermark)
    }
}

private struct CaptureCoachReviewKnownPrompt {
    let context: CaptureCoachReviewPromptContext
    var snapshot: CaptureCoachPromptSnapshot?
    let streamId: String?
}

private struct CaptureCoachReviewShownPrompt {
    let promptId: String
    let context: CaptureCoachReviewPromptContext
    let snapshot: CaptureCoachPromptSnapshot
    let streamId: String?
    let streamSequence: Int

    func identityEquals(_ other: Self) -> Bool {
        captureCoachReviewTextExactlyEqual(promptId, other.promptId)
            && context.exactlyEquals(other.context)
            && captureCoachReviewEncodedExactlyEqual(snapshot, other.snapshot)
            && captureCoachReviewOptionalTextExactlyEqual(
                streamId,
                other.streamId)
    }
}

private func captureCoachReviewEncodedExactlyEqual<T: Encodable>(
    _ lhs: T,
    _ rhs: T
) -> Bool {
    guard let left = try? JazzArchiveCanonicalJSON.encode(lhs),
        let right = try? JazzArchiveCanonicalJSON.encode(rhs)
    else {
        return false
    }
    return left == right
}

private func captureCoachReviewTextExactlyEqual(
    _ lhs: String,
    _ rhs: String
) -> Bool {
    Data(lhs.utf8) == Data(rhs.utf8)
}

private func captureCoachReviewOptionalTextExactlyEqual(
    _ lhs: String?,
    _ rhs: String?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        true
    case let (left?, right?):
        captureCoachReviewTextExactlyEqual(left, right)
    default:
        false
    }
}

public struct CaptureCoachReviewLabelSummary: Identifiable, Equatable, Sendable {
    public let labelId: String
    public let declarationText: String?
    public let processName: String?
    public let slots: [CaptureCoachReviewSlotSummary]

    public var id: String { labelId }

    public var displayName: String {
        if let processName, !processName.isEmpty {
            if let declarationText, !declarationText.isEmpty,
                !captureCoachReviewTextExactlyEqual(processName, declarationText)
            {
                return "\(processName) — declared “\(declarationText)”"
            }
            return processName
        }
        return declarationText?.isEmpty == false ? declarationText! : labelId
    }

    public var answeredSlots: [CaptureCoachSemanticSlot] {
        slots.filter { $0.state == .answered }.map(\.slot)
    }

    public var unansweredSlots: [CaptureCoachSemanticSlot] {
        slots.filter { $0.state == .unanswered }.map(\.slot)
    }
}

public struct CaptureCoachReviewSlotSummary: Identifiable, Equatable, Sendable {
    public let labelId: String
    public let slot: CaptureCoachSemanticSlot
    public let shownPromptCount: Int
    public let answeredPromptCount: Int
    public let recordedAnswerModes: [CaptureCoachResponseMode]
    public let state: CaptureCoachReviewAnswerState

    public var id: String { "\(labelId):\(slot.rawValue)" }
}

public enum CaptureCoachReviewAnswerState: String, Equatable, Sendable {
    case answered
    case unanswered
}

public enum CaptureCoachReviewMuteState: String, Equatable, Sendable {
    case neverMuted = "never_muted"
    case muted
    case resumed
}

public enum CaptureCoachReviewSummaryError: Error, Equatable, CustomStringConvertible {
    case conflictingShownPrompt(String)
    case conflictingPromptContext(String)
    case answerBeforeShown(String)
    case answerContextMismatch(String)
    case invalidCanonicalOrder(String)
    case outerLabelBindingMismatch(String)
    case captureBindingMismatch(String)
    case duplicateCanonicalLabel(String)
    case missingCanonicalLabel(String)
    case invalidAnswerEnvelope(String)

    public var description: String {
        switch self {
        case let .conflictingShownPrompt(promptId):
            return "Capture Coach prompt changed after it was shown: \(promptId)"
        case let .conflictingPromptContext(promptId):
            return "Capture Coach prompt context changed: \(promptId)"
        case let .answerBeforeShown(promptId):
            return "Capture Coach answer has no earlier shown prompt: \(promptId)"
        case let .answerContextMismatch(promptId):
            return "Capture Coach answer does not match its shown prompt context: \(promptId)"
        case let .invalidCanonicalOrder(observationId):
            return "Capture Coach record is outside canonical stream order: \(observationId)"
        case let .outerLabelBindingMismatch(observationId):
            return "Capture Coach record labelRefs do not exactly bind its payload: \(observationId)"
        case let .captureBindingMismatch(recordId):
            return "Capture Coach record is bound to another capture: \(recordId)"
        case let .duplicateCanonicalLabel(labelId):
            return "Capture Coach label registry contains a duplicate: \(labelId)"
        case let .missingCanonicalLabel(labelId):
            return "Capture Coach evidence does not bind to a canonical label: \(labelId)"
        case let .invalidAnswerEnvelope(observationId):
            return "Capture Coach answer is not a declared fact from exactly one known human respondent: \(observationId)"
        }
    }
}

/// Pure UI wording for the native local-review pane. Keeping this in Core makes the advisory-only
/// behavior testable without SwiftUI or OS APIs.
public enum CaptureCoachReviewPresentation {
    public static let title =
        "offline explanation checklist — not semantic assessment"
    public static let inactiveTitle =
        "Capture Coach inactive — no semantic assessment"
    public static let semanticCaveat =
        "“Answered” only means a typed response or persisted spoken response was recorded for the shown prompt. It does not mean the explanation is correct or sufficient."
    public static let inactiveCaveat =
        "No Capture Coach question was shown. The recording can still be reviewed from its screen, input, and narration evidence."

    public static func title(_ summary: CaptureCoachReviewSummary) -> String {
        summary.hasReviewActivity ? title : inactiveTitle
    }

    public static func caveat(_ summary: CaptureCoachReviewSummary) -> String {
        summary.hasReviewActivity ? semanticCaveat : inactiveCaveat
    }

    public static func checklistLines(
        _ summary: CaptureCoachReviewSummary
    ) -> [String] {
        guard summary.hasReviewActivity else {
            return ["No Capture Coach questions were presented."]
        }
        var lines: [String] = []
        if summary.labels.isEmpty {
            lines.append("Shown slots: none")
        } else {
            for label in summary.labels {
                lines.append("Process · \(label.displayName) · \(label.labelId)")
                if label.slots.isEmpty {
                    lines.append("Shown slots: none")
                } else {
                    lines.append(contentsOf: label.slots.map { slot in
                        let modes = slot.recordedAnswerModes.map(answerModeLabel)
                            .joined(separator: ", ")
                        let evidence = modes.isEmpty ? "" : " · \(modes) recorded"
                        return
                            "Shown slot · \(slotLabel(slot.slot)): \(slot.state.rawValue) (\(slot.answeredPromptCount)/\(slot.shownPromptCount) prompts\(evidence))"
                    })
                }
            }
        }
        lines.append(
            "Finish anyway: \(summary.finishAnywayObserved ? "recorded" : "not recorded")")
        switch summary.muteState {
        case .neverMuted:
            lines.append("Mute state: never muted")
        case .resumed:
            lines.append("Mute state: resumed after mute")
        case .muted:
            lines.append(
                summary.mutedUntil.map { "Mute state: muted until \($0)" }
                    ?? "Mute state: muted")
        }
        return lines
    }

    public static func softWarning(
        _ summary: CaptureCoachReviewSummary
    ) -> String? {
        guard summary.hasReviewActivity else { return nil }
        var notes: [String] = []
        if summary.labels.isEmpty {
            notes.append("no explanation slots were shown")
        } else {
            for label in summary.labels {
                if label.slots.isEmpty {
                    notes.append(
                        "\(label.displayName) (\(label.labelId)): no explanation slots were shown")
                } else if !label.unansweredSlots.isEmpty {
                    let slots = label.unansweredSlots.map(slotLabel)
                        .joined(separator: ", ")
                    notes.append(
                        "\(label.displayName) (\(label.labelId)): shown slots without a recorded answer: \(slots)")
                }
            }
        }
        if summary.finishAnywayObserved {
            notes.append("Finish anyway was used")
        }
        if summary.muteState == .muted {
            notes.append("Capture Coach was left muted")
        }
        guard !notes.isEmpty else { return nil }
        return "Review note: \(notes.joined(separator: "; ")). Confirmation remains available."
    }

    public static func slotLabel(_ slot: CaptureCoachSemanticSlot) -> String {
        switch slot {
        case .intent: return "Intent"
        case .inputOrObject: return "Input or business object"
        case .decisionRule: return "Decision rule"
        case .expectedOutput: return "Expected output"
        case .success: return "Success check"
        case .exception: return "Exception"
        case .handoff: return "Handoff"
        }
    }

    private static func answerModeLabel(_ mode: CaptureCoachResponseMode) -> String {
        switch mode {
        case .typedText: return "typed"
        case .spoken: return "spoken"
        }
    }
}
