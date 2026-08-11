import XCTest

@testable import JazzCaptureCore

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

    func testLabeledAnswerRequiresExactLabelHumanRespondentAndDeclaredProvenance() throws {
        let fixture = makeEnvelopeFixture(actorKind: .human)
        var record = labeledAnswerRecord(fixture)
        try record.validate(manifest: fixture.manifest, session: fixture.session)

        record.actorRefs[0].basis = .observed
        try record.validate(manifest: fixture.manifest, session: fixture.session)

        record.labelRefs.append(Identifiers.newLabelId())
        XCTAssertThrowsError(
            try record.validate(manifest: fixture.manifest, session: fixture.session))

        record = labeledAnswerRecord(fixture)
        record.actorRefs[0].role = "performer"
        XCTAssertThrowsError(
            try record.validate(manifest: fixture.manifest, session: fixture.session))

        record = labeledAnswerRecord(fixture)
        record.actorRefs.append(record.actorRefs[0])
        XCTAssertThrowsError(
            try record.validate(manifest: fixture.manifest, session: fixture.session))

        record = labeledAnswerRecord(fixture)
        record.provenance.factClass = .observed
        XCTAssertThrowsError(
            try record.validate(manifest: fixture.manifest, session: fixture.session))

        let agentFixture = makeEnvelopeFixture(actorKind: .agent)
        let agentRecord = labeledAnswerRecord(agentFixture)
        XCTAssertThrowsError(
            try agentRecord.validate(
                manifest: agentFixture.manifest,
                session: agentFixture.session))
    }

    func testLabelLessVersionOneAnswerRemainsValidRawEvidence() throws {
        let fixture = makeEnvelopeFixture(actorKind: .human)
        let interaction = CaptureCoachInteraction(
            interactionType: .answered,
            occurredAt: timestamp,
            promptId: Identifiers.newCoachPromptId(),
            localBaselineRef: CaptureCoachLocalBaselinePlan.current.reference,
            inputWatermark: CaptureCoachInputWatermark(
                captureId: fixture.captureId,
                streams: [CaptureCoachStreamWatermark(
                    streamId: fixture.streamId,
                    throughSequence: 0)]),
            answer: CaptureCoachAnswer(
                mode: .typedText,
                text: "Compatibility evidence."))
        let record = ArchiveRecord(
            interaction: interaction,
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: 0,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId,
                role: "audit_recorder")],
            actorRefs: [],
            provenance: JazzArchiveProvenance(
                factClass: .observed,
                sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured,
                policyVersion: "test"))

        try record.validate(manifest: fixture.manifest, session: fixture.session)
    }

    private struct EnvelopeFixture {
        let originId: String
        let captureId: String
        let streamId: String
        let actorId: String
        let sourceId: String
        let manifest: JazzArchiveManifest
        let session: JazzArchiveSession
    }

    private func makeEnvelopeFixture(
        actorKind: JazzArchiveActorKind
    ) -> EnvelopeFixture {
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let actorId = Identifiers.newActorId()
        let sourceId = Identifiers.newSourceId()
        let producer = JazzArchiveProducer(
            name: "Coach test",
            version: "1",
            platform: "macOS")
        let actor = JazzArchiveActor(
            actorId: actorId,
            kind: actorKind,
            identityStatus: .identified,
            displayName: "Recorder",
            provenance: JazzArchiveProvenance(
                factClass: .declared,
                sources: []))
        let source = JazzArchiveSource(
            sourceId: sourceId,
            kind: "coach-test",
            actorId: actorId,
            producer: producer,
            provenance: JazzArchiveProvenance(
                factClass: .observed,
                sources: []))
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            createdAt: timestamp,
            producer: producer,
            contracts: [.captureCoachInteraction],
            actors: [actor],
            sources: [source],
            sessions: [JazzArchiveSessionRef(captureId: captureId)])
        let session = JazzArchiveSession(
            captureId: captureId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: timestamp,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "test",
                consentedAt: timestamp,
                modalities: [.accessibility],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        return EnvelopeFixture(
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            actorId: actorId,
            sourceId: sourceId,
            manifest: manifest,
            session: session)
    }

    private func labeledAnswerRecord(
        _ fixture: EnvelopeFixture
    ) -> ArchiveRecord<CaptureCoachInteraction> {
        let interaction = CaptureCoachInteraction(
            interactionType: .answered,
            occurredAt: timestamp,
            promptId: Identifiers.newCoachPromptId(),
            labelId: Identifiers.newLabelId(),
            localBaselineRef: CaptureCoachLocalBaselinePlan.current.reference,
            inputWatermark: CaptureCoachInputWatermark(
                captureId: fixture.captureId,
                streams: [CaptureCoachStreamWatermark(
                    streamId: fixture.streamId,
                    throughSequence: 0)]),
            answer: CaptureCoachAnswer(
                mode: .typedText,
                text: "The approval badge is green."))
        return ArchiveRecord(
            interaction: interaction,
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: 0,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId,
                role: "audit_recorder")],
            actorRefs: [JazzArchiveActorRef(
                actorId: fixture.actorId,
                role: "respondent",
                basis: .declared,
                method: "coach_ui")],
            provenance: JazzArchiveProvenance(
                factClass: .declared,
                sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured,
                policyVersion: "test"))
    }
}
