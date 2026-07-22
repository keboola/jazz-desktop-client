import Combine
import Foundation
import JasnostCaptureCore

/// Keboola onboarding. The supported path imports a server-issued per-device bundle (ADR 0005),
/// which carries its exact stack, scoped token, and already-provisioned OTLP endpoint. A legacy
/// advanced path accepts only a non-master token plus an existing endpoint; the desktop never
/// provisions Stream sources (the server owns sources + sinks, so a source cannot look healthy
/// while silently dropping data — #198).
///
/// Secret handling: the token and the stream endpoint (its URL path embeds the stream
/// secret) live ONLY in the Keychain; neither is logged, surfaced, or persisted elsewhere.
/// The non-secret results (stack, project id/name, user email) land in ``AgentSettings``
/// so the UI can show what's connected without re-verifying.
@MainActor
final class KeboolaConnection: ObservableObject {
    enum StepState: Equatable {
        case pending, running, ok
        case failed(String)
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let label: String
        var state: StepState
    }

    /// The two onboarding steps shown as status rows in Settings.
    @Published private(set) var steps: [Step] = KeboolaConnection.initialSteps()
    @Published private(set) var isRunning = false
    /// Token verified AND a stream endpoint is stored — capture can ship.
    @Published private(set) var connected: Bool
    /// The legacy token verified but has no stored endpoint — the UI reveals the manual
    /// pre-provisioned stream-URL field on exactly this.
    @Published private(set) var needsStreamURL = false
    /// Validation failure of the manually pasted stream URL (never echoes the URL).
    @Published private(set) var streamURLError: String?
    /// Failure of the enrollment-bundle import (parse error, master-token refusal, or verify
    /// failure). Never echoes the bundle's token/endpoint — only the human-readable reason.
    @Published private(set) var bundleError: String?
    /// Launch-time reconnect failure, surfaced in the menu (the manual Connect flow shows
    /// its failures in the step rows instead).
    @Published private(set) var lastError: String?

    /// Called right after a stream endpoint is stored in the Keychain, on the main actor. The
    /// app wires this to nudge the background sender so a spool backlog (offline period, or the
    /// very first run before onboarding) ships immediately instead of waiting out its backoff.
    var onEndpointStored: (@MainActor () -> Void)?

    static func initialSteps() -> [Step] {
        [
            Step(id: "verify", label: "Verify token (detect stack, project, identity)", state: .pending),
            Step(id: "stream", label: "Resolve the Data Stream endpoint", state: .pending),
        ]
    }

    /// True once a token is in the Keychain (so the UI can offer re-Connect without re-pasting).
    var hasStoredToken: Bool { Keychain.has(account: Keychain.Account.kbcToken) }
    /// True once a stream endpoint is in the Keychain (the sender reads it lazily per drain).
    var hasStreamEndpoint: Bool { Keychain.has(account: Keychain.Account.streamEndpoint) }

    init() {
        // Both secrets present from a previous run → connected without any network call;
        // the optional launch-time reconnect re-verifies in the background.
        connected =
            Keychain.has(account: Keychain.Account.kbcToken)
            && Keychain.has(account: Keychain.Account.streamEndpoint)
    }

