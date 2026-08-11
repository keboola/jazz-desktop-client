import Foundation

/// The questions a BDM workshop walks the user through, in order.
///
/// A BDM workshop is a *narrated, guided* recording: the floating panel shows one question at a
/// time, the user answers by speaking AND showing things on screen, and each question's answer is
/// captured as its own bracketed-label segment (audio + screenshots + events tagged `label:<id>`).
/// The actual Business Data Model is then assembled — adaptively, by the LLM — back in the Data App
/// by replaying those segments (one BDM turn per segment). So this script's job is only to *guide*
/// the conversation through Keboola's BDM methodology (Steps 0–5), not to be the model itself.
///
/// It lives in `JazzCaptureCore` (pure Foundation, no TCC) so the question set and the
/// progression logic are unit-testable without Accessibility/Screen-Recording grants.
/// A question relayed back from the Data App's interviewer during a LIVE workshop.
///
/// In a live workshop the floating panel no longer walks a fixed list: after each answered segment
/// the Data App's BDM turn picks the single best NEXT question from what was just said (the engine
/// in ``bdm_interview``), and the embedded SPA relays it here. The panel then asks *that* question,
/// so the interview adapts to the person instead of following a checklist. ``id`` ties the segment
/// back to the question; ``text`` is shown in the panel and used as the segment's label.
public struct BdmAdaptiveQuestion: Sendable, Equatable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// What the workshop panel should do once a segment closes — ask another question, or finish.
public enum BdmWorkshopAction: Equatable, Sendable {
    case ask(BdmInterviewScript.Question)
    case finish
}

/// What the live page relayed back after a segment's turn:
/// - ``question``: ask this next (the adaptive path);
/// - ``done``: the interviewer says the model is complete — finish;
/// - ``fallback``: the turn errored — fall back to the scripted skeleton NOW, rather than making
///   the panel sit on its spinner until the safety-net timeout fires.
public enum BdmRelayOutcome: Sendable, Equatable {
    case question(BdmAdaptiveQuestion)
    case done
    case fallback
}

public struct BdmInterviewScript: Sendable {
    /// One scripted question.
    public struct Question: Sendable, Equatable {
        /// Stable id (also used as the label/`askedId` so a segment ties back to its question).
        public let id: String
        /// BDM methodology step this question belongs to (0 Round-up … 5 Iterate).
        public let step: Int
        /// The prompt shown to the user in the panel and stored as the segment's label text.
        public let text: String

        public init(id: String, step: Int, text: String) {
            self.id = id
            self.step = step
            self.text = text
        }
    }

    public let questions: [Question]

    /// Build a script. Defaults to the bundled methodology walk-through; a custom set can be passed
    /// (e.g. for tests or a future server-supplied script).
    public init(questions: [Question] = BdmInterviewScript.methodology) {
        self.questions = questions
    }

    public var count: Int { questions.count }

    /// The question at `index`, or `nil` once the script is exhausted (interview complete).
    public func question(at index: Int) -> Question? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    /// Whether `index` is the final question (so the panel can show "Finish" instead of "Next").
    public func isLast(_ index: Int) -> Bool {
        !questions.isEmpty && index == questions.count - 1
    }

    /// Decide what to ask after a segment closes, given the live relay outcome. Pure so the
    /// (untestable, TCC-bound) panel controller can delegate the decision and have it covered.
    ///
    /// - ``done``: the interviewer signalled the model is complete -> ``.finish``.
    /// - ``adaptive``: a question relayed from the Data App -> ask exactly that (the live path).
    /// - neither (the relay never arrived — turn errored, offline, or no live canvas) -> fall back
    ///   to the scripted skeleton at ``fallbackIndex`` so a workshop never stalls; past the end of
    ///   the script that means ``.finish``.
    public func nextAction(
        adaptive: BdmAdaptiveQuestion?, done: Bool, fallbackIndex: Int
    ) -> BdmWorkshopAction {
        if done { return .finish }
        if let adaptive {
            return .ask(Question(id: adaptive.id, step: 0, text: adaptive.text))
        }
        if let scripted = question(at: fallbackIndex) {
            return .ask(scripted)
        }
        return .finish
    }

    /// The default BDM methodology walk-through. Each question nudges the user to both *say* and
    /// *show* (open the real system, click through it) — that pairing of narration + screenshots is
    /// exactly what the downstream BDM extraction needs.
    public static let methodology: [Question] = [
        Question(
            id: "scope",
            step: 0,
            text: "Which part of the business are we mapping today? Name the area and what's in or out of scope."
        ),
        Question(
            id: "systems",
            step: 1,
            text: "Which systems hold the data for this area? Open each one and show me."
        ),
        Question(
            id: "entities",
            step: 1,
            text: "What are the main things you track here — customers, orders, tickets…? Show a few real records."
        ),
        Question(
            id: "define",
            step: 2,
            text: "Pick the most important thing. What defines one of them, and which fields really matter? Point them out on screen."
        ),
        Question(
            id: "relations",
            step: 3,
            text: "How do these things connect? For example, one customer has many orders. Show where that link lives."
        ),
        Question(
            id: "transactions",
            step: 3,
            text: "Where do events or transactions show up — something with a date and an amount? Open one and walk me through it."
        ),
        Question(
            id: "test",
            step: 4,
            text: "Take one real example and follow it end to end. Does anything not fit the picture we've built?"
        ),
        Question(
            id: "iterate",
            step: 5,
            text: "What's still missing, unclear, or named differently in practice? Anything you'd add or rename?"
        ),
    ]
}
