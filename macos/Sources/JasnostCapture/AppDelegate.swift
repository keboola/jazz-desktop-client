import AppKit
import Combine
import JasnostCaptureCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let controller = CaptureController()
    private let connection = KeboolaConnection()
    private let labelPanel = LabelPanelController()
    private let bdmWorkshop = BdmWorkshopController()
    private let coachPanel = CaptureCoachPanel()
    /// Drives the live BDM canvas in the main window during a workshop (set on workshop start,
    /// fed each closed segment via ``CaptureController/onSegmentReady``).
    private let bdmLiveBridge = BdmLiveBridge()
    private let updateChecker = UpdateChecker()
    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var mainModel: SessionListModel?
    private var cancellable: AnyCancellable?
    private var connectionCancellable: AnyCancellable?
    private var archiveUploadCancellable: AnyCancellable?
    /// Ticks once a second to keep the menu-bar recording indicator's elapsed time live.
    private var recTimer: Timer?
    /// Slow re-poke for the update check on long-running instances (menu-bar apps run for
    /// weeks without a relaunch). The actual fetch is throttled to once a day by the
    /// persisted stamp — this timer only asks "is it due yet?".
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An LSUIElement (menu-bar) app has no main menu by default, so ⌘C/⌘V/⌘A never reach the
        // focused text field (e.g. the Keboola token field) — paste silently does nothing. Install a
        // minimal Edit menu so the standard editing shortcuts route through the responder chain.
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Bracketed labeling: the panel reads capture state lazily; ⌥⌘L toggles a label
        // (start when none open, end the open one). The hotkey works system-wide from here on.
        labelPanel.isCapturing = { [weak self] in self?.controller.isCapturing ?? false }
        labelPanel.currentLabel = { [weak self] in self?.controller.currentLabel }
        // Guided capture: the session's declared process inventory (fetched from the Area
        // registry at Start) drives the panel's process picker; empty = Explore (free text).
        labelPanel.processInventory = { [weak self] in self?.controller.processInventory ?? [] }
        labelPanel.onSubmit = { [weak self] label, pickedProcess in
            self?.controller.startLabel(
                name: label,
                userSelectedProcess: pickedProcess)
        }
        labelPanel.onEnd = { [weak self] in self?.controller.endLabel() }
        labelPanel.registerHotKey()
        coachPanel.onAnswer = { [weak self] in self?.controller.answerCoach($0) }
        coachPanel.onSpokenAnswer = { [weak self] in self?.controller.answerCoachSpoken() }
        coachPanel.onDismiss = { [weak self] in self?.controller.dismissCoach() }
        coachPanel.onMute = { [weak self] in self?.controller.muteCoach() }
        coachPanel.onResume = { [weak self] in self?.controller.resumeCoach() }
        coachPanel.onFinishAnyway = { [weak self] in self?.controller.finishCoachAnyway() }
        controller.onCoachPresentation = { [weak self] prompt, mutedUntil in
            guard let self else { return }
            if let prompt {
                self.coachPanel.show(
                    prompt: prompt,
                    spokenAvailable: self.controller.canAnswerCoachSpoken)
            } else if let mutedUntil {
                self.coachPanel.showMuted(until: mutedUntil)
            } else {
                self.coachPanel.hide()
            }
        }
        // BDM workshop: the floating panel walks the user through the scripted interview, opening a
        // label segment per question (mic + screenshots) and closing it on Next. Wiring lives here
        // so the capture lifecycle keeps a single owner.
        bdmWorkshop.onStartCapture = { [weak self] in
            guard let self else { return false }
            return await self.controller.startBdmWorkshop()
        }
        bdmWorkshop.onAskQuestion = { [weak self] question in
            self?.controller.startLabel(name: question.text)
        }
        bdmWorkshop.onEndSegment = { [weak self] in self?.controller.endLabel() }
        bdmWorkshop.onStopCapture = { [weak self] in self?.controller.stop() }
        // Live BDM: once a workshop segment's narration audio has uploaded, push the segment (audio
        // + shown screenshots) to the embedded Data App so it runs a turn and the model grows live.
        controller.onSegmentReady = {
            [weak self] sessionId, labelId, label, audioFileId, screenshots in
            self?.bdmLiveBridge.push(
                sessionId: sessionId, labelId: labelId, label: label,
                audioFileId: audioFileId, screenshots: screenshots)
        }
        // Live BDM (the other half): once the Data App runs a turn it relays back the consultant's
        // next question (built from that answer), which the floating panel asks next — so the
        // workshop adapts to what the person says instead of walking the fixed script. The relay
        // also carries "done" (finish) and "fallback" (a failed turn -> drop to the script now).
        bdmLiveBridge.onNextQuestion = { [weak self] outcome in
            self?.bdmWorkshop.receiveAdaptiveQuestion(outcome)
        }
        rebuildMenu()
        // Re-render the menu whenever the capture state OR the Keboola connection changes (so
        // sender status / connection errors show live in the menu).
        cancellable = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.rebuildMenu()
                // The sessions sidebar refreshes on capture activity (debounced in the
                // model) — local listing only, no network polling.
                self?.mainModel?.noteCaptureActivity()
            }
        }
        connectionCancellable = connection.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }
        archiveUploadCancellable = controller.archiveUploadManager.objectWillChange.sink {
            [weak self] _ in
            DispatchQueue.main.async {
                self?.rebuildMenu()
                self?.mainModel?.reload()
            }
        }
        // The moment onboarding stores a stream endpoint, wake the sender so any spool backlog
        // (first run, or events captured while offline) ships at once rather than waiting out
        // the reconnect backoff.
        connection.onEndpointStored = { [weak self] in
            self?.controller.nudgeSender()
            // A fresh connect can satisfy the continuous-capture preconditions — start now.
            self?.autoStartCaptureIfEnabled()
        }
        // Keep the menu-bar elapsed time ticking while recording (objectWillChange only fires on
        // event/state changes, not every second).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop, so we are on the main actor at runtime.
            MainActor.assumeIsolated { self?.updateStatusTitle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recTimer = timer

        // Update check: fetch the latest GitHub release (at most once a day, silent on any
        // failure) and surface a newer version as a menu item. Launch kick + a slow timer
        // so instances that run for weeks still learn about releases.
        updateChecker.onUpdateFound = { [weak self] in self?.rebuildMenu() }
        Task { @MainActor in await self.updateChecker.checkIfDue() }
        let update = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.updateChecker.checkIfDue() }
            }
        }
        RunLoop.main.add(update, forMode: .common)
        updateTimer = update

        // Launch-time reconnect: if a token was stored on a previous run (and the user left
        // the toggle on), re-verify it in the background — refreshing the detected identity
        // and surfacing an expired token in the menu. Soft-fail, never blocks launch. The
        // spool sender drains regardless (CaptureController starts it unconditionally).
        Task { @MainActor in
            let plan = autoStartPlan(
                enabled: AgentSettings.shared.reconnectOnLaunch,
                hasStoredToken: connection.hasStoredToken
            )
            if plan == .reconnect {
                await connection.reconnectAtLaunch()
                rebuildMenu()
            }
            // Continuous capture (opt-in): once we know we're connected, start capturing
            // automatically so the user just leaves jasnost running and brackets work with labels.
            autoStartCaptureIfEnabled()
        }
    }

    /// The menu-bar item's title: a live "● 2:34 · 47" while recording, "○ Jazz" when idle.
    private func updateStatusTitle() {
        if controller.isCapturing, let started = controller.captureStartedAt {
            statusItem.button?.title = RecordingIndicator.menuBarTitle(
                elapsed: Date().timeIntervalSince(started), events: controller.eventCount)
        } else {
            statusItem.button?.title = "○ Jazz"
        }
    }

    /// Install a main menu with an Edit submenu so ⌘X/⌘C/⌘V/⌘A and right-click → Paste work in text
    /// fields. The items use the standard responder-chain selectors (nil target), so they act on
    /// whatever text field is first responder. Without this, a menu-bar app's fields can't paste.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        // App menu (conventional first slot; also gives ⌘Q a home).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit Jazz Capture", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Edit menu — the part that makes paste work.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )

        NSApp.mainMenu = mainMenu
    }

    private func rebuildMenu() {
        updateStatusTitle()

        let menu = NSMenu()
        let status = NSMenuItem(title: controller.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if controller.isCapturing, let started = controller.captureStartedAt {
            let rec = NSMenuItem(
                title: RecordingIndicator.statusLine(
                    elapsed: Date().timeIntervalSince(started),
                    events: controller.eventCount, workshop: controller.isWorkshopSession
                ),
                action: nil, keyEquivalent: ""
            )
            rec.isEnabled = false
            menu.addItem(rec)
        }
        // The open bracketed label (and thus the mic indicator — voice records ONLY while a
        // label is open). The 🔴🎙 prefix doubles as the mic-active indicator.
        if controller.isCapturing, let label = controller.currentLabel {
            let l = NSMenuItem(
                title: "🔴🎙 \(label)".prefix(70).description, action: nil, keyEquivalent: "")
            l.isEnabled = false
            menu.addItem(l)
        }
        if controller.isCapturing {
            let coach = NSMenuItem(
                title: "Coach: \(controller.coachStatus)".prefix(80).description,
                action: nil,
                keyEquivalent: "")
            coach.isEnabled = false
            menu.addItem(coach)
        }
        if let err = controller.lastError {
            let e = NSMenuItem(title: "⚠︎ \(err)".prefix(80).description, action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        let archiveDelivery = controller.archiveUploadManager
        let delivery = NSMenuItem(
            title: "Archive delivery: \(archiveDelivery.status)".prefix(90).description,
            action: nil,
            keyEquivalent: "")
        delivery.isEnabled = false
        menu.addItem(delivery)
        if let uploadError = archiveDelivery.lastError {
            let item = NSMenuItem(
                title: "⚠︎ \(uploadError)".prefix(90).description,
                action: nil,
                keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // OTLP/Files counters exist only for the explicit migration compatibility mode.
        if controller.deliveryPolicy.usesLiveCompatibilityProjection,
            controller.senderStatus.pendingCount > 0
        {
            let p = NSMenuItem(
                title: "⇪ \(controller.senderStatus.pendingCount) batch(es) waiting to ship",
                action: nil, keyEquivalent: ""
            )
            p.isEnabled = false
            menu.addItem(p)
        }
        if controller.deliveryPolicy.usesLiveCompatibilityProjection,
            let serr = controller.senderStatus.lastError
        {
            let e = NSMenuItem(title: "⚠︎ \(serr)".prefix(80).description, action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        // Narration backlog/error: clips staged on disk waiting to upload (durable — they
        // survive an offline period and a restart), and why an upload is deferred.
        if controller.deliveryPolicy.usesLiveCompatibilityProjection,
            controller.narrationStatus.pendingCount > 0
        {
            let p = NSMenuItem(
                title: "🎙 \(controller.narrationStatus.pendingCount) narration clip(s) waiting to upload",
                action: nil, keyEquivalent: ""
            )
            p.isEnabled = false
            menu.addItem(p)
        }
        if controller.deliveryPolicy.usesLiveCompatibilityProjection,
            let nerr = controller.narrationStatus.lastError
        {
            let e = NSMenuItem(title: "⚠︎ \(nerr)".prefix(80).description, action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        if controller.deliveryPolicy.usesLiveCompatibilityProjection,
            controller.artifactStatus.pendingCount > 0
        {
            let p = NSMenuItem(
                title: "⇪ \(controller.artifactStatus.pendingCount) archive artifact(s) waiting to upload",
                action: nil, keyEquivalent: "")
            p.isEnabled = false
            menu.addItem(p)
        }
        if controller.deliveryPolicy.usesLiveCompatibilityProjection,
            let artifactError = controller.artifactStatus.lastError
        {
            let item = NSMenuItem(
                title: "⚠︎ \(artifactError)".prefix(80).description,
                action: nil,
                keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let cerr = connection.lastError {
            let e = NSMenuItem(title: "⚠︎ \(cerr)".prefix(80).description, action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        // Tap re-arms: a rising count means the tap callback is too slow (the OS keeps
        // disabling it) — visible here so a capture stall is diagnosable, not silent.
        if controller.tapReArms > 0 {
            let t = NSMenuItem(
                title: "⚠︎ Event tap re-armed \(controller.tapReArms)× this session",
                action: nil, keyEquivalent: ""
            )
            t.isEnabled = false
            menu.addItem(t)
        }
        menu.addItem(.separator())

        // Not connected yet → the one actionable next step, right in the menu.
        if !connection.connected {
            let connect = NSMenuItem(
                title: "Connect Keboola (Settings)…",
                action: #selector(openSettings), keyEquivalent: ""
            )
            connect.target = self
            menu.addItem(connect)
        }

        let toggle = NSMenuItem(
            title: bdmWorkshop.isRunning
                ? "End BDM workshop"
                : (controller.isCapturing ? "Stop capture" : "Start capture"),
            action: #selector(toggleCapture), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        // The Area (scope) the next capture is anchored to (ADR 0002 / docs/AREA_MODEL_PLAN.md).
        // An Area groups related captures — downstream they share one process inventory and one
        // ontology. Picked while idle (the area is fixed once a session's events start streaming),
        // sticky across launches; "General" is the un-anchored default. Hidden mid-capture and
        // during a workshop (a workshop is itself area-agnostic for now).
        if !controller.isCapturing && !bdmWorkshop.isRunning {
            let settings = AgentSettings.shared
            let enrolledScope = settings.archiveUploadScope
            let currentName: String
            if let enrolledScope {
                currentName = enrolledScope.areaId == CaptureScope.generalAreaId
                    ? CaptureScope.generalAreaName
                    : (settings.lastAreaName.isEmpty
                        ? enrolledScope.areaId : settings.lastAreaName)
            } else {
                currentName = settings.lastAreaName.isEmpty
                    ? CaptureScope.generalAreaName : settings.lastAreaName
            }
            let area = NSMenuItem(title: "Area: \(currentName)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if enrolledScope != nil {
                let fixed = NSMenuItem(
                    title: "Fixed by device enrollment", action: nil, keyEquivalent: "")
                fixed.state = .on
                submenu.addItem(fixed)
                area.submenu = submenu
                menu.addItem(area)
            } else {
                let isGeneral = settings.lastAreaId.isEmpty

                let general = NSMenuItem(
                    title: CaptureScope.generalAreaName, action: #selector(useGeneralArea),
                    keyEquivalent: ""
                )
                general.target = self
                general.state = isGeneral ? .on : .off
                submenu.addItem(general)

                // Keep the current non-General pick listed (and checked) so staying on it is one click.
                if !isGeneral {
                    let pick = NSMenuItem(title: currentName, action: nil, keyEquivalent: "")
                    pick.state = .on
                    submenu.addItem(pick)
                }

                submenu.addItem(.separator())
                let newArea = NSMenuItem(
                    title: "New area…", action: #selector(promptNewArea), keyEquivalent: ""
                )
                newArea.target = self
                submenu.addItem(newArea)

                area.submenu = submenu
                menu.addItem(area)
            }
        }

        // Bracketed labeling — ⌥⌘L toggles. With a label open, the item ends it directly
        // (the mic stops); otherwise it opens the start panel (a hint shows while idle). Hidden
        // during a BDM workshop, which owns the label segments itself (one per question).
        if !bdmWorkshop.isRunning {
            let label: NSMenuItem
            if controller.isCapturing, let open = controller.currentLabel {
                label = NSMenuItem(
                    title: "End label — \(open)".prefix(60).description,
                    action: #selector(endLabel), keyEquivalent: "l"
                )
            } else {
                label = NSMenuItem(
                    title: "Label current task…", action: #selector(openLabelPanel),
                    keyEquivalent: "l"
                )
            }
            label.keyEquivalentModifierMask = [.option, .command]
            label.target = self
            menu.addItem(label)
        }

        // BDM workshop: a guided, narrated recording. A floating panel walks the user through the
        // interview questions; each answer (spoken + shown on screen) is recorded as its own label
        // segment, and the Business Data Model is assembled afterwards in the review app
        // ("Build BDM from recording"). Offered only while idle; "End BDM workshop" stops it.
        if !controller.isCapturing {
            // A submenu lets the user pick the workshop language before starting (the request the
            // app never asked before). The choice is persisted, so the last pick is pre-checked.
            let workshop = NSMenuItem(
                title: "Start BDM workshop session", action: nil, keyEquivalent: ""
            )
            let submenu = NSMenu()
            let current = AgentSettings.shared.bdmLanguage
            for choice in Self.bdmLanguageChoices {
                let item = NSMenuItem(
                    title: choice.label, action: #selector(startWorkshopWithLanguage(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = choice.value
                item.state = (choice.value == current) ? .on : .off
                submenu.addItem(item)
            }
            workshop.submenu = submenu
            menu.addItem(workshop)
        }

        let main = NSMenuItem(
            title: "Open Jazz…", action: #selector(openMain), keyEquivalent: "o"
        )
        main.target = self
        menu.addItem(main)

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        // A newer release exists (checked at most daily against GitHub Releases) — one
        // unobtrusive item that opens the release page in the browser. No auto-download,
        // no dialogs; absent entirely until an update is actually found.
        if let release = updateChecker.available {
            let update = NSMenuItem(
                title: "Update available — \(release.tagName)",
                action: #selector(openReleasePage), keyEquivalent: ""
            )
            update.target = self
            menu.addItem(update)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleCapture() {
        if bdmWorkshop.isRunning {
            // "Stop capture" during a workshop ends it cleanly: closes the open segment, stops
            // capture, and hides the panel (same as the panel's own End button).
            bdmWorkshop.finish()
        } else if controller.isCapturing {
            controller.stop()
        } else {
            controller.start()
        }
        rebuildMenu()
    }

    /// Start capture automatically for the continuous-capture opt-in. Called at launch (after any
    /// reconnect) and right after a connect. Confirmed-archive mode is fully offline, so a stored
    /// token is required only for the explicit live compatibility policy.
    /// Idempotent: never restarts an already-running session (which would mint a new sessionId).
    private func autoStartCaptureIfEnabled() {
        guard !controller.isCapturing else { return }
        guard
            shouldAutoStartCapture(
                continuousCapture: AgentSettings.shared.continuousCapture,
                deliveryPolicy: AgentSettings.shared.deliveryPolicy,
                hasStoredToken: connection.hasStoredToken,
                accessibilityGranted: Permissions.status(.accessibility) == .granted
            )
        else { return }
        controller.start()
        rebuildMenu()
    }

    @objc private func openLabelPanel() {
        labelPanel.show()
    }

    /// Open the newer release's GitHub page in the browser (the update menu item).
    @objc private func openReleasePage() {
        updateChecker.openReleasePage()
    }

    /// End the open bracketed label directly from the menu (mirrors ⌥⌘L while a label is open).
    @objc private func endLabel() {
        controller.endLabel()
        rebuildMenu()
    }

    /// Anchor the next capture to the default "General" Area — clears the sticky pick so the
    /// processor applies its own General default (we send no area.id at all).
    @objc private func useGeneralArea() {
        guard AgentSettings.shared.archiveUploadScope == nil else { return }
        AgentSettings.shared.lastAreaId = ""
        AgentSettings.shared.lastAreaName = ""
        rebuildMenu()
    }

    /// Prompt for a new Area name, mint a stable kebab-case id from it (``CaptureScope``), and make
    /// it the sticky pick for the next capture. Empty/cancelled leaves the current pick unchanged.
    /// The id is minted here (not downstream) so it's the one stable handle the processor groups by.
    @objc private func promptNewArea() {
        guard AgentSettings.shared.archiveUploadScope == nil else { return }
        let alert = NSAlert()
        alert.messageText = "New Area"
        alert.informativeText =
            "Name the area of work the next capture belongs to (e.g. \"Merchant Onboarding\"). "
            + "Captures in the same area share one process inventory and one ontology."
        alert.addButton(withTitle: "Use this area")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Area name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        AgentSettings.shared.lastAreaName = name
        AgentSettings.shared.lastAreaId = CaptureScope.mintAreaId(from: name)
        rebuildMenu()
    }

    /// Languages offered for a BDM workshop (menu label -> value passed to the backend, which writes
    /// the questions AND the model's wording in it). Empty value = Auto (mirror the spoken
    /// narration). Mirrors the L4 output-language choices in the SPA for consistency.
    private static let bdmLanguageChoices: [(label: String, value: String)] = [
        ("Auto (mirror narration)", ""),
        ("English", "English"),
        ("Čeština", "Czech"),
        ("Deutsch", "German"),
        ("Español", "Spanish"),
        ("Français", "French"),
    ]

    /// Pick the workshop language (persisted as the new default), then start. Every submenu item
    /// points here, carrying its language in ``representedObject``; Auto is the empty string.
    @objc private func startWorkshopWithLanguage(_ sender: NSMenuItem) {
        AgentSettings.shared.bdmLanguage = (sender.representedObject as? String) ?? ""
        startWorkshop()
    }

    /// Start a BDM workshop: the floating panel guides the scripted interview while capture records
    /// each spoken+shown answer as its own label segment. When a review app is configured, the main
    /// window also opens in LIVE mode — each closed segment is pushed to the embedded Data App so
    /// the Business Data Model assembles itself on screen as the interview proceeds (it can still be
    /// rebuilt afterwards in the review app via "Build BDM from recording").
    @objc private func startWorkshop() {
        // Adaptive questioning needs the live canvas to host the turn loop that relays each next
        // question back; without a review app the workshop stays the fully-scripted walk-through.
        let reviewAppURL = AgentSettings.shared.reviewAppURL.trimmingCharacters(in: .whitespaces)
        bdmWorkshop.adaptive = !reviewAppURL.isEmpty
        bdmWorkshop.start()
        // Mirror the workshop into the main window's live canvas — only when it actually started
        // (permissions could refuse) and a review app is configured to host the canvas.
        if bdmWorkshop.isRunning, !reviewAppURL.isEmpty {
            bdmLiveBridge.begin(sessionId: controller.currentSessionId)
            // Forward the picked language so each pushed segment's live turn runs in it.
            bdmLiveBridge.language = AgentSettings.shared.bdmLanguage
            openMain()
        }
        rebuildMenu()
    }

    @objc private func openMain() {
        let settings = AgentSettings.shared
        if mainModel == nil {
            // The sidebar reads the capture controller's own spool — instant, local.
            mainModel = SessionListModel(
                spool: controller.spool,
                archiveUploads: controller.archiveUploadManager)
        }
        if mainWindow == nil, let model = mainModel {
            let view = MainView(
                model: model,
                archiveUploads: controller.archiveUploadManager,
                liveBridge: bdmLiveBridge,
                reviewAppURL: settings.reviewAppURL,
                onMessage: { [weak self] type in
                    if type == "openSettings" {
                        Task { @MainActor in self?.openSettings() }
                    }
                }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Jazz"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.delegate = self
            mainWindow = window
        }
        // The big window is a real app surface, so become a regular app while it's open: it then
        // shows in the Dock, ⌘-Tab, and gets the menu bar. (LSUIElement keeps us menu-bar-only at
        // rest.) Reverted to .accessory when the window closes (windowWillClose).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.center()
        mainWindow?.makeKeyAndOrderFront(nil)
        mainModel?.reload()
    }

    /// When the main window closes, drop back to a menu-bar-only accessory app.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(connection: connection))
            let window = NSWindow(contentViewController: host)
            window.title = "Jazz Capture — Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 460))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)  // applicationShouldTerminate finishes capture + flushes the spool
    }

    /// Finish capture and let the spool sender settle before dying: `.terminateLater` plus a
    /// bounded drain (5s, inside ``CaptureController/shutdown(deadline:)``). The spool
    /// persists everything, so the deadline only trades promptness — never data (leftovers
    /// ship on the next launch).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await controller.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
