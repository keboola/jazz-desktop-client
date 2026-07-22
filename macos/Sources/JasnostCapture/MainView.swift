import JasnostCaptureCore
import SwiftUI

/// Sessions for the native sidebar, listed straight from the local ``EventSpool``
/// (spool + journal merged) — instant, offline, no network polling. The app produced the
/// events, so it doesn't need to ask Keboola what it captured; refreshes ride on capture
/// activity (``noteCaptureActivity()``), not a timer hitting a remote endpoint.
@MainActor
final class SessionListModel: ObservableObject {
    @Published private(set) var items: [EventSpool.SessionSummary] = []
    @Published var selectedId: String?

    private let spool: EventSpool
    /// Coalesces bursts of capture events into one disk scan (the listing reads every
    /// batch file, so a per-event reload would thrash during fast interaction).
    private var reloadDebounce: Timer?

    init(spool: EventSpool) {
        self.spool = spool
    }

    /// Re-read the local listing. The user's current selection is preserved when still
    /// present — a refresh must not yank the detail pane to another session; it only picks
    /// the first row when nothing valid is selected.
    func reload() {
        items = spool.sessions()
        let current = selectedId  // capture the value, not the property (Swift 6)
        if current == nil || !items.contains(where: { $0.id == current }) {
            selectedId = items.first?.id
        }
    }

    /// Called on every capture-state change (AppDelegate forwards the controller's
    /// objectWillChange) — debounced so the sidebar follows a running session live without
    /// re-scanning the spool hundreds of times a minute.
    func noteCaptureActivity() {
        reloadDebounce?.invalidate()
        reloadDebounce = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    /// Replay steps for any listed session, distilled from its locally journaled events —
    /// works offline and for sessions captured on previous launches.
    func replaySteps(sessionId: String) -> [ReplayStep] {
        ReplayBuilder.steps(fromActivityEvents: spool.sessionEvents(sessionId: sessionId))
    }
}

/// The main window: a native sessions sidebar on the left (local journal, instant), and a
/// detail pane on the right. The detail pane shows the selected session's local facts with
/// an "Open review" button that swaps in the embedded hosted review app (WebCanvas) for
/// the deep work — timeline, clarify, L4, BDM workshop.
struct MainView: View {
    @ObservedObject var model: SessionListModel
    @ObservedObject var replayer: ReplayController
    /// Drives the LIVE BDM canvas: when ``liveBridge.liveSessionId`` is set (a workshop is running),
    /// the detail pane shows the model assembling itself instead of the normal review/local detail.
    @ObservedObject var liveBridge: BdmLiveBridge
    let reviewAppURL: String
    var onMessage: (String) -> Void = { _ in }

    /// The session currently open in the review canvas; the detail pane shows when this
    /// doesn't match the selection (selecting another row drops back to local detail).
    @State private var reviewSessionId: String?
    @State private var replayError: String?

