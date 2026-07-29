import AppKit
import Carbon.HIToolbox
import JasnostCaptureCore
import SwiftUI

/// Bracketed labeling: a small floating panel ("Now doing: ___") reachable from the menu bar
/// and via the global hotkey ⌥⌘L (Carbon `RegisterEventHotKey` — works system-wide and needs
/// no extra TCC permission). ⌥⌘L TOGGLES: with no label open it shows the start field
/// (``CaptureController/startLabel(name:)``); with a label open it ends it
/// (``CaptureController/endLabel()``) without showing the panel. A label is the window the mic
/// records in. While idle (not capturing) the field is disabled with a hint — continuous
/// capture isn't built yet, so labeling happens inside an explicit Start/Stop session.
@MainActor
final class LabelPanelController: NSObject {
    /// Carbon four-char signature identifying our hotkey registration ("jsnl").
    private static let hotKeySignature: OSType = {
        var result: OSType = 0
        for byte in "jsnl".utf8 { result = (result << 8) | OSType(byte) }
        return result
    }()
    /// Panel placement: centered horizontally, this far below the menu bar — near where the
    /// user's eye already is (Spotlight-like), without covering the work area's center.
    private static let topOffset: CGFloat = 60

    /// Wiring to the capture side — injected by AppDelegate so this stays UI-only.
    var isCapturing: () -> Bool = { false }
    var currentLabel: () -> String? = { nil }
    /// Guided capture: the current session's declared process inventory (empty = Explore mode,
    /// the classic free-text field). Read lazily on every show, like the capture state.
    var processInventory: () -> [ProcessChoice] = { [] }
    /// Start a new bracketed label with the given name.
    /// The Boolean distinguishes an explicit registry-picker choice from free text that happened
    /// to resolve to the same Process. That provenance is preserved in `labels.ndjson`.
    var onSubmit: (String, Bool) -> Void = { _, _ in }
    /// End the open bracketed label.
    var onEnd: () -> Void = {}

    private var panel: NSPanel?
    private let model = LabelPanelModel()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Register the global hotkey ⌥⌘L. Call once at launch; safe to call again (no-op).
    func registerHotKey() {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The C callback can't capture context — the controller rides in as userData.
        // Carbon dispatches on the main event loop, so we are on the main actor at runtime.
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let controller = Unmanaged<LabelPanelController>.fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated { controller.toggle() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L), UInt32(optionKey | cmdKey), hotKeyID,
            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    /// ⌥⌘L is a toggle: with a label open, end it immediately (no panel — the mic stops at
    /// once); with no label open, show the start field. If the panel is already up, dismiss it.
    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        if isCapturing(), currentLabel() != nil {
            onEnd()
            return
        }
        show()
    }

