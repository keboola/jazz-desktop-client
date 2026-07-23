import AppKit
import JasnostCaptureCore
import SwiftUI

/// Drives a BDM workshop: a small floating panel walks the user through the scripted interview
/// (``BdmInterviewScript``) one question at a time while capture records in the background.
///
/// Each question is answered by *speaking and showing* — so each question is wrapped in its own
/// bracketed-label segment: asking a question opens a label (named after the question, which turns
/// the mic on), and moving to the next question closes that label (uploading its audio, tagged
/// `label:<id>`) and opens the next. The Business Data Model itself is assembled later, back in the
/// Data App, by replaying those segments (one BDM turn per segment) — so this panel stays purely a
/// guided recorder and needs no network/OIDC of its own.
///
/// The panel is a non-activating floating window (like ``LabelPanelController``): it shows the
/// question and a Next/Finish button without stealing focus, so the user can click around their
/// real apps (open the system they're describing, click through it) while the question stays in
/// view. UI-only — capture wiring is injected by ``AppDelegate`` so this target stays testable by
/// inspection and the capture lifecycle has a single owner.
@MainActor
final class BdmWorkshopController: NSObject {
    /// Same Spotlight-like placement as the label panel: centered, just below the menu bar.
    private static let topOffset: CGFloat = 60

    // Wiring to the capture side (injected by AppDelegate). Kept as closures so this stays UI-only.
    /// Begin recording in BDM-workshop mode (forces mic + dense screenshots). Returns whether
    /// capture actually started (permissions could refuse it).
    var onStartCapture: () async -> Bool = { false }
    /// Open a bracketed-label segment named after the question (turns the mic on for the answer).
    var onAskQuestion: (BdmInterviewScript.Question) -> Void = { _ in }
    /// Close the open segment (mic off, audio uploads tagged `label:<id>`).
    var onEndSegment: () -> Void = {}
    /// Stop capture entirely (ends the workshop session).
    var onStopCapture: () -> Void = {}

    /// LIVE adaptive mode: after each segment closes, wait for the Data App to relay the next
    /// question (built from the answer just given) instead of advancing the local script. Set by
    /// ``AppDelegate`` when the workshop opens with a live canvas to host the turn loop; ``false``
    /// (the default) keeps the fully-scripted walk-through, which needs no network of its own.
    var adaptive = false

    /// How long to wait for the relayed adaptive question before falling back to the scripted
    /// skeleton — generous because the turn runs server-side (audio upload + transcription + merge
    /// + question), so a normal turn can take tens of seconds. The fallback guarantees the workshop
    /// never stalls if a turn errors, the canvas is gone, or the device went offline.
    private static let adaptiveTimeout: TimeInterval = 60

    private let script: BdmInterviewScript
    private var index = 0
    private var active = false
    /// True between closing a segment and the next question arriving (adaptive mode): a stray/late
    /// relay outside this window is ignored, and the timeout below falls back to the script.
    private var awaitingAdaptive = false
    private var fallbackTimer: Timer?

    private var panel: NSPanel?
    private let model = BdmPanelModel()

    init(script: BdmInterviewScript = BdmInterviewScript()) {
        self.script = script
        super.init()
    }

    /// Whether a workshop is currently running (so the menu can offer Start vs nothing).
    var isRunning: Bool { active }

    /// Start the workshop: begin capture, show the panel, and ask the first question. No-op if a
    /// workshop is already running or capture refuses to start (e.g. missing permission).
    func start() {
        guard !active else { return }
        Task { @MainActor [weak self] in
            guard let self, await self.onStartCapture() else { return }
            self.active = true
            self.index = 0
            self.awaitingAdaptive = false
            self.showPanel()
            self.askCurrent()  // opener is scripted; local archive is durable before this point
        }
    }

    /// Advance past the current question: close the segment, then ask the next. In adaptive mode the
    /// next question comes from the Data App (built from this answer), so we show a "thinking" state
    /// and wait for the relay (with a timeout fallback to the script); otherwise we walk the script.
    func next() {
        guard active else { return }
        onEndSegment()
        index += 1
        if adaptive {
            beginAwaitingAdaptive()
        } else if script.question(at: index) != nil {
            askCurrent()
        } else {
            finish()
        }
    }

    /// The live page relayed a turn outcome: ask the consultant's next question, finish (interview
    /// complete), or fall back to the script NOW (the turn errored — no need to wait out the
    /// timeout). Ignored unless we're actually awaiting one — guards against stale or duplicate
    /// relays (e.g. a backlog turn from a closed canvas).
    func receiveAdaptiveQuestion(_ outcome: BdmRelayOutcome) {
        guard active, awaitingAdaptive else { return }
        switch outcome {
        case .question(let question):
            resolveNext(adaptive: question, done: false)
        case .done:
            resolveNext(adaptive: nil, done: true)
        case .fallback:
            resolveNext(adaptive: nil, done: false)
        }
    }

