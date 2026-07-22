import SwiftUI
import WebKit

/// Embeds the hosted jasnost review Data App (the React SPA: timeline + clarify + L4 + BDM
/// workshop) in a WKWebView, loaded in `?embed=macos&session=<id>` mode so it hides its own
/// sidebar/header and shows the session the native sidebar selected.
///
/// Selection is driven by the URL: when the native sidebar picks a different session, the web
/// view reloads at `?embed=macos&session=<newId>`, so the SPA deterministically seeds that
/// session on mount — no dependency on JS-injection timing. The web->native channel stays for
/// messages the page posts to `window.webkit.messageHandlers.jasnost` (a known set of `type`s).
///
/// Failure handling: a hosted app can be down/unreachable — a failed load shows an explicit
/// message + Reload button instead of stranding the user on a silent white panel. An empty
/// URL (review app not configured yet) shows a setup hint instead of loading anything.
struct WebCanvas: View {
    let reviewAppURL: String
    let sessionId: String?
    /// Validated web->native messages (e.g. "openSettings", "export").
    var onMessage: (String) -> Void = { _ in }
    /// LIVE BDM workshop mode: load the SPA's `#/session/<id>/bdm-live` page and feed it segments
    /// over ``liveBridge`` as the workshop records (instead of the normal review embed).
    var live: Bool = false
    var liveBridge: BdmLiveBridge?

    @State private var loadError: String?
    /// Incremented by the Reload button; the representable reloads when it changes.
    @State private var reloadToken = 0

    var body: some View {
        if reviewAppURL.trimmingCharacters(in: .whitespaces).isEmpty {
            placeholder
        } else {
            ZStack {
                WebCanvasRepresentable(
                    reviewAppURL: reviewAppURL,
                    sessionId: sessionId,
                    live: live,
                    liveBridge: liveBridge,
                    reloadToken: reloadToken,
                    onMessage: onMessage,
                    onLoadFailure: { message in loadError = message },
                    onLoadSuccess: { loadError = nil }
                )
                if let loadError {
                    failureOverlay(loadError)
                }
            }
        }
    }

    /// Review app not configured yet — say what to do, don't load a blank page.
    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No review app configured")
                .font(.headline)
            Text("Set the review app URL (your hosted Jazz Data App) in Settings to open sessions for review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Open Settings…") { onMessage("openSettings") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    /// The load failed (offline, app down, bad URL) — explain and offer a retry.
    private func failureOverlay(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't load the review app")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Reload") {
                loadError = nil
                reloadToken += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// The actual WKWebView wrapper (kept private — ``WebCanvas`` is the public surface).
private struct WebCanvasRepresentable: NSViewRepresentable {
    let reviewAppURL: String
    let sessionId: String?
    let live: Bool
    let liveBridge: BdmLiveBridge?
    let reloadToken: Int
    var onMessage: (String) -> Void
    var onLoadFailure: (String) -> Void
    var onLoadSuccess: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            liveBridge: liveBridge,
            onMessage: onMessage, onLoadFailure: onLoadFailure, onLoadSuccess: onLoadSuccess)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "jasnost")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.reloadToken = reloadToken
        // In live mode the bridge needs a handle to this web view to deliver segments into it.
        if live { liveBridge?.attach(webView) }
        if let url = Self.embedURL(reviewAppURL: reviewAppURL, sessionId: sessionId, live: live) {
            context.coordinator.loadedSession = sessionId
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.onLoadFailure = onLoadFailure
        context.coordinator.onLoadSuccess = onLoadSuccess
        // Reload when the selected session changes (fresh URL) OR the user hit Reload
        // after a failure (same URL, fresh attempt).
        let sessionChanged = context.coordinator.loadedSession != sessionId
        let reloadRequested = context.coordinator.reloadToken != reloadToken
        guard sessionChanged || reloadRequested,
            let url = Self.embedURL(reviewAppURL: reviewAppURL, sessionId: sessionId, live: live)
        else { return }
        context.coordinator.loadedSession = sessionId
        context.coordinator.reloadToken = reloadToken
        if live { liveBridge?.attach(webView) }
        webView.load(URLRequest(url: url))
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "jasnost")
        webView.navigationDelegate = nil
        coordinator.liveBridge?.detach(webView)
    }

    /// `https://<review-app>/?embed=macos[&session=<id>]`, with `#/session/<id>/bdm-live` appended
    /// in live mode (the SPA's full-page live BDM route).
    static func embedURL(reviewAppURL: String, sessionId: String?, live: Bool) -> URL? {
        let base = reviewAppURL.hasSuffix("/") ? String(reviewAppURL.dropLast()) : reviewAppURL
        guard var comps = URLComponents(string: base + "/") else { return nil }
        var items = [URLQueryItem(name: "embed", value: "macos")]
        if let sessionId, !sessionId.isEmpty {
            items.append(URLQueryItem(name: "session", value: sessionId))
        }
        comps.queryItems = items
        if live, let sessionId, !sessionId.isEmpty {
            comps.fragment = "/session/\(sessionId)/bdm-live"
        }
        return comps.url
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var liveBridge: BdmLiveBridge?
        var onMessage: (String) -> Void
        var onLoadFailure: (String) -> Void
        var onLoadSuccess: () -> Void
        /// The session currently loaded in the web view (so we only reload on a real change).
        var loadedSession: String?
        /// Mirrors the view's reload token (so updateNSView detects a Reload click).
        var reloadToken = 0

        private static let allowedTypes: Set<String> = [
            "ready", "openSettings", "export", "bdmLiveReady", "bdmNextQuestion",
        ]

        init(
            liveBridge: BdmLiveBridge?,
            onMessage: @escaping (String) -> Void,
            onLoadFailure: @escaping (String) -> Void,
            onLoadSuccess: @escaping () -> Void
        ) {
            self.liveBridge = liveBridge
            self.onMessage = onMessage
            self.onLoadFailure = onLoadFailure
            self.onLoadSuccess = onLoadSuccess
        }

        // web -> native
        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "jasnost",
                let body = message.body as? String,
                let data = body.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = json["type"] as? String,
                Self.allowedTypes.contains(type)
            else { return }
            switch type {
            // The live BDM page signals it registered its push hook — flush any queued segments.
            case "bdmLiveReady":
                liveBridge?.markReady()
            // The live page relayed the consultant's next adaptive question (or that it's done) —
            // forward it to the workshop panel so it asks what the answer just prompted.
            case "bdmNextQuestion":
                liveBridge?.receiveNextQuestion(
                    question: json["question"] as? String,
                    qid: (json["qid"] as? String) ?? "",
                    done: (json["done"] as? Bool) ?? false,
                    fallback: (json["fallback"] as? Bool) ?? false)
            case "ready":
                break
            default:
                onMessage(type)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadSuccess()
        }

        // A failure BEFORE any content arrived (DNS, refused, offline) — the classic
        // silent-white-screen case. NSURLErrorCancelled is normal churn (a new load
        // superseding the old one), not a failure to show.
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            report(error)
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            else { return }
            onLoadFailure(nsError.localizedDescription)
        }

        // The web content process can crash under memory pressure (e.g. rendering a large L4
        // or a long extract SSE stream), leaving the canvas blank with no recovery of its
        // own. Reload the last URL to bring the SPA back instead of stranding the user.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("jasnost: web content process terminated; reloading the canvas")
            webView.reload()
        }
    }
}
