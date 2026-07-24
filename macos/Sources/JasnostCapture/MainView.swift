import AppKit
import AVKit
import JasnostCaptureCore
import SwiftUI
import UniformTypeIdentifiers

/// Archive-primary native review model. EventSpool contributes delivery counters only, so an
/// OTLP projection failure can never hide locally committed evidence from the user.
@MainActor
final class SessionListModel: ObservableObject {
    @Published private(set) var items: [JazzArchiveSessionSummary] = []
    @Published var selectedId: String?
    @Published private(set) var isWorking = false
    @Published private(set) var operationStatus: String?
    @Published private(set) var reviewError: String?
    @Published private(set) var playback: JazzArchiveEvidencePlaybackSnapshot?
    @Published private(set) var playbackPlayhead: JazzArchiveEvidencePlayheadState?
    @Published private(set) var playbackError: String?
    @Published private(set) var isLoadingPlayback = false
    @Published private(set) var pendingServerDownload:
        JazzArchiveServerDownloadPendingOperation?

    private let archiveRoot: URL
    private let archiveIndex: JazzArchiveLocalIndex
    private let archiveStore: JazzArchiveDraftStore
    private let reviewStore: JazzArchiveReviewStore
    private let finalizer: JazzArchiveFinalizer
    private let importer: JazzArchiveImporter
    private let serverDownloadRecovery: JazzArchiveServerDownloadRecovery
    private let importIdentityStore: CaptureIdentityStore
    private let revisionForker: JazzArchiveRevisionForker
    private let playbackBuilder: JazzArchiveEvidencePlaybackBuilder
    let archiveUploads: ArchiveUploadManager
    private var reloadDebounce: Timer?
    private var reloadTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var playbackMachine: JazzArchiveEvidencePlayhead?
    private var playbackTimer: Timer?
    private var lastPlaybackTick: TimeInterval?

    init(spool: EventSpool, archiveUploads: ArchiveUploadManager) {
        let root = spool.root.appendingPathComponent("archives", isDirectory: true)
        self.archiveRoot = root
        self.archiveIndex = JazzArchiveLocalIndex(root: root, eventSpool: spool)
        self.archiveStore = JazzArchiveDraftStore(root: root)
        self.reviewStore = JazzArchiveReviewStore(root: root)
        self.finalizer = JazzArchiveFinalizer(root: root)
        self.importer = JazzArchiveImporter(
            root: root,
            durability: JazzArchiveFilesystemPlatform.durability)
        self.serverDownloadRecovery = JazzArchiveServerDownloadRecovery(
            root: root,
            importTargetRoot: root,
            leaseProvider: JazzArchiveServerDownloadPlatform.leaseProvider,
            durability: JazzArchiveFilesystemPlatform.durability)
        self.importIdentityStore = CaptureIdentityStore(root: root)
        self.revisionForker = JazzArchiveRevisionForker(root: root)
        self.playbackBuilder = JazzArchiveEvidencePlaybackBuilder(root: root)
        self.archiveUploads = archiveUploads
        Task { [weak self] in
            await self?.refreshPendingServerDownload()
        }
    }

