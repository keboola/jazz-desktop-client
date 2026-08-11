import XCTest

@testable import JazzCaptureCore

final class CaptureCoachPresentationStateTests: XCTestCase {
    private func prompt(
        captureId: String,
        labelId: String,
        sequence: Int = 1
    ) -> CaptureCoachPrompt {
        CaptureCoachPrompt(
            promptId: Identifiers.newCoachPromptId(),
            labelId: labelId,
            localBaselineRef: CaptureCoachLocalBaselineRef(
                planId: "capture-coach-local-baseline",
                planVersion: "1.0.0",
                planDigest: String(repeating: "b", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                captureId: captureId,
                streams: [
                    CaptureCoachStreamWatermark(
                        streamId: Identifiers.newStreamId(),
                        throughSequence: sequence)
                ]),
            snapshot: CaptureCoachPromptSnapshot(
                text: "What decides the next step?",
                slot: .decisionRule,
                policyVersion: "capture-coach-local-baseline-v1",
                responseModes: [.typedText, .spoken]))
    }

    private func snapshot(
        prompt: CaptureCoachPrompt?
    ) -> CaptureCoachCoordinatorSnapshot {
        CaptureCoachCoordinatorSnapshot(
            outstandingPrompt: prompt,
            pendingReceivedPrompt: nil,
            mutedUntil: nil,
            cooldownUntil: nil,
            finishedAnyway: false,
            captureCommitted: false,
            closedLabelIds: [],
            knownPromptCount: prompt == nil ? 0 : 1)
    }

    func testCloseAStartBRetractsAAndRejectsItsLateProjection() throws {
        let captureId = Identifiers.newCaptureId()
        let labelA = Identifiers.newLabelId()
        let labelB = Identifiers.newLabelId()
        let promptA = prompt(captureId: captureId, labelId: labelA)
        var state = CaptureCoachPresentationState()
        state.beginCapture(captureId: captureId)
        let contextA = try XCTUnwrap(
            state.openLabel(captureId: captureId, labelId: labelA))

        XCTAssertTrue(state.present(promptA, in: contextA))
        XCTAssertEqual(state.prompt, promptA)
        XCTAssertTrue(state.closeLabel(captureId: captureId, labelId: labelA))
        XCTAssertNil(state.prompt, "endLabel must synchronously retract the panel")

        let contextB = try XCTUnwrap(
            state.openLabel(captureId: captureId, labelId: labelB))
        XCTAssertFalse(state.apply(snapshot(prompt: promptA), in: contextA))
        XCTAssertFalse(
            state.present(
                prompt(captureId: Identifiers.newCaptureId(), labelId: labelB),
                in: contextB))
        XCTAssertNil(state.prompt)
        XCTAssertEqual(state.currentContext, contextB)
    }

    func testDelayedCallbackRequiresExactGenerationEvenWhenLabelIdentityRepeats() throws {
        let captureId = Identifiers.newCaptureId()
        let labelId = Identifiers.newLabelId()
        let delayed = prompt(captureId: captureId, labelId: labelId)
        var state = CaptureCoachPresentationState()
        state.beginCapture(captureId: captureId)
        let oldContext = try XCTUnwrap(
            state.openLabel(captureId: captureId, labelId: labelId))
        XCTAssertTrue(state.closeLabel(captureId: captureId, labelId: labelId))
        let newContext = try XCTUnwrap(
            state.openLabel(captureId: captureId, labelId: labelId))

        XCTAssertNotEqual(oldContext.generation, newContext.generation)
        XCTAssertFalse(state.present(delayed, in: oldContext))
        XCTAssertNil(state.prompt)
    }

    func testBlockedSpokenArtifactCompletionCannotContaminateNewLabel() throws {
        let captureId = Identifiers.newCaptureId()
        let labelA = Identifiers.newLabelId()
        let labelB = Identifiers.newLabelId()
        let promptA = prompt(captureId: captureId, labelId: labelA)
        let promptB = prompt(captureId: captureId, labelId: labelB, sequence: 2)
        var state = CaptureCoachPresentationState()
        state.beginCapture(captureId: captureId)
        let artifactGatedContext = try XCTUnwrap(
            state.openLabel(captureId: captureId, labelId: labelA))
        XCTAssertTrue(state.present(promptA, in: artifactGatedContext))

        XCTAssertTrue(state.closeLabel(captureId: captureId, labelId: labelA))
        let contextB = try XCTUnwrap(
            state.openLabel(captureId: captureId, labelId: labelB))
        XCTAssertTrue(state.present(promptB, in: contextB))

        // This models the coordinator snapshot emitted only after label A's narration artifact gate
        // finally resolves. It must neither re-show A nor clear B.
        XCTAssertFalse(
            state.apply(snapshot(prompt: promptA), in: artifactGatedContext))
        XCTAssertEqual(state.prompt, promptB)
        XCTAssertEqual(state.currentContext, contextB)
    }
}
