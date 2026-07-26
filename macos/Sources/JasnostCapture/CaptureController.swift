import AppKit
import Combine
import JasnostCaptureCore

private actor CaptureCoachArtifactGate {
    private var result: String??
    private var continuation: CheckedContinuation<String?, Never>?

    func wait() async -> String? {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ artifactId: String?) {
        guard result == nil else { return }
        result = .some(artifactId)
        continuation?.resume(returning: artifactId)
        continuation = nil
    }
}

/// Orchestrates a desktop capture session: installs the event tap + app-switch observer,
/// turns each raw interaction into a semantic ActivityEvent (AX target, redaction, sparse
/// screenshot), and writes canonical observations/artifacts to ``CaptureJournal`` before the
/// optional compatibility ``EventSpool`` and Files projections see them. Confirmed-archive mode
/// performs no capture delivery network operation at all. All UI state lives on the main actor; AX enrichment runs on a
/// utility queue so the tap callback stays fast.
@MainActor
final class CaptureController: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isStarting = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var archiveStatus = "Archive ready"
    @Published private(set) var deliveryPolicy = JazzCaptureDeliveryPolicy.confirmedArchive
    @Published private(set) var recoverableArchiveCount = 0
    @Published private(set) var status = "Idle"
    @Published private(set) var eventCount = 0
    /// When the current capture session started (nil while idle) — drives the recording indicator.
    @Published private(set) var captureStartedAt: Date?
    @Published var lastError: String?
    /// Times the OS disabled our event tap and we re-enabled it. A rising counter means the
    /// tap callback is too slow — surfaced so a silent capture stall is diagnosable.
    @Published private(set) var tapReArms = 0
    /// Live state of the background sender (pending batches, last send, last error).
    @Published private(set) var senderStatus = StreamSender.Status()
    /// Live state of the durable narration uploader (audio clips waiting on disk, last error).
    @Published private(set) var narrationStatus = NarrationUploader.Status()
    @Published private(set) var artifactStatus = ArchiveArtifactUploader.Status()
    @Published private(set) var coachPrompt: CaptureCoachPrompt?
    @Published private(set) var coachMutedUntil: String?
    @Published private(set) var coachStatus = "Capture Coach idle"
    /// The human name of the active label (bracketed segment), or nil when no label is open —
    /// shown in the menu/panel. A label is the explicit "now I'm showing you X … done" window;
    /// the mic records ONLY while one is open. Set by ``startLabel(name:)``, cleared by
    /// ``endLabel()`` and at session boundaries.
    @Published private(set) var currentLabel: String?
    /// Stable id of the active label, minted at ``startLabel(name:)`` and stamped (with
    /// ``currentLabel``) onto every event captured while the label is open; nil when none.
    private var currentLabelId: String?
    /// Guided capture (ADR 0002): the Area's declared process inventory, fetched once per capture
    /// session from the Area registry (``RegistryFetcher``) right after ``start()``. Empty = Explore
    /// mode (no registry / no Area / fetch failed) — the label panel then behaves exactly as before.
    /// The fetch is async and best-effort; this published copy is the per-session cache the panel reads.
    @Published private(set) var processInventory: [ProcessChoice] = []
    /// The resolved Process of the ACTIVE label segment (Guided capture): set by
    /// ``startLabel(name:)`` when the label text resolves against ``processInventory``
    /// (``CaptureScope/resolveLabelPick(text:inventory:)``), cleared by ``endLabel()``. Stamped
    /// (with ``currentLabelId``/``currentLabel``) onto every event inside the segment as
    /// `process.id`/`process.name`; nil for free-text (Explore) labels.
    private var currentProcessId: String?
    private var currentProcessName: String?
    private var closedLabelIds = Set<String>()
    private var narrationReservation: CaptureCoachNarrationReservation?
    private var narrationFileClaim: JazzArchiveWritableFileClaim?

    private struct PendingSpokenCoachAnswer: Sendable {
        var promptId: String
        var reservation: CaptureCoachNarrationReservation
    }

    private var pendingSpokenCoachAnswer: PendingSpokenCoachAnswer?

    var canAnswerCoachSpoken: Bool {
        guard let prompt = coachPrompt,
            prompt.snapshot.responseModes.contains(.spoken),
            let labelId = currentLabelId,
            narration.isRecording,
            narrationReservation?.labelId == labelId
        else { return false }
        return true
    }

    private struct LabelScopeSnapshot: Sendable {
        var labelId: String?
        var label: String?
        var processId: String?
        var process: String?
    }

    /// How long ``shutdown(deadline:)`` waits for the sender/uploader to settle at quit.
    /// The spool persists everything, so hitting the deadline only delays delivery, never
    /// loses data.
    nonisolated private static let shutdownDeadline: TimeInterval = 5
    /// Budget for the screenshot Files-prepare call on the click path — a slow network must
    /// never hold an event back longer than this.
    private static let prepareBudget: TimeInterval = 3
    /// Max dHash Hamming distance (of 64 bits) for two consecutive shots to count as the SAME
    /// view — at or below this the new shot is skipped (no upload), cutting the per-click
    /// screenshot flood. ~4/64 tolerates JPEG/AA noise while still catching real screen changes.
    private static let shotDedupThreshold = 4
    /// AX enrichment queue: the hit-test + hierarchy walk happens here, OFF the tap
    /// callback, so the OS never sees the tap as unresponsive.
    nonisolated private static let axQueue = DispatchQueue(
        label: "dev.jasnost.ax-enrich", qos: .utility)

    private let tap = EventTap()
    private let narration = NarrationRecorder()
    /// The durable spool — also the sessions sidebar's data source (read-only there).
    let spool: EventSpool
    private let sender: StreamSender
    private let shots: ScreenshotUploader
    /// The durable narration audio uploader — stages clips on disk and ships them off the
    /// capture path, surviving an offline period or a restart (see ``NarrationUploader``).
    private let narrationUploader: NarrationUploader
    private let artifactQueue: JazzArchiveDeliveryQueue
    private let artifactUploader: ArchiveArtifactUploader
    private let projectionReconciler: JazzArchiveProjectionReconciler
    private let archiveRoot: URL
    private let identityStore: CaptureIdentityStore
    let archiveUploadManager: ArchiveUploadManager
    private var captureJournal: CaptureJournal?
    private var journalRuntime: CaptureJournalRuntime?
    private var coachCoordinator: CaptureCoachCoordinator?
    private var coachLiveRuntime: CaptureCoachLiveRuntime?
    private var coachLiveObservationRouter: CaptureCoachLiveObservationRouter?
    private var coachLiveAudioAdmissionTail: CaptureCoachLivePCMAdmissionTail?
    private var coachLiveLabelContextTail: CaptureCoachLiveLabelContextAdmissionTail?
    private var coachLiveTransport: CaptureCoachLiveTransportPartition?
    private var coachLiveBackgroundDrainer: CaptureCoachLiveBackgroundDrainer?
    private var coachUnavailable = true
    private var archiveId = ""
    private var captureId = ""
    private var streamId = ""
    private var sourceId = ""
    private var actorId = ""
    /// Frozen when a capture starts so changing Settings cannot split one capture across policies.
    private var activeDeliveryPolicy = JazzCaptureDeliveryPolicy.confirmedArchive
    /// Serializes calls to `runtime.submit`, so stream positions follow controller admission order
    /// even though enrichment and artifact capture run concurrently after reservation.
    private var journalAdmissionTail: Task<Void, Never>?
    private var coachActionTail: Task<Void, Never>?
    private var coachBaselineTask: Task<Void, Never>?
    private var coachBaselineCursor = CaptureCoachBaselineCursor()
    private var keboola: KeboolaClient
    private var policy = RedactionPolicy()
    private var sessionId = ""
    private var sequence = 0
    private var buffer: [ActivityEvent] = []
    private var flushTimer: Timer?
    private var appObserver: NSObjectProtocol?
    private var coachLiveConsentObserver: NSObjectProtocol?
    private var lastScroll = Date.distantPast
    private var captureScreenshots = true
    /// dHash of the last screenshot we kept this session — used to skip near-identical frames
    /// (repeated clicks in the same view). Reset per session in ``start()``.
    private var lastShotHash: UInt64?
    private var workshopMode = false
    private let highlight = HighlightOverlay()
    private var highlightClicks = true
    /// Our own process id — used to ignore interactions with jasnost's own UI (menu bar, window),
    /// which the Workspace "frontmost app" can't tell us about (menu-bar extras don't change it).
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// The async tail of stop(): spool endSession + final flush + sender nudge. Awaited at quit.
    private var shutdownTask: Task<Void, Never>?
    private var startTask: Task<Bool, Never>?

    /// Screenshot Files ids captured under each open label, keyed by labelId. A LIVE BDM workshop
    /// hands these (with the label's narration audio id) to the model the moment a segment closes,
    /// so the turn can read what was shown. Built up as screenshots upload; snapshotted + dropped
    /// when the segment's audio upload completes. Reset per session in ``start()``.
    private var labelScreenshots: [String: [String]] = [:]
    /// Fired (main actor) once a label segment's narration audio has uploaded (via the durable
    /// ``NarrationUploader``): ``(sessionId, labelId, label, audioFileId, screenshotIds)``. The LIVE
    /// workshop pushes this to the embedded Data App so it runs one BDM turn and the model grows on
    /// screen. Set by AppDelegate; the bridge ignores any segment whose session isn't the live one
    /// (so a backlog clip draining on a later launch can't bleed into an unrelated workshop).
    var onSegmentReady: ((String, String, String, String, [String]) -> Void)?
    /// Presentation hook for a non-activating desktop surface. Future live/offline inference
    /// adapters inject prompts through ``deliverCoachPrompt(_:)``; they never control capture.
    var onCoachPresentation: ((CaptureCoachPrompt?, String?) -> Void)?

    // Keystroke capture ("semantic text + shortcuts"): printable keys accumulate into one redacted
    // `input` event per field; the field + app are pinned when typing starts and flushed at a focus
    // boundary (click, app switch, special key, shortcut, stop).
    private var typing = TypingAccumulator()
    private var typingTarget: EventTarget?
    private var typingFront: FrontApp?
    private var typingKey: String?  // focused-element identity, to detect mid-typing focus moves

    /// The current capture session id (valid while capturing). The BDM voice workshop threads
    /// its processor turns under this same id, so the assembled model ties to this session.
    var currentSessionId: String { sessionId }

    /// Whether the running session is a BDM workshop (drives the status-line wording).
    var isWorkshopSession: Bool { workshopMode }

    init(spool: EventSpool = EventSpool()) {
        self.spool = spool
        let archiveRoot = spool.root.appendingPathComponent("archives", isDirectory: true)
        self.archiveRoot = archiveRoot
        self.identityStore = CaptureIdentityStore(
            root: archiveRoot,
            durability: JazzArchiveFilesystemPlatform.durability,
            leaseProvider: CaptureIdentityStorePlatform.leaseProvider)
        self.archiveUploadManager = ArchiveUploadManager(spoolRoot: spool.root)
        // Read the complete signed authority lazily per drain pass. In signed mode an explicit nil
        // endpoint is authoritative and must not inherit the legacy Keychain projection; corrupt
        // signed bytes likewise fail closed. The standalone item is consulted only when no signed
        // envelope exists.
        self.sender = StreamSender(
            spool: spool,
            endpoint: {
                try? SignedDeviceCredentialKeychain.vault.streamEndpoint(
                    legacyEndpoint: Keychain.get(account: Keychain.Account.streamEndpoint))
            },
            credentialProvider: KeychainArchiveCredentialProvider())
        self.shots = ScreenshotUploader(
            directory: spool.root.appendingPathComponent("shots", isDirectory: true))
        let sender = self.sender
        self.narrationUploader = NarrationUploader(
            spool: NarrationSpool(
                directory: spool.root.appendingPathComponent("narration", isDirectory: true)),
            eventSpool: spool,
            stackURL: AgentSettings.shared.kbcStackURL,
            onRecordAppended: { await sender.nudge() })
        let artifactQueue = JazzArchiveDeliveryQueue(
            root: spool.root.appendingPathComponent(
                "archive-artifact-delivery", isDirectory: true))
        self.artifactQueue = artifactQueue
        self.artifactUploader = ArchiveArtifactUploader(
            queue: artifactQueue,
            archiveRoot: archiveRoot,
            stackURL: AgentSettings.shared.kbcStackURL)
        self.projectionReconciler = JazzArchiveProjectionReconciler(
            archiveRoot: archiveRoot,
            eventSpool: spool,
            artifactQueue: artifactQueue,
            durability: JazzArchiveFilesystemPlatform.durability)
        self.keboola = KeboolaClient(stackURL: AgentSettings.shared.kbcStackURL)
        coachLiveConsentObserver = NotificationCenter.default.addObserver(
            forName: .captureCoachLiveConsentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.nudgeSender() }
        }
        if AgentSettings.shared.captureCoachLive,
            let routeBinding = AgentSettings.shared.archiveUploadRouteBinding
        {
            do {
                let transport = try CaptureCoachLiveTransportPartition(
                    baseRoot: spool.root.appendingPathComponent(
                        "capture-coach-live", isDirectory: true),
                    routeBinding: routeBinding)
                let drainer = CaptureCoachLiveBackgroundDrainer(
                    worker: transport.worker)
                coachLiveTransport = transport
                coachLiveBackgroundDrainer = drainer
                let authority = transport.boundRoute.authority
                Task { [weak self] in
                    await transport.worker.setStatusHandler { [weak self] status in
                        await self?.setLiveCoachDeliveryStatus(
                            status, authority: authority)
                    }
                    await drainer.start()
                }
            } catch {
                lastError = "Capture Coach delivery suspended: \(error)"
            }
        }

        // Legacy projection drains only under the explicit compatibility policy. Whole-archive
        // delivery has its own confirmed-only queue and starts safely with no pending package.
        let startsLiveCompatibility = AgentSettings.shared.deliveryPolicy
            .usesLiveCompatibilityProjection
        self.deliveryPolicy = AgentSettings.shared.deliveryPolicy
        let narrationUploader = self.narrationUploader
        Task { [weak self] in
            await sender.setStatusHandler { status in
                Task { @MainActor in self?.senderStatus = status }
            }
            if startsLiveCompatibility { await sender.start() }
        }
        Task { [weak self] in
            await narrationUploader.setStatusHandler { status in
                Task { @MainActor in self?.narrationStatus = status }
            }
            // Live BDM: when a clip's narration record lands, hand the segment (audio id + the
            // screenshots shown under that label) to whoever is listening (AppDelegate -> the live
            // canvas). The uploader is an actor, so hop to the main actor to read labelScreenshots.
            await narrationUploader.setSegmentReadyHandler {
                sessionId, labelId, label, audioFileId in
                Task { @MainActor in
                    guard let self else { return }
                    let shots = self.labelScreenshots.removeValue(forKey: labelId) ?? []
                    self.onSegmentReady?(sessionId, labelId, label, audioFileId, shots)
                }
            }
            if startsLiveCompatibility { await narrationUploader.start() }
        }
        let artifactUploader = self.artifactUploader
        Task { [weak self] in
            guard let controller = self else { return }
            await artifactUploader.setStatusHandler { status in
                Task { @MainActor [weak controller] in
                    controller?.artifactStatus = status
                }
            }
            await artifactUploader.setDeliveredHandler { [weak controller] entry, remoteId in
                guard let controller else { return }
                if entry.kind == "screenshot", let labelId = entry.labelId {
                    controller.labelScreenshots[labelId, default: []].append(remoteId)
                } else if entry.kind == "narration_audio",
                    let labelId = entry.labelId, let label = entry.label
                {
                    let screenshots = controller.labelScreenshots.removeValue(forKey: labelId) ?? []
                    controller.onSegmentReady?(
                        entry.legacySessionId, labelId, label, remoteId, screenshots)
                }
            }
            if startsLiveCompatibility { await artifactUploader.start() }
        }
        let projectionReconciler = self.projectionReconciler
        Task { [weak self] in
            let recoveryIndex = CaptureJournal(
                root: archiveRoot,
                durability: JazzArchiveFilesystemPlatform.durability)
            let interrupted = await recoveryIndex.recoverableArchiveIds()
            var recoveryFailures: [String] = []
            for archiveId in interrupted {
                do {
                    let recoveryJournal = CaptureJournal(
                        root: archiveRoot,
                        durability: JazzArchiveFilesystemPlatform.durability)
                    let reopened = try await recoveryJournal.reopen(archiveId: archiveId)
                    if let captureId = reopened.captureId {
                        try await CaptureCoachLiveRecoveryScanner.recoverPromptReceipts(
                            liveRoot: spool.root.appendingPathComponent(
                                "capture-coach-live", isDirectory: true),
                            archiveRoot: archiveRoot,
                            archiveId: archiveId,
                            captureId: captureId,
                            journal: recoveryJournal,
                            durability: JazzArchiveFilesystemPlatform.durability)
                        try await CaptureCoachLiveRecoveryScanner.recoverActionReceipts(
                            liveRoot: spool.root.appendingPathComponent(
                                "capture-coach-live", isDirectory: true),
                            archiveRoot: archiveRoot,
                            archiveId: archiveId,
                            captureId: captureId,
                            durability: JazzArchiveFilesystemPlatform.durability)
                    }
                    let recovered = try await recoveryJournal.recoverInterrupted(
                        archiveId: archiveId)
                    try await CaptureCoachLiveRecoveryScanner
                        .markActionCaptureCommitted(
                            liveRoot: spool.root.appendingPathComponent(
                                "capture-coach-live", isDirectory: true),
                            captureId: recovered.captureId,
                            durability: JazzArchiveFilesystemPlatform.durability)
                    if startsLiveCompatibility {
                        _ = try await projectionReconciler.reconcile(archiveId: archiveId)
                    }
                } catch {
                    recoveryFailures.append(archiveId)
                }
            }
            do {
                _ = try await CaptureCoachLiveRecoveryScanner.recoverAllActionReceipts(
                    liveRoot: spool.root.appendingPathComponent(
                        "capture-coach-live", isDirectory: true),
                    archiveRoot: archiveRoot,
                    durability: JazzArchiveFilesystemPlatform.durability)
            } catch {
                recoveryFailures.append("capture-coach-live")
            }
            let reconciled =
                startsLiveCompatibility
                ? await projectionReconciler.reconcileAll() : []
            if startsLiveCompatibility {
                await sender.nudge()
                await artifactUploader.nudge()
            }
            let recoverable = await CaptureJournal(
                root: archiveRoot,
                durability: JazzArchiveFilesystemPlatform.durability
            ).recoverableArchiveIds()
            guard let self else { return }
            self.recoverableArchiveCount = recoverable.count
            if !recoverable.isEmpty {
                self.archiveStatus = "\(recoverable.count) capture(s) need local recovery"
                if !recoveryFailures.isEmpty {
                    self.lastError = "Some interrupted archives require manual recovery"
                }
            } else if reconciled.contains(where: {
                if case .failure = $0 { return true }
                return false
            }) {
                self.archiveStatus = "Some archive projections need recovery"
            } else if !interrupted.isEmpty {
                self.archiveStatus = "Recovered \(interrupted.count) interrupted capture(s)"
            }
        }
    }

    // MARK: lifecycle

    private func transportForCurrentAuthority(
        _ routeBinding: JazzArchiveUploadRouteBinding
    ) throws -> CaptureCoachLiveTransportPartition {
        let authority = try CaptureCoachLiveRouteAuthority(
            routeBinding: routeBinding)
        if let current = coachLiveTransport,
            current.boundRoute.authority == authority
        {
            return current
        }
        coachLiveTransport?.client.invalidateAndCancel()
        if let prior = coachLiveBackgroundDrainer {
            Task { await prior.stop() }
        }
        let transport = try CaptureCoachLiveTransportPartition(
            baseRoot: spool.root.appendingPathComponent(
                "capture-coach-live", isDirectory: true),
            routeBinding: routeBinding)
        let drainer = CaptureCoachLiveBackgroundDrainer(worker: transport.worker)
        coachLiveTransport = transport
        coachLiveBackgroundDrainer = drainer
        let boundAuthority = transport.boundRoute.authority
        Task { [weak self] in
            await transport.worker.setStatusHandler { [weak self] status in
                await self?.setLiveCoachDeliveryStatus(
                    status, authority: boundAuthority)
            }
            await drainer.start()
        }
        return transport
    }

    private func suspendCoachLiveDelivery() {
        coachLiveTransport?.client.invalidateAndCancel()
        if let drainer = coachLiveBackgroundDrainer {
            Task { await drainer.stop() }
        }
        if coachLiveRuntime != nil || coachLiveAudioAdmissionTail != nil
            || coachLiveLabelContextTail != nil
        {
            let runtime = coachLiveRuntime
            let audioTail = coachLiveAudioAdmissionTail
            let labelTail = coachLiveLabelContextTail
            Task {
                await runtime?.suspendProjection()
                await labelTail?.drain()
                await audioTail?.drain()
                await runtime?.stop()
            }
        }
        coachLiveBackgroundDrainer = nil
        coachLiveTransport = nil
        coachLiveRuntime = nil
        coachLiveObservationRouter = nil
        coachLiveAudioAdmissionTail = nil
        coachLiveLabelContextTail = nil
    }

    private func setLiveCoachDeliveryStatus(
        _ delivery: CaptureCoachLiveDeliveryStatus,
        authority: CaptureCoachLiveRouteAuthority
    ) {
        guard AgentSettings.shared.captureCoachLive,
            coachLiveTransport?.boundRoute.authority == authority
        else { return }
        switch delivery.state {
        case .ready:
            guard coachLiveRuntime != nil else { return }
            coachUnavailable = false
            if currentLabelId == nil {
                coachStatus = "Capture Coach live — waiting for a guided label"
            }
        case .retrying:
            coachUnavailable = true
            coachStatus = "Capture Coach delivery retrying — local data is safe"
        case .suspended:
            coachUnavailable = true
            coachStatus = "Capture Coach delivery suspended — \(delivery.detail)"
            if let runtime = coachLiveRuntime {
                Task { await runtime.suspendProjection() }
            }
        }
    }

    func start() {
        guard !isCapturing, !isStarting, !isFinalizing else { return }
        startTask = Task { [weak self] in
            guard let self else { return false }
            return await self.startAndWait()
        }
    }

    @discardableResult
    private func startAndWait() async -> Bool {
        guard !isCapturing, !isStarting, !isFinalizing else { return false }
        // No prompts here — all permissions are granted up front in Settings → Permissions.
        // Capture just checks (preflight) and uses whatever is granted.
        guard Permissions.status(.accessibility) == .granted else {
            status = "Grant Accessibility in Settings → Permissions, then Start."
            return false
        }
        isStarting = true
        status = "Starting local archive…"
        let settings = AgentSettings.shared
        activeDeliveryPolicy = settings.deliveryPolicy
        deliveryPolicy = activeDeliveryPolicy

        // Capture the whole desktop for this session, minus the privacy denylist.
        policy = RedactionPolicy(denylist: settings.denylist)
        // Screenshots if the toggle (or workshop mode) AND Screen Recording permission are on.
        captureScreenshots =
            (workshopMode || settings.captureScreenshots)
            && Permissions.status(.screenRecording) == .granted
        highlightClicks = settings.highlightClicks
        keboola = KeboolaClient(stackURL: settings.kbcStackURL)
        // Compatibility senders are dormant unless this capture explicitly opts into the old
        // direct path. Starting them is idempotent and does not alter canonical archive IDs.
        let uploader = narrationUploader
        let artifactUploader = self.artifactUploader
        let stack = settings.kbcStackURL
        if activeDeliveryPolicy.usesLiveCompatibilityProjection {
            Task {
                await sender.start()
                await sender.nudge()
            }
            Task {
                await uploader.setStackURL(stack)
                await uploader.start()
            }
            Task {
                await artifactUploader.setStackURL(stack)
                await artifactUploader.start()
            }
        }
        sessionId = Identifiers.newSessionId()
        sequence = 0
        buffer = []
        eventCount = 0
        typing = TypingAccumulator()
        typingTarget = nil
        typingFront = nil
        typingKey = nil
        lastError = nil
        currentLabel = nil  // labels belong to one session; a new session starts unlabeled
        lastShotHash = nil  // screenshot dedup is per-session
        currentLabelId = nil
        currentProcessId = nil  // the process pick is label-scoped; a new session starts unanchored
        currentProcessName = nil
        closedLabelIds.removeAll()
        narrationReservation = nil
        narrationFileClaim?.abandon()
        narrationFileClaim = nil
        pendingSpokenCoachAnswer = nil
        processInventory = []  // per-session cache; re-fetched below for the picked Area
        labelScreenshots.removeAll()  // per-label screenshot tracking belongs to one session
        journalAdmissionTail = nil
        coachActionTail = nil
        coachBaselineTask?.cancel()
        coachBaselineTask = nil
        coachBaselineCursor.resetCapture()
        coachCoordinator = nil
        coachLiveRuntime = nil
        coachLiveObservationRouter = nil
        coachLiveAudioAdmissionTail = nil
        coachLiveLabelContextTail = nil
        coachUnavailable = true
        coachPrompt = nil
        coachMutedUntil = nil
        coachStatus = "Capture Coach starting…"
        onCoachPresentation?(nil, nil)

        // Stable legacy projection identity is minted alongside the canonical archive. It is used
        // only when the explicit compatibility policy is active; local archive durability does not
        // depend on creating an EventSpool session.
        let captureBinding = JazzArchiveCaptureBinding(
            uploadScope: settings.archiveUploadScope,
            selectedAreaId: settings.lastAreaId,
            selectedAreaName: settings.lastAreaName)
        let meta = EventSpool.SessionMeta(
            sessionId: sessionId,
            traceId: OtlpIds.traceId(),
            spanId: OtlpIds.spanId(),
            startedAt: Timestamps.iso8601(),
            // Both session types carry an explicit kind: a BDM workshop vs. a normal
            // process-mapping capture (the latter used to be left nil).
            kind: workshopMode ? "bdm-workshop" : "process-mapping",
            user: Self.effectiveUser(settings),
            instanceName: Self.effectiveInstanceName(settings),
            // An enrollment's Area is authoritative. Without enrollment the local menu choice is
            // still preserved, but it cannot later be rebound silently to another server scope.
            areaId: captureBinding.area?.areaId,
            areaName: captureBinding.area?.nameSnapshot
        )
        do {
            let descriptor = try await makeArchiveDescriptor(
                meta: meta,
                settings: settings,
                screenshots: captureScreenshots,
                captureBinding: captureBinding)
            let journal = CaptureJournal(
                root: archiveRoot,
                durability: JazzArchiveFilesystemPlatform.durability)
            _ = try await journal.begin(
                manifest: descriptor.manifest, session: descriptor.session)
            let sid = sessionId
            let spool = self.spool
            let sender = self.sender
            let artifactUploader = self.artifactUploader
            let eventProjection: CaptureJournalRuntime.Projection?
            let artifactProjection: CaptureJournalRuntime.ArtifactProjection?
            let liveCompatibilityProjection: CaptureJournalRuntime.LiveCompatibilityProjection?
            let liveObservationRouter: CaptureCoachLiveObservationRouter?
            let coachCanonicalProjection: CaptureJournalRuntime.CanonicalObservationProjection?
            if settings.captureCoachLive,
                settings.archiveUploadRouteBinding != nil
            {
                let router = CaptureCoachLiveObservationRouter()
                liveObservationRouter = router
                coachCanonicalProjection = { record, event in
                    await router.project(record, event: event)
                }
            } else {
                liveObservationRouter = nil
                coachCanonicalProjection = nil
            }
            if activeDeliveryPolicy.usesLiveCompatibilityProjection {
                let binding = try JazzLiveCanonicalBinding(
                    archiveId: descriptor.manifest.archiveId,
                    originId: descriptor.manifest.originId,
                    captureId: descriptor.session.captureId)
                eventProjection = nil
                liveCompatibilityProjection = { record, artifacts, event in
                    _ = try spool.appendCanonicalProjection(
                        sessionId: sid,
                        binding: binding,
                        record: record,
                        artifacts: artifacts,
                        event: event)
                    await sender.nudge()
                }
                artifactProjection = { artifact, event in
                    try await artifactUploader.enqueue(
                        JazzArchiveProjectionReconciler.deliveryEntry(
                            archiveId: descriptor.manifest.archiveId,
                            session: descriptor.session,
                            legacySessionId: sid,
                            artifact: artifact,
                            event: event))
                }
            } else {
                eventProjection = nil
                artifactProjection = nil
                liveCompatibilityProjection = nil
            }
            let runtime = CaptureJournalRuntime(
                journal: journal,
                context: descriptor.context,
                projection: eventProjection,
                canonicalObservationProjection: coachCanonicalProjection,
                artifactProjection: artifactProjection,
                liveCompatibilityProjection: liveCompatibilityProjection)
            captureJournal = journal
            journalRuntime = runtime
            archiveId = descriptor.manifest.archiveId
            captureId = descriptor.session.captureId
            streamId = descriptor.context.streamId
            sourceId = descriptor.context.sourceId
            actorId = descriptor.context.actorId
            archiveStatus = "Recording to \(archiveId)"

            if activeDeliveryPolicy.usesLiveCompatibilityProjection {
                // Failure cannot invalidate the already-claimed canonical archive.
                do {
                    let liveRouteBinding = settings.archiveUploadRouteBinding
                    let liveDeliveryRequirements:
                        JazzLiveCompatibilityDeliveryRequirements?
                    if let liveRouteBinding {
                        guard let signedEnvelope =
                                try SignedDeviceCredentialKeychain.vault.envelope(),
                            signedEnvelope.routeBinding == liveRouteBinding
                        else {
                            throw JazzArchiveUploadError.credentialBindingMismatch
                        }
                        liveDeliveryRequirements =
                            try JazzLiveCompatibilityDeliveryRequirements(
                                routeBinding: liveRouteBinding,
                                signedEnvelope: signedEnvelope)
                    } else {
                        liveDeliveryRequirements = nil
                    }
                    let liveMeta = EventSpool.SessionMeta(
                        sessionId: meta.sessionId,
                        traceId: meta.traceId,
                        spanId: meta.spanId,
                        startedAt: meta.startedAt,
                        kind: meta.kind,
                        user: meta.user,
                        instanceName: meta.instanceName,
                        areaId: meta.areaId,
                        areaName: meta.areaName,
                        liveCanonicalBinding: try JazzLiveCanonicalBinding(
                            archiveId: descriptor.manifest.archiveId,
                            originId: descriptor.manifest.originId,
                            captureId: descriptor.session.captureId),
                        // Signed authority is pinned per session. nil intentionally preserves the
                        // legacy direct-stream compatibility path for manual/offline enrollment.
                        liveRouteBinding: liveRouteBinding,
                        liveDeliveryRequirements: liveDeliveryRequirements)
                    try spool.createSession(liveMeta)
                } catch {
                    lastError = "OTLP compatibility projection unavailable: \(error)"
                }
            }

            let startEvent = simpleEvent(type: .sessionStart)
            _ = try await runtime.submit { _ in
                .observation(CaptureJournalActivityObservation(event: startEvent))
            }
            await runtime.waitForAdmittedWork()
            eventCount = 1

            let coachWriter = CaptureCoachJournalWriter(
                journal: journal,
                context: CaptureCoachRecordContext(
                    originId: descriptor.context.originId,
                    captureId: descriptor.context.captureId,
                    streamId: descriptor.context.streamId,
                    sourceRefs: [
                        JazzArchiveSourceRef(
                            sourceId: descriptor.context.sourceId, role: "coach_ui")
                    ],
                    actorRefs: [
                        JazzArchiveActorRef(
                            actorId: descriptor.context.actorId,
                            role: "respondent",
                            basis: .declared,
                            method: "session_recorder")
                    ],
                    provenance: JazzArchiveProvenance(
                        factClass: .observed,
                        sources: [descriptor.context.sourceId]),
                    quality: JazzArchiveQuality(status: .complete),
                    privacy: JazzArchivePrivacy(
                        status: .captured,
                        policyVersion: descriptor.context.policyVersion)))
            let coach = try CaptureCoachCoordinator(
                captureId: descriptor.context.captureId,
                recorder: coachWriter)
            coachCoordinator = coach
            if settings.captureCoachLive,
                let routeBinding = settings.archiveUploadRouteBinding,
                let liveObservationRouter
            {
                let transport = try transportForCurrentAuthority(routeBinding)
                let liveAudioAvailable =
                    (workshopMode || settings.captureNarration)
                    && Permissions.status(.microphone) == .granted
                let live = try CaptureCoachLiveRuntime(
                    transport: transport,
                    sourceId: descriptor.context.sourceId,
                    archiveId: descriptor.manifest.archiveId,
                    captureId: descriptor.context.captureId,
                    liveAudioAvailable: liveAudioAvailable,
                    coordinator: coach,
                    onPresentation: { [weak self] prompt in
                        await self?.presentLiveCoachPrompt(prompt) ?? false
                    },
                    onAvailability: { [weak self] available in
                        await self?.setLiveCoachAvailability(available)
                    })
                coachLiveRuntime = live
                coachLiveObservationRouter = liveObservationRouter
                coachLiveAudioAdmissionTail = CaptureCoachLivePCMAdmissionTail {
                    labelId, processId, chunk in
                    await live.projectAudioChunk(
                        labelId: labelId, processId: processId, chunk: chunk)
                }
                coachLiveLabelContextTail =
                    CaptureCoachLiveLabelContextAdmissionTail {
                        labelId, processId in
                        let generation = await live.setActiveLabel(
                            labelId: labelId, processId: processId)
                        if let generation {
                            Task {
                                await live.nudge(
                                    labelContextGeneration: generation)
                            }
                        }
                    }
                await liveObservationRouter.install(live)
                await live.start()
                coachUnavailable = false
                coachStatus = "Capture Coach live — waiting for a guided label"
            } else {
                if !settings.captureCoachLive {
                    suspendCoachLiveDelivery()
                }
                coachUnavailable = false
                coachStatus = "Capture Coach ready — offline baseline"
                enqueueCoachAction { coordinator in
                    _ = try await coordinator.reportUnavailable(.offline)
                }
            }
        } catch {
            isStarting = false
            status = "Could not create the local Jazz archive: \(error)"
            archiveStatus = "Archive start failed"
            workshopMode = false
            return false
        }

        tap.onEvent = { [weak self] raw in self?.onRaw(raw) }
        tap.onReArm = { [weak self] count in
            // The tap callback runs on the main run loop, so we are on the main actor.
            MainActor.assumeIsolated { self?.tapReArms = count }
        }
        guard tap.start() else {
            status = "Could not start the event tap (Accessibility permission?)."
            if let runtime = journalRuntime {
                let endEvent = simpleEvent(type: .sessionEnd)
                _ = try? await runtime.submit { _ in
                    .observation(CaptureJournalActivityObservation(event: endEvent))
                }
                _ = try? await runtime.close(endedAt: Timestamps.iso8601())
            }
            isStarting = false
            workshopMode = false
            return false
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.onAppActivated(note) }
        }

        // The mic is NEVER started here: it records only inside a bracketed label
        // (startLabel → endLabel). Plain capture is mic-off by design.

        flushTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushToSpool() }
        }
        isCapturing = true
        isStarting = false
        captureStartedAt = Date()
        status = (workshopMode ? "BDM workshop — " : "Capturing — ") + sessionId

        // Guided capture: fetch the picked Area's declared process inventory in the background so
        // the ⌥⌘L panel can offer a process picker. Fire-and-forget AFTER capture is running —
        // a slow/failed fetch leaves processInventory empty (Explore mode) and never blocks
        // capture. Skipped for workshops (a workshop names its own label segments — question
        // text must never accidentally resolve to a process pick) and for the General Area
        // (no areaId → no registry to fetch).
        if !workshopMode, let areaId = meta.areaId {
            let sid = sessionId
            Task { [weak self] in
                let inventory = await RegistryFetcher.fetchInventory(
                    areaId: areaId, stackURL: stack)
                // Only publish into the session the fetch was started for.
                guard let self, self.isCapturing, self.sessionId == sid else { return }
                self.processInventory = inventory
            }
        }
        return true
    }

    /// Start a capture session in BDM-workshop mode: a narrated, guided interview. The mic
    /// (inside each question's label segment) and dense focused-window screenshots are forced on
    /// regardless of the user's toggles, and the session is tagged ``session.kind="bdm-workshop"``
    /// so the processor recognises it as a workshop. The question walk-through + segment lifecycle
    /// is driven by ``BdmWorkshopController``.
    func startBdmWorkshop() async -> Bool {
        workshopMode = true
        let started = await startAndWait()
        if !started { workshopMode = false }
        return started
    }

    func stop() {
        guard isCapturing else { return }
        flushTyping()  // commit any text typed right before stopping
        // A label is an open span — close it first so the mic can't stay hot and its
        // label-scoped audio uploads cleanly before the session itself ends.
        if currentLabelId != nil { endLabel() }
        tap.stop()
        flushTimer?.invalidate()
        flushTimer = nil
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
            self.appObserver = nil
        }
        append(simpleEvent(type: .sessionEnd))

        let endedAt = Timestamps.iso8601()
        let sid = sessionId
        let closingArchiveId = archiveId
        let admissionTail = journalAdmissionTail
        let coachTail = coachActionTail
        let coach = coachCoordinator
        let coachLive = coachLiveRuntime
        let coachAudioTail = coachLiveAudioAdmissionTail
        let coachLabelTail = coachLiveLabelContextTail
        let runtime = journalRuntime

        isCapturing = false
        isFinalizing = true
        captureStartedAt = nil
        highlight.hide()
        status = "Finalizing local archive…"
        archiveStatus = "Draining admitted capture work"
        coachPrompt = nil
        coachMutedUntil = nil
        coachBaselineTask?.cancel()
        coachBaselineTask = nil
        onCoachPresentation?(nil, nil)
        workshopMode = false

        let closingDeliveryPolicy = activeDeliveryPolicy
        // The async tail waits only for local producer work and the canonical commit. Confirmed
        // archive delivery begins later, after review; stop itself stays fully local.
        shutdownTask = Task { [weak self] in
            guard let self else { return }
            await coachLabelTail?.drain()
            await coachAudioTail?.drain()
            await coachLive?.stop()
            await admissionTail?.value
            await coachTail?.value
            if let runtime {
                do {
                    let commit = try await runtime.close(endedAt: endedAt)
                    await coachLive?.retireRecoveryState()
                    self.archiveStatus = "Committed locally — \(closingArchiveId)"
                    if closingDeliveryPolicy.usesLiveCompatibilityProjection {
                        do {
                            try self.spool.endSession(
                                sessionId: sid,
                                endedAt: endedAt,
                                captureCommit: commit)
                        } catch {
                            self.lastError = "canonical live commit projection: \(error)"
                        }
                    }
                } catch {
                    self.lastError = "archive commit: \(error)"
                    self.archiveStatus = "Archive needs recovery — \(closingArchiveId)"
                    self.recoverableArchiveCount += 1
                }
            }
            await coach?.markCaptureCommitted()
            if closingDeliveryPolicy.usesLiveCompatibilityProjection {
                do {
                    if self.spool.sessionMeta(sessionId: sid)?.endedAt == nil {
                        try self.spool.endSession(sessionId: sid, endedAt: endedAt)
                    }
                } catch {
                    self.lastError = "OTLP compatibility projection end: \(error)"
                }
                if !closingArchiveId.isEmpty {
                    do {
                        _ = try await self.projectionReconciler.reconcile(
                            archiveId: closingArchiveId)
                    } catch {
                        self.lastError = "archive compatibility reconciliation: \(error)"
                    }
                }
                await self.sender.nudge()
            }
            self.isFinalizing = false
            self.status =
                "Stopped — \(self.eventCount) events · saved locally · review before upload"
        }
    }

    /// Wake the background sender AND the narration uploader from outside a capture session —
    /// e.g. right after onboarding stores the stream endpoint/token, so a backlog from an
    /// offline/first-run period (events AND staged audio) ships immediately instead of waiting
    /// out the (up to 60s) reconnect backoff.
    func nudgeSender() {
        archiveUploadManager.reconnectAndRetry()
        if AgentSettings.shared.captureCoachLive,
            let route = AgentSettings.shared.archiveUploadRouteBinding
        {
            do {
                _ = try transportForCurrentAuthority(route)
                if let drainer = coachLiveBackgroundDrainer {
                    Task { await drainer.nudge() }
                }
            } catch {
                coachUnavailable = true
                coachStatus = "Capture Coach delivery suspended — invalid enrollment route"
            }
        } else if !AgentSettings.shared.captureCoachLive {
            suspendCoachLiveDelivery()
        }
        guard AgentSettings.shared.deliveryPolicy.usesLiveCompatibilityProjection else { return }
        let sender = self.sender
        let narrationUploader = self.narrationUploader
        let artifactUploader = self.artifactUploader
        Task { await sender.nudge() }
        Task { await narrationUploader.nudge() }
        Task { await artifactUploader.nudge() }
    }

    // MARK: Capture Coach advisory surface

    private func refreshCoachPresentation() async {
        guard let coordinator = coachCoordinator else { return }
        let snapshot = await coordinator.snapshot()
        coachPrompt = snapshot.outstandingPrompt
        coachMutedUntil = snapshot.mutedUntil
        if snapshot.finishedAnyway {
            coachStatus = "Capture Coach finished for this capture"
        } else if let mutedUntil = snapshot.mutedUntil {
            coachStatus = "Capture Coach muted until \(mutedUntil)"
        } else if snapshot.outstandingPrompt != nil {
            coachStatus = "Capture Coach has a question"
        } else {
            coachStatus =
                coachUnavailable
                ? "Capture Coach unavailable — capture continues offline"
                : "Capture Coach listening"
        }
        onCoachPresentation?(snapshot.outstandingPrompt, snapshot.mutedUntil)
    }

    private func setLiveCoachAvailability(_ available: Bool) {
        coachUnavailable = !available
        if !available, coachPrompt == nil {
            coachStatus = "Capture Coach unavailable — capture continues offline"
        } else if available, coachPrompt == nil {
            coachStatus = "Capture Coach listening"
        }
    }

    /// The return value is the explicit presentation confirmation consumed by the live projector.
    /// This method is MainActor-isolated, so setting the published prompt and notifying the panel
    /// completes before the canonical `shown` interaction may be appended.
    private func presentLiveCoachPrompt(_ prompt: CaptureCoachPrompt) -> Bool {
        guard isCapturing else { return false }
        coachPrompt = prompt
        coachMutedUntil = nil
        coachUnavailable = false
        coachStatus = "Capture Coach has a question"
        onCoachPresentation?(prompt, nil)
        return true
    }

    /// Injection point for a future live server or offline assessor. Delivery is advisory: an
    /// invalid/unavailable prompt is audited and surfaced, but never pauses or stops capture.
    func deliverCoachPrompt(_ prompt: CaptureCoachPrompt) {
        guard isCapturing else { return }
        coachUnavailable = false
        enqueueCoachAction { coordinator in
            _ = try await coordinator.receive(prompt)
        }
    }

    /// Start the evidence-agnostic offline fallback for the active label. The fallback asks at most
    /// one outstanding question and never inspects captured content; a future server prompt and a
    /// local prompt therefore share the same coordinator, cooldown, mute, and first-arrival wins
    /// arbitration.
    private func scheduleLocalBaseline(for labelId: String) {
        coachBaselineTask?.cancel()
        let plan = CaptureCoachLocalBaselinePlan.current
        guard
            coachBaselineCursor.nextIndex(
                for: labelId,
                templateCount: plan.templates.count) != nil
        else { return }
        let captureGeneration = captureId
        coachBaselineTask = Task { [weak self] in
            var delay = plan.initialDelaySeconds
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
                guard let self,
                    self.isCapturing,
                    self.captureId == captureGeneration,
                    self.currentLabelId == labelId
                else { return }
                let exhausted = await self.issueLocalBaselinePrompt(
                    plan: plan, labelId: labelId)
                if exhausted { return }
                delay = plan.cadenceSeconds
            }
        }
    }

    /// Returns true when the version-pinned baseline has no question left for this label.
    private func issueLocalBaselinePrompt(
        plan: CaptureCoachLocalBaselinePlan,
        labelId: String
    ) async -> Bool {
        guard let coordinator = coachCoordinator, let journal = captureJournal else { return false }
        let coach = await coordinator.snapshot()
        if coach.finishedAnyway { return true }
        guard coach.outstandingPrompt == nil, coach.pendingReceivedPrompt == nil,
            coach.mutedUntil == nil, !coach.captureCommitted
        else { return false }
        guard
            let baselineIndex = coachBaselineCursor.nextIndex(
                for: labelId,
                templateCount: plan.templates.count)
        else { return true }

        let journalState = await journal.snapshot()
        guard journalState.captureId == captureId,
            let nextSequence = journalState.nextSequenceByStream[streamId]
        else { return false }
        let watermark = CaptureCoachInputWatermark(
            captureId: captureId,
            streams: [
                CaptureCoachStreamWatermark(
                    streamId: streamId,
                    throughSequence: max(0, nextSequence - 1))
            ])
        let responseModes: [CaptureCoachResponseMode] =
            narration.isRecording
            ? [.typedText, .spoken] : [.typedText]
        do {
            guard
                let prompt = try plan.prompt(
                    at: baselineIndex,
                    labelId: labelId,
                    inputWatermark: watermark,
                    responseModes: responseModes)
            else { return true }
            let exhausted = coachBaselineCursor.advance(
                labelId: labelId,
                issuedIndex: baselineIndex,
                templateCount: plan.templates.count)
            deliverCoachPrompt(prompt)
            return exhausted
        } catch {
            lastError = "Capture Coach local baseline: \(error)"
            return true
        }
    }

    func answerCoach(_ text: String) {
        guard let promptId = coachPrompt?.promptId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Capture Coach answer cannot be empty"
            return
        }
        // Typed input is the explicit fallback. It cancels a not-yet-materialized spoken intent;
        // no Coach record has referenced that reserved artifact at this point.
        pendingSpokenCoachAnswer = nil
        let live = coachLiveRuntime
        let proposedDate = Date()
        enqueueCoachAction { coordinator in
            var intent: CaptureCoachLiveActionProjectionIntent?
            if let live {
                intent = try? await live.preparePromptAction(
                    promptId: promptId,
                    interactionType: .answered,
                    at: proposedDate)
            }
            let actionDate =
                intent.flatMap {
                    Timestamps.parse($0.clientRecordedAt)
                } ?? proposedDate
            let interaction = try await coordinator.answer(
                promptId: promptId,
                answer: CaptureCoachAnswer(mode: .typedText, text: trimmed),
                at: actionDate,
                interactionId: intent?.interactionId
                    ?? Identifiers.newCoachInteractionId())
            if intent != nil { await live?.projectAction(interaction) }
        }
    }

    /// Bind the outstanding Coach answer to the narration currently being recorded. This records
    /// only intent; the `.spoken` interaction is appended after `endLabel` has durably persisted
    /// the exact reserved artifact ID. A failed/empty recording therefore leaves no dangling ref.
    func answerCoachSpoken() {
        guard let prompt = coachPrompt else { return }
        guard prompt.snapshot.responseModes.contains(.spoken) else {
            lastError = String(describing: CaptureCoachSpokenAnswerError.modeNotOffered)
            return
        }
        guard let labelId = currentLabelId else {
            lastError = String(describing: CaptureCoachSpokenAnswerError.labelNotOpen)
            return
        }
        guard narration.isRecording,
            let reservation = narrationReservation,
            reservation.labelId == labelId
        else {
            lastError = String(describing: CaptureCoachSpokenAnswerError.microphoneNotRecording)
            return
        }
        pendingSpokenCoachAnswer = PendingSpokenCoachAnswer(
            promptId: prompt.promptId,
            reservation: reservation)
        coachStatus = "Capture Coach will attach this answer when the label audio is saved"
    }

    func dismissCoach() {
        guard let promptId = coachPrompt?.promptId else { return }
        let live = coachLiveRuntime
        let proposedDate = Date()
        enqueueCoachAction { coordinator in
            var intent: CaptureCoachLiveActionProjectionIntent?
            if let live {
                intent = try? await live.preparePromptAction(
                    promptId: promptId,
                    interactionType: .dismissed,
                    at: proposedDate)
            }
            let actionDate =
                intent.flatMap {
                    Timestamps.parse($0.clientRecordedAt)
                } ?? proposedDate
            let interaction = try await coordinator.dismiss(
                promptId: promptId,
                at: actionDate,
                interactionId: intent?.interactionId
                    ?? Identifiers.newCoachInteractionId())
            if intent != nil { await live?.projectAction(interaction) }
        }
    }

    func muteCoach() {
        let live = coachLiveRuntime
        let proposedDate = Date()
        enqueueCoachAction { coordinator in
            var intent: CaptureCoachLiveActionProjectionIntent?
            if let live {
                intent = try? await live.prepareScopeAction(
                    interactionType: .muted, at: proposedDate)
            }
            let actionDate =
                intent.flatMap {
                    Timestamps.parse($0.clientRecordedAt)
                } ?? proposedDate
            let interaction = try await coordinator.mute(
                at: actionDate,
                interactionId: intent?.interactionId
                    ?? Identifiers.newCoachInteractionId())
            if intent != nil { await live?.projectAction(interaction) }
        }
    }

    func resumeCoach() {
        let live = coachLiveRuntime
        let proposedDate = Date()
        enqueueCoachAction { coordinator in
            var intent: CaptureCoachLiveActionProjectionIntent?
            if let live {
                intent = try? await live.prepareScopeAction(
                    interactionType: .resumed, at: proposedDate)
            }
            let actionDate =
                intent.flatMap {
                    Timestamps.parse($0.clientRecordedAt)
                } ?? proposedDate
            let interaction = try await coordinator.resume(
                at: actionDate,
                interactionId: intent?.interactionId
                    ?? Identifiers.newCoachInteractionId())
            if let interaction, intent != nil {
                await live?.projectAction(interaction)
            }
        }
    }

    func finishCoachAnyway() {
        let live = coachLiveRuntime
        let proposedDate = Date()
        enqueueCoachAction { coordinator in
            var intent: CaptureCoachLiveActionProjectionIntent?
            if let live {
                intent = try? await live.prepareScopeAction(
                    interactionType: .finishAnyway, at: proposedDate)
            }
            let actionDate =
                intent.flatMap {
                    Timestamps.parse($0.clientRecordedAt)
                } ?? proposedDate
            let interaction = try await coordinator.finishAnyway(
                at: actionDate,
                interactionId: intent?.interactionId
                    ?? Identifiers.newCoachInteractionId())
            if let interaction, intent != nil {
                await live?.projectAction(interaction)
            }
        }
    }

    private func enqueueCoachAction(
        _ operation: @escaping @Sendable (CaptureCoachCoordinator) async throws -> Void
    ) {
        guard let coordinator = coachCoordinator else { return }
        let predecessor = coachActionTail
        coachActionTail = Task { [weak self] in
            await predecessor?.value
            do {
                try await operation(coordinator)
                let snapshot = await coordinator.snapshot()
                guard let self else { return }
                self.coachPrompt = snapshot.outstandingPrompt
                self.coachMutedUntil = snapshot.mutedUntil
                if snapshot.finishedAnyway {
                    self.coachStatus = "Capture Coach finished for this capture"
                } else if let mutedUntil = snapshot.mutedUntil {
                    self.coachStatus = "Capture Coach muted until \(mutedUntil)"
                } else if snapshot.outstandingPrompt != nil {
                    self.coachStatus = "Capture Coach has a question"
                } else if self.coachUnavailable {
                    self.coachStatus = "Capture Coach unavailable — capture continues offline"
                } else {
                    self.coachStatus = "Capture Coach listening"
                }
                self.onCoachPresentation?(snapshot.outstandingPrompt, snapshot.mutedUntil)
            } catch {
                guard let self else { return }
                self.lastError = "Capture Coach: \(error)"
                self.coachStatus = "Capture Coach unavailable — capture continues"
            }
        }
    }

    /// Finish capture and give the background work a bounded window to settle. Called from
    /// applicationShouldTerminate — the spool persists everything, so hitting the deadline
    /// is safe (leftovers ship on the next launch).
    func shutdown(deadline: TimeInterval = CaptureController.shutdownDeadline) async {
        if isStarting { _ = await startTask?.value }
        if isCapturing { stop() }
        await shutdownTask?.value
        guard activeDeliveryPolicy.usesLiveCompatibilityProjection else { return }
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let senderIdle = await sender.pendingWork() == 0
            let shotsIdle = await shots.pending() == 0
            // Narration clips are durable, so a slow upload that misses the deadline just ships
            // on the next launch — waiting here only lets a quick one finish before quit.
            let narrationIdle = await narrationUploader.pending() == 0
            let artifactIdle = await artifactUploader.pending() == 0
            if senderIdle && shotsIdle && narrationIdle && artifactIdle { return }
            try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s poll, bounded by deadline
        }
    }

    /// Identity attributed to captured sessions: the Settings override, else the OS user
    /// (NSUserName()) as the fallback.
    private static func effectiveUser(_ settings: AgentSettings) -> String {
        let email = settings.userEmail.trimmingCharacters(in: .whitespaces)
        return email.isEmpty ? NSUserName() : email
    }

    /// The recording machine attributed to captured sessions: the Settings override, else the
    /// OS hostname (the `instanceName` getter already auto-fills + persists when empty). Becomes
    /// `host.name` on every event — WHICH machine, distinct from ``effectiveUser`` (WHO).
    private static func effectiveInstanceName(_ settings: AgentSettings) -> String {
        let name = settings.instanceName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? ProcessInfo.processInfo.hostName : name
    }

    private struct ArchiveDescriptor {
        var manifest: JazzArchiveManifest
        var session: JazzArchiveSession
        var context: CaptureJournalActivityContext
    }

    private func makeArchiveDescriptor(
        meta: EventSpool.SessionMeta,
        settings: AgentSettings,
        screenshots: Bool,
        captureBinding: JazzArchiveCaptureBinding
    ) async throws -> ArchiveDescriptor {
        let installed = try await identityStore.loadOrCreate(createdAt: meta.startedAt)
        let sourceIdentity = try await identityStore.source(
            kind: "macos.native", createdAt: meta.startedAt)
        let user = meta.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityNamespace = user.contains("@") ? "user.email" : "macos.username"
        let actorIdentity = try await identityStore.actor(
            namespace: identityNamespace,
            value: user.isEmpty ? NSUserName() : user,
            displayName: user.isEmpty ? NSFullUserName() : user,
            at: meta.startedAt)
        let archiveId = Identifiers.newArchiveId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let version =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String
        let producer = JazzArchiveProducer(
            name: "Jazz Desktop Client",
            version: version,
            build: build,
            platform: "macOS",
            model: ProcessInfo.processInfo.operatingSystemVersionString)
        let actor = JazzArchiveActor(
            actorId: actorIdentity.actorId,
            kind: .human,
            identityStatus: .identified,
            displayName: actorIdentity.displayName,
            externalIdentities: [
                JazzArchiveExternalIdentity(
                    namespace: actorIdentity.namespace, value: actorIdentity.value)
            ],
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        var capabilities = [
            "pointer.capture", "keyboard.capture", "accessibility.context",
        ]
        if screenshots { capabilities.append("screen.capture") }
        let narrationAvailable =
            Permissions.status(.microphone) == .granted
            && (workshopMode || settings.captureNarration)
        if narrationAvailable { capabilities.append("audio.capture") }
        var unavailable: [JazzArchiveUnavailableCapability] = []
        if workshopMode || settings.captureScreenshots, !screenshots {
            unavailable.append(
                JazzArchiveUnavailableCapability(
                    capability: "screen.capture", reason: .permissionDenied))
        }
        if workshopMode || settings.captureNarration, !narrationAvailable {
            unavailable.append(
                JazzArchiveUnavailableCapability(
                    capability: "audio.capture", reason: .permissionDenied))
        }
        let source = JazzArchiveSource(
            sourceId: sourceIdentity.sourceId,
            kind: sourceIdentity.kind,
            actorId: actorIdentity.actorId,
            producer: producer,
            externalIdentities: [
                JazzArchiveExternalIdentity(
                    namespace: "macos.host", value: meta.instanceName)
            ],
            clock: JazzArchiveClock(
                wallClock: "system",
                timeZone: TimeZone.current.identifier),
            capabilities: capabilities,
            unavailableCapabilities: unavailable,
            provenance: JazzArchiveProvenance(factClass: .observed, sources: []))
        let sessionRef = JazzArchiveSessionRef(
            captureId: captureId, legacySessionId: meta.sessionId)
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: installed.installation.originId,
            enrolledDeviceIdentity: captureBinding.enrolledDeviceIdentity,
            createdAt: meta.startedAt,
            producer: producer,
            contracts: [.activityEvent, .captureCoachInteraction],
            actors: [actor],
            sources: [source],
            sessions: [sessionRef])
        var modalities: [JazzArchiveModality] = [.pointer, .keyboard, .accessibility]
        if screenshots { modalities.append(.screenshots) }
        if narrationAvailable { modalities.append(.narration) }
        let reasons = unavailable.map {
            "\($0.capability.replacingOccurrences(of: ".", with: "_"))_unavailable"
        }
        let quality = JazzArchiveQuality(
            status: reasons.isEmpty ? .complete : .partial,
            reasons: reasons)
        let area = captureBinding.area
        let policyVersion = "desktop-consent-v1"
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: meta.sessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: meta.startedAt,
            sessionKind: meta.kind,
            recorderActorId: actorIdentity.actorId,
            sourceIds: [sourceIdentity.sourceId],
            area: area,
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: policyVersion,
                consentedAt: meta.startedAt,
                modalities: modalities,
                excludedApplications: policy.denylist.sorted(),
                businessDataCapture: false),
            clock: JazzArchiveClock(
                wallClock: "system", timeZone: TimeZone.current.identifier),
            quality: quality)
        return ArchiveDescriptor(
            manifest: manifest,
            session: session,
            context: CaptureJournalActivityContext(
                originId: installed.installation.originId,
                captureId: captureId,
                streamId: streamId,
                sourceId: sourceIdentity.sourceId,
                actorId: actorIdentity.actorId,
                policyVersion: policyVersion))
    }

    // MARK: event handling

    private func onRaw(_ raw: EventTap.RawEvent) {
        guard isCapturing else { return }
        let front = AppContext.frontmost()
        guard policy.isCaptureAllowed(bundleID: front?.bundleID) else { return }  // consent gate

        // Keystrokes are classified separately (typed text + shortcuts) and never fall through to the
        // click/screenshot path.
        if raw.kind == .key {
            handleKey(raw.key, front: front)
            return
        }
        // A click or clipboard action ends any in-progress typing run (a focus boundary).
        if [.click, .rightClick, .copy, .cut, .paste].contains(raw.kind) { flushTyping() }

        let type: EventType
        switch raw.kind {
        case .click: type = .click
        case .drag: type = .drag
        case .rightClick: type = .contextmenu
        case .copy: type = .copy
        case .cut: type = .cut
        case .paste: type = .paste
        case .scroll:
            let now = Date()
            guard now.timeIntervalSince(lastScroll) > 0.8 else { return }  // throttle scroll noise
            lastScroll = now
            type = .scroll
        case .key:
            return  // already handled above (handleKey); never reaches here
        }

        // Pre-assign the sequence HERE (main actor, in arrival order) and do the AX hit-test
        // on the utility queue: the tap callback must return fast or the OS disables the tap
        // (kCGEventTapDisabledByTimeout — the historical "it just stopped recording" bug).
        // Enrichment hops back to the main actor to build + append with the pre-assigned
        // sequence, so event ORDER is fixed even when enrichments finish out of order.
        let seq = nextSequence()
        let sid = sessionId
        let kind = raw.kind
        let location = raw.location
        let clickCount = raw.clickCount
        let dragEnd = raw.dragEnd
        let gestureId = raw.gestureId
        let labelScope = LabelScopeSnapshot(
            labelId: currentLabelId,
            label: currentLabel,
            processId: currentProcessId,
            process: currentProcessName)
        // Clipboard payload is read only for paste (sensitivity-gated). Copy/cut evidence comes
        // from the focused AX selection because the pasteboard may update after this tap callback.
        let clipboard = clipboardText(for: kind)
        let ownPID = ownPID  // captured for the background hit-test (no `self` access off-main)
        let wantsScreenshot =
            captureScreenshots
            && (workshopMode || kind == .click || kind == .rightClick || kind == .drag)
        admitJournalProducer { [weak self] _ in
            let ax = await Self.enrichedTarget(
                kind: kind, location: location, excluding: ownPID)
            guard let self else {
                return .gap(reason: .captureLoss, detail: "capture controller released")
            }
            return await self.finishInteraction(
                type: type, kind: kind, sequence: seq, sessionId: sid,
                front: front, ax: ax, clickCount: clickCount, dragEnd: dragEnd,
                gestureId: gestureId, clipboard: clipboard,
                labelScope: labelScope,
                wantsScreenshot: wantsScreenshot)
        }
    }

    /// Reserve happens before this function starts. The foreign-app hit test stays on the utility
    /// queue; only the system-wide fallback touches in-process AX on the main thread.
    nonisolated private static func enrichedTarget(
        kind: EventTap.RawKind,
        location: CGPoint,
        excluding ownPID: pid_t
    ) async -> AXTargetInfo? {
        await withCheckedContinuation { continuation in
            axQueue.async {
                let usesFocusedTarget = kind == .copy || kind == .cut || kind == .paste
                let foreignPID =
                    usesFocusedTarget
                    ? nil : Accessibility.foreignWindowPID(at: location, excluding: ownPID)
                let foreignAX = foreignPID.flatMap {
                    Accessibility.target(inApp: $0, atScreenPoint: location)
                }
                DispatchQueue.main.async {
                    let ax =
                        usesFocusedTarget
                        ? Accessibility.focusedInfo()
                        : foreignPID == nil
                            ? Accessibility.target(atScreenPoint: location) : foreignAX
                    continuation.resume(returning: ax)
                }
            }
        }
    }

    /// Second half of an interaction, after AX enrichment came back (main actor).
    private func finishInteraction(
        type: EventType, kind: EventTap.RawKind, sequence seq: Int, sessionId sid: String,
        front: FrontApp?, ax: AXTargetInfo?, clickCount: Int = 1, dragEnd: CGPoint? = nil,
        gestureId: String? = nil, clipboard: String? = nil,
        labelScope: LabelScopeSnapshot,
        wantsScreenshot: Bool
    ) async -> CaptureJournalActivityOutcome {
        // The session may have been stopped + restarted while we enriched — an event built
        // now would carry the wrong session id. Drop it (the pre-assigned sequence just gaps).
        guard sid == sessionId else {
            return .gap(reason: .captureLoss, detail: "capture generation changed")
        }

        // Attribute the interaction to the app that OWNS the target element, not the Workspace
        // "frontmost app": menu-bar extras and Spotlight don't change frontmost, so a click on our
        // own tray menu would otherwise be mis-attributed to (and replayed into) the prior app.
        let owner = effectiveFront(ax: ax, fallback: front)
        // Ignore jasnost's own UI (menu bar, main window) entirely.
        if owner?.pid == ownPID {
            return .gap(reason: .intentionallyOmitted, detail: "desktop client UI")
        }
        // The preliminary frontmost-app gate ran before AX enrichment. Enforce policy again against
        // the element's actual owner (Spotlight/menu extras can differ from frontmost).
        guard
            policy.isCaptureAllowed(
                preliminaryBundleID: front?.bundleID,
                actualOwnerBundleID: owner?.bundleID)
        else {
            return .gap(reason: .intentionallyOmitted, detail: "application denylist")
        }

        // Show the user (and any screen recording) exactly where they clicked / dragged.
        if highlightClicks, isCapturing, kind == .click || kind == .rightClick || kind == .drag,
            let f = ax?.frame
        {
            highlight.flash(axFrame: f)
        }
        // clickCount only carries meaning for pointer interactions; dragEnd only for a drag.
        let cc = (kind == .click || kind == .rightClick || kind == .drag) ? clickCount : nil
        let event = buildEvent(
            type: type.rawValue, sequence: seq, front: owner, ax: ax, clickCount: cc,
            dragEnd: dragEnd, gestureId: gestureId, clipboardText: clipboard,
            labelScope: labelScope)

        guard wantsScreenshot else {
            return .observation(CaptureJournalActivityObservation(event: event))
        }
        return await screenshotOutcome(
            event, sessionId: sid, bundleID: owner?.bundleID, targetRect: ax?.frame)
    }

    /// Capture visual evidence locally. The runtime reserves the observation before this async
    /// work starts and content-addresses kept JPEG bytes into the Jazz archive; Files delivery is
    /// a later projection and can never decide whether the evidence exists.
    private func screenshotOutcome(
        _ event: ActivityEvent,
        sessionId sid: String,
        bundleID: String?,
        targetRect: CGRect?
    ) async -> CaptureJournalActivityOutcome {
        let shot = await ScreenCapture.focusedWindowShot(
            bundleID: bundleID, targetRect: targetRect)
        // Gate the UPLOAD (not the event) on a meaningful visual change: skip a frame that's
        // near-identical to the last one we kept this session — repeated clicks in the same
        // view shouldn't each cost a Files upload. Dedup is per-session, so only consult and
        // update lastShotHash while still on `sid`.
        guard let shot else {
            return .observation(
                CaptureJournalActivityObservation(
                    event: event,
                    quality: JazzArchiveQuality(
                        status: .partial, reasons: ["screenshot_unavailable"])))
        }
        let keep: Bool = {
            guard sessionId == sid else { return false }
            let duplicate =
                lastShotHash.map {
                    PerceptualHash.hammingDistance(shot.hash, $0) <= Self.shotDedupThreshold
                } ?? false
            if !duplicate { lastShotHash = shot.hash }
            return !duplicate
        }()
        guard keep else {
            return .observation(CaptureJournalActivityObservation(event: event))
        }
        return .observation(
            CaptureJournalActivityObservation(
                event: event,
                artifact: CaptureJournalArtifactInput(
                    bytes: shot.data,
                    kind: "screenshot",
                    mediaType: "image/jpeg",
                    role: "screenshot",
                    sourceRole: "screen_capture",
                    actorRole: "performer",
                    captureInterval: JazzArchiveArtifactCaptureInterval(
                        startedAt: event.timestamp),
                    privacy: JazzArchivePrivacy(
                        status: .captured, policyVersion: "desktop-consent-v1"))))
    }

    private func onAppActivated(_ note: Notification) {
        guard isCapturing,
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let front = FrontApp(
            bundleID: app.bundleIdentifier,
            name: app.localizedName,
            version: app.bundleURL.flatMap(Bundle.init(url:))?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            pid: app.processIdentifier
        )
        guard policy.isCaptureAllowed(bundleID: front.bundleID) else { return }
        flushTyping()  // switching apps ends any in-progress typing run
        append(
            buildEvent(
                type: EventType.navigate.rawValue, sequence: nextSequence(), front: front, ax: nil)
        )
    }

    // MARK: keystrokes (semantic text + shortcuts)

    /// Classify one key press and route it: printable keys accumulate into the typing buffer (unless
    /// the focused field is secure/sensitive), backspace edits the buffer, and special keys /
    /// shortcuts flush the buffer then emit a `keydown` event. Stays ON the tap callback by
    /// design: the focused-element read skips the hierarchy walk and is bounded by the AX
    /// messaging timeout, so it is cheap per key press.
    private func handleKey(_ key: EventTap.KeyInfo?, front: FrontApp?) {
        guard let key else { return }
        let focused = Accessibility.focusedInfo()
        // Ignore keys whose focus is jasnost's own UI (e.g. typing in our embedded web app); flush any
        // prior typing first so it isn't lost.
        if focused?.ownerPID == ownPID {
            flushTyping()
            return
        }
        // Attribute by the FOCUSED element's owning app (Spotlight etc. don't change frontmost), so
        // text typed into Spotlight isn't mis-attributed to the app behind it.
        let keyFront = frontFromFocus(focused) ?? front
        // The preliminary frontmost-app gate can differ from the focused AX owner (password
        // managers, menu extras, overlays). Re-apply the denylist to the actual owner before any
        // key classification or buffering, exactly like the pointer path does after hit-testing.
        guard
            policy.isCaptureAllowed(
                preliminaryBundleID: front?.bundleID,
                actualOwnerBundleID: keyFront?.bundleID)
        else {
            flushTyping()
            return
        }
        let action = KeyClassifier.classify(
            keycode: key.keycode, characters: key.characters,
            command: key.flags.contains(.maskCommand), control: key.flags.contains(.maskControl),
            option: key.flags.contains(.maskAlternate), shift: key.flags.contains(.maskShift)
        )
        switch action {
        case .text(let s):
            // Never record typing into a secure/sensitive field (password, "PIN", etc.).
            if Sensitivity.isSensitiveField(
                role: focused?.role, subrole: focused?.subrole, label: focused?.label)
            {
                flushTyping()
                return
            }
            let identity = focusKey(focused)
            if !typing.isEmpty, identity != typingKey { flushTyping() }  // focus moved mid-typing
            if typing.isEmpty {
                typingTarget = targetForTyping(focused)
                typingFront = keyFront
                typingKey = identity
            }
            typing.append(s)
        case .backspace:
            if typing.isEmpty {
                emitKey(name: "Delete", front: keyFront)
            } else {
                typing.backspace()
            }
        case .special(let name):
            flushTyping()
            emitKey(name: name, front: keyFront)
        case .shortcut(let combo):
            flushTyping()
            emitKey(name: combo, front: keyFront)
        case .ignored:
            break
        }
    }

    /// Build a FrontApp from an AX element's owning app (the app that really owns the element), or
    /// nil if unknown. Lets capture attribute events to the right app for menu-bar extras / overlays.
    private func frontFromFocus(_ ax: AXTargetInfo?) -> FrontApp? {
        guard let ax, let pid = ax.ownerPID else { return nil }
        return FrontApp(
            bundleID: ax.ownerBundleID,
            name: ax.ownerName,
            version: ax.ownerVersion,
            pid: pid)
    }

    /// The owning app of the clicked element when known, else the Workspace frontmost app.
    private func effectiveFront(ax: AXTargetInfo?, fallback: FrontApp?) -> FrontApp? {
        frontFromFocus(ax) ?? fallback
    }

    /// Commit the accumulated typing as one redacted `input` evidence event.
    private func flushTyping() {
        guard !typing.isEmpty else { return }
        let raw = typing.flush()
        let front = typingFront
        let target = typingTarget
        typingFront = nil
        typingTarget = nil
        typingKey = nil
        guard let text = Sensitivity.redactTyped(raw), !text.isEmpty else { return }
        append(
            buildKeyboardEvent(
                type: .input, value: text, target: target, front: front, masked: true))
    }

    /// Emit a `keydown` evidence event for a shortcut ("Cmd+S") or named special key ("Enter").
    /// Shortcuts/special keys carry no typed content, so they are recorded regardless of field
    /// sensitivity (the combo name reveals nothing secret).
    private func emitKey(name: String, front: FrontApp?) {
        append(
            buildKeyboardEvent(
                type: .keydown, value: name, target: nil, front: front, masked: false))
    }

    /// A stable-ish identity for the focused element, to notice focus moving between keystrokes.
    /// Deliberately excludes the window title (some apps mutate it mid-edit, e.g. "— Edited").
    private func focusKey(_ ax: AXTargetInfo?) -> String {
        [ax?.identifier, ax?.role, ax?.label].map { $0 ?? "" }.joined(separator: "|")
    }

    private func targetForTyping(_ ax: AXTargetInfo?) -> EventTarget? {
        guard let ax else { return nil }
        return EventTarget(
            tag: ax.role, role: ax.role, accessibleName: Sensitivity.sanitize(ax.label)
        )
    }

    /// Max clipboard payload to capture on a paste (a guard against pasting megabytes of text).
    private static let clipboardCap = 4000

    /// The clipboard payload to attach to a copy/cut/paste event. Only PASTE reads the pasteboard:
    /// at capture time it holds the content being pasted. For copy/cut the app updates the clipboard
    /// only AFTER the key event, so a read here would be STALE — the copied content is instead
    /// carried by `selectedText` (the selection being copied). Length-capped; secret-masking happens
    /// in `buildEvent` against the destination field.
    private func clipboardText(for kind: EventTap.RawKind) -> String? {
        guard kind == .paste else { return nil }
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return nil }
        return String(s.prefix(Self.clipboardCap))
    }

    private func buildKeyboardEvent(
        type: EventType, value: String?, target: EventTarget?, front: FrontApp?, masked: Bool
    ) -> ActivityEvent {
        let seq = nextSequence()
        let bundle = front?.bundleID ?? "unknown"
        let application = front?.bundleID.map {
            ActivityApplicationIdentity(
                namespace: "macos.bundle-id", value: $0,
                name: front?.name, version: front?.version)
        }
        return ActivityEvent(
            sessionId: sessionId,
            eventId: Identifiers.eventId(sessionId: sessionId, sequence: seq),
            sequence: seq,
            timestamp: Timestamps.iso8601(),
            eventType: type.rawValue,
            url: "app://\(bundle)",
            application: application,
            system: front?.name,
            target: target,
            value: value,
            inputMasked: masked ? true : nil,
            labelId: currentLabelId,  // stamp the active label (nil when none is open)
            label: currentLabel,
            processId: currentProcessId,  // and its resolved Process (nil for free-text labels)
            process: currentProcessName
        )
    }

    // MARK: event construction

    private func nextSequence() -> Int {
        defer { sequence += 1 }
        return sequence
    }

    /// Build an interaction event with a PRE-ASSIGNED sequence (assigned on the tap
    /// callback, before the async AX enrichment, so ordering survives out-of-order hops).
    private func buildEvent(
        type: String, sequence seq: Int, front: FrontApp?, ax: AXTargetInfo?,
        clickCount: Int? = nil, dragEnd: CGPoint? = nil, gestureId: String? = nil,
        clipboardText: String? = nil,
        labelScope: LabelScopeSnapshot? = nil
    ) -> ActivityEvent {
        let bundle = front?.bundleID ?? "unknown"
        var target: EventTarget?
        var isSensitive: Bool?
        var selectedText: String?
        if let ax {
            let sensitive = Sensitivity.isSensitiveField(
                role: ax.role, subrole: ax.subrole, label: ax.label
            )
            isSensitive = sensitive ? true : nil
            // The selection (double-click word / drag range), never from a sensitive field.
            selectedText = sensitive ? nil : Sensitivity.sanitize(ax.selectedText)
            var box: BoundingBox?
            if let f = ax.frame {
                box = BoundingBox(
                    x: f.origin.x, y: f.origin.y, width: f.size.width, height: f.size.height
                )
            }
            target = EventTarget(
                tag: ax.role,
                role: ax.role,
                accessibleName: Sensitivity.sanitize(ax.label),
                text: sensitive ? nil : Sensitivity.sanitize(ax.value),
                boundingBox: box
            )
        }
        let application = front?.bundleID.map {
            ActivityApplicationIdentity(
                namespace: "macos.bundle-id", value: $0,
                name: front?.name, version: front?.version)
        }
        let documentURL = ObservedDocumentURL.sanitize(ax?.documentURL)
        let scope =
            labelScope
            ?? LabelScopeSnapshot(
                labelId: currentLabelId,
                label: currentLabel,
                processId: currentProcessId,
                process: currentProcessName)
        // Clipboard payload (paste): never carry it into a sensitive destination field.
        let clip = (isSensitive == true) ? nil : Sensitivity.sanitize(clipboardText)
        return ActivityEvent(
            sessionId: sessionId,
            eventId: Identifiers.eventId(sessionId: sessionId, sequence: seq),
            sequence: seq,
            timestamp: Timestamps.iso8601(),
            eventType: type,
            url: "app://\(bundle)",
            application: application,
            documentURL: documentURL,
            pageTitle: Sensitivity.sanitize(ax?.windowTitle),
            system: front?.name,
            target: target,
            selectedText: selectedText,
            clipboardText: clip,
            clickCount: clickCount,
            dragEnd: dragEnd.map { DragPoint(x: $0.x, y: $0.y) },
            gestureId: gestureId,
            isSensitive: isSensitive,
            labelId: scope.labelId,
            label: scope.label,
            processId: scope.processId,
            process: scope.process
        )
    }

    private func simpleEvent(type: EventType) -> ActivityEvent {
        let seq = nextSequence()
        return ActivityEvent(
            sessionId: sessionId,
            eventId: Identifiers.eventId(sessionId: sessionId, sequence: seq),
            sequence: seq,
            timestamp: Timestamps.iso8601(),
            eventType: type.rawValue,
            url: "app://session",
            labelId: currentLabelId,  // stamp the active label (nil when none is open)
            label: currentLabel,
            processId: currentProcessId,  // and its resolved Process (nil for free-text labels)
            process: currentProcessName
        )
    }

    // MARK: bracketed labels (start/end, mic gated to the open window)

    /// Open a bracketed label ("now I'm showing you how I do X" … "done") — the user's own
    /// declaration of what they are doing, from the panel/⌥⌘L. One label is open at a time:
    /// if another is already open it is auto-ended first. Emits a `label_start` boundary
    /// event, stamps ``currentLabelId``/``currentLabel`` onto every subsequent event, and —
    /// only here — starts the microphone (subject to permission + the "record voice during
    /// labeled activities" toggle). No-op while idle. Downstream treats the label as an
    /// authoritative activity boundary.
    func startLabel(name: String, userSelectedProcess: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCapturing, !trimmed.isEmpty else { return }
        // One active label at a time: a new label auto-ends the previous one.
        if currentLabelId != nil { endLabel() }

        // Guided capture: resolve the typed/picked text against the Area's declared inventory.
        // A picker submit is an exact name match; free text may still resolve (unique substring);
        // anything else stays a plain Explore label (nil processId — the agent never mints ids).
        // The resolved label is the CANONICAL process name so label and process.name agree.
        let pick = CaptureScope.resolveLabelPick(text: trimmed, inventory: processInventory)
        let declarationMode =
            workshopMode ? "bdm_question" : (pick.processId == nil ? "free_text" : "guided")
        let bindingResolution: String? = {
            guard let processId = pick.processId else { return nil }
            if userSelectedProcess { return "user_selected" }
            let exact = processInventory.contains {
                $0.id == processId
                    && $0.name.compare(
                        trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            return exact ? "exact_match" : "unique_substring"
        }()
        var labelExtensions: [String: JazzArchiveJSONValue] = [
            "dev.jazz.label.declarationMode": .string(declarationMode),
            // `event.label` remains the canonical process name for live compatibility. Preserve
            // the user's actual words separately so the portable label declaration is lossless.
            "dev.jazz.label.declarationText": .string(trimmed),
        ]
        if let bindingResolution {
            labelExtensions["dev.jazz.label.bindingResolution"] = .string(bindingResolution)
        }

        let labelId = Identifiers.newLabelId()
        // The boundary event carries the label fields explicitly — currentLabelId/currentLabel
        // are not set yet, so build it directly rather than through buildEvent's stamping.
        let seq = nextSequence()
        append(
            ActivityEvent(
                sessionId: sessionId,
                eventId: Identifiers.eventId(sessionId: sessionId, sequence: seq),
                sequence: seq,
                timestamp: Timestamps.iso8601(),
                eventType: EventType.labelStart.rawValue,
                url: "app://session",
                labelId: labelId,
                label: pick.label,
                processId: pick.processId,
                process: pick.processName
            ),
            extensions: labelExtensions)
        flushToSpool()  // labels are rare and high-value — make them durable immediately
        currentLabelId = labelId
        currentLabel = pick.label
        currentProcessId = pick.processId
        currentProcessName = pick.processName
        narrationReservation = nil
        coachLiveLabelContextTail?.submit(
            labelId: labelId, processId: pick.processId)

        // The mic records ONLY inside a label, and (with permission) when EITHER the "record
        // voice" toggle is on OR this is a BDM workshop — a workshop is a narrated interview, so
        // spoken answers must always be captured (mirrors how workshopMode forces screenshots).
        if workshopMode || AgentSettings.shared.captureNarration,
            Permissions.status(.microphone) == .granted
        {
            let artifactId = Identifiers.newArtifactId()
            do {
                let fileClaim = try JazzArchiveWritableFileClaim.prepare(
                    root: archiveRoot,
                    archiveId: archiveId,
                    captureId: captureId,
                    artifactId: artifactId,
                    fileExtension: "m4a")
                do {
                    let livePCMHandler: NarrationRecorder.LivePCMHandler?
                    if let audioTail = coachLiveAudioAdmissionTail,
                        let processId = pick.processId
                    {
                        livePCMHandler = { chunk in
                            audioTail.submit(
                                labelId: labelId,
                                processId: processId,
                                chunk: chunk)
                        }
                    } else {
                        livePCMHandler = nil
                    }
                    _ = try narration.start(
                        at: fileClaim.recordingURL,
                        livePCMHandler: livePCMHandler)
                    guard narration.isRecording else {
                        throw CaptureCoachSpokenAnswerError.microphoneNotRecording
                    }
                    narrationReservation = try CaptureCoachNarrationReservation(
                        labelId: labelId,
                        artifactId: artifactId)
                    narrationFileClaim = fileClaim
                } catch {
                    _ = narration.stop()
                    fileClaim.abandon()
                    throw error
                }
            } catch {
                narrationReservation = nil
                narrationFileClaim = nil
                lastError = "Narration: \(error)"
            }
        }
        scheduleLocalBaseline(for: labelId)
        if let coachPrompt { onCoachPresentation?(coachPrompt, nil) }
    }

    /// Close the open bracketed label: stop the mic, emit a `label_end` boundary event, and
    /// kick a label-scoped narration upload (per-label filename + Files tag `label:<id>`, the
    /// narration record carrying the label fields). No-op when no label is open. Called on
    /// ⌥⌘L while a label is active, on auto-end by ``startLabel(name:)``, and on stop/quit.
    @discardableResult
    func endLabel() -> String? {
        guard let labelId = currentLabelId, let labelName = currentLabel else { return nil }
        coachBaselineTask?.cancel()
        coachBaselineTask = nil
        let reservedNarration = narrationReservation
        narrationReservation = nil
        let writableNarrationClaim = narrationFileClaim
        narrationFileClaim = nil
        let spokenAnswer = pendingSpokenCoachAnswer.flatMap {
            $0.reservation.labelId == labelId ? $0 : nil
        }
        if spokenAnswer != nil { pendingSpokenCoachAnswer = nil }
        let spokenArtifactGate = spokenAnswer.map { _ in CaptureCoachArtifactGate() }
        let stoppedNarration = narration.stop()
        var narrationResult:
            (
                claimedFile: JazzArchiveClaimedFile, startedAt: String, endedAt: String
            )?
        if let stoppedNarration, let writableNarrationClaim,
            stoppedNarration.url == writableNarrationClaim.recordingURL
        {
            do {
                narrationResult = (
                    try writableNarrationClaim.seal(),
                    stoppedNarration.startedAt,
                    stoppedNarration.endedAt
                )
            } catch {
                writableNarrationClaim.abandon()
                lastError = "Narration claim: \(error)"
            }
        } else {
            writableNarrationClaim?.abandon()
        }

        // The closing boundary carries the segment's process pick too (like labelId/label).
        let processId = currentProcessId
        let processName = currentProcessName
        let seq = nextSequence()
        append(
            ActivityEvent(
                sessionId: sessionId,
                eventId: Identifiers.eventId(sessionId: sessionId, sequence: seq),
                sequence: seq,
                timestamp: Timestamps.iso8601(),
                eventType: EventType.labelEnd.rawValue,
                url: "app://session",
                labelId: labelId,
                label: labelName,
                processId: processId,
                process: processName
            ))
        flushToSpool()  // boundary event — durable immediately
        // Reserve the narration record's sequence AFTER label_end so the audio record sorts
        // after the boundary it belongs to.
        let narrationSeq = narrationResult != nil ? nextSequence() : 0

        let sid = sessionId
        currentLabelId = nil
        currentLabel = nil
        currentProcessId = nil  // the process pick is label-scoped, like the label itself
        currentProcessName = nil
        coachLiveLabelContextTail?.submit(labelId: nil, processId: nil)
        closedLabelIds.insert(labelId)
        let closedLabels = closedLabelIds
        let coachLive = coachLiveRuntime
        if let spokenAnswer, let spokenArtifactGate {
            enqueueCoachAction { coordinator in
                let persistedArtifactId = await spokenArtifactGate.wait()
                do {
                    let answer = try spokenAnswer.reservation.spokenAnswer(
                        persistedArtifactId: persistedArtifactId)
                    let proposedDate = Date()
                    var intent: CaptureCoachLiveActionProjectionIntent?
                    if let coachLive {
                        intent = try? await coachLive.preparePromptAction(
                            promptId: spokenAnswer.promptId,
                            interactionType: .answered,
                            at: proposedDate)
                    }
                    let actionDate =
                        intent.flatMap {
                            Timestamps.parse($0.clientRecordedAt)
                        } ?? proposedDate
                    let interaction = try await coordinator.answer(
                        promptId: spokenAnswer.promptId,
                        answer: answer,
                        at: actionDate,
                        interactionId: intent?.interactionId
                            ?? Identifiers.newCoachInteractionId())
                    if intent != nil {
                        await coachLive?.projectAction(interaction)
                    }
                    await coordinator.updateClosedLabelIds(closedLabels)
                } catch {
                    await coordinator.updateClosedLabelIds(closedLabels)
                    throw error
                }
            }
        } else {
            enqueueCoachAction { coordinator in
                await coordinator.updateClosedLabelIds(closedLabels)
            }
        }

        // Label-scoped audio: reserve its observation now and ingest the m4a into the canonical
        // archive. A Files uploader may project the content later; no remote file id is needed to
        // describe or commit the narration evidence.
        if let n = narrationResult {
            let artifactId = reservedNarration?.artifactId ?? Identifiers.newArtifactId()
            let narrationEvent = ActivityEvent(
                sessionId: sid,
                eventId: Identifiers.eventId(sessionId: sid, sequence: narrationSeq),
                sequence: narrationSeq,
                timestamp: n.startedAt,
                eventType: EventType.narration.rawValue,
                url: "app://session",
                labelId: labelId,
                label: labelName,
                processId: processId,
                process: processName)
            eventCount += 1
            admitJournalProducer { _ in
                .observation(
                    CaptureJournalActivityObservation(
                        event: narrationEvent,
                        artifact: CaptureJournalArtifactInput(
                            artifactId: artifactId,
                            claimedFile: n.claimedFile,
                            kind: "narration_audio",
                            mediaType: NarrationRecorder.mimeType,
                            role: "narration_audio",
                            sourceRole: "microphone_capture",
                            actorRole: "narrator",
                            captureInterval: JazzArchiveArtifactCaptureInterval(
                                startedAt: n.startedAt,
                                endedAt: n.endedAt),
                            privacy: JazzArchivePrivacy(
                                status: .captured,
                                policyVersion: "desktop-consent-v1"))))
            } onResolved: { resolution in
                if case .failed = resolution { n.claimedFile.discard() }
                guard let spokenArtifactGate else { return }
                switch resolution {
                case .persisted(_, let persistedArtifactId):
                    await spokenArtifactGate.resolve(
                        persistedArtifactId == spokenAnswer?.reservation.artifactId
                            ? persistedArtifactId : nil)
                case .failed:
                    await spokenArtifactGate.resolve(nil)
                }
            }
        } else if let spokenArtifactGate {
            Task { await spokenArtifactGate.resolve(nil) }
            lastError = String(
                describing:
                    CaptureCoachSpokenAnswerError.narrationArtifactUnavailable(
                        spokenAnswer?.reservation.artifactId ?? "unknown"))
        }
        // Return the just-closed label id so the BDM workshop orchestrator can tie a turn to this
        // segment's audio/screenshots (Files tag `label:<id>`).
        return labelId
    }

    // MARK: buffering

    private func append(
        _ event: ActivityEvent,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) {
        eventCount += 1
        admitJournalProducer { _ in
            .observation(
                CaptureJournalActivityObservation(
                    event: event,
                    extensions: extensions))
        }
    }

    /// Serialize only the durable reservation. Once `submit` returns, each producer runs
    /// concurrently and stop can await it through CaptureJournalRuntime's local drain barrier.
    private func admitJournalProducer(
        _ producer: @escaping CaptureJournalRuntime.Producer,
        onResolved: CaptureJournalRuntime.ResolutionObserver? = nil
    ) {
        guard let runtime = journalRuntime else {
            lastError = "Local archive is not ready"
            if let onResolved {
                Task {
                    await onResolved(
                        .failed(
                            reason: .captureLoss,
                            detail: "local archive is not ready"))
                }
            }
            return
        }
        let predecessor = journalAdmissionTail
        journalAdmissionTail = Task { [weak self] in
            await predecessor?.value
            do {
                _ = try await runtime.submit(producer, onResolved: onResolved)
            } catch {
                await onResolved?(
                    .failed(
                        reason: .captureLoss,
                        detail: "archive admission failed"))
                guard let self else { return }
                self.lastError = "archive admission: \(error)"
            }
        }
    }

    /// Append the in-memory buffer to the durable spool and wake the sender. The spool IS
    /// the retry queue — network failures never reach here, so there is no requeue loop;
    /// only a local disk error keeps the buffer for the next tick.
    private func flushToSpool() {
        guard activeDeliveryPolicy.usesLiveCompatibilityProjection else { return }
        let sender = self.sender
        Task { await sender.nudge() }
    }
}
