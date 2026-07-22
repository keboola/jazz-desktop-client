import Foundation
import JasnostCaptureCore
import WebKit

/// Shared channel that drives the LIVE BDM canvas embedded in the main window's ``WebCanvas``.
///
/// During a BDM workshop the native floating panel walks the scripted interview while capture
/// records; the moment each question's segment closes and its narration audio uploads,
/// ``CaptureController`` reports it and ``AppDelegate`` calls ``push(labelId:label:audioFileId:screenshots:)``
/// here. This bridge forwards the segment into the embedded Data App SPA (loaded at
/// ``#/session/<id>/bdm-live``) by calling its ``window.__jasnostBdmSegment`` hook over
/// ``WKWebView.evaluateJavaScript`` — the SPA then runs one BDM turn and the model grows on screen.
///
/// Two ordering hazards it absorbs:
/// - The web page may not have registered its hook yet when the first segment arrives. Segments
///   queue until the page posts ``bdmLiveReady`` (``markReady()``), then flush in order.
/// - The page (and its hook) outlive a single ``evaluateJavaScript``; turns are sequenced on the
///   SPA side, so this side only has to deliver every segment exactly once, in order.
///
/// ``liveSessionId`` is observed by ``MainView``: when set, the detail pane shows the live canvas
/// for that session instead of the normal review/local detail.
@MainActor
final class BdmLiveBridge: ObservableObject {
    /// The session whose live BDM canvas the main window should show, or nil when not live.
    @Published private(set) var liveSessionId: String?

    /// The web view currently hosting the live page (set by ``WebCanvas`` on creation). Weak: the
    /// SPA owns its lifetime; we only borrow it to deliver segments.
    private weak var webView: WKWebView?
    /// Segments awaiting delivery — populated before the page signals ready, drained on ``flush()``.
    private var pending: [String] = []
    /// Whether the live page has registered its ``__jasnostBdmSegment`` hook (it posted ``bdmLiveReady``).
    private var ready = false

    /// Relayed back from the live page after each turn: ask the consultant's next question, finish,
    /// or fall back to the script (the turn errored). Set by ``AppDelegate`` to drive the floating
    /// workshop panel — this is the inverse of ``push`` (segments go native -> web; the next question
    /// comes web -> native), the half that makes the macOS workshop adaptive instead of a fixed script.
    var onNextQuestion: (BdmRelayOutcome) -> Void = { _ in }

    /// The workshop language picked from the menu before starting (e.g. "Czech"), or empty/nil for
    /// Auto. Set by ``AppDelegate`` when the workshop opens and forwarded with every pushed segment,
    /// so each live turn runs in that language — both the adaptive next question and the wording of
    /// the assembled Business Data Model. Empty = the backend mirrors the spoken narration.
    var language: String?

    /// Enter live mode for ``sessionId``: the main window will show the live canvas, and incoming
    /// segments are delivered to it. Resets readiness — the freshly loaded page re-signals.
    func begin(sessionId: String) {
        pending.removeAll()
        ready = false
        liveSessionId = sessionId
    }

    /// Leave live mode (the workshop ended or the user navigated away). Keeps nothing pending.
    func end() {
        pending.removeAll()
        ready = false
        liveSessionId = nil
    }

    /// The hosting ``WKWebView`` was (re)created — adopt it. A fresh web view hasn't loaded the
    /// page yet, so it isn't ready until it posts ``bdmLiveReady``.
    func attach(_ webView: WKWebView) {
        self.webView = webView
        ready = false
    }

    /// The hosting web view went away — forget it (only if it's still the one we hold).
    func detach(_ webView: WKWebView) {
        if self.webView === webView {
            self.webView = nil
            ready = false
        }
    }

    /// The live page registered its hook (posted ``bdmLiveReady``) — deliver anything queued.
    func markReady() {
        ready = true
        flush()
    }

    /// The live page relayed a ``bdmNextQuestion`` message. Forward it to the workshop panel via
    /// ``onNextQuestion``: ``fallback`` -> drop to the script now (the turn errored); ``done`` (or an
    /// empty question) -> the interview is complete; otherwise -> ask the relayed question. Ignored
    /// when not live, so a stale relay from a closed canvas can't drive a fresh workshop.
    func receiveNextQuestion(question: String?, qid: String, done: Bool, fallback: Bool) {
        guard liveSessionId != nil else { return }
        if fallback {
            onNextQuestion(.fallback)
            return
        }
        let text = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if done || text.isEmpty {
            onNextQuestion(.done)
        } else {
            onNextQuestion(.question(BdmAdaptiveQuestion(id: qid, text: text)))
        }
    }

    /// Hand one closed workshop segment to the live page. Queued until the page is ready. Ignored
    /// unless the segment belongs to the session we're live for — a backlog clip from another
    /// session (draining on a later launch) must not bleed into the current workshop's canvas.
    func push(
        sessionId: String, labelId: String, label: String, audioFileId: String,
        screenshots: [String]
    ) {
        guard sessionId == liveSessionId else { return }
        var payload: [String: Any] = [
            "labelId": labelId,
            "label": label,
            "audioFileId": audioFileId,
            "screenshots": screenshots,
        ]
        // Carry the workshop language so the live turn (question + model wording) runs in it.
        // Omitted when empty — the SPA then sends no language and the backend mirrors narration.
        if let language, !language.isEmpty {
            payload["language"] = language
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else { return }
        pending.append(json)
        flush()
    }

    /// Deliver every queued segment to the page in order, then clear the queue. No-op until the
    /// page is ready and a web view is attached.
    private func flush() {
        guard ready, let webView else { return }
        let batch = pending
        pending.removeAll()
        for json in batch {
            // The JSON object literal is a valid JS argument; the `&&` guard is a belt-and-braces
            // no-op if the hook somehow isn't present despite the readiness signal. Delivery is
            // best-effort: a JS failure (page mid-reload / web content crashed) can't be retried
            // here without risking a loop, so log it — a lost live segment is then diagnosable, and
            // the durable recording + post-hoc "Build BDM from recording" remain the safety net
            // (webViewWebContentProcessDidTerminate reloads the canvas on a crash).
            webView.evaluateJavaScript(
                "window.__jasnostBdmSegment && window.__jasnostBdmSegment(\(json));"
            ) { _, error in
                if let error {
                    NSLog(
                        "jasnost: live BDM segment delivery failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