    func reload() {
        reloadTask?.cancel()
        let current = selectedId
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await archiveIndex.sessions()
            guard !Task.isCancelled else { return }
            items = loaded
            if current == nil || !loaded.contains(where: { $0.id == current }) {
                selectedId = loaded.first?.id
            }
            await refreshPendingServerDownload()
        }
    }

    func noteCaptureActivity() {
        reloadDebounce?.invalidate()
        reloadDebounce = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    func recordReview(
        _ session: JazzArchiveSessionSummary,
        decision: JazzArchiveAssertionDecision,
        correction: String = ""
    ) {
        let text = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        if decision == .correct, text.isEmpty {
            reviewError = "Describe the correction first."
            return
        }
        if decision == .correct, session.isFinalized, !session.hasWorkingDraft {
            reviewError =
                "This imported archive is immutable. Capture or import a corrected revision instead."
            return
        }
        isWorking = true
        reviewError = nil
        operationStatus = "Saving review locally…"
        Task { [weak self] in
            guard let self else { return }
            do {
                if session.isFinalized, decision == .correct {
                    let fork = try await revisionForker.forkCorrection(
                        sourceArchiveId: session.archiveId,
                        correction: text)
                    selectedId = "\(fork.archiveId):\(session.captureId)"
                    operationStatus =
                        "Created revision \(fork.revision) — review and confirm it before upload"
                    isWorking = false
                    reload()
                    return
                }
                let manifest = try await archiveStore.manifest(archiveId: session.archiveId)
                let capture = try await archiveStore.session(
                    archiveId: session.archiveId, captureId: session.captureId)
                let previous = try await reviewStore.latestArchiveAssertion(
                    archiveId: session.archiveId)
                let assertion = JazzArchiveAssertion(
                    target: JazzArchiveAssertionTarget(
                        kind: .archive,
                        id: session.archiveId,
                        path: decision == .correct ? "/review/correction" : nil),
                    decision: decision,
                    value: decision == .correct ? .string(text) : nil,
                    reason: decision == .reject
                        ? (text.isEmpty ? "Rejected during local review" : text)
                        : decision == .correct ? text : nil,
                    authoredByActorId: capture.recorderActorId,
                    baseRevision: manifest.revision,
                    scope: .archive,
                    supersedes: previous?.assertionId,
                    provenance: JazzArchiveProvenance(
                        factClass: decision == .correct ? .corrected : .declared,
                        sources: []))
                _ = try await reviewStore.append(
                    archiveId: session.archiveId, assertion: assertion)
                if decision == .confirm {
                    let delivery = try await archiveUploads.enqueueConfirmed(
                        archiveId: session.archiveId)
                    operationStatus = delivery.state == .reconnectRequired
                        ? "Confirmed and sealed locally — reconnect to upload"
                        : "Confirmed and queued as one immutable Jazz Archive"
                } else {
                    operationStatus = "Review assertion saved — nothing queued"
                }
                isWorking = false
                reload()
            } catch {
                reviewError = String(describing: error)
                operationStatus = nil
                isWorking = false
            }
        }
    }

    func exportArchive(_ session: JazzArchiveSessionSummary, to destination: URL) {
        isWorking = true
        reviewError = nil
        operationStatus = "Verifying and finalizing archive…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let package = try await finalizer.finalize(
                    archiveId: session.archiveId,
                    requireArchiveConfirmation: true)
                _ = try await finalizer.export(package, to: destination)
                operationStatus = "Exported \(destination.lastPathComponent)"
                isWorking = false
                reload()
            } catch {
                reviewError = String(describing: error)
                operationStatus = nil
                isWorking = false
            }
        }
    }

    func importArchive(from source: URL) {
        isWorking = true
        reviewError = nil
        operationStatus = "Copying and verifying Jazz Archive locally…"
        let hasSecurityScope = source.startAccessingSecurityScopedResource()
        Task { [weak self] in
            defer {
                if hasSecurityScope {
                    source.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }
            do {
                let settings = AgentSettings.shared
                let configuredUser = settings.userEmail.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let user = configuredUser.isEmpty ? NSUserName() : configuredUser
                let installed = try await importIdentityStore.loadOrCreate()
                let importingSource = try await importIdentityStore.source(
                    kind: "macos.native")
                let configuredDevice = settings.instanceName.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let device = configuredDevice.isEmpty
                    ? ProcessInfo.processInfo.hostName : configuredDevice
                let context = JazzArchiveImportContext(
                    importedBy: JazzArchiveExternalIdentity(
                        namespace: user.contains("@") ? "user.email" : "macos.username",
                        value: user),
                    importingOriginId: installed.installation.originId,
                    importingSourceId: importingSource.sourceId,
                    importingDevice: JazzArchiveExternalIdentity(
                        namespace: "macos.device-name",
                        value: device))
                let result = try await importer.importArchive(
                    at: source, context: context)
                selectedId = result.snapshot.sessions.first.map {
                    "\(result.snapshot.manifest.archiveId):\($0.captureId)"
                }
                operationStatus = result.disposition == .imported
                    ? "Imported and verified \(source.lastPathComponent) — available offline"
                    : "The exact Jazz Archive was already imported"
                isWorking = false
                reload()
            } catch {
                reviewError = "Jazz Archive import blocked: \(error)"
                operationStatus = nil
                isWorking = false
            }
        }
    }

    func importArchiveFromServer(ingestId rawIngestId: String) {
        let ingestId = rawIngestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking else {
            reviewError = "Another local archive operation is already in progress."
            return
        }
        guard pendingServerDownload == nil else {
            reviewError =
                "A server download is already pending. Resume or deliberately abandon it before starting a different import."
            operationStatus = nil
            return
        }
        let signedEnvelope = try? SignedDeviceCredentialKeychain.vault.envelope()
        guard !ingestId.isEmpty,
            let routeBinding = signedEnvelope?.routeBinding,
            routeBinding.hasSignedAuthority
        else {
            reviewError =
                "Server import needs an ingest ID and a valid enrolled Jazz archive connection."
            operationStatus = nil
            return
        }
        let request = JazzArchiveServerDownloadRequest(
            ingestId: ingestId,
            scope: JazzArchiveServerScope(
                companyId: routeBinding.scope.companyId,
                areaId: routeBinding.scope.areaId,
                deviceId: routeBinding.scope.deviceId),
            downloadOperationId: Identifiers.newDownloadOperationId())
        runServerImport(
            request: request,
            routeBinding: routeBinding)
    }

    func resumePendingServerDownload() {
        guard !isWorking else {
            reviewError = "Another local archive operation is already in progress."
            return
        }
        guard let pendingServerDownload else {
            reviewError = "No pending server download is available to resume."
            return
        }
        guard pendingServerDownload.routeBinding != nil else {
            reviewError =
                "This legacy download journal cannot prove its original server authority. Inspect it, then deliberately abandon it before starting a new download."
            return
        }
        let signedEnvelope = try? SignedDeviceCredentialKeychain.vault.envelope()
        guard let routeBinding = signedEnvelope?.routeBinding,
            routeBinding.hasSignedAuthority
        else {
            reviewError =
                "Resume needs a valid enrolled Jazz archive connection for the pending operation."
            return
        }
        runServerImport(
            request: JazzArchiveServerDownloadRequest(
                ingestId: pendingServerDownload.ingestId,
                scope: pendingServerDownload.scope,
                downloadOperationId: pendingServerDownload.downloadOperationId),
            routeBinding: routeBinding)
    }

    func abandonPendingServerDownload() {
        guard !isWorking else {
            reviewError = "Another local archive operation is already in progress."
            return
        }
        guard let pendingServerDownload else {
            reviewError = "No pending server download is available to abandon."
            return
        }
        isWorking = true
        reviewError = nil
        operationStatus = "Recording the deliberate abandonment locally…"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await serverDownloadRecovery.abandonPendingOperation(
                    downloadOperationId: pendingServerDownload.downloadOperationId,
                    reason: "user_confirmed_from_desktop")
                self.pendingServerDownload = nil
                operationStatus =
                    "Pending download abandoned; imported archive evidence, if any, was retained"
                isWorking = false
            } catch {
                reviewError = "Could not abandon pending server download: \(error)"
                operationStatus = nil
                isWorking = false
                await refreshPendingServerDownload()
            }
        }
    }

    private func runServerImport(
        request: JazzArchiveServerDownloadRequest,
        routeBinding: JazzArchiveUploadRouteBinding
    ) {

        isWorking = true
        reviewError = nil
        operationStatus = "Authorizing and downloading the verified Jazz Archive…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let transport = try JazzArchiveServerDownloadHTTPTransport(
                    routeBinding: routeBinding,
                    credential: {
                        guard
                            let credential = try? await KeychainArchiveCredentialProvider()
                                .credential(for: routeBinding)
                        else { return nil }
                        return credential.withValue { $0 }
                    })
                let installed = try await importIdentityStore.loadOrCreate()
                let importingSource = try await importIdentityStore.source(
                    kind: "macos.native")
                let coordinator = JazzArchiveServerImportCoordinator(
                    root: archiveRoot,
                    importer: importer,
                    transport: transport,
                    leaseProvider: JazzArchiveServerDownloadPlatform.leaseProvider,
                    durability: JazzArchiveFilesystemPlatform.durability)
                let result = try await coordinator.importReadyArchive(
                    request,
                    context: JazzArchiveImportContext(
                        importingOriginId: installed.installation.originId,
                        importingSourceId: importingSource.sourceId,
                        acquisition: .jazzServerDownload))
                selectedId = result.snapshot.sessions.first.map {
                    "\(result.snapshot.manifest.archiveId):\($0.captureId)"
                }
                operationStatus = result.disposition == .imported
                    ? "Downloaded, verified, and imported \(result.snapshot.manifest.archiveId)"
                    : "The exact server Jazz Archive was already imported"
                isWorking = false
                reload()
            } catch {
                reviewError = "Jazz server archive import blocked: \(error)"
                operationStatus = nil
                isWorking = false
                await refreshPendingServerDownload()
            }
        }
    }

    private func refreshPendingServerDownload() async {
        do {
            pendingServerDownload = try await serverDownloadRecovery.pendingOperation()
        } catch {
            reviewError = "Pending server download journal needs attention: \(error)"
        }
    }

    func retryUpload(_ session: JazzArchiveSessionSummary) {
        archiveUploads.retry(archiveId: session.archiveId)
    }

    func reconcileLegacyUpload(archiveId: String) {
        archiveUploads.reconcileLegacy(archiveId: archiveId)
    }

    func cancelUpload(_ session: JazzArchiveSessionSummary) {
        archiveUploads.cancel(archiveId: session.archiveId)
    }

    func loadPlayback(_ session: JazzArchiveSessionSummary) {
        playbackTask?.cancel()
        stopPlaybackTimer()
        playbackMachine = nil
        playbackPlayhead = nil
        isLoadingPlayback = true
        playback = nil
        playbackError = nil
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await playbackBuilder.build(
                    archiveId: session.archiveId,
                    captureId: session.captureId)
                guard !Task.isCancelled else { return }
                let machine = try JazzArchiveEvidencePlayhead(snapshot: loaded)
                playback = loaded
                playbackMachine = machine
                playbackPlayhead = machine.state
                isLoadingPlayback = false
            } catch {
                guard !Task.isCancelled else { return }
                playbackError = "Local evidence verification failed: \(error)"
                isLoadingPlayback = false
            }
        }
    }

    func closePlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        stopPlaybackTimer()
        playbackMachine = nil
        playbackPlayhead = nil
        playback = nil
        playbackError = nil
        isLoadingPlayback = false
    }

    func togglePlayback() {
        guard var machine = playbackMachine else { return }
        machine.togglePlayback()
        playbackMachine = machine
        playbackPlayhead = machine.state
        if machine.state.isPlaying {
            startPlaybackTimer()
        } else {
            stopPlaybackTimer()
        }
    }

    func seekPlayback(toMillis: Int64) {
        guard var machine = playbackMachine else { return }
        machine.seek(toMillis: toMillis)
        playbackMachine = machine
        playbackPlayhead = machine.state
        if machine.state.isPlaying {
            lastPlaybackTick = ProcessInfo.processInfo.systemUptime
            startPlaybackTimerIfNeeded()
        } else {
            stopPlaybackTimer()
        }
    }

    func selectPlaybackEntry(_ entryId: String) {
        guard var machine = playbackMachine else { return }
        do {
            try machine.select(entryId: entryId)
            playbackMachine = machine
            playbackPlayhead = machine.state
            if machine.state.isPlaying {
                lastPlaybackTick = ProcessInfo.processInfo.systemUptime
                startPlaybackTimerIfNeeded()
            }
        } catch {
            playbackError = "Evidence timeline selection failed: \(error)"
            stopPlaybackTimer()
        }
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        lastPlaybackTick = ProcessInfo.processInfo.systemUptime
        playbackTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 30.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickPlayback() }
        }
    }

    private func startPlaybackTimerIfNeeded() {
        guard playbackTimer == nil else { return }
        startPlaybackTimer()
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        lastPlaybackTick = nil
    }

    private func tickPlayback() {
        guard var machine = playbackMachine, machine.state.isPlaying else {
            stopPlaybackTimer()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = lastPlaybackTick ?? now
        lastPlaybackTick = now
        let elapsed = max(0, Int64(((now - previous) * 1_000).rounded()))
        guard elapsed > 0 else { return }
        do {
            try machine.advance(byMillis: elapsed)
            playbackMachine = machine
            playbackPlayhead = machine.state
            if !machine.state.isPlaying {
                stopPlaybackTimer()
            }
        } catch {
            playbackError = "Evidence timeline clock failed: \(error)"
            stopPlaybackTimer()
        }
    }
}

