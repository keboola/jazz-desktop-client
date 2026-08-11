import XCTest

@testable import JazzCaptureCore

final class CaptureCoachReviewSummaryTests: XCTestCase {
    private let timestamp = "2026-07-23T12:00:00.000Z"

    func testCanonicalReducerCorrelatesOnlyRecordedAnswersToShownPromptSlots() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let intent = Identifiers.newCoachPromptId()
        let exception = Identifiers.newCoachPromptId()
        let success = Identifiers.newCoachPromptId()
        let labelId = Identifiers.newLabelId()
        let interactions = [
            shown(
                intent, slot: .intent, labelId: labelId,
                captureId: captureId, streamId: streamId),
            answered(
                intent,
                answer: CaptureCoachAnswer(mode: .typedText, text: "Create the invoice."),
                labelId: labelId, captureId: captureId, streamId: streamId),
            shown(
                exception, slot: .exception, labelId: labelId,
                captureId: captureId, streamId: streamId),
            promptScoped(
                .dismissed,
                promptId: exception,
                labelId: labelId, captureId: captureId, streamId: streamId),
            shown(
                success, slot: .success, labelId: labelId,
                captureId: captureId, streamId: streamId),
            answered(
                success,
                answer: CaptureCoachAnswer(
                    mode: .spoken,
                    narrationArtifactId: Identifiers.newArtifactId()),
                labelId: labelId, captureId: captureId, streamId: streamId),
            CaptureCoachInteraction(
                interactionType: .muted,
                occurredAt: timestamp,
                mutedUntil: "2026-07-23T12:05:00.000Z"),
            CaptureCoachInteraction(
                interactionType: .resumed,
                occurredAt: timestamp),
            CaptureCoachInteraction(
                interactionType: .finishAnyway,
                occurredAt: timestamp),
        ]
        let fixture = try canonicalFixture(
            interactions,
            captureId: captureId,
            streamId: streamId)

        let summary = try CaptureCoachReviewSummary(
            canonicalRecords: fixture.records,
            canonicalLabels: fixture.labels,
            humanActorIds: fixture.humanActorIds)