    var body: some View {
        // HSplitView gives two OPAQUE side-by-side panes. NavigationSplitView's sidebar uses a
        // translucent material, and the embedded WKWebView (full-bleed) showed THROUGH it — the SPA
        // content bled over the native session list. Side-by-side opaque panes fix that.
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            detailPane
                .frame(minWidth: 520)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { model.reload() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
            List(selection: $model.selectedId) {
                ForEach(model.items) { session in
                    sessionRow(session)
                        .tag(session.id)
                        .contextMenu {
                            Button {
                                model.selectedId = session.id
                                triggerReplay(session.id)
                            } label: {
                                Label("Replay this session", systemImage: "play.fill")
                            }
                            .disabled(replayer.isReplaying)
                            Button {
                                model.selectedId = session.id
                                reviewSessionId = session.id
                            } label: {
                                Label("Open review", systemImage: "globe")
                            }
                        }
                }
                if model.items.isEmpty {
                    Text("No sessions yet — start a capture from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .background(.background)
    }

    /// Right pane: the hosted review app once explicitly opened for the selected session,
    /// else the instant local detail (no network until the user asks for the deep view).
    @ViewBuilder
    private var detailPane: some View {
        if let live = liveBridge.liveSessionId {
            liveBdmPane(live)
        } else if let selected = model.selectedId, reviewSessionId == selected {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        reviewSessionId = nil
                    } label: {
                        Label("Details", systemImage: "chevron.left")
                    }
                    .controlSize(.small)
                    Spacer()
                    Text(selected)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(6)
                Divider()
                WebCanvas(reviewAppURL: reviewAppURL, sessionId: selected, onMessage: onMessage)
            }
        } else if let summary = selectedSummary {
            sessionDetail(summary)
        } else {
            Text("Select a session")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
    }

    /// Live BDM workshop pane: the embedded SPA's `#/session/<id>/bdm-live` page, fed segments as
    /// the workshop records so the model draws itself. "Sessions" leaves live mode (the captured
    /// session, and its model, remain — reopen it via "Open review" any time).
    private func liveBdmPane(_ sessionId: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    liveBridge.end()
                } label: {
                    Label("Sessions", systemImage: "chevron.left")
                }
                .controlSize(.small)
                Spacer()
                Label("BDM workshop — live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            Divider()
            WebCanvas(
                reviewAppURL: reviewAppURL,
                sessionId: sessionId,
                onMessage: onMessage,
                live: true,
                liveBridge: liveBridge
            )
        }
    }

    private var selectedSummary: EventSpool.SessionSummary? {
        model.items.first { $0.id == model.selectedId }
    }

    /// Local session detail — everything we know without any network call.
    private func sessionDetail(_ session: EventSpool.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(session.startedDisplay.isEmpty ? session.id : session.startedDisplay)
                    .font(.title3)
                    .fontWeight(.semibold)
                kindBadge(session)
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                detailRow("Session", session.id)
                if let user = session.user, !user.isEmpty { detailRow("User", user) }
                if !session.durationDisplay.isEmpty {
                    detailRow("Duration", session.durationDisplay)
                } else if session.endedAt == nil {
                    detailRow("Duration", "still open")
                }
                detailRow("Events", "\(session.eventCount)")
                detailRow(
                    "Upload",
                    session.pendingCount > 0
                        ? "\(session.sentCount) sent · \(session.pendingCount) pending"
                        : "all \(session.sentCount) batches sent")
            }
            if !session.labels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task labels").font(.headline)
                    ForEach(Array(session.labels.enumerated()), id: \.offset) { _, label in
                        Label(label, systemImage: "tag")
                            .font(.callout)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    reviewSessionId = session.id
                } label: {
                    Label("Open review", systemImage: "globe")
                }
                .buttonStyle(.borderedProminent)
                .help("Open this session in the hosted review app (timeline, clarify, L4)")
                Button {
                    triggerReplay(session.id)
                } label: {
                    Label("Replay", systemImage: "play.fill")
                }
                .disabled(replayer.isReplaying)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    /// Sidebar footer: live replay status (when running) over the replay/reload actions.
    private var footer: some View {
        VStack(spacing: 6) {
            if replayer.isReplaying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(replayer.progress)  \(replayer.status)")
                        .font(.caption2).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button("Stop") { replayer.stop() }.controlSize(.small)
                }
            } else if !replayer.status.isEmpty {
                Text(replayer.status)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if let error = replayError {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                Button { if let id = model.selectedId { triggerReplay(id) } } label: {
                    Label("Replay", systemImage: "play.fill")
                }
                .controlSize(.small)
                .disabled(model.selectedId == nil || replayer.isReplaying)
                .help("Re-run this session's clicks via Accessibility")
                Button { model.reload() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
        .padding(8)
    }

    /// Distil the session's locally journaled events to replay steps and hand them to the
    /// shared replayer. Posts REAL synthetic input, so it stays explicit (user-triggered),
    /// paced, visible (highlight), and interruptible (Stop).
    private func triggerReplay(_ sessionId: String) {
        replayError = nil
        let steps = model.replaySteps(sessionId: sessionId)
        guard !steps.isEmpty else {
            replayError = "No replayable steps in this session."
            return
        }
        replayer.replay(steps)
    }

    @ViewBuilder
    private func sessionRow(_ session: EventSpool.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.startedDisplay.isEmpty ? "(no start time)" : session.startedDisplay)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                kindBadge(session)
                Spacer()
                if session.pendingCount > 0 {
                    // Batches still waiting locally — orange until the sender drains them.
                    Label("\(session.pendingCount)", systemImage: "arrow.up.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("\(session.pendingCount) batch(es) waiting to upload")
                } else if session.sentCount > 0 {
                    Image(systemName: "checkmark.icloud")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("All batches uploaded")
                }
            }
            Text(secondLine(session))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !session.labels.isEmpty {
                Label(session.labels.joined(separator: " · "), systemImage: "tag")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }

    /// "5m 23s · 142 events" (or "recording · …" while the session is still open).
    private func secondLine(_ session: EventSpool.SessionSummary) -> String {
        let duration =
            session.durationDisplay.isEmpty
            ? (session.endedAt == nil ? "open" : "")
            : session.durationDisplay
        let parts = [duration, "\(session.eventCount) events"].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func kindBadge(_ session: EventSpool.SessionSummary) -> some View {
        if let kind = session.kind, !kind.isEmpty {
            // Render the known kinds with a human label; any future kind shows verbatim.
            Text(kindLabel(kind))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    /// Human-readable label for a session kind tag: the two known kinds map to a friendly
    /// name; anything else is shown verbatim (forward-compatible with future kinds).
    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "bdm-workshop": return "BDM workshop"
        case "process-mapping": return "Process mapping"
        default: return kind
        }
    }
}
