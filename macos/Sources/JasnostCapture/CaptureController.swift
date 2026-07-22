import AppKit
import Combine
import JasnostCaptureCore

/// Orchestrates a desktop capture session: installs the event tap + app-switch observer,
/// turns each raw interaction into a semantic ActivityEvent (AX target, redaction, sparse
/// screenshot), and appends batches to the durable ``EventSpool`` — the ``StreamSender``
/// drains the spool and ships OTLP/JSON straight to the Keboola Data Stream (no local
/// services on the capture path). Screenshots and narration audio go to Keboola Files
/// directly. All state lives on the main actor; AX enrichment runs on a utility queue so
/// the tap callback stays fast.
@MainActor
final class CaptureController: ObservableObject {
    @Published private(set) var isCapturing = false
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
    private static let axQueue = DispatchQueue(label: "dev.jasnost.ax-enrich", qos: .utility)

    private let tap = EventTap()
    private let narration = NarrationRecorder()
    /// The durable spool — also the sessions sidebar's data source (read-only there).
    let spool: EventSpool
    private let sender: StreamSender
    private let shots: ScreenshotUploader
    /// The durable narration audio uploader — stages clips on disk and ships them off the
    /// capture path, surviving an offline period or a restart (see ``NarrationUploader``).
    private let narrationUploader: NarrationUploader
    private var keboola: KeboolaClient
    private var policy = RedactionPolicy()
    private var sessionId = ""
    private var sequence = 0
    private var buffer: [ActivityEvent] = []
    private var flushTimer: Timer?
    private var appObserver: NSObjectProtocol?
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
    /// Replayable steps (clicks, app switches, typed text, shortcuts) from the current/last session.
    private(set) var replaySteps: [ReplayStep] = []
    /// The async tail of stop(): spool endSession + final flush + sender nudge. Awaited at quit.
    private var shutdownTask: Task<Void, Never>?

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
        // The stream endpoint embeds a secret, so it lives in the Keychain — read lazily per
        // drain pass so connecting in Settings takes effect without a restart.
        self.sender = StreamSender(spool: spool) {
            (try? Keychain.get(account: Keychain.Account.streamEndpoint)) ?? nil
        }
        self.shots = ScreenshotUploader(
            directory: spool.root.appendingPathComponent("shots", isDirectory: true))
        let sender = self.sender
        self.narrationUploader = NarrationUploader(
            spool: NarrationSpool(
                directory: spool.root.appendingPathComponent("narration", isDirectory: true)),
            eventSpool: spool,
            stackURL: AgentSettings.shared.kbcStackURL,
            onRecordAppended: { await sender.nudge() })
        self.keboola = KeboolaClient(stackURL: AgentSettings.shared.kbcStackURL)

