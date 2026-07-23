import XCTest

@testable import JasnostCaptureCore

final class CaptureCoachCoordinatorTests: XCTestCase {
    private enum InjectedFailure: Error { case append }

    private actor Recorder: CaptureCoachInteractionRecorder {
        private var values: [CaptureCoachInteraction] = []
        private var failOnceOn: CaptureCoachInteractionType?

        init(failOnceOn: CaptureCoachInteractionType? = nil) {
            self.failOnceOn = failOnceOn
        }

        func append(_ interaction: CaptureCoachInteraction) throws {
            if failOnceOn == interaction.interactionType {
                failOnceOn = nil
                throw InjectedFailure.append
            }
            values.append(interaction)
        }

        func interactions() -> [CaptureCoachInteraction] { values }
    }

    private let baseDate = Date(timeIntervalSince1970: 1_784_716_800)

    private func date(_ offset: TimeInterval) -> Date {
        baseDate.addingTimeInterval(offset)
    }

    private func assessmentId() -> String {
        "cqa-\(Identifiers.newUUIDv7().uuidString.lowercased())"
    }

    private func prompt(
        captureId: String,
        streamId: String,
        sequence: Int,
        promptId: String = Identifiers.newCoachPromptId(),
        labelId: String? = nil
    ) -> CaptureCoachPrompt {
        CaptureCoachPrompt(
            promptId: promptId,
            labelId: labelId,
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId: assessmentId(),
                revision: 1,
                inputDigest: String(repeating: "b", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                captureId: captureId,
                streams: [CaptureCoachStreamWatermark(
                    streamId: streamId,
                    throughSequence: sequence)]),
            snapshot: CaptureCoachPromptSnapshot(
                text: "What exception changes this step?",
                slot: .exception,
                policyVersion: "delivery-v1",
                responseModes: [.typedText, .spoken]))
    }