    /// End the workshop early or after the last question: close the open segment, stop capture,
    /// and hide the panel.
    func finish() {
        guard active else { return }
        active = false
        clearAwaiting()
        onEndSegment()
        onStopCapture()
        panel?.orderOut(nil)
    }

    /// Enter the "thinking" state after a segment closed in adaptive mode: disable Next, show a
    /// spinner, and arm the fallback timer so a lost/slow relay can't stall the workshop.
    private func beginAwaitingAdaptive() {
        awaitingAdaptive = true
        model.thinking = true
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(
            withTimeInterval: Self.adaptiveTimeout, repeats: false
        ) { [weak self] _ in
            // Timer fires on the main run loop, so we're on the main actor at runtime.
            MainActor.assumeIsolated { self?.resolveNext(adaptive: nil, done: false) }
        }
    }

    private func clearAwaiting() {
        awaitingAdaptive = false
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        model.thinking = false
    }

    /// Decide and perform the next step once a segment closed: ask the relayed adaptive question,
    /// fall back to the scripted skeleton (timeout / no relay), or finish (the interviewer is done).
    private func resolveNext(adaptive question: BdmAdaptiveQuestion?, done: Bool) {
        guard awaitingAdaptive else { return }
        clearAwaiting()
        switch script.nextAction(adaptive: question, done: done, fallbackIndex: index) {
        case .ask(let next):
            ask(next)
        case .finish:
            finish()
        }
    }

    /// Ask the question at the current index (open its segment + show it), or finish at the end.
    private func askCurrent() {
        guard let question = script.question(at: index) else {
            finish()
            return
        }
        ask(question)
    }

    /// Open a segment for ``question`` and show it in the panel. Shared by the scripted opener, the
    /// scripted fallback, and the relayed adaptive question.
    private func ask(_ question: BdmInterviewScript.Question) {
        onAskQuestion(question)
        model.question = question.text
        model.position = index + 1
        model.total = script.count
        model.adaptive = adaptive
        model.thinking = false
        // In adaptive mode the Data App decides when the interview is done, so never offer the
        // script's "Finish"; the user ends via "End workshop" (or the relay's done signal).
        model.isLast = !adaptive && script.isLast(index)
    }

    private func showPanel() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - frame.width / 2,
                    y: screen.visibleFrame.maxY - frame.height - Self.topOffset))
        }
        panel.orderFront(nil)  // order front WITHOUT activating jasnost (non-activating panel)
    }

    private func makePanel() -> NSPanel {
        model.onNext = { [weak self] in self?.next() }
        model.onFinish = { [weak self] in self?.finish() }
        let host = NSHostingController(rootView: BdmPanelView(model: model))
        let panel = NSPanel(contentViewController: host)
        panel.title = "BDM workshop"
        // Non-activating + floating: the question stays visible above the user's real apps and
        // takes button clicks WITHOUT activating jasnost, so the user keeps clicking through the
        // system they're describing while answering aloud.
        panel.styleMask = [.titled, .utilityWindow, .nonactivatingPanel]
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }
}

/// Bridge between the AppKit panel and its SwiftUI content.
@MainActor
final class BdmPanelModel: ObservableObject {
    @Published var question = ""
    @Published var position = 1
    @Published var total = 1
    @Published var isLast = false
    /// Adaptive (live) mode: show a turn counter instead of "N / total" (there is no fixed total).
    @Published var adaptive = false
    /// Between answering and the next adaptive question arriving: show a spinner, disable Next.
    @Published var thinking = false
    var onNext: () -> Void = {}
    var onFinish: () -> Void = {}
}

struct BdmPanelView: View {
    @ObservedObject var model: BdmPanelModel

    /// In adaptive mode there's no fixed total, so show the turn number; otherwise "N / total".
    private var counter: String {
        model.adaptive ? "Q\(model.position)" : "\(model.position) / \(model.total)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
                Text("BDM workshop").font(.headline)
                Spacer()
                Text(counter)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if model.thinking {
                // The answer just closed; the Data App is transcribing it and forming the next
                // question. Show progress instead of a stale question, and block Next until it lands.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Listening to your answer and forming the next question…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(model.question)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    "Answer out loud — and open the system to show me as you go.",
                    systemImage: "mic.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
            HStack {
                Button("End workshop") { model.onFinish() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isLast {
                    Button("Finish") { model.onFinish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Next question") { model.onNext() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.thinking)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