/// AVKit receives only a digest-verified archive-owned file URL. Its transport is a projection of
/// the capture-wide playhead: AVKit never exposes or owns an independent play/pause/seek control.
private struct LocalEvidenceMediaPlayer: NSViewRepresentable {
    let url: URL
    let timelinePositionMillis: Int64
    let artifactOffsetMillis: Int64
    let isPlaying: Bool

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = AVPlayer(url: url)
        synchronize(view.player)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context _: Context) {
        let currentURL = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
        synchronize(view.player)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator _: ()) {
        view.player?.pause()
        view.player = nil
    }

    private func synchronize(_ player: AVPlayer?) {
        guard let player else { return }
        let expected = max(
            0,
            Double(timelinePositionMillis - artifactOffsetMillis) / 1_000)
        let current = player.currentTime().seconds
        if !current.isFinite || abs(current - expected) > (isPlaying ? 0.35 : 0.02) {
            player.seek(
                to: CMTime(seconds: expected, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero)
        }
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
    }
}

/// The main window: a native sessions sidebar on the left (local journal, instant), and a
/// detail pane on the right. Evidence playback stays entirely local; server analysis is a
/// separately named, explicit action so an offline review can never open a network surface.
struct MainView: View {
    @ObservedObject var model: SessionListModel
    @ObservedObject var archiveUploads: ArchiveUploadManager
    /// Drives the LIVE BDM canvas: when ``liveBridge.liveSessionId`` is set (a workshop is running),
    /// the detail pane shows the model assembling itself instead of the normal review/local detail.
    @ObservedObject var liveBridge: BdmLiveBridge
    let reviewAppURL: String
    var onMessage: (String) -> Void = { _ in }