        XCTAssertEqual(summary.shownSlots, [.intent, .exception, .success])
        XCTAssertEqual(summary.answeredSlots, [.intent, .success])
        XCTAssertEqual(summary.unansweredSlots, [.exception])
        XCTAssertEqual(summary.slots[0].recordedAnswerModes, [.typedText])
        XCTAssertEqual(summary.slots[1].state, .unanswered)
        XCTAssertEqual(summary.slots[2].recordedAnswerModes, [.spoken])
        XCTAssertTrue(summary.finishAnywayObserved)
        XCTAssertEqual(summary.muteState, .resumed)
        XCTAssertNil(summary.mutedUntil)
        XCTAssertTrue(summary.allowsConfirmation)
    }

    func testAnswerInModeNotOfferedByShownPromptRemainsUnanswered() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let promptId = Identifiers.newCoachPromptId()
        let labelId = Identifiers.newLabelId()
        let shown = CaptureCoachInteraction(
            interactionType: .shown,
            occurredAt: timestamp,
            promptId: promptId,
            labelId: labelId,
            localBaselineRef: CaptureCoachLocalBaselinePlan.current.reference,
            inputWatermark: watermark(captureId: captureId, streamId: streamId),
            promptSnapshot: CaptureCoachPromptSnapshot(
                text: "What is the expected output?",
                slot: .expectedOutput,
                policyVersion: "local-test",
                responseModes: [.typedText]))
        let spoken = answered(
            promptId,
            answer: CaptureCoachAnswer(
                mode: .spoken,
                narrationArtifactId: Identifiers.newArtifactId()),
            labelId: labelId, captureId: captureId, streamId: streamId)

        let summary = try CaptureCoachReviewSummary(interactions: [shown, spoken])

        XCTAssertEqual(summary.answeredSlots, [])
        XCTAssertEqual(summary.unansweredSlots, [.expectedOutput])
        XCTAssertEqual(summary.slots.first?.answeredPromptCount, 0)
    }

    func testAnswerMustMatchExactShownContext() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let promptId = Identifiers.newCoachPromptId()
        let labelId = Identifiers.newLabelId()
        let shownInteraction = shown(
            promptId, slot: .decisionRule, labelId: labelId,
            captureId: captureId, streamId: streamId)
        let validAnswer = answered(
            promptId,
            answer: CaptureCoachAnswer(mode: .typedText, text: "Use the approved rate."),
            labelId: labelId,
            captureId: captureId,
            streamId: streamId)

        var wrongLabel = validAnswer
        wrongLabel.labelId = Identifiers.newLabelId()
        assertContextMismatch([shownInteraction, wrongLabel], promptId: promptId)

        var wrongReference = validAnswer
        wrongReference.localBaselineRef = CaptureCoachLocalBaselineRef(
            planId: CaptureCoachLocalBaselinePlan.current.reference.planId,
            planVersion: "different-plan-version",
            planDigest: CaptureCoachLocalBaselinePlan.current.reference.planDigest)
        assertContextMismatch([shownInteraction, wrongReference], promptId: promptId)

        var wrongWatermark = validAnswer
        wrongWatermark.inputWatermark = CaptureCoachInputWatermark(
            captureId: captureId,
            streams: [CaptureCoachStreamWatermark(
                streamId: streamId,
                throughSequence: 1)])
        assertContextMismatch([shownInteraction, wrongWatermark], promptId: promptId)

        var unicodeShown = shownInteraction
        unicodeShown.localBaselineRef?.planId = "baseline-café"
        var unicodeAnswer = validAnswer
        unicodeAnswer.localBaselineRef?.planId = "baseline-cafe\u{301}"
        assertContextMismatch([unicodeShown, unicodeAnswer], promptId: promptId)
    }

    func testCanonicallyEquivalentPromptSnapshotTextIsStillAConflict() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let promptId = Identifiers.newCoachPromptId()
        let labelId = Identifiers.newLabelId()
        var composed = shown(
            promptId, slot: .intent, labelId: labelId,
            captureId: captureId, streamId: streamId)
        composed.promptSnapshot?.text = "Explain café"
        var decomposed = composed
        decomposed.promptSnapshot?.text = "Explain cafe\u{301}"

        XCTAssertThrowsError(
            try CaptureCoachReviewSummary(
                interactions: [composed, decomposed])
        ) {
            XCTAssertEqual(
                $0 as? CaptureCoachReviewSummaryError,
                .conflictingShownPrompt(promptId))
        }
    }

    func testAnswerBeforeShownFailsClosed() {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let promptId = Identifiers.newCoachPromptId()
        let labelId = Identifiers.newLabelId()
        let shownInteraction = shown(
            promptId, slot: .handoff, labelId: labelId,
            captureId: captureId, streamId: streamId)
        let answer = answered(
            promptId,
            answer: CaptureCoachAnswer(mode: .typedText, text: "Send it to Finance."),
            labelId: labelId,
            captureId: captureId,
            streamId: streamId)

        XCTAssertThrowsError(
            try CaptureCoachReviewSummary(interactions: [answer, shownInteraction])
        ) {
            XCTAssertEqual(
                $0 as? CaptureCoachReviewSummaryError,
                .answerBeforeShown(promptId))
        }
    }

    func testCanonicalRecordRequiresExactOuterLabelBinding() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let promptId = Identifiers.newCoachPromptId()
        let labelId = Identifiers.newLabelId()
        var fixture = try canonicalFixture([
            shown(
                promptId, slot: .intent, labelId: labelId,
                captureId: captureId, streamId: streamId),
        ], captureId: captureId, streamId: streamId)
        fixture.records[0].labelRefs = [labelId, Identifiers.newLabelId()]

        XCTAssertThrowsError(try CaptureCoachReviewSummary(
            canonicalRecords: fixture.records,
            canonicalLabels: fixture.labels,
            humanActorIds: fixture.humanActorIds)
        ) {
            guard case .outerLabelBindingMismatch = $0 as? CaptureCoachReviewSummaryError
            else { return XCTFail("unexpected error: \($0)") }
        }
    }

    func testCanonicalRecordsMustBeInStrictStreamOrder() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let labelId = Identifiers.newLabelId()
        var fixture = try canonicalFixture([
            shown(
                Identifiers.newCoachPromptId(), slot: .intent, labelId: labelId,
                captureId: captureId, streamId: streamId),
            shown(
                Identifiers.newCoachPromptId(), slot: .success, labelId: labelId,
                captureId: captureId, streamId: streamId),
        ], captureId: captureId, streamId: streamId)
        fixture.records.reverse()

        XCTAssertThrowsError(try CaptureCoachReviewSummary(
            canonicalRecords: fixture.records,
            canonicalLabels: fixture.labels,
            humanActorIds: fixture.humanActorIds)
        ) {
            guard case .invalidCanonicalOrder = $0 as? CaptureCoachReviewSummaryError
            else { return XCTFail("unexpected error: \($0)") }
        }
    }

    func testCanonicalAnswerRequiresDeclaredHumanRespondentEnvelope() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let promptId = Identifiers.newCoachPromptId()
        let labelId = Identifiers.newLabelId()
        let interactions = [
            shown(
                promptId, slot: .intent, labelId: labelId,
                captureId: captureId, streamId: streamId),
            answered(
                promptId,
                answer: CaptureCoachAnswer(mode: .typedText, text: "Human explanation."),
                labelId: labelId, captureId: captureId, streamId: streamId),
        ]
        let valid = try canonicalFixture(
            interactions, captureId: captureId, streamId: streamId)
        XCTAssertNoThrow(try CaptureCoachReviewSummary(
            canonicalRecords: valid.records,
            canonicalLabels: valid.labels,
            humanActorIds: valid.humanActorIds))

        var spoofed = valid.records
        spoofed[1].actorRefs[0].actorId = Identifiers.newActorId()
        assertInvalidAnswerEnvelope(
            spoofed, fixture: valid, observationId: spoofed[1].observationId)

        var noActor = valid.records
        noActor[1].actorRefs = []
        assertInvalidAnswerEnvelope(
            noActor, fixture: valid, observationId: noActor[1].observationId)

        var multipleActors = valid.records
        multipleActors[1].actorRefs.append(multipleActors[1].actorRefs[0])
        assertInvalidAnswerEnvelope(
            multipleActors,
            fixture: valid,
            observationId: multipleActors[1].observationId)

        var observedBasis = valid.records
        observedBasis[1].actorRefs[0].basis = .observed
        XCTAssertNoThrow(try CaptureCoachReviewSummary(
            canonicalRecords: observedBasis,
            canonicalLabels: valid.labels,
            humanActorIds: valid.humanActorIds))

        var observedFact = valid.records
        observedFact[1].provenance.factClass = .observed
        assertInvalidAnswerEnvelope(
            observedFact,
            fixture: valid,
            observationId: observedFact[1].observationId)
    }

    func testCanonicalCoachRecordRequiresSameCaptureLabelRegistryEntry() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let labelId = Identifiers.newLabelId()
        let fixture = try canonicalFixture([
            shown(
                Identifiers.newCoachPromptId(), slot: .intent, labelId: labelId,
                captureId: captureId, streamId: streamId),
        ], captureId: captureId, streamId: streamId)

        XCTAssertThrowsError(try CaptureCoachReviewSummary(
            canonicalRecords: fixture.records,
            canonicalLabels: [],
            humanActorIds: fixture.humanActorIds)
        ) {
            XCTAssertEqual(
                $0 as? CaptureCoachReviewSummaryError,
                .missingCanonicalLabel(labelId))
        }

        var crossCaptureLabels = fixture.labels
        crossCaptureLabels[0].captureId = Identifiers.newCaptureId()
        XCTAssertThrowsError(try CaptureCoachReviewSummary(
            canonicalRecords: fixture.records,
            canonicalLabels: crossCaptureLabels,
            humanActorIds: fixture.humanActorIds)
        ) {
            XCTAssertEqual(
                $0 as? CaptureCoachReviewSummaryError,
                .missingCanonicalLabel(labelId))
        }
    }

    func testCanonicalChecklistKeepsSameSemanticSlotSeparatePerProcessLabel()
        throws
    {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let firstLabelId = Identifiers.newLabelId()
        let secondLabelId = Identifiers.newLabelId()
        let firstPromptId = Identifiers.newCoachPromptId()
        let secondPromptId = Identifiers.newCoachPromptId()
        var fixture = try canonicalFixture([
            shown(
                firstPromptId, slot: .intent, labelId: firstLabelId,
                captureId: captureId, streamId: streamId),
            answered(
                firstPromptId,
                answer: CaptureCoachAnswer(
                    mode: .typedText,
                    text: "Issue the approved invoice."),
                labelId: firstLabelId,
                captureId: captureId,
                streamId: streamId),
            shown(
                secondPromptId, slot: .intent, labelId: secondLabelId,
                captureId: captureId, streamId: streamId),
        ], captureId: captureId, streamId: streamId)
        fixture.labels[fixture.labels.firstIndex {
            $0.labelId == firstLabelId
        }!].declaration.text = "Issue invoices"
        fixture.labels[fixture.labels.firstIndex {
            $0.labelId == secondLabelId
        }!].declaration.text = "Approve expenses"

        let summary = try CaptureCoachReviewSummary(
            canonicalRecords: fixture.records,
            canonicalLabels: fixture.labels,
            humanActorIds: fixture.humanActorIds)
        let first = try XCTUnwrap(
            summary.labels.first { $0.labelId == firstLabelId })
        let second = try XCTUnwrap(
            summary.labels.first { $0.labelId == secondLabelId })

        XCTAssertEqual(first.answeredSlots, [.intent])
        XCTAssertEqual(first.unansweredSlots, [])
        XCTAssertEqual(second.answeredSlots, [])
        XCTAssertEqual(second.unansweredSlots, [.intent])
        XCTAssertEqual(summary.slots.count, 2)
        XCTAssertNotEqual(summary.slots[0].id, summary.slots[1].id)
        let lines = CaptureCoachReviewPresentation.checklistLines(summary)
            .joined(separator: "\n")
        XCTAssertTrue(lines.contains("Issue invoices"))
        XCTAssertTrue(lines.contains("Approve expenses"))
        let warning = try XCTUnwrap(
            CaptureCoachReviewPresentation.softWarning(summary))
        XCTAssertFalse(warning.contains("Issue invoices"))
        XCTAssertTrue(warning.contains("Approve expenses"))
        XCTAssertTrue(warning.contains(secondLabelId))
    }

    func testLabelLessVersionOnePromptEvidenceIsNotUsedByChecklist() throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let promptId = Identifiers.newCoachPromptId()
        let summary = try CaptureCoachReviewSummary(interactions: [
            shown(
                promptId, slot: .intent, labelId: nil,
                captureId: captureId, streamId: streamId),
            answered(
                promptId,
                answer: CaptureCoachAnswer(mode: .typedText, text: "Legacy evidence."),
                labelId: nil,
                captureId: captureId,
                streamId: streamId),
        ])

        XCTAssertTrue(summary.slots.isEmpty)
    }

    func testPresentationIsExplicitlyAdvisoryAndSurfacesWarningAndControlState() throws {
        let summary = try CaptureCoachReviewSummary(interactions: [
            CaptureCoachInteraction(
                interactionType: .muted,
                occurredAt: timestamp,
                mutedUntil: "2026-07-23T12:05:00.000Z"),
            CaptureCoachInteraction(
                interactionType: .finishAnyway,
                occurredAt: timestamp),
        ])

        XCTAssertEqual(
            CaptureCoachReviewPresentation.title,
            "offline explanation checklist — not semantic assessment")
        let lines = CaptureCoachReviewPresentation.checklistLines(summary)
        XCTAssertTrue(lines.contains("Shown slots: none"))
        XCTAssertTrue(lines.contains("Finish anyway: recorded"))
        XCTAssertTrue(lines.contains("Mute state: muted until 2026-07-23T12:05:00.000Z"))
        let warning = try XCTUnwrap(CaptureCoachReviewPresentation.softWarning(summary))
        XCTAssertTrue(warning.contains("no explanation slots were shown"))
        XCTAssertTrue(warning.contains("Finish anyway was used"))
        XCTAssertTrue(warning.contains("Capture Coach was left muted"))
        XCTAssertTrue(warning.contains("Confirmation remains available"))
        XCTAssertTrue(
            CaptureCoachReviewPresentation.semanticCaveat
                .contains("does not mean the explanation is correct"))
        XCTAssertTrue(summary.allowsConfirmation)
    }

    func testUnavailableCoachDoesNotManufactureAReviewWarning() throws {
        let summary = try CaptureCoachReviewSummary(interactions: [
            CaptureCoachInteraction(
                interactionType: .unavailable,
                occurredAt: timestamp,
                dispositionReason: .offline)
        ])

        XCTAssertFalse(summary.hasReviewActivity)
        XCTAssertEqual(summary.presentedPromptCount, 0)
        XCTAssertEqual(
            CaptureCoachReviewPresentation.title(summary),
            CaptureCoachReviewPresentation.inactiveTitle)
        XCTAssertEqual(
            CaptureCoachReviewPresentation.checklistLines(summary),
            ["No Capture Coach questions were presented."])
        XCTAssertNil(CaptureCoachReviewPresentation.softWarning(summary))
        XCTAssertEqual(
            CaptureCoachReviewPresentation.caveat(summary),
            CaptureCoachReviewPresentation.inactiveCaveat)
    }

    private func shown(
        _ promptId: String,
        slot: CaptureCoachSemanticSlot,
        labelId: String?,
        captureId: String,
        streamId: String
    ) -> CaptureCoachInteraction {
        CaptureCoachInteraction(
            interactionType: .shown,
            occurredAt: timestamp,
            promptId: promptId,
            labelId: labelId,
            localBaselineRef: CaptureCoachLocalBaselinePlan.current.reference,
            inputWatermark: watermark(captureId: captureId, streamId: streamId),
            promptSnapshot: CaptureCoachPromptSnapshot(
                text: "Please explain \(slot.rawValue).",
                slot: slot,
                policyVersion: "local-test",
                responseModes: [.typedText, .spoken]))
    }

    private func answered(
        _ promptId: String,
        answer: CaptureCoachAnswer,
        labelId: String?,
        captureId: String,
        streamId: String
    ) -> CaptureCoachInteraction {
        CaptureCoachInteraction(
            interactionType: .answered,
            occurredAt: timestamp,
            promptId: promptId,
            labelId: labelId,
            localBaselineRef: CaptureCoachLocalBaselinePlan.current.reference,
            inputWatermark: watermark(captureId: captureId, streamId: streamId),
            answer: answer)
    }

    private func promptScoped(
        _ type: CaptureCoachInteractionType,
        promptId: String,
        labelId: String?,
        captureId: String,
        streamId: String
    ) -> CaptureCoachInteraction {
        CaptureCoachInteraction(
            interactionType: type,
            occurredAt: timestamp,
            promptId: promptId,
            labelId: labelId,
            localBaselineRef: CaptureCoachLocalBaselinePlan.current.reference,
            inputWatermark: watermark(captureId: captureId, streamId: streamId))
    }

    private func watermark(
        captureId: String,
        streamId: String
    ) -> CaptureCoachInputWatermark {
        CaptureCoachInputWatermark(
            captureId: captureId,
            streams: [CaptureCoachStreamWatermark(
                streamId: streamId,
                throughSequence: 0)])
    }

    private func canonicalFixture(
        _ interactions: [CaptureCoachInteraction],
        captureId: String,
        streamId: String
    ) throws -> CanonicalCoachFixture {
        let originId = Identifiers.newOriginId()
        let actorId = Identifiers.newActorId()
        let records = try interactions.enumerated().map { sequence, interaction in
            try JazzArchiveRecord(erasing: ArchiveRecord<CaptureCoachInteraction>(
                interaction: interaction,
                originId: originId,
                captureId: captureId,
                streamId: streamId,
                streamSequence: sequence,
                sourceRefs: [],
                actorRefs: interaction.interactionType == .answered
                    ? [JazzArchiveActorRef(
                        actorId: actorId,
                        role: "respondent",
                        basis: .declared,
                        method: "coach_ui")]
                    : [],
                provenance: JazzArchiveProvenance(
                    factClass: interaction.interactionType == .answered
                        ? .declared : .observed,
                    sources: []),
                quality: JazzArchiveQuality(status: .complete),
                privacy: JazzArchivePrivacy(
                    status: .captured,
                    policyVersion: "test")))
        }
        let labels = Set(interactions.compactMap(\.labelId)).map { labelId in
            let firstRecord = records.first { $0.labelRefs == [labelId] }!
            return JazzArchiveLabel(
                schemaVersion: 1,
                labelId: labelId,
                captureId: captureId,
                status: .open,
                declaration: JazzArchiveLabelDeclaration(
                    text: "Test process",
                    declaredByActorId: actorId,
                    declaredAt: timestamp,
                    mode: .guided),
                interval: JazzArchiveLabelInterval(
                    startObservationId: firstRecord.observationId,
                    startStreamSequence: firstRecord.streamSequence,
                    endObservationId: nil,
                    endStreamSequence: nil),
                processBinding: nil,
                narrationArtifactRefs: [],
                provenance: JazzArchiveProvenance(
                    factClass: .declared,
                    sources: []),
                extensions: nil)
        }
        return CanonicalCoachFixture(
            records: records,
            labels: labels,
            humanActorIds: [actorId])
    }

    private func assertInvalidAnswerEnvelope(
        _ records: [JazzArchiveRecord],
        fixture: CanonicalCoachFixture,
        observationId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try CaptureCoachReviewSummary(
            canonicalRecords: records,
            canonicalLabels: fixture.labels,
            humanActorIds: fixture.humanActorIds),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                $0 as? CaptureCoachReviewSummaryError,
                .invalidAnswerEnvelope(observationId),
                file: file,
                line: line)
        }
    }

    private func assertContextMismatch(
        _ interactions: [CaptureCoachInteraction],
        promptId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CaptureCoachReviewSummary(interactions: interactions),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                $0 as? CaptureCoachReviewSummaryError,
                .answerContextMismatch(promptId),
                file: file,
                line: line)
        }
    }
}

private struct CanonicalCoachFixture {
    var records: [JazzArchiveRecord]
    var labels: [JazzArchiveLabel]
    var humanActorIds: Set<String>
}