    private func set(_ id: String, _ state: StepState) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].state = state
    }

    // MARK: - Connect (manual, from Settings)

    /// Run the legacy existing-credentials flow. Master tokens are refused; a verified scoped
    /// token without a stored endpoint leaves ``needsStreamURL`` true so the UI asks for one.
    func connect(token: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        steps = Self.initialSteps()
        connected = false
        needsStreamURL = false
        streamURLError = nil
        lastError = nil

        // 1. Verify — prefer the last successful stack (also supports a previously-imported
        //    dedicated stack), then the public fallbacks. Never store a master token: the
        //    server-issued enrollment bundle is the supported path (ADR 0005 contract 1).
        set("verify", .running)
        let stacks = KeboolaStack.verificationCandidates(
            preferred: AgentSettings.shared.kbcStackURL,
            known: AgentSettings.knownStacks.map(\.url))
        guard let (stack, verify) = await KeboolaClient.verifyToken(token: token, stacks: stacks)
        else {
            set("verify", .failed("Token was not accepted by the configured or known Keboola stack."))
            return
        }
        guard !verify.isMaster else {
            // Also purge an old pre-ADR master token when this call is a re-Connect from Keychain.
            try? Keychain.delete(account: Keychain.Account.kbcToken)
            set(
                "verify",
                .failed("Master tokens are not allowed on a device — import an enrollment bundle."))
            return
        }
        do {
            try Keychain.set(token, account: Keychain.Account.kbcToken)
        } catch {
            set("verify", .failed("Keychain: \(error)"))
            return
        }
        applyIdentity(stack: stack, verify: verify)
        set("verify", .ok)

        // 2. The legacy path may keep or accept an EXISTING endpoint, but never creates a source.
        //    Source+sinks provisioning belongs to the server-side enrollment broker (#198).
        set("stream", .running)
        if hasStreamEndpoint {
            set("stream", .ok)  // keep the endpoint stored on a previous run
            connected = true
        } else {
            needsStreamURL = true
            set(
                "stream",
                .failed("Paste an existing, sink-backed Data Stream OTLP URL below."))
        }
    }

    /// Manual existing-endpoint path: normalize the pasted URL, prove it with an empty OTLP POST,
    /// and store it in the Keychain. Returns true when connected.
    @discardableResult
    func saveStreamURL(_ raw: String) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        streamURLError = nil

        guard let endpoint = StreamEndpoint.normalize(raw) else {
            streamURLError = "That doesn't look like an OTLP ingest URL (https://stream-in.…)."
            return false
        }
        set("stream", .running)
        if let error = await KeboolaClient.validateStreamEndpoint(endpoint) {
            streamURLError = error
            set("stream", .failed("The stream URL did not validate."))
            return false
        }
        do {
            try Keychain.set(endpoint, account: Keychain.Account.streamEndpoint)
        } catch {
            streamURLError = "Keychain: \(error)"
            set("stream", .failed("Could not store the stream URL."))
            return false
        }
        needsStreamURL = false
        set("stream", .ok)
        connected = true
        onEndpointStored?()
        return true
    }

    // MARK: - Enrollment bundle import (ADR 0005)

    /// Import a one-time enrollment bundle (ADR 0005): parse it, refuse a mistakenly-pasted master
    /// token via the live `tokens/verify` check (contract 1 — the desktop must never hold a master
    /// token), then store the scoped token + stream endpoint in the SAME Keychain accounts the raw
    /// paste path uses. Returns true when connected. Never echoes the token or endpoint on any error.
    @discardableResult
    func importBundle(_ text: String) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        steps = Self.initialSteps()
        connected = false
        needsStreamURL = false
        streamURLError = nil
        bundleError = nil
        lastError = nil

        // 1. Parse — a pure local check (kind, non-empty token/deviceId, token shape).
        let bundle: DeviceBundle
        switch DeviceBundle.parse(text) {
        case let .success(parsed): bundle = parsed
        case let .failure(error):
            bundleError = error.description
            return false
        }

        // 2. Verify + master-token refusal (contract 1). New bundles carry their exact stack,
        //    including dedicated/single-tenant hosts (#197); legacy bundles fall back to the
        //    persisted/public candidates for backward compatibility.
        set("verify", .running)
        let bundleStacks = bundle.normalizedStackURL.map { [$0] }
            ?? KeboolaStack.verificationCandidates(
                preferred: AgentSettings.shared.kbcStackURL,
                known: AgentSettings.knownStacks.map(\.url))
        guard
            let (stack, verify) = await KeboolaClient.verifyToken(
                token: bundle.token, stacks: bundleStacks)
        else {
            set("verify", .failed("The bundle's token was not accepted by its Keboola stack."))
            bundleError = "The enrollment bundle's token did not verify."
            return false
        }
        if verify.isMaster {
            // Contract 1: absolute. Do NOT store this token; make the admin re-issue a scoped bundle.
            set("verify", .failed("That is a master token — import a device-scoped enrollment bundle."))
            bundleError =
                "That bundle carries a MASTER token. A device must never hold a master token — "
                + "have the admin issue a device-scoped enrollment bundle instead."
            return false
        }

        // 3. Persist — token + (optional) stream endpoint into the existing Keychain accounts.
        do {
            try Keychain.set(bundle.token, account: Keychain.Account.kbcToken)
        } catch {
            set("verify", .failed("Keychain: \(error)"))
            bundleError = "Could not store the device token in the Keychain."
            return false
        }
        applyIdentity(stack: stack, verify: verify)
        set("verify", .ok)

        set("stream", .running)
        if let endpoint = bundle.streamEndpoint,
            let normalized = StreamEndpoint.normalize(endpoint)
        {
            do {
                try Keychain.set(normalized, account: Keychain.Account.streamEndpoint)
                set("stream", .ok)
                connected = true
                onEndpointStored?()
            } catch {
                set("stream", .failed("Could not store the stream endpoint."))
                bundleError = "Could not store the stream endpoint in the Keychain."
                return false
            }
        } else if hasStreamEndpoint {
            // The bundle omitted the endpoint but one is already stored — keep it.
            set("stream", .ok)
            connected = true
        } else {
            // A scoped bundle without an endpoint and none stored: fall back to the manual URL field.
            needsStreamURL = true
            set("stream", .failed("The bundle carried no stream endpoint — paste the OTLP URL below."))
        }
        return connected
    }

    // MARK: - Launch-time reconnect (headless, soft-fail)

    /// Re-verify the stored token in the background against the persisted stack first. Every
    /// failure is soft — it surfaces as ``lastError`` in the menu, never as a dialog, never
    /// blocking launch. A positively identified legacy master token is removed (ADR 0005).
    func reconnectAtLaunch() async {
        guard !isRunning else { return }
        guard
            let token = (try? Keychain.get(account: Keychain.Account.kbcToken)) ?? nil,
            !token.isEmpty
        else { return }
        isRunning = true
        defer { isRunning = false }

        let settings = AgentSettings.shared
        let stacks = KeboolaStack.verificationCandidates(
            preferred: settings.kbcStackURL, known: AgentSettings.knownStacks.map(\.url))
        guard let (stack, verify) = await KeboolaClient.verifyToken(token: token, stacks: stacks)
        else {
            // Could be an expired token OR plain offline — either way capture still spools
            // locally; the user reconnects in Settings when convenient.
            lastError = "Keboola token didn't verify — reconnect in Settings."
            connected = false
            return
        }
        guard !verify.isMaster else {
            // Upgrade safety for devices configured before ADR 0005: do not keep a project master
            // token resident after the app has positively identified it.
            try? Keychain.delete(account: Keychain.Account.kbcToken)
            lastError = "Stored master token removed — import a device enrollment bundle."
            connected = false
            return
        }
        applyIdentity(stack: stack, verify: verify)
        connected = hasStreamEndpoint
        lastError = nil
    }

    // MARK: - Disconnect

    /// Forget everything provisioned locally: both Keychain secrets and the detected
    /// project identity. (The remote Data Stream is left intact — tearing it down is an
    /// explicit, separate action so a disconnect never destroys captured data.)
    func disconnect() {
        try? Keychain.delete(account: Keychain.Account.kbcToken)
        try? Keychain.delete(account: Keychain.Account.streamEndpoint)
        let settings = AgentSettings.shared
        settings.kbcProjectId = ""
        settings.kbcProjectName = ""
        steps = Self.initialSteps()
        connected = false
        needsStreamURL = false
        streamURLError = nil
        bundleError = nil
        lastError = nil
    }

    // MARK: - Internals

    /// Persist the non-secret identity the verify returned. The user-email override is
    /// only prefilled when empty — a manual override must survive re-verification.
    private func applyIdentity(stack: String, verify: KeboolaAPI.TokenVerify) {
        let settings = AgentSettings.shared
        settings.kbcStackURL = stack
        settings.kbcProjectId = String(verify.owner.id)
        settings.kbcProjectName = verify.owner.name
        if settings.userEmail.trimmingCharacters(in: .whitespaces).isEmpty,
            let email = verify.userEmail
        {
            settings.userEmail = email
        }
    }
}
