import Combine
import Foundation
import JasnostCaptureCore

/// Token-only Keboola onboarding: one pasted Storage API token is verified across the known
/// stacks (auto-detecting stack + project + user identity), and a master token additionally
/// finds-or-creates the "jasnost" OTLP Data Stream source — no kbagent, no local services,
/// no stack picker. Non-master tokens get a manual stream-URL field instead, validated by
/// an empty OTLP POST (``KeboolaClient/validateStreamEndpoint(_:)``).
///
/// Secret handling: the token and the stream endpoint (its URL path embeds the stream
/// secret) live ONLY in the Keychain; neither is logged, surfaced, or persisted elsewhere.
/// The non-secret results (stack, project id/name, user email) land in ``AgentSettings``
/// so the UI can show what's connected without re-verifying.
@MainActor
final class KeboolaConnection: ObservableObject {
    /// Name of the OTLP Data Stream source provisioned on the master-token path — one
    /// shared source per project, same convention the retired kbagent bootstrap used.
    static let streamSourceName = "jasnost"

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
    /// The token verified but cannot provision the stream (not a master token) — the UI
    /// reveals the manual stream-URL field on exactly this.
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

    /// Run the token-only onboarding. On success ``connected`` flips true; a non-master
    /// token leaves ``needsStreamURL`` true so the UI asks for the URL instead.
    func connect(token: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        steps = Self.initialSteps()
        connected = false
        needsStreamURL = false
        streamURLError = nil
        lastError = nil

        // 1. Verify — one GET across the known stacks; the first 200 wins and tells us
        //    everything (stack, project, user). The token goes to the Keychain only after
        //    it verified, so a typo never overwrites a working stored token.
        set("verify", .running)
        guard let (stack, verify) = await KeboolaClient.verifyToken(token: token) else {
            set("verify", .failed("Token was not accepted by any known Keboola stack."))
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

        // 2. Stream endpoint — master tokens provision it via the Stream API; others keep
        //    an already-stored endpoint or fall back to the manual URL field.
        set("stream", .running)
        if verify.isMaster {
            await resolveStreamViaAPI(stack: stack)
        } else if hasStreamEndpoint {
            set("stream", .ok)  // keep the endpoint stored on a previous run
            connected = true
        } else {
            needsStreamURL = true
            set(
                "stream",
                .failed("Not a master token — paste your Data Stream's OTLP URL below."))
        }
    }

    /// Master-token path: find-or-create the "jasnost" OTLP source and store its ingest URL
    /// in the Keychain. The Stream API can still refuse (token classified non-master there)
    /// — that flips to the manual-URL fallback rather than failing the onboarding.
    private func resolveStreamViaAPI(stack: String) async {
        do {
            let source = try await KeboolaClient(stackURL: stack)
                .findOrCreateStreamSource(name: Self.streamSourceName)
            guard let endpoint = source.otlpEndpoint, !endpoint.isEmpty else {
                set("stream", .failed("The stream source came back without an OTLP URL."))
                return
            }
            try Keychain.set(endpoint, account: Keychain.Account.streamEndpoint)
            set("stream", .ok)
            connected = true
            onEndpointStored?()
        } catch KeboolaClient.ClientError.masterTokenRequired {
            needsStreamURL = true
            set(
                "stream",
                .failed("The Stream API wants a master token — paste the OTLP URL below."))
        } catch {
            set("stream", .failed("\(error)"))
        }
    }

    /// Manual stream-URL path (non-master tokens): normalize the pasted URL, prove it with
    /// an empty OTLP POST, and store it in the Keychain. Returns true when connected.
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

        // 2. Verify + master-token refusal (contract 1). Reuse the existing multi-stack verify so
        //    the bundle's scoped token is proven and its stack/project/identity are detected. If the
        //    token verifies as MASTER we refuse — a device must never hold a master token, and a
        //    bundle is only ever supposed to carry a scoped one.
        set("verify", .running)
        guard let (stack, verify) = await KeboolaClient.verifyToken(token: bundle.token) else {
            set("verify", .failed("The bundle's token was not accepted by any known Keboola stack."))
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

    /// Re-verify the stored token in the background: refreshes the detected identity, and
    /// (master tokens only) re-resolves a missing stream endpoint. Every failure is soft —
    /// it surfaces as ``lastError`` in the menu, never as a dialog, never blocking launch.
    func reconnectAtLaunch() async {
        guard !isRunning else { return }
        guard
            let token = (try? Keychain.get(account: Keychain.Account.kbcToken)) ?? nil,
            !token.isEmpty
        else { return }
        isRunning = true
        defer { isRunning = false }

        guard let (stack, verify) = await KeboolaClient.verifyToken(token: token) else {
            // Could be an expired token OR plain offline — either way capture still spools
            // locally; the user reconnects in Settings when convenient.
            lastError = "Keboola token didn't verify — reconnect in Settings."
            connected = false
            return
        }
        applyIdentity(stack: stack, verify: verify)
        if !hasStreamEndpoint, verify.isMaster {
            if let source = try? await KeboolaClient(stackURL: stack)
                .findOrCreateStreamSource(name: Self.streamSourceName),
                let endpoint = source.otlpEndpoint, !endpoint.isEmpty
            {
                try? Keychain.set(endpoint, account: Keychain.Account.streamEndpoint)
                onEndpointStored?()
            }
        }
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