        // Drain-at-launch: batches AND narration clips left over from a crash/offline period
        // ship as soon as the app is up, before any new capture begins.
        let narrationUploader = self.narrationUploader
        Task { [weak self] in
            await sender.setStatusHandler { status in
                Task { @MainActor in self?.senderStatus = status }
            }
            await sender.start()
        }
        Task { [weak self] in
            await narrationUploader.setStatusHandler { status in
                Task { @MainActor in self?.narrationStatus = status }
            }
            // Live BDM: when a clip's narration record lands, hand the segment (audio id + the
            // screenshots shown under that label) to whoever is listening (AppDelegate -> the live
            // canvas). The uploader is an actor, so hop to the main actor to read labelScreenshots.
            await narrationUploader.setSegmentReadyHandler { sessionId, labelId, label, audioFileId in
                Task { @MainActor in
                    guard let self else { return }
                    let shots = self.labelScreenshots.removeValue(forKey: labelId) ?? []
                    self.onSegmentReady?(sessionId, labelId, label, audioFileId, shots)
                }
            }
            await narrationUploader.start()
        }
    }

    // MARK: lifecycle

    func start() {
        guard !isCapturing else { return }
        // No prompts here — all permissions are granted up front in Settings → Permissions.
        // Capture just checks (preflight) and uses whatever is granted.
        guard Permissions.status(.accessibility) == .granted else {
            status = "Grant Accessibility in Settings → Permissions, then Start."
            return
        }
        let settings = AgentSettings.shared

        // Capture the whole desktop for this session, minus the privacy denylist.
        policy = RedactionPolicy(denylist: settings.denylist)
        // Screenshots if the toggle (or workshop mode) AND Screen Recording permission are on.
        captureScreenshots =
            (workshopMode || settings.captureScreenshots)
            && Permissions.status(.screenRecording) == .granted
        highlightClicks = settings.highlightClicks
        keboola = KeboolaClient(stackURL: settings.kbcStackURL)
        // Point the durable narration uploader at the current stack too (a re-connect may have
        // changed it) so any clips it ships go to the right project.
        let uploader = narrationUploader
        let stack = settings.kbcStackURL
        Task { await uploader.setStackURL(stack) }
        sessionId = Identifiers.newSessionId()
        sequence = 0
        buffer = []
        eventCount = 0
        replaySteps = []
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
        processInventory = []  // per-session cache; re-fetched below for the picked Area
        labelScreenshots.removeAll()  // per-label screenshot tracking belongs to one session

        // The session's OTLP identity (trace/span ids) is generated NOW and persisted in the
        // spool meta, so every batch — and the final span — shares the trace across crashes
        // and restarts. A spool-create failure means no durability: refuse to capture.
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
            // The Area (scope) this capture is anchored to (ADR 0002). Sticky last-pick from the
            // menu; empty = the default "General" Area, carried as nil so the processor applies
            // its own General default rather than us inventing a magic string here.
            areaId: settings.lastAreaId.isEmpty ? nil : settings.lastAreaId,
            areaName: settings.lastAreaName.isEmpty ? nil : settings.lastAreaName
        )
        do {
            try spool.createSession(meta)
        } catch {
            status = "Could not create the local event spool: \(error)"
            return
        }

        tap.onEvent = { [weak self] raw in self?.onRaw(raw) }
        tap.onReArm = { [weak self] count in
            // The tap callback runs on the main run loop, so we are on the main actor.
            MainActor.assumeIsolated { self?.tapReArms = count }
        }
        guard tap.start() else {
            status = "Could not start the event tap (Accessibility permission?)."
            return
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.onAppActivated(note) }
        }

        append(simpleEvent(type: .sessionStart))

        // The mic is NEVER started here: it records only inside a bracketed label
        // (startLabel → endLabel). Plain capture is mic-off by design.

        flushTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushToSpool() }
        }
        isCapturing = true
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
                let inventory = await RegistryFetcher.fetchInventory(areaId: areaId, stackURL: stack)
                // Only publish into the session the fetch was started for.
                guard let self, self.isCapturing, self.sessionId == sid else { return }
                self.processInventory = inventory
            }
        }
    }

    /// Start a capture session in BDM-workshop mode: a narrated, guided interview. The mic
    /// (inside each question's label segment) and dense focused-window screenshots are forced on
    /// regardless of the user's toggles, and the session is tagged ``session.kind="bdm-workshop"``
    /// so the processor recognises it as a workshop. The question walk-through + segment lifecycle
    /// is driven by ``BdmWorkshopController``.
    func startBdmWorkshop() {
        workshopMode = true
        start()
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
        flushToSpool()  // final flush — events are durable on disk from here

        let endedAt = Timestamps.iso8601()
        let sid = sessionId

        isCapturing = false
        captureStartedAt = nil
        highlight.hide()
        status = "Stopped — \(eventCount) events"
        workshopMode = false

        // The async tail: close the session for the EVENTS path (endSession → span ships once
        // batches drain). The spool keeps everything safe if the app dies mid-way; shutdown()
        // awaits this task at quit. Narration is NOT handled here anymore — it is scoped to a
        // label and ships from ``endLabel()`` (called just above if a label was still open).
        shutdownTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.spool.endSession(sessionId: sid, endedAt: endedAt)
            } catch {
                self.lastError = "spool endSession: \(error)"
            }
            // Sweep stragglers from in-flight enrichment tasks — but ONLY if no new capture
            // started during the async tail above. If one did, `self.sessionId` is now the new
            // session and its own flush path owns the buffer; flushing here would misfile its
            // events. Old-session stragglers were already auto-flushed by append() while
            // !isCapturing, before any new session could begin.
            if self.sessionId == sid { self.flushToSpool() }
            await self.sender.nudge()
        }
    }

    /// Wake the background sender AND the narration uploader from outside a capture session —
    /// e.g. right after onboarding stores the stream endpoint/token, so a backlog from an
    /// offline/first-run period (events AND staged audio) ships immediately instead of waiting
    /// out the (up to 60s) reconnect backoff.
    func nudgeSender() {
        let sender = self.sender
        let narrationUploader = self.narrationUploader
        Task { await sender.nudge() }
        Task { await narrationUploader.nudge() }
    }

    /// Finish capture and give the background work a bounded window to settle. Called from
    /// applicationShouldTerminate — the spool persists everything, so hitting the deadline
    /// is safe (leftovers ship on the next launch).
    func shutdown(deadline: TimeInterval = CaptureController.shutdownDeadline) async {
        if isCapturing { stop() }
        await shutdownTask?.value
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let senderIdle = await sender.pendingWork() == 0
            let shotsIdle = await shots.pending() == 0
            // Narration clips are durable, so a slow upload that misses the deadline just ships
            // on the next launch — waiting here only lets a quick one finish before quit.
            let narrationIdle = await narrationUploader.pending() == 0
            if senderIdle && shotsIdle && narrationIdle { return }
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
        let ownPID = ownPID  // captured for the background hit-test (no `self` access off-main)
        Self.axQueue.async { [weak self] in
            // Fast path (off-main, IPC-safe): hit-test only the topmost FOREIGN app under the point.
            // We never hit-test system-wide off-main — that can resolve our OWN window (e.g. the
            // click-through highlight overlay) in-process via AppKit's main-thread-only
            // NSAccessibility and crash (#ax-crash).
            let foreignPID = Accessibility.foreignWindowPID(at: location, excluding: ownPID)
            let foreignAX = foreignPID.flatMap {
                Accessibility.target(inApp: $0, atScreenPoint: location)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Fallback (main thread, where in-process AX is safe): if no foreign window was
                    // identified off-main — the click is on our own UI, or CGWindowList is
                    // restricted without Screen Recording (macOS 15+) — hit-test system-wide here so
                    // AX enrichment is not silently lost.
                    let ax =
                        foreignPID == nil
                        ? Accessibility.target(atScreenPoint: location) : foreignAX
                    self.finishInteraction(
                        type: type, kind: kind, sequence: seq, sessionId: sid,
                        front: front, ax: ax)
                }
            }
        }
    }

    /// Second half of an interaction, after AX enrichment came back (main actor).
    private func finishInteraction(
        type: EventType, kind: EventTap.RawKind, sequence seq: Int, sessionId sid: String,
        front: FrontApp?, ax: AXTargetInfo?
    ) {
        // The session may have been stopped + restarted while we enriched — an event built
        // now would carry the wrong session id. Drop it (the pre-assigned sequence just gaps).
        guard sid == sessionId else { return }

        // Attribute the interaction to the app that OWNS the target element, not the Workspace
        // "frontmost app": menu-bar extras and Spotlight don't change frontmost, so a click on our
        // own tray menu would otherwise be mis-attributed to (and replayed into) the prior app.
        let owner = effectiveFront(ax: ax, fallback: front)
        // Ignore jasnost's own UI (menu bar, main window) entirely.
        if owner?.pid == ownPID { return }

        // Show the user (and any screen recording) exactly where they clicked.
        if highlightClicks, isCapturing, kind == .click || kind == .rightClick, let f = ax?.frame {
            highlight.flash(axFrame: f)
        }
        // Record a replayable step for clicks (re-found later by identifier / role + name).
        if kind == .click || kind == .rightClick {
            replaySteps.append(
                ReplayStep(
                    kind: .click, bundleID: owner?.bundleID, role: ax?.role, name: ax?.label,
                    boundingBox: ax?.frame, label: "Click \(ax?.label ?? ax?.role ?? "element")",
                    identifier: ax?.identifier, index: ax?.index
                )
            )
        }
        let event = buildEvent(type: type.rawValue, sequence: seq, front: owner, ax: ax)

        // Workshop mode grabs a focused-window screenshot on every interaction (materials are
        // shown continuously, so capture them densely); normal capture shoots only on clicks.
        let wantShot = workshopMode || kind == .click || kind == .rightClick
        if captureScreenshots && wantShot {
            captureScreenshotAndAppend(event, bundleID: owner?.bundleID, targetRect: ax?.frame)
        } else {
            append(event)
        }
    }

    /// Prepare-early screenshot flow: capture the focused window as PNG, ask Files for a
    /// slot (bounded budget — a slow network must not delay the event), stamp the event with
    /// the `screenshot_id`, and hand the bytes to the background uploader. Any failure
    /// appends the event without a screenshotId and drops the shot (the event still ships;
    /// only the screenshot is lost).
    private func captureScreenshotAndAppend(
        _ event: ActivityEvent, bundleID: String?, targetRect: CGRect?
    ) {
        let sid = sessionId
        let keboola = self.keboola
        let shots = self.shots
        Task { [weak self] in
            let shot = await ScreenCapture.focusedWindowShot(bundleID: bundleID, targetRect: targetRect)
            guard let self else { return }
            var enriched = event
            // Gate the UPLOAD (not the event) on a meaningful visual change: skip a frame that's
            // near-identical to the last one we kept this session — repeated clicks in the same
            // view shouldn't each cost a Files upload. Dedup is per-session, so only consult and
            // update lastShotHash while still on `sid`.
            let sameSession = self.sessionId == sid
            if let shot {
                let isDup =
                    sameSession
                    && (self.lastShotHash.map {
                        PerceptualHash.hammingDistance(shot.hash, $0) <= Self.shotDedupThreshold
                    } ?? false)
                if !isDup {
                    // Record the kept frame's hash before the (awaited) upload, so dedup tracks the
                    // screen state regardless of whether the upload later succeeds.
                    if sameSession { self.lastShotHash = shot.hash }
                    // Files name/tag convention the processor's discovery relies on
                    // (jasnost-<session>-<ts>.jpg, tags jasnost + session:<id>).
                    let name = "jasnost-\(sid)-\(Int(Date().timeIntervalSince1970)).jpg"
                    let prepared = try? await withTimeout(seconds: Self.prepareBudget) {
                        try await keboola.prepareFile(
                            name: name, tags: ["jasnost", "session:\(sid)"], isPermanent: true)
                    }
                    if let prepared, let gcs = prepared.gcsUploadParams {
                        enriched.screenshotId = String(prepared.id)
                        // Track the shot under its label (stamped at build time) so a live BDM
                        // workshop can hand the segment's screenshots to its turn. Best-effort:
                        // only shots that finished preparing before the segment's audio upload.
                        if self.sessionId == sid, let lid = enriched.labelId {
                            self.labelScreenshots[lid, default: []].append(String(prepared.id))
                        }
                        await shots.enqueue(
                            data: shot.data, fileId: prepared.id, params: gcs,
                            contentType: "image/jpeg")
                    }
                }
            }
            // If a NEW session started while we worked, write straight to the old session's
            // spool dir — the event must not leak into the new session's batches.
            if self.sessionId == sid {
                self.append(enriched)
            } else {
                _ = try? self.spool.appendBatch(sessionId: sid, events: [enriched])
                await self.sender.nudge()
            }
        }
    }

    private func onAppActivated(_ note: Notification) {
        guard isCapturing,
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let front = FrontApp(
            bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier
        )
        guard policy.isCaptureAllowed(bundleID: front.bundleID) else { return }
        flushTyping()  // switching apps ends any in-progress typing run
        if front.bundleID != Bundle.main.bundleIdentifier {
            replaySteps.append(
                ReplayStep(
                    kind: .navigate, bundleID: front.bundleID, role: nil, name: nil,
                    boundingBox: nil,
                    label: "Switch to \(front.name ?? front.bundleID ?? "app")"
                )
            )
        }
        append(buildEvent(type: EventType.navigate.rawValue, sequence: nextSequence(), front: front, ax: nil))
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
        let action = KeyClassifier.classify(
            keycode: key.keycode, characters: key.characters,
            command: key.flags.contains(.maskCommand), control: key.flags.contains(.maskControl),
            option: key.flags.contains(.maskAlternate), shift: key.flags.contains(.maskShift)
        )
        switch action {
        case let .text(s):
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
        case let .special(name):
            flushTyping()
            emitKey(name: name, front: keyFront)
        case let .shortcut(combo):
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
        return FrontApp(bundleID: ax.ownerBundleID, name: ax.ownerName, pid: pid)
    }

    /// The owning app of the clicked element when known, else the Workspace frontmost app.
    private func effectiveFront(ax: AXTargetInfo?, fallback: FrontApp?) -> FrontApp? {
        frontFromFocus(ax) ?? fallback
    }

    /// Commit the accumulated typing as one redacted `input` event (and a `.type` replay step).
    private func flushTyping() {
        guard !typing.isEmpty else { return }
        let raw = typing.flush()
        let front = typingFront
        let target = typingTarget
        typingFront = nil
        typingTarget = nil
        typingKey = nil
        guard let text = Sensitivity.redactTyped(raw), !text.isEmpty else { return }
        append(buildKeyboardEvent(type: .input, value: text, target: target, front: front, masked: true))
        guard front?.bundleID != Bundle.main.bundleIdentifier else { return }
        replaySteps.append(
            ReplayStep(
                kind: .type, bundleID: front?.bundleID, role: target?.role,
                name: target?.accessibleName, boundingBox: nil, label: "Type “\(text.prefix(30))”",
                text: text
            )
        )
    }

    /// Emit a `keydown` event for a shortcut ("Cmd+S") or named special key ("Enter"), plus a
    /// replay step. Shortcuts/special keys carry no typed content, so they are recorded regardless of
    /// field sensitivity (the combo name reveals nothing secret).
    private func emitKey(name: String, front: FrontApp?) {
        append(buildKeyboardEvent(type: .keydown, value: name, target: nil, front: front, masked: false))
        guard front?.bundleID != Bundle.main.bundleIdentifier else { return }
        let isShortcut = name.contains("+")
        replaySteps.append(
            ReplayStep(
                kind: isShortcut ? .shortcut : .key, bundleID: front?.bundleID, role: nil,
                name: name, boundingBox: nil, label: isShortcut ? name : "Press \(name)"
            )
        )
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

    private func buildKeyboardEvent(
        type: EventType, value: String?, target: EventTarget?, front: FrontApp?, masked: Bool
    ) -> ActivityEvent {
        let seq = nextSequence()
        let bundle = front?.bundleID ?? "unknown"
        return ActivityEvent(
            sessionId: sessionId,
            eventId: Identifiers.eventId(sessionId: sessionId, sequence: seq),
            sequence: seq,
            timestamp: Timestamps.iso8601(),
            eventType: type.rawValue,
            url: "app://\(bundle)",
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
        type: String, sequence seq: Int, front: FrontApp?, ax: AXTargetInfo?
    ) -> ActivityEvent {
        let bundle = front?.bundleID ?? "unknown"
        var target: EventTarget?
        var isSensitive: Bool?
        if let ax {
            let sensitive = Sensitivity.isSensitiveField(
                role: ax.role, subrole: ax.subrole, label: ax.label
            )
            isSensitive = sensitive ? true : nil
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
        return ActivityEvent(
            sessionId: sessionId,
            eventId: Identifiers.eventId(sessionId: sessionId, sequence: seq),
            sequence: seq,
            timestamp: Timestamps.iso8601(),
            eventType: type,
            url: "app://\(bundle)",
            pageTitle: Sensitivity.sanitize(ax?.windowTitle),
            system: front?.name,
            target: target,
            isSensitive: isSensitive,
            labelId: currentLabelId,  // stamp the active label (nil when none is open)
            label: currentLabel,
            processId: currentProcessId,  // and its resolved Process (nil for free-text labels)
            process: currentProcessName
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
    func startLabel(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCapturing, !trimmed.isEmpty else { return }
        // One active label at a time: a new label auto-ends the previous one.
        if currentLabelId != nil { endLabel() }

        // Guided capture: resolve the typed/picked text against the Area's declared inventory.
        // A picker submit is an exact name match; free text may still resolve (unique substring);
        // anything else stays a plain Explore label (nil processId — the agent never mints ids).
        // The resolved label is the CANONICAL process name so label and process.name agree.
        let pick = CaptureScope.resolveLabelPick(text: trimmed, inventory: processInventory)

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
            ))
        flushToSpool()  // labels are rare and high-value — make them durable immediately
        currentLabelId = labelId
        currentLabel = pick.label
        currentProcessId = pick.processId
        currentProcessName = pick.processName

        // The mic records ONLY inside a label, and (with permission) when EITHER the "record
        // voice" toggle is on OR this is a BDM workshop — a workshop is a narrated interview, so
        // spoken answers must always be captured (mirrors how workshopMode forces screenshots).
        if workshopMode || AgentSettings.shared.captureNarration,
            Permissions.status(.microphone) == .granted
        {
            do { try narration.start() } catch { lastError = "Narration: \(error)" }
        }
    }

    /// Close the open bracketed label: stop the mic, emit a `label_end` boundary event, and
    /// kick a label-scoped narration upload (per-label filename + Files tag `label:<id>`, the
    /// narration record carrying the label fields). No-op when no label is open. Called on
    /// ⌥⌘L while a label is active, on auto-end by ``startLabel(name:)``, and on stop/quit.
    @discardableResult
    func endLabel() -> String? {
        guard let labelId = currentLabelId, let labelName = currentLabel else { return nil }
        let narrationResult = narration.stop()

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

        // Label-scoped audio: stage it into the durable narration spool and let the background
        // uploader ship it. Staging on disk is what makes it crash/offline-safe — a failed
        // upload is retried, even across a restart, and is NEVER dropped (only retention
        // eviction can, and that's surfaced). Contrast the old best-effort give-up-and-delete.
        if let n = narrationResult {
            let meta = NarrationSpool.PendingNarration(
                sessionId: sid, labelId: labelId, label: labelName, sequence: narrationSeq,
                startedAt: n.startedAt, stagedAt: Timestamps.iso8601(),
                processId: processId, processName: processName)
            let uploader = narrationUploader
            let audioURL = n.url
            Task { @MainActor [weak self] in
                let evicted = await uploader.enqueue(audioURL: audioURL, meta: meta)
                if !evicted.isEmpty {
                    self?.lastError =
                        "Narration spool full — dropped \(evicted.count) oldest clip(s) to make room"
                }
            }
        }
        // Return the just-closed label id so the BDM workshop orchestrator can tie a turn to this
        // segment's audio/screenshots (Files tag `label:<id>`).
        return labelId
    }

    // MARK: buffering

    private func append(_ event: ActivityEvent) {
        buffer.append(event)
        eventCount += 1
        // After stop, the periodic flush timer is gone — write stragglers (late screenshot /
        // AX enrichment tasks) through immediately so they still land in the spool.
        if !isCapturing { flushToSpool() }
    }

    /// Append the in-memory buffer to the durable spool and wake the sender. The spool IS
    /// the retry queue — network failures never reach here, so there is no requeue loop;
    /// only a local disk error keeps the buffer for the next tick.
    private func flushToSpool() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        do {
            try spool.appendBatch(sessionId: sessionId, events: batch)
            buffer.removeAll()
            let sender = self.sender
            Task { await sender.nudge() }
        } catch {
            lastError = "spool write: \(error)"
        }
    }
}
