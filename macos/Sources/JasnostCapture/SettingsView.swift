import AppKit
import JasnostCaptureCore
import SwiftUI

/// Mirrors AgentSettings (UserDefaults) + live TCC permission status for the settings window.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var captureScreenshots: Bool {
        didSet { AgentSettings.shared.captureScreenshots = captureScreenshots }
    }
    @Published var captureNarration: Bool {
        didSet { AgentSettings.shared.captureNarration = captureNarration }
    }
    @Published var captureCoachLive: Bool {
        didSet { AgentSettings.shared.captureCoachLive = captureCoachLive }
    }
    @Published var highlightClicks: Bool {
        didSet { AgentSettings.shared.highlightClicks = highlightClicks }
    }
    @Published var userEmail: String { didSet { AgentSettings.shared.userEmail = userEmail } }
    @Published var instanceName: String {
        didSet { AgentSettings.shared.instanceName = instanceName }
    }
    @Published var reviewAppURL: String {
        didSet { AgentSettings.shared.reviewAppURL = reviewAppURL }
    }
    @Published var guidedExecutionURL: String {
        didSet {
            AgentSettings.shared.guidedExecutionURL = guidedExecutionURL
            invalidateGuidedCredentialIfEndpointChanged()
        }
    }
    /// Scoped Jazz credential is write-only in the UI and persisted exclusively in Keychain.
    @Published var guidedExecutionToken = ""
    @Published private(set) var guidedExecutionCredentialStatus: String?
    @Published var reconnectOnLaunch: Bool {
        didSet { AgentSettings.shared.reconnectOnLaunch = reconnectOnLaunch }
    }
    @Published var continuousCapture: Bool {
        didSet { AgentSettings.shared.continuousCapture = continuousCapture }
    }
    @Published var deliveryPolicy: JazzCaptureDeliveryPolicy {
        didSet { AgentSettings.shared.deliveryPolicy = deliveryPolicy }
    }
    /// The non-master token typed into the legacy Secure field — never persisted here; written to
    /// the Keychain (after it verified) by ``KeboolaConnection/connect(token:)``.
    @Published var kbcToken: String = ""
    /// The manually pasted, already-provisioned stream URL — Keychain-bound, never persisted here.
    @Published var streamURL: String = ""
    /// The pasted one-time bootstrap or signed enrollment bundle — consumed by
    /// ``KeboolaConnection/importEnrollmentReveal`` and never persisted in this UI store.
    @Published var bundleText: String = ""
    /// Apps excluded from capture (everything else IS captured).
    @Published var denylist: [String]
    /// Live TCC status, polled while the window is open so it updates after the user grants.
    @Published var permissions: [Permission: PermissionStatus] = [:]

    private var pollTimer: Timer?

    init() {
        let s = AgentSettings.shared
        captureScreenshots = s.captureScreenshots
        captureNarration = s.captureNarration
        captureCoachLive = s.captureCoachLive
        highlightClicks = s.highlightClicks
        userEmail = s.userEmail
        instanceName = s.instanceName
        reviewAppURL = s.reviewAppURL
        guidedExecutionURL = s.guidedExecutionURL
        if let stored =
            (try? Keychain.get(account: Keychain.Account.guidedExecutionToken)) ?? nil
        {
            let configured = GuidedExecutionEndpointBinding.normalize(s.guidedExecutionURL)
            let bound = GuidedExecutionEndpointBinding.boundEndpoint(storedValue: stored)
            guidedExecutionCredentialStatus =
                configured?.absoluteString == bound?.absoluteString
                ? "A scoped credential is stored and bound to this endpoint."
                : "The stored guided credential is unbound or belongs to another endpoint; save it again."
        } else {
            guidedExecutionCredentialStatus = nil
        }
        reconnectOnLaunch = s.reconnectOnLaunch
        continuousCapture = s.continuousCapture
        deliveryPolicy = s.deliveryPolicy
        denylist = s.denylist.sorted()
        refreshPermissions()
    }

    func refreshPermissions() {
        var map: [Permission: PermissionStatus] = [:]
        for permission in Permission.allCases { map[permission] = Permissions.status(permission) }
        permissions = map
    }

    func startPolling() {
        refreshPermissions()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func exclude(_ bundleID: String) {
        guard !bundleID.isEmpty, !denylist.contains(bundleID) else { return }
        denylist.append(bundleID)
        denylist.sort()
        AgentSettings.shared.denylist = Set(denylist)
    }

    func include(_ bundleID: String) {
        denylist.removeAll { $0 == bundleID }
        AgentSettings.shared.denylist = Set(denylist)
    }

    func saveGuidedExecutionCredential() {
        do {
            guard let endpoint = GuidedExecutionEndpointBinding.normalize(guidedExecutionURL)
            else {
                guidedExecutionCredentialStatus =
                    "Use an HTTPS governance API base URL without credentials or query parameters."
                return
            }
            let credential = guidedExecutionToken.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !credential.isEmpty else {
                guidedExecutionCredentialStatus = "The scoped credential cannot be empty."
                return
            }
            guidedExecutionURL = endpoint.absoluteString
            try Keychain.set(
                GuidedExecutionEndpointBinding.encodeCredential(
                    token: credential, endpoint: endpoint),
                account: Keychain.Account.guidedExecutionToken)
            guidedExecutionToken = ""
            guidedExecutionCredentialStatus =
                "Scoped credential saved in Keychain and bound to this endpoint."
        } catch {
            guidedExecutionCredentialStatus = "Could not save guided credential: \(error)"
        }
    }

    func removeGuidedExecutionCredential() {
        do {
            try Keychain.delete(account: Keychain.Account.guidedExecutionToken)
            guidedExecutionToken = ""
            guidedExecutionCredentialStatus = "Guided execution credential removed."
        } catch {
            guidedExecutionCredentialStatus = "Could not remove guided credential: \(error)"
        }
    }

    private func invalidateGuidedCredentialIfEndpointChanged() {
        guard
            let stored =
                (try? Keychain.get(account: Keychain.Account.guidedExecutionToken)) ?? nil
        else { return }
        let configured = GuidedExecutionEndpointBinding.normalize(guidedExecutionURL)
        let bound = GuidedExecutionEndpointBinding.boundEndpoint(storedValue: stored)
        guard configured?.absoluteString != bound?.absoluteString else { return }
        do {
            try Keychain.delete(account: Keychain.Account.guidedExecutionToken)
            guidedExecutionToken = ""
            guidedExecutionCredentialStatus =
                "Endpoint changed; the previously bound guided credential was removed."
        } catch {
            guidedExecutionCredentialStatus =
                "Endpoint changed, but the old guided credential could not be removed: \(error)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var connection: KeboolaConnection
    @StateObject private var store = SettingsStore()
    @State private var picked = ""
    /// Whether the legacy developer fallback is expanded. Collapsed by default; it accepts only a
    /// non-master token and an existing sink-backed endpoint, and never provisions infrastructure.
    @State private var showTokenFallback = false

    var body: some View {
        Form {
            Section("Permissions") {
                Text("Grant all three here so capturing never interrupts you with prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Permission.allCases) { permission in
                    permissionRow(permission)
                }
                Button("Request all missing") { Permissions.requestAllMissing() }
                if needsRelaunch {
                    Divider()
                    Text(
                        "Toggled Accessibility or Screen Recording ON in System Settings but it "
                            + "still shows ⚠ above? macOS applies those two only to a freshly "
                            + "launched app — quit and reopen Jazz Capture."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Quit & Reopen") { Permissions.relaunch() }
                }
            }
            Section("Keboola") {
                Text(
                    "Import the enrollment bundle your Jazz admin generated for this device — it "
                        + "carries a device-scoped, expiring token and Jazz Archive routing, so "
                        + "no master token ever lives on this laptop. Capture works offline and "
                        + "only a confirmed archive is delivered — no local services."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if connection.connected {
                    connectedSummary
                } else {
                    bundleImportFields
                    tokenFallbackDisclosure
                }
                if showSteps {
                    ForEach(connection.steps) { step in
                        stepRow(step)
                    }
                }
                if connection.needsStreamURL {
                    streamURLFields
                }
                TextField("Your email (identity on captured sessions)", text: $store.userEmail)
                    .textFieldStyle(.roundedBorder)
                    .help("WHO is recording — your identity (enduser.id) on every captured event.")
                TextField(
                    "This machine's name (which computer is recording)", text: $store.instanceName
                )
                .textFieldStyle(.roundedBorder)
                .help(
                    "WHICH machine is recording — tags every event with host.name so you can "
                        + "tell captures from different computers apart. Distinct from your "
                        + "email (that's WHO; this is WHICH machine)."
                )
                Toggle("Reconnect automatically on launch", isOn: $store.reconnectOnLaunch)
                Toggle(
                    "Capture continuously (start on launch, run until paused)",
                    isOn: $store.continuousCapture
                )
                Text(
                    "When on, Jazz starts capturing as soon as it launches/connects and keeps recording until you stop it — just leave it running and bracket activities with ⌥⌘L labels. Off by default."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(
                    "Re-verify the stored token each launch (refreshes the detected "
                        + "project/identity and surfaces an expired token in the menu)."
                )
            }
            Section("Review app") {
                Text(
                    "URL of your hosted Jazz review Data App (timeline, clarify, L4, BDM "
                        + "workshop). “Open Jazz…” embeds it next to the native session list."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                TextField("https://your-review-app.example.com", text: $store.reviewAppURL)
                    .textFieldStyle(.roundedBorder)
            }
            Section("Guided execution") {
                Text(
                    "Production v2 replay derives the exact Jazz governance route and current "
                        + "device credential from signed enrollment, then also requires the "
                        + "short-lived capability in the imported packet. “Your email” must exactly "
                        + "match its authorized operator. The fields below are legacy local/development "
                        + "v1 fallback only and are disabled by policy whenever this client is enrolled."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                TextField(
                    "https://jazz.example.com/governance",
                    text: $store.guidedExecutionURL
                )
                .textFieldStyle(.roundedBorder)
                SecureField(
                    "Scoped guided-execution credential",
                    text: $store.guidedExecutionToken
                )
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save credential") {
                        store.saveGuidedExecutionCredential()
                    }
                    .disabled(
                        store.guidedExecutionURL.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty || store.guidedExecutionToken.isEmpty)
                    if Keychain.has(account: Keychain.Account.guidedExecutionToken) {
                        Button("Remove", role: .destructive) {
                            store.removeGuidedExecutionCredential()
                        }
                    }
                    Spacer()
                }
                if let status = store.guidedExecutionCredentialStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Capture") {
                Picker("Delivery", selection: $store.deliveryPolicy) {
                    Text("Confirmed Jazz Archive (default)")
                        .tag(JazzCaptureDeliveryPolicy.confirmedArchive)
                    Text("Live OTLP + Files compatibility")
                        .tag(JazzCaptureDeliveryPolicy.liveCompatibility)
                }
                Text(
                    store.deliveryPolicy == .confirmedArchive
                        ? "Nothing is streamed while you record. Stop saves locally; explicit review confirmation queues one immutable Jazz Archive."
                        : "Migration mode: every canonical observation (including capability and Coach audit records), artifact metadata, and the final commit are also projected live with the same IDs. This does not enable raw-audio Coach analysis; that has its own consent toggle."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("Screenshots (focused window, on click)", isOn: $store.captureScreenshots)
                Toggle("Record voice during labeled activities", isOn: $store.captureNarration)
                    .help(
                        "The microphone is OFF except while a label is open. Start a label "
                            + "(⌥⌘L → “Now doing…”) to record voice for that activity; end the "
                            + "label and the mic stops. Plain capture is never recorded."
                    )
                Toggle(
                    "Context-aware Capture Coach (optional)",
                    isOn: $store.captureCoachLive
                )
                Text(
                    "Only enable this with a configured Jazz server. Jazz may ask a follow-up only after evaluating bounded privacy-filtered process context and the narration recorded inside an open guided label. There are no generic offline checklist prompts. Canonical capture remains local-first; network or Coach failure never blocks stop or archive finalization."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("Highlight where I click on screen", isOn: $store.highlightClicks)
            }
            Section("Excluded apps (never captured)") {
                Text(
                    "The whole desktop is captured during a session. Add apps here to exclude "
                        + "them — e.g. password managers, banking, personal apps. Secure text "
                        + "fields are always masked everywhere."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(store.denylist, id: \.self) { id in
                    HStack {
                        Text(id).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Allow") { store.include(id) }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Picker("Exclude a running app", selection: $picked) {
                        Text("Choose…").tag("")
                        ForEach(runningApps(), id: \.0) { app in
                            Text(app.1).tag(app.0)
                        }
                    }
                    Button("Exclude") {
                        store.exclude(picked)
                        picked = ""
                    }
                    .disabled(picked.isEmpty)
                }
            }
            Section {
                HStack {
                    Text("Version").foregroundStyle(.secondary)
                    Spacer()
                    Text(AppInfo.version).font(.system(.body, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 820)
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
    }

    // MARK: - Keboola section pieces

    /// Connected state: show WHAT we're connected to (project + stack host) and offer Disconnect.
    private var connectedSummary: some View {
        let settings = AgentSettings.shared
        let project =
            settings.kbcProjectName.isEmpty
            ? "project \(settings.kbcProjectId)"
            : "\(settings.kbcProjectName) (\(settings.kbcProjectId))"
        let host = URL(string: settings.kbcStackURL)?.host ?? settings.kbcStackURL
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Connected", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("\(project) · \(host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Disconnect") { connection.disconnect() }
        }
    }

    /// Enrollment import: production pastes a short-lived bootstrap whose bearer and exact claim
    /// move immediately to Keychain; an already signed bundle keeps the established legacy path.
    private var bundleImportFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(
                "Paste enrollment bootstrap or signed bundle (JSON)", text: $store.bundleText
            )
            .textFieldStyle(.roundedBorder)
            .help(
                "Production bootstraps are redeemed to this Mac's Secure Enclave keys. Jazz then "
                    + "independently verifies the signed issuer, refuses a master token, and stores "
                    + "the activated credential in Keychain."
            )
            HStack {
                Button(connection.isRunning ? "Importing…" : "Import enrollment") {
                    importBundle()
                }
                .buttonStyle(.borderedProminent)
                .disabled(connection.isRunning || store.bundleText.isEmpty)
                if connection.deviceEnrollmentPending {
                    Button("Resume enrollment") {
                        resumeDeviceEnrollment()
                    }
                    .disabled(connection.isRunning)
                    Button("Discard pending enrollment", role: .destructive) {
                        discardPendingDeviceEnrollment()
                    }
                    .disabled(connection.isRunning)
                }
                Spacer()
            }
            if let err = connection.bundleError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Legacy developer fallback. It deliberately cannot accept a master token or create a Stream
    /// source; normal users import the server-issued enrollment bundle (ADR 0005).
    @ViewBuilder
    private var tokenFallbackDisclosure: some View {
        DisclosureGroup(isExpanded: $showTokenFallback) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Developer fallback: paste a non-master Storage API token. You must also supply "
                        + "an existing OTLP endpoint whose logs/traces sinks were provisioned by an admin."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                connectFields
            }
        } label: {
            Text("Advanced: connect with existing credentials")
                .font(.caption)
        }
    }

    private var connectFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Non-master Storage API token", text: $store.kbcToken)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(connection.isRunning ? "Connecting…" : "Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        connection.isRunning
                            || (store.kbcToken.isEmpty && !connection.hasStoredToken))
                if connection.hasStoredToken && store.kbcToken.isEmpty {
                    Text("A token is stored — Connect re-verifies it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    /// Manual endpoint for the legacy non-master-token fallback. It must already have sinks; source
    /// provisioning belongs to the server-side enrollment broker (#198).
    private var streamURLFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Ask a project admin for a sink-backed Data Stream OTLP URL. It embeds a secret, "
                    + "so Jazz keeps it in the Keychain."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            SecureField(
                "https://stream-in.…/otlp/<project>/<source>/<secret>", text: $store.streamURL
            )
            .textFieldStyle(.roundedBorder)
            HStack {
                Button(connection.isRunning ? "Validating…" : "Validate & save") { saveStreamURL() }
                    .disabled(connection.isRunning || store.streamURL.isEmpty)
                Spacer()
            }
            if let err = connection.streamURLError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Show the onboarding step rows once anything started (not on a fresh window).
    private var showSteps: Bool {
        connection.isRunning || connection.steps.contains { $0.state != .pending }
    }

    /// Accessibility / Screen Recording are the relaunch-sensitive permissions — macOS won't
    /// report a fresh grant to the running process until it restarts.
    private var needsRelaunch: Bool {
        [Permission.accessibility, .screenRecording].contains {
            (store.permissions[$0] ?? .denied) != .granted
        }
    }

    @ViewBuilder
    private func permissionRow(_ permission: Permission) -> some View {
        let status = store.permissions[permission] ?? .denied
        HStack(alignment: .top) {
            Image(
                systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .foregroundStyle(status == .granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).fontWeight(.medium)
                Text(permission.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status != .granted {
                Button("Grant") {
                    Permissions.request(permission)
                    Permissions.openSystemSettings(permission)
                }
            }
        }
    }

    /// Run the legacy existing-credentials flow, then clear the field. Falls back to an already
    /// stored non-master token when empty, so a developer can re-verify without re-pasting it.
    private func connect() {
        let typed = store.kbcToken
        Task {
            if typed.isEmpty {
                // Re-resolve through the atomic signed envelope first. The connection owns the
                // genuine-absence-only legacy fallback; UI must not read a stale raw projection.
                await connection.reconnectAtLaunch()
            } else {
                await connection.connect(token: typed)
            }
            if connection.connected || connection.needsStreamURL { store.kbcToken = "" }
        }
    }

    private func saveStreamURL() {
        let typed = store.streamURL
        Task {
            if await connection.saveStreamURL(typed) { store.streamURL = "" }
        }
    }

    /// Import the pasted enrollment bundle, then clear the field on success (don't keep the secret
    /// around). A needs-stream-URL fallback also clears it — the bundle itself is consumed.
    private func importBundle() {
        let pasted = store.bundleText
        Task {
            await connection.importEnrollmentReveal(pasted)
            if connection.connected || connection.needsStreamURL
                || connection.deviceEnrollmentPending
            {
                store.bundleText = ""
            }
        }
    }

    private func resumeDeviceEnrollment() {
        Task {
            await connection.resumeDeviceEnrollment()
        }
    }

    private func discardPendingDeviceEnrollment() {
        Task {
            await connection.discardPendingDeviceEnrollment()
        }
    }

    @ViewBuilder
    private func stepRow(_ step: KeboolaConnection.Step) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                switch step.state {
                case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .font(.caption2)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.label).font(.caption)
                if case .failed(let msg) = step.state {
                    Text(msg).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
        }
    }

    /// Regular (windowed) running apps, de-duplicated by bundle id, sorted by name.
    private func runningApps() -> [(String, String)] {
        var seen = Set<String>()
        return
            NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                    !seen.contains(id)
                else { return nil }
                seen.insert(id)
                return (id, name)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}