    /// Show the panel (creating it lazily) and focus the text field. While idle, beep —
    /// audible feedback that the hotkey worked but there is nothing to label yet (the panel
    /// still opens, showing the hint).
    func show() {
        model.isCapturing = isCapturing()
        model.currentLabel = currentLabel()
        model.text = ""
        // Guided mode: offer the Area's declared processes when the registry produced any.
        // Default to the first process (the guided flow); "Something else…" is the free-text out.
        model.inventory = processInventory()
        model.selectedProcessId = model.inventory.first?.id ?? ""
        if !model.isCapturing { NSSound.beep() }
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if let screen = NSScreen.main {
            // Near the top of the active screen, centered — Spotlight-like.
            let frame = panel.frame
            panel.setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - frame.width / 2,
                    y: screen.visibleFrame.maxY - frame.height - Self.topOffset))
        }
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1  // tells the SwiftUI view to focus the field
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        model.onSubmit = { [weak self] label, pickedProcess in
            self?.onSubmit(label, pickedProcess)
            self?.close()
        }
        model.onEnd = { [weak self] in
            self?.onEnd()
            self?.close()
        }
        model.onClose = { [weak self] in self?.close() }
        let host = NSHostingController(rootView: LabelPanelView(model: model))
        let panel = NSPanel(contentViewController: host)
        panel.title = "Label current task"
        // Non-activating: the panel takes keystrokes WITHOUT activating jasnost, so the
        // user's work app keeps focus context and capture attribution stays clean (typing
        // into our own UI is ignored by the keystroke pipeline via ownPID anyway).
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Follow the user to the active Space (incl. full-screen apps) — labeling happens
        // mid-work, wherever that is.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }

    deinit {
        // App-lifetime object; unregister defensively anyway (Carbon handles are process-global).
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

/// Bridge between the AppKit panel and its SwiftUI content.
@MainActor
final class LabelPanelModel: ObservableObject {
    @Published var text = ""
    @Published var isCapturing = false
    /// The open bracketed label's name, or nil when none is open — drives start-vs-end UI.
    @Published var currentLabel: String?
    /// Guided capture: the Area's declared processes for this session. Empty = Explore mode
    /// (free-text only, the panel's classic behavior).
    @Published var inventory: [ProcessChoice] = []
    /// The picker selection: a process id from ``inventory``, or "" for "Something else…"
    /// (free text). Only meaningful while ``inventory`` is non-empty.
    @Published var selectedProcessId = ""
    /// Incremented on every show so the view re-focuses the field (onAppear fires only once).
    @Published var focusToken = 0
    var onSubmit: (String, Bool) -> Void = { _, _ in }
    var onEnd: () -> Void = {}
    var onClose: () -> Void = {}
}

struct LabelPanelView: View {
    @ObservedObject var model: LabelPanelModel
    @FocusState private var fieldFocused: Bool

    /// A label is open (we are inside a bracketed segment, mic recording).
    private var labelOpen: Bool {
        model.isCapturing && (model.currentLabel?.isEmpty == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill").foregroundStyle(.tint)
                Text(labelOpen ? "Recording" : "Now doing").font(.headline)
                Spacer()
                Text("⌥⌘L").font(.caption2).foregroundStyle(.secondary)
            }
            if labelOpen {
                activeLabelContent
            } else {
                startContent
            }
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusToken) { fieldFocused = true }
    }

    /// A label is open: show what's being recorded and offer to end it.
    @ViewBuilder private var activeLabelContent: some View {
        Label("\(model.currentLabel ?? "")", systemImage: "mic.fill")
            .foregroundStyle(.red)
            .lineLimit(1)
            .truncationMode(.tail)
        Text("Voice is recording for this label. End it when you're done — the mic stops.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Close") { model.onClose() }
                .keyboardShortcut(.cancelAction)
            Button("End label") { model.onEnd() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Guided mode: capturing, and the Area's registry declared at least one process. The panel
    /// then offers a picker; Explore (empty inventory) keeps the classic free-text-only field.
    private var guided: Bool {
        model.isCapturing && !model.inventory.isEmpty
    }

    /// The process picked in Guided mode, or nil when "Something else…" (free text) is chosen.
    private var pickedProcess: ProcessChoice? {
        guard guided, !model.selectedProcessId.isEmpty else { return nil }
        return model.inventory.first { $0.id == model.selectedProcessId }
    }

    /// No label open: the start field (capturing) or a "start a session first" hint (idle).
    /// In Guided mode a process picker comes first, with free text as the explicit fallback.
    @ViewBuilder private var startContent: some View {
        if guided {
            Picker("Process", selection: $model.selectedProcessId) {
                ForEach(model.inventory, id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
                Divider()
                Text("Something else…").tag("")
            }
            .labelsHidden()
        }
        if pickedProcess == nil {
            TextField("e.g. Invoice approval for Acme", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .disabled(!model.isCapturing)
                .onSubmit { submit() }
        }
        if !model.isCapturing {
            // The disabled-state hint: labels live INSIDE an explicit Start/Stop session
            // (continuous always-on capture isn't built yet).
            Label(
                "Not capturing — start a session first, then label what you're doing.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if guided {
            Text("Pick the process you're demonstrating — or describe it freely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Starts a labeled segment and records voice until you end it (⌥⌘L).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            Spacer()
            Button("Cancel") { model.onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Start label") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isCapturing || (pickedProcess == nil && trimmed.isEmpty))
        }
    }

    private var trimmed: String {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard model.isCapturing else { return }
        // A picked process submits its CANONICAL name — the controller's resolver then
        // exact-matches it, so the picker and free text share one resolution path.
        let label = pickedProcess?.name ?? trimmed
        guard !label.isEmpty else { return }
        model.onSubmit(label, pickedProcess != nil)
        model.currentLabel = label
        model.text = ""
    }
}
