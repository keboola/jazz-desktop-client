import XCTest

@testable import JazzCaptureCore

/// The scripted BDM-workshop question walk-through: ordering, bounds, and "is this the last one?".
final class BdmInterviewScriptTests: XCTestCase {
    func testDefaultMethodologyIsNonEmptyWithStableUniqueIds() {
        let script = BdmInterviewScript()
        XCTAssertGreaterThan(script.count, 0)
        let ids = script.questions.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "question ids must be unique (used as askedId)")
        // Steps stay within the BDM methodology range 0…5 and start at the scope round-up.
        XCTAssertTrue(script.questions.allSatisfy { (0...5).contains($0.step) })
        XCTAssertEqual(script.questions.first?.step, 0)
    }

    func testQuestionAtReturnsNilPastTheEnd() {
        let script = BdmInterviewScript()
        XCTAssertEqual(script.question(at: 0)?.id, script.questions.first?.id)
        XCTAssertNil(script.question(at: -1))
        XCTAssertNil(script.question(at: script.count), "one past the end is the 'interview done' signal")
    }

    func testIsLastOnlyTrueForFinalIndex() {
        let script = BdmInterviewScript()
        XCTAssertFalse(script.isLast(0))
        XCTAssertTrue(script.isLast(script.count - 1))
        XCTAssertFalse(script.isLast(script.count))
    }

    func testCustomScriptIsHonored() {
        let custom = BdmInterviewScript(questions: [
            .init(id: "a", step: 0, text: "first?"),
            .init(id: "b", step: 1, text: "second?"),
        ])
        XCTAssertEqual(custom.count, 2)
        XCTAssertEqual(custom.question(at: 1)?.text, "second?")
        XCTAssertTrue(custom.isLast(1))
    }

    func testEmptyScriptHasNoLast() {
        let empty = BdmInterviewScript(questions: [])
        XCTAssertFalse(empty.isLast(0))
        XCTAssertNil(empty.question(at: 0))
    }

    // --- nextAction: live adaptive relay vs scripted fallback -----------------

    func testNextActionAsksTheAdaptiveQuestionWhenRelayed() {
        let script = BdmInterviewScript()
        let action = script.nextAction(
            adaptive: BdmAdaptiveQuestion(id: "aq-1", text: "You mentioned invoices — who issues them?"),
            done: false,
            fallbackIndex: 1)
        guard case let .ask(q) = action else { return XCTFail("expected .ask") }
        XCTAssertEqual(q.id, "aq-1")
        XCTAssertEqual(q.text, "You mentioned invoices — who issues them?")
    }

    func testNextActionFallsBackToScriptWhenNoQuestionRelayed() {
        let script = BdmInterviewScript()
        // No adaptive question arrived (turn errored / offline / no live canvas): use the skeleton.
        let action = script.nextAction(adaptive: nil, done: false, fallbackIndex: 1)
        guard case let .ask(q) = action else { return XCTFail("expected .ask fallback") }
        XCTAssertEqual(q.id, script.questions[1].id)
    }

    func testNextActionFinishesWhenDone() {
        let script = BdmInterviewScript()
        // 'done' wins even if a question is somehow present.
        XCTAssertEqual(
            script.nextAction(
                adaptive: BdmAdaptiveQuestion(id: "x", text: "ignored"), done: true, fallbackIndex: 0),
            .finish)
    }

    func testNextActionFinishesWhenFallbackPastEndOfScript() {
        let script = BdmInterviewScript()
        XCTAssertEqual(
            script.nextAction(adaptive: nil, done: false, fallbackIndex: script.count), .finish)
    }
}