    @State private var analysisSessionId: String?
    @State private var playbackSessionId: String?
    @State private var correction = ""
    @State private var serverIngestId = ""
    @State private var confirmPendingDownloadAbandonment = false
    @State private var legacyUploadReconciliationArchiveId: String?

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
        .onChange(of: model.selectedId) { _, selectedId in
            guard playbackSessionId != nil, playbackSessionId != selectedId else { return }
            playbackSessionId = nil
            model.closePlayback()
        }
        .confirmationDialog(
            "Abandon this pending server download?",
            isPresented: $confirmPendingDownloadAbandonment,
            titleVisibility: .visible
        ) {
            Button("Keep and resume later", role: .cancel) {}
            Button("Abandon pending operation", role: .destructive) {
                model.abandonPendingServerDownload()
            }
        } message: {
            Text(
                "Jazz will retain a non-secret abandonment record and will not delete any imported archive evidence.")
        }
        .confirmationDialog(
            "Reconcile this legacy upload?",
            isPresented: Binding(
                get: { legacyUploadReconciliationArchiveId != nil },
                set: { if !$0 { legacyUploadReconciliationArchiveId = nil } }),
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) {
                legacyUploadReconciliationArchiveId = nil
            }
            Button("Reconcile with Jazz server") {
                guard let archiveId = legacyUploadReconciliationArchiveId else { return }
                legacyUploadReconciliationArchiveId = nil
                model.reconcileLegacyUpload(archiveId: archiveId)
            }
        } message: {
            Text(
                "Jazz will make one authenticated legacy intent lookup without a local operation ID, validate the exact archive identity, and adopt only the stable operation ID returned by the upgraded server.")
        }
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
                                openPlayback(session)
                            } label: {
                                Label("Open evidence playback", systemImage: "play.rectangle")
                            }
                            .disabled(!session.isCommitted)
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

    /// Right pane: verified local playback and hosted analysis are intentionally distinct modes.
    @ViewBuilder
    private var detailPane: some View {
        if let live = liveBridge.liveSessionId {
            liveBdmPane(live)
        } else if let summary = selectedSummary, playbackSessionId == summary.id {
            evidencePlaybackPane(summary)
        } else if let summary = selectedSummary, analysisSessionId == summary.id {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        analysisSessionId = nil
                    } label: {
                        Label("Details", systemImage: "chevron.left")
                    }
                    .controlSize(.small)
                    Spacer()
                    Text(summary.legacySessionId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(6)
                Divider()
                WebCanvas(
                    reviewAppURL: reviewAppURL,
                    sessionId: summary.legacySessionId,
                    onMessage: onMessage)
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

    private var selectedSummary: JazzArchiveSessionSummary? {
        model.items.first { $0.id == model.selectedId }
    }

    /// Local session detail — everything we know without any network call.
    private func sessionDetail(_ session: JazzArchiveSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(
                    session.startedDisplay.isEmpty
                        ? session.legacySessionId : session.startedDisplay)
                    .font(.title3)
                    .fontWeight(.semibold)
                kindBadge(session)
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                detailRow("Session", session.legacySessionId)
                detailRow("Archive", session.archiveId)
                detailRow("Capture", session.captureId)
                detailRow("Revision", "\(session.revision)")
                if let prior = session.supersedesArchiveId {
                    detailRow("Supersedes", prior)
                }
                if let user = session.user, !user.isEmpty { detailRow("User", user) }
                if !session.durationDisplay.isEmpty {
                    detailRow("Duration", session.durationDisplay)
                } else if session.endedAt == nil {
                    detailRow("Duration", "still open")
                }
                detailRow("Events", "\(session.eventCount)")
                detailRow("Artifacts", "\(session.artifactCount)")
                detailRow("Local state", session.isCommitted ? "committed" : "recovering")
                if session.isFinalized, !session.hasWorkingDraft {
                    detailRow("Archive source", "verified portable import · read only")
                }
                detailRow("Review", reviewLabel(session.reviewDecision))
                detailRow("Archive delivery", deliveryLabel(session))
                if AgentSettings.shared.deliveryPolicy.usesLiveCompatibilityProjection {
                    detailRow(
                        "Live compatibility",
                        session.pendingCount > 0
                            ? "\(session.sentCount) sent · \(session.pendingCount) pending"
                            : "all \(session.sentCount) batches sent")
                }
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
                    openPlayback(session)
                } label: {
                    Label("Open evidence playback", systemImage: "play.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.isCommitted)
                .help("Review the observed timeline; this does not execute captured input")
                Button {
                    playbackSessionId = nil
                    analysisSessionId = session.id
                } label: {
                    Label("Open server analysis", systemImage: "network")
                }
                .help("Open the hosted analysis workspace; this may require a network connection")
            }
            GroupBox("Local archive review") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(CaptureCoachReviewPresentation.title)
                            .font(.caption.weight(.semibold))
                        if let coachReview = session.coachReviewSummary {
                            ForEach(
                                CaptureCoachReviewPresentation.checklistLines(coachReview),
                                id: \.self
                            ) { line in
                                Text(line)
                                    .font(.caption)
                            }
                            if let warning =
                                CaptureCoachReviewPresentation.softWarning(coachReview)
                            {
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Text(CaptureCoachReviewPresentation.semanticCaveat)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(
                                "The local explanation checklist could not be read. Confirmation remains available.",
                                systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Divider()
                    TextField("Correction or rejection reason", text: $correction)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button("Confirm") {
                            model.recordReview(session, decision: .confirm)
                        }
                        .disabled(!session.isCommitted || session.isFinalized || model.isWorking)
                        Button("Reject") {
                            model.recordReview(
                                session, decision: .reject, correction: correction)
                        }
                        .disabled(!session.isCommitted || session.isFinalized || model.isWorking)
                        Button(session.isFinalized ? "Create corrected revision" : "Save correction") {
                            model.recordReview(
                                session, decision: .correct, correction: correction)
                        }
                        .disabled(
                            !session.isCommitted || model.isWorking
                                || (session.isFinalized && !session.hasWorkingDraft))
                        .help(
                            session.isFinalized && !session.hasWorkingDraft
                                ? "Imported archives are immutable; import or capture a new revision"
                                : "Save a correction as an explicit revision")
                        Spacer()
                        Button {
                            export(session)
                        } label: {
                            Label("Export Jazz Archive", systemImage: "archivebox")
                        }
                        .disabled(
                            !session.isCommitted || session.reviewDecision != .confirm
                                || model.isWorking)
                    }
                    if let status = model.operationStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.reviewError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if let upload = archiveUploads.item(archiveId: session.archiveId) {
                        Divider()
                        HStack(spacing: 8) {
                            Label(
                                deliveryLabel(session),
                                systemImage: deliveryIcon(upload.state))
                                .font(.caption)
                                .foregroundStyle(deliveryColor(upload.state))
                            Spacer()
                            if [.reconnectRequired, .cancelled].contains(upload.state)
                                || (upload.state == .retryable && upload.canRunAutomatically())
                            {
                                Button(upload.state == .reconnectRequired ? "Reconnect & retry" : "Retry") {
                                    if upload.state == .reconnectRequired {
                                        onMessage("openSettings")
                                    }
                                    model.retryUpload(session)
                                }
                                .disabled(model.isWorking)
                            }
                            if upload.state == .conflict,
                                upload.issue?.code
                                    == "ARCHIVE_UPLOAD_OPERATION_RECONCILIATION_REQUIRED"
                            {
                                Button("Reconcile legacy upload…") {
                                    legacyUploadReconciliationArchiveId = session.archiveId
                                }
                                .disabled(model.isWorking)
                            }
                            if !upload.state.isTerminal {
                                Button("Cancel upload", role: .destructive) {
                                    model.cancelUpload(session)
                                }
                                .disabled(model.isWorking)
                            }
                        }
                        if let issue = upload.issue {
                            Text("\(issue.code): \(issue.message)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private func openPlayback(_ session: JazzArchiveSessionSummary) {
        analysisSessionId = nil
        playbackSessionId = session.id
        model.loadPlayback(session)
    }

    @ViewBuilder
    private func evidencePlaybackPane(_ session: JazzArchiveSessionSummary) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    playbackSessionId = nil
                    model.closePlayback()
                } label: {
                    Label("Details", systemImage: "chevron.left")
                }
                .controlSize(.small)
                Spacer()
                Label("Verified local evidence", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Offline · read only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            Divider()

            if model.isLoadingPlayback {
                ProgressView("Verifying local archive and artifact digests…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.playbackError {
                ContentUnavailableView(
                    "Evidence playback blocked",
                    systemImage: "exclamationmark.shield",
                    description: Text(error))
            } else if let playback = model.playback,
                playback.archiveId == session.archiveId,
                playback.captureId == session.captureId,
                let playhead = model.playbackPlayhead
            {
                VStack(spacing: 0) {
                    playbackTransport(playhead, playback: playback)
                    Divider()
                    HSplitView {
                        List(
                            playback.entries,
                            selection: Binding<String?>(
                                get: { model.playbackPlayhead?.selectedEntryId },
                                set: { entryId in
                                    if let entryId {
                                        model.selectPlaybackEntry(entryId)
                                    }
                                })
                        ) { entry in
                            Button {
                                model.selectPlaybackEntry(entry.id)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: playbackIcon(entry.item.kind))
                                        .frame(width: 18)
                                        .foregroundStyle(
                                            entry.item.kind == .gap ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title)
                                            .lineLimit(2)
                                        HStack(spacing: 5) {
                                            Text(formatOffset(entry.item.offsetMillis))
                                            if let end = entry.endOffsetMillis,
                                                end > entry.item.offsetMillis
                                            {
                                                Text("– \(formatOffset(end))")
                                            }
                                        }
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if playhead.activeEntryIds.contains(entry.id) {
                                        Image(systemName: "circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.tint)
                                            .help("Active on the presentation timeline")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tag(entry.id)
                        }
                        .frame(minWidth: 240, idealWidth: 300)

                        playbackDetail(
                            playback.entries.first {
                                $0.id == playhead.selectedEntryId
                            },
                            activeMedia: activeMediaEntries(
                                playback: playback,
                                playhead: playhead),
                            playhead: playhead)
                            .frame(
                                minWidth: 320,
                                maxWidth: .infinity,
                                maxHeight: .infinity)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No local evidence",
                    systemImage: "rectangle.stack.badge.questionmark",
                    description: Text("The committed archive contains no playable observations."))
            }
        }
        .background(.background)
    }

    private func playbackTransport(
        _ playhead: JazzArchiveEvidencePlayheadState,
        playback: JazzArchiveEvidencePlaybackSnapshot
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: playhead.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(
                playhead.isPlaying
                    ? "Pause the presentation timeline"
                    : "Play the presentation timeline")

            Text(formatOffset(playhead.positionMillis))
                .font(.caption.monospacedDigit())
                .frame(width: 76, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { Double(model.playbackPlayhead?.positionMillis ?? 0) },
                    set: { model.seekPlayback(toMillis: Int64($0.rounded())) }),
                in: 0...Double(max(1, playhead.durationMillis)))
            Text(formatOffset(playhead.durationMillis))
                .font(.caption.monospacedDigit())
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Text(
                    JazzArchiveEvidencePlaybackTimingPresentation.timelineSummary(
                        playback))
                Text("Cross-domain order is not proof of causality")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(JazzArchiveEvidencePlaybackTimingPresentation.causalityNotice)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func activeMediaEntries(
        playback: JazzArchiveEvidencePlaybackSnapshot,
        playhead: JazzArchiveEvidencePlayheadState
    ) -> [JazzArchiveEvidencePlaybackEntry] {
        var artifactIds = Set<String>()
        return playback.entries.filter { entry in
            guard playhead.activeEntryIds.contains(entry.id),
                let artifact = entry.artifact,
                artifact.mediaType.hasPrefix("audio/")
                    || artifact.mediaType.hasPrefix("video/"),
                artifactIds.insert(artifact.artifactId).inserted
            else { return false }
            return true
        }
    }

    @ViewBuilder
    private func playbackDetail(
        _ entry: JazzArchiveEvidencePlaybackEntry?,
        activeMedia: [JazzArchiveEvidencePlaybackEntry],
        playhead: JazzArchiveEvidencePlayheadState
    ) -> some View {
        if entry != nil || !activeMedia.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let entry {
                        HStack(alignment: .firstTextBaseline) {
                            Label(entry.title, systemImage: playbackIcon(entry.item.kind))
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Text(formatOffset(entry.item.offsetMillis))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let artifact = entry.artifact,
                            !activeMedia.contains(where: { $0.id == entry.id })
                        {
                            localArtifactPreview(
                                artifact,
                                artifactOffsetMillis: entry.item.offsetMillis,
                                playhead: playhead)
                        }
                        if let detail = entry.detail, !detail.isEmpty {
                            Text(detail)
                                .textSelection(.enabled)
                        }
                        if entry.item.kind == .gap {
                            Label(
                                "Jazz will not infer what happened inside this interval.",
                                systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        if let evidenceRef = entry.item.evidenceRef {
                            Text(evidenceRef)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        let timingLines =
                            JazzArchiveEvidencePlaybackTimingPresentation.detailLines(
                                entry)
                        if !timingLines.isEmpty {
                            GroupBox("Timing and source evidence") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(timingLines, id: \.self) { line in
                                        Text(line)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                    Text(
                                        JazzArchiveEvidencePlaybackTimingPresentation
                                            .causalityNotice
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                }
                                .padding(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if !activeMedia.isEmpty {
                        ForEach(activeMedia) { media in
                            if let artifact = media.artifact {
                                GroupBox(
                                    media.id == entry?.id
                                        ? "Aligned media (presentation)"
                                        : "Active on presentation timeline · \(media.title)"
                                ) {
                                    localArtifactPreview(
                                        artifact,
                                        artifactOffsetMillis: media.item.offsetMillis,
                                        playhead: playhead)
                                        .padding(4)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            Text("Select a timeline item")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func localArtifactPreview(
        _ artifact: JazzArchiveEvidencePlaybackArtifact,
        artifactOffsetMillis: Int64,
        playhead: JazzArchiveEvidencePlayheadState
    ) -> some View {
        if artifact.mediaType.hasPrefix("image/"), let image = NSImage(contentsOf: artifact.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 440)
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if artifact.mediaType.hasPrefix("audio/")
            || artifact.mediaType.hasPrefix("video/")
        {
            LocalEvidenceMediaPlayer(
                url: artifact.url,
                timelinePositionMillis: playhead.positionMillis,
                artifactOffsetMillis: artifactOffsetMillis,
                isPlaying: playhead.isPlaying)
                .frame(minHeight: artifact.mediaType.hasPrefix("audio/") ? 90 : 300)
        } else {
            Label(
                "Verified local artifact · \(artifact.mediaType)",
                systemImage: "doc.badge.checkmark")
                .foregroundStyle(.secondary)
        }
    }

    private func playbackIcon(_ kind: EvidencePlaybackKind) -> String {
        switch kind {
        case .event: return "cursorarrow.click"
        case .screenshot: return "photo"
        case .narration: return "waveform"
        case .transcript: return "text.quote"
        case .label: return "tag"
        case .coachInteraction: return "bubble.left.and.exclamationmark.bubble.right"
        case .gap: return "exclamationmark.triangle"
        }
    }

    private func formatOffset(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let millis = milliseconds % 1_000
        if hours > 0 {
            return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, millis)
        }
        return String(format: "%02lld:%02lld.%03lld", minutes, seconds, millis)
    }

    private func export(_ session: JazzArchiveSessionSummary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.archiveId).jazz-archive"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.exportArchive(session, to: destination)
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "jazz-archive") ?? .data
        ]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        model.importArchive(from: source)
    }

    private func reviewLabel(_ decision: JazzArchiveAssertionDecision?) -> String {
        switch decision {
        case .confirm: return "confirmed"
        case .reject: return "rejected"
        case .correct: return "corrected — confirm to export"
        case .exclude: return "excluded"
        case .split: return "split"
        case .merge: return "merged"
        case .redact: return "redacted"
        case .delete: return "deleted"
        case nil: return "not reviewed"
        }
    }

    private func deliveryLabel(_ session: JazzArchiveSessionSummary) -> String {
        if session.isFinalized, !session.hasWorkingDraft {
            return "portable import · local only"
        }
        guard let item = archiveUploads.item(archiveId: session.archiveId) else {
            return session.reviewDecision == .confirm
                ? "confirmed locally — preparing package" : "not queued — confirmation required"
        }
        switch item.state {
        case .queued, .creatingIntent: return "queued"
        case .uploading: return "uploading exact archive bytes"
        case .finalizing: return "upload complete — finalizing"
        case .verifying: return "verifying"
        case .processing: return "processing on server"
        case .ready: return "ready"
        case .retryable:
            return item.nextAttemptAt.map {
                "safe locally — server retry after \($0)"
            } ?? "safe locally — retry available"
        case .reconnectRequired: return "reconnect required"
        case .failedTerminal: return "terminal server failure — local copy retained"
        case .rejected: return "rejected — local copy retained"
        case .quarantined: return "quarantined — local copy retained"
        case .conflict: return "identity conflict — upload stopped"
        case .cancelled: return "cancelled — local copy retained"
        }
    }

    private func deliveryIcon(_ state: JazzArchiveUploadState) -> String {
        switch state {
        case .ready: "checkmark.icloud.fill"
        case .uploading, .finalizing, .verifying, .processing, .creatingIntent: "arrow.up.circle"
        case .reconnectRequired: "person.crop.circle.badge.exclamationmark"
        case .retryable: "arrow.clockwise.circle"
        case .failedTerminal, .rejected, .quarantined, .conflict: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .queued: "clock"
        }
    }

    private func deliveryColor(_ state: JazzArchiveUploadState) -> Color {
        switch state {
        case .ready: .green
        case .failedTerminal, .rejected, .quarantined, .conflict: .red
        case .reconnectRequired, .retryable: .orange
        default: .secondary
        }
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

    /// Import only publishes a fully verified immutable snapshot. Executing observed input still
    /// requires an approved RunbookVersion and is not exposed from the raw capture timeline.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    importArchive()
                } label: {
                    Label("Import Jazz Archive…", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isWorking)
                .controlSize(.small)
                Spacer()
                Button { model.reload() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                TextField("Server ingest ID (ing-…)", text: $serverIngestId)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Jazz server ingest ID")
                    .disabled(model.isWorking || model.pendingServerDownload != nil)
                    .onSubmit { importArchiveFromServer() }
                Button {
                    importArchiveFromServer()
                } label: {
                    Label("Import from Server", systemImage: "icloud.and.arrow.down")
                }
                .disabled(
                    model.isWorking
                        || model.pendingServerDownload != nil
                        || serverIngestId.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                .help(
                    model.pendingServerDownload == nil
                        ? "Import a ready Jazz Archive from its server ingest ID"
                        : "Resume or deliberately abandon the pending server download first")
                .controlSize(.small)
            }
            if let pending = model.pendingServerDownload {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pending server download")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("\(pending.ingestId) · \(pending.downloadOperationId)")
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Button("Resume pending") {
                            model.resumePendingServerDownload()
                        }
                        .disabled(
                            model.isWorking
                                || pending.routeBinding == nil)
                        .help(
                            pending.routeBinding == nil
                                ? "Legacy journal: the original signed server authority was not recorded, so only deliberate abandonment is safe"
                                : "Resume the exact durable download operation")
                        Button("Abandon…", role: .destructive) {
                            confirmPendingDownloadAbandonment = true
                        }
                        .disabled(model.isWorking)
                    }
                    .controlSize(.small)
                }
                .padding(6)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let status = model.operationStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let error = model.reviewError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func sessionRow(_ session: JazzArchiveSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.startedDisplay.isEmpty ? "(no start time)" : session.startedDisplay)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                kindBadge(session)
                Spacer()
                if let upload = archiveUploads.item(archiveId: session.archiveId) {
                    Image(systemName: deliveryIcon(upload.state))
                        .font(.caption2)
                        .foregroundStyle(deliveryColor(upload.state))
                        .help(deliveryLabel(session))
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
    private func secondLine(_ session: JazzArchiveSessionSummary) -> String {
        let duration =
            session.durationDisplay.isEmpty
            ? (session.endedAt == nil ? "open" : "")
            : session.durationDisplay
        let parts = [duration, "\(session.eventCount) events"].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func kindBadge(_ session: JazzArchiveSessionSummary) -> some View {
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

    private func importArchiveFromServer() {
        let ingestId = serverIngestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isWorking, !ingestId.isEmpty else { return }
        model.importArchiveFromServer(ingestId: ingestId)
    }
}
