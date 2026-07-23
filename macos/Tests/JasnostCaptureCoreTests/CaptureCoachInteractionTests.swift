import XCTest

@testable import JasnostCaptureCore

final class CaptureCoachInteractionTests: XCTestCase {
    private let timestamp = "2026-07-22T10:00:00.000Z"

    func testPromptShownRoundTripsAndValidates() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let value = CaptureCoachInteraction(
            interactionType: .shown,
            occurredAt: timestamp,
            promptId: Identifiers.newCoachPromptId(),
            labelId: Identifiers.newLabelId(),
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId: "cqa-018bcfe5-6800-7fff-bfff-ffffffffffff",
                revision: 1,
                inputDigest: String(repeating: "a", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                captureId: captureId,
                streams: [CaptureCoachStreamWatermark(
                    streamId: streamId, throughSequence: 4)]),
            promptSnapshot: CaptureCoachPromptSnapshot(
                text: "How do you know the invoice is ready?",
                slot: .success,
                policyVersion: "coach-policy/v1",
                responseModes: [.typedText, .spoken]))

        try value.validate()
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(CaptureCoachInteraction.self, from: data), value)
    }

    func testLocalBaselinePromptIsPinnedWithoutPretendingToHaveAnAssessment() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let prompt = try XCTUnwrap(try CaptureCoachLocalBaselinePlan.current.prompt(
            at: 0,
            labelId: Identifiers.newLabelId(),
            inputWatermark: CaptureCoachInputWatermark(
                captureId: captureId,
                streams: [CaptureCoachStreamWatermark(
                    streamId: streamId, throughSequence: 2)]),
            responseModes: [.typedText]))

        XCTAssertNil(prompt.assessmentRef)
        XCTAssertEqual(prompt.localBaselineRef, CaptureCoachLocalBaselinePlan.current.reference)
        try prompt.validate(for: captureId)

        let interaction = CaptureCoachInteraction(
            interactionType: .shown,
            occurredAt: timestamp,
            promptId: prompt.promptId,
            labelId: prompt.labelId,
            localBaselineRef: prompt.localBaselineRef,
            inputWatermark: prompt.inputWatermark,
            promptSnapshot: prompt.snapshot)
        try interaction.validate()
        let decoded = try JSONDecoder().decode(
            CaptureCoachInteraction.self,
            from: JSONEncoder().encode(interaction))
        XCTAssertEqual(decoded, interaction)
    }

    func testPromptCannotClaimServerAssessmentAndLocalBaselineTogether() {
        let value = CaptureCoachInteraction(
            interactionType: .shown,
            occurredAt: timestamp,
            promptId: Identifiers.newCoachPromptId(),
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId: "cqa-018bcfe5-6800-7fff-bfff-ffffffffffff",
                revision: 1,
                inputDigest: String(repeating: "a", count: 64)),
            localBaselineRef: CaptureCoachLocalBaselinePlan.current.reference,
            inputWatermark: CaptureCoachInputWatermark(
                captureId: Identifiers.newCaptureId(),
                streams: [CaptureCoachStreamWatermark(
                    streamId: Identifiers.newStreamId(), throughSequence: 0)]),
            promptSnapshot: CaptureCoachPromptSnapshot(
                text: "Why?", slot: .intent, policyVersion: "test", responseModes: [.typedText]))

        XCTAssertThrowsError(try value.validate())
    }

    func testAnsweredRequiresAConcreteAnswer() {
        let value = CaptureCoachInteraction(
            interactionType: .answered,
            occurredAt: timestamp,
            promptId: Identifiers.newCoachPromptId(),
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId: "cqa-018bcfe5-6800-7fff-bfff-ffffffffffff",
                revision: 1,
                inputDigest: String(repeating: "b", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                captureId: Identifiers.newCaptureId(),
                streams: [CaptureCoachStreamWatermark(
                    streamId: Identifiers.newStreamId(), throughSequence: 0)]))

        XCTAssertThrowsError(try value.validate())
    }

    func testSuppressedRequiresAuditableReason() {
        let value = CaptureCoachInteraction(
            interactionType: .suppressed,
            occurredAt: timestamp,
            promptId: Identifiers.newCoachPromptId(),
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId: "cqa-018bcfe5-6800-7fff-bfff-ffffffffffff",
                revision: 1,
                inputDigest: String(repeating: "c", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                captureId: Identifiers.newCaptureId(),
                streams: [CaptureCoachStreamWatermark(
                    streamId: Identifiers.newStreamId(), throughSequence: 0)]))

        XCTAssertThrowsError(try value.validate())
    }

    func testOfflineUnavailableDoesNotNeedServerPrompt() throws {
        let value = CaptureCoachInteraction(
            interactionType: .unavailable,
            occurredAt: timestamp,
            dispositionReason: .offline)
        try value.validate()
    }

    func testSpokenAnswerUsesReservedArtifactOnlyAfterPersistence() throws {
        let artifactId = Identifiers.newArtifactId()
        let reservation = try CaptureCoachNarrationReservation(
            labelId: Identifiers.newLabelId(), artifactId: artifactId)

        XCTAssertThrowsError(try reservation.spokenAnswer(persistedArtifactId: nil)) {
            XCTAssertEqual(
                $0 as? CaptureCoachSpokenAnswerError,
                .narrationArtifactUnavailable(artifactId))
        }
        XCTAssertThrowsError(try reservation.spokenAnswer(
            persistedArtifactId: Identifiers.newArtifactId()))

        let answer = try reservation.spokenAnswer(persistedArtifactId: artifactId)
        XCTAssertEqual(answer.mode, .spoken)
        XCTAssertEqual(answer.narrationArtifactId, artifactId)
        XCTAssertNil(answer.text)
    }

    func testAnswerModesCannotClaimBothTextAndNarration() {
        let context = (
            promptId: Identifiers.newCoachPromptId(),
            assessment: CaptureCoachAssessmentRef(
                assessmentId: "cqa-018bcfe5-6800-7fff-bfff-ffffffffffff",
                revision: 1,
                inputDigest: String(repeating: "d", count: 64)),
            watermark: CaptureCoachInputWatermark(
                captureId: Identifiers.newCaptureId(),
                streams: [CaptureCoachStreamWatermark(
                    streamId: Identifiers.newStreamId(), throughSequence: 0)]))

        for answer in [
            CaptureCoachAnswer(
                mode: .typedText,
                text: "typed fallback",
                narrationArtifactId: Identifiers.newArtifactId()),
            CaptureCoachAnswer(
                mode: .spoken,
                text: "not a spoken artifact",
                narrationArtifactId: Identifiers.newArtifactId()),
        ] {
            let interaction = CaptureCoachInteraction(
                interactionType: .answered,
                occurredAt: timestamp,
                promptId: context.promptId,
                assessmentRef: context.assessment,
                inputWatermark: context.watermark,
                answer: answer)
            XCTAssertThrowsError(try interaction.validate())
        }
    }
}