    func testCrashAfterReceivedResumesShownAndDuplicateIsAuditedOnlyOnce() async throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let candidate = prompt(captureId: captureId, streamId: streamId, sequence: 3)
        let interruptedRecorder = Recorder(failOnceOn: .shown)
        let interrupted = try CaptureCoachCoordinator(
            captureId: captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 0),
            recorder: interruptedRecorder)

        do {
            _ = try await interrupted.receive(candidate, at: date(0))
            XCTFail("expected injected append failure")
        } catch InjectedFailure.append {}
        let beforeCrash = await interruptedRecorder.interactions()
        XCTAssertEqual(beforeCrash.map(\.interactionType), [.received])

        // A new coordinator represents process death: the audit history is the recovery state.
        let recoveredRecorder = Recorder()
        let recovered = try CaptureCoachCoordinator(
            captureId: captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 0),
            recorder: recoveredRecorder,
            recoveredInteractions: beforeCrash)
        let resumed = try await recovered.receive(candidate, at: date(1))
        XCTAssertEqual(resumed.disposition, .shown)
        XCTAssertEqual(resumed.recordedInteractions.map(\.interactionType), [.shown])

        let duplicate = try await recovered.receive(candidate, at: date(2))
        XCTAssertEqual(duplicate.disposition, .suppressed(.duplicate))
        XCTAssertEqual(duplicate.recordedInteractions.map(\.interactionType), [.suppressed])
        let repeatedDuplicate = try await recovered.receive(candidate, at: date(3))
        XCTAssertEqual(repeatedDuplicate.disposition, .suppressed(.duplicate))
        XCTAssertTrue(repeatedDuplicate.recordedInteractions.isEmpty)

        let recoveredValues = await recoveredRecorder.interactions()
        XCTAssertEqual(recoveredValues.map(\.interactionType), [.shown, .suppressed])
        XCTAssertEqual(recoveredValues.last?.dispositionReason, .duplicate)
    }

    func testWatermarkCooldownAndOneOutstandingPromptAreDeterministic() async throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let recorder = Recorder()
        let coordinator = try CaptureCoachCoordinator(
            captureId: captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 10),
            recorder: recorder)

        let first = prompt(captureId: captureId, streamId: streamId, sequence: 5)
        let firstDecision = try await coordinator.receive(first, at: date(0))
        XCTAssertEqual(firstDecision.disposition, .shown)
        _ = try await coordinator.dismiss(promptId: first.promptId, at: date(1))

        let duringCooldown = prompt(captureId: captureId, streamId: streamId, sequence: 6)
        let cooldownDecision = try await coordinator.receive(duringCooldown, at: date(2))
        XCTAssertEqual(cooldownDecision.disposition, .suppressed(.rateLimited))

        let stale = prompt(captureId: captureId, streamId: streamId, sequence: 4)
        let staleDecision = try await coordinator.receive(stale, at: date(12))
        XCTAssertEqual(staleDecision.disposition, .suppressed(.staleWatermark))

        let current = prompt(captureId: captureId, streamId: streamId, sequence: 6)
        let currentDecision = try await coordinator.receive(current, at: date(12))
        XCTAssertEqual(currentDecision.disposition, .shown)
        let whileOutstanding = prompt(captureId: captureId, streamId: streamId, sequence: 7)
        let outstandingDecision = try await coordinator.receive(whileOutstanding, at: date(13))
        XCTAssertEqual(outstandingDecision.disposition, .suppressed(.rateLimited))
        let outstandingSnapshot = await coordinator.snapshot()
        XCTAssertEqual(outstandingSnapshot.outstandingPrompt?.promptId, current.promptId)
    }

    func testClosedAndCommittedCaptureSuppressWithExplicitReasons() async throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let closedLabel = Identifiers.newLabelId()
        let recorder = Recorder()
        let coordinator = try CaptureCoachCoordinator(
            captureId: captureId,
            recorder: recorder,
            closedLabelIds: [closedLabel])

        let closed = prompt(
            captureId: captureId,
            streamId: streamId,
            sequence: 1,
            labelId: closedLabel)
        let closedDecision = try await coordinator.receive(closed, at: date(0))
        XCTAssertEqual(closedDecision.disposition, .suppressed(.closedLabel))

        await coordinator.markCaptureCommitted()
        let committed = prompt(captureId: captureId, streamId: streamId, sequence: 2)
        let committedDecision = try await coordinator.receive(committed, at: date(1))
        XCTAssertEqual(committedDecision.disposition, .suppressed(.committedCapture))
        let values = await recorder.interactions()
        XCTAssertEqual(values.map(\.dispositionReason), [.closedLabel, .committedCapture])
    }

    func testOfflineMuteResumeAnswerAndFinishAnywayRemainAdvisory() async throws {
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let recorder = Recorder()
        let coordinator = try CaptureCoachCoordinator(
            captureId: captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 0, defaultMuteSeconds: 60),
            recorder: recorder)

        _ = try await coordinator.reportUnavailable(.offline, at: date(0))
        let first = prompt(captureId: captureId, streamId: streamId, sequence: 1)
        _ = try await coordinator.receive(first, at: date(1))
        let muted = try await coordinator.mute(at: date(2))
        XCTAssertEqual(muted.mutedUntil, Timestamps.iso8601(date(62)))

        let whileMuted = prompt(captureId: captureId, streamId: streamId, sequence: 2)
        let mutedDecision = try await coordinator.receive(whileMuted, at: date(3))
        XCTAssertEqual(mutedDecision.disposition, .suppressed(.userAction))
        let resumed = try await coordinator.resume(at: date(4))
        XCTAssertNotNil(resumed)

        let second = prompt(captureId: captureId, streamId: streamId, sequence: 2)
        let secondDecision = try await coordinator.receive(second, at: date(5))
        XCTAssertEqual(secondDecision.disposition, .shown)
        _ = try await coordinator.answer(
            promptId: second.promptId,
            answer: CaptureCoachAnswer(mode: .typedText, text: "A rejected invoice."),
            at: date(6))
        let firstFinish = try await coordinator.finishAnyway(at: date(7))
        XCTAssertNotNil(firstFinish)
        let secondFinish = try await coordinator.finishAnyway(at: date(8))
        XCTAssertNil(secondFinish)

        let afterFinish = prompt(captureId: captureId, streamId: streamId, sequence: 3)
        let afterFinishDecision = try await coordinator.receive(afterFinish, at: date(9))
        XCTAssertEqual(afterFinishDecision.disposition, .suppressed(.userAction))
        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.finishedAnyway)
        XCTAssertNil(snapshot.outstandingPrompt)
        let values = await recorder.interactions()
        XCTAssertEqual(values.first?.interactionType, .unavailable)
        XCTAssertTrue(values.contains { $0.interactionType == .answered })
        XCTAssertTrue(values.contains { $0.interactionType == .finishAnyway })
    }
}
