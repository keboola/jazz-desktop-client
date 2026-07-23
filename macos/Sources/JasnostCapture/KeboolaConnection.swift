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
    var hasArchiveConfiguration: Bool { AgentSettings.shared.hasArchiveDeliveryConfiguration }

    init() {
        // Both secrets present from a previous run → connected without any network call;
        // the optional launch-time reconnect re-verifies in the background.
        let settings = AgentSettings.shared
        connected = Keychain.has(account: Keychain.Account.kbcToken)
            && (settings.deliveryPolicy.usesLiveCompatibilityProjection
                ? Keychain.has(account: Keychain.Account.streamEndpoint)
                : settings.hasArchiveDeliveryConfiguration)
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
        let previousToken = (try? Keychain.get(account: Keychain.Account.kbcToken)) ?? nil
        let previousStream = (try? Keychain.get(account: Keychain.Account.streamEndpoint)) ?? nil
        do {
            try Keychain.set(token, account: Keychain.Account.kbcToken)
            // A raw token has no authenticated relation to a prior enrollment or Stream URL.
            // Live compatibility may add a fresh stream endpoint below; archive delivery requires
            // a complete server-issued bundle.
            try Keychain.delete(account: Keychain.Account.streamEndpoint)
        } catch {
            restoreKeychain(previousToken, account: Keychain.Account.kbcToken)
            restoreKeychain(previousStream, account: Keychain.Account.streamEndpoint)
            set("verify", .failed("Keychain: \(error)"))
            return
        }
        AgentSettings.shared.archiveEnrollmentRouting = nil
        applyIdentity(stack: stack, verify: verify)
        set("verify", .ok)

        // 2. The legacy path may keep or accept an EXISTING endpoint, but never creates a source.
        //    Source+sinks provisioning belongs to the server-side enrollment broker (#198).
        set("stream", .running)
        if AgentSettings.shared.deliveryPolicy.usesLiveCompatibilityProjection {
            needsStreamURL = true
            set(
                "stream",
                .failed("Paste an existing, sink-backed Data Stream OTLP URL below."))
        } else {
            set(
                "stream",
                .failed("Confirmed archive delivery requires a device enrollment bundle."))
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

        // 2. Verify the exact finite, narrow credential (contract 1). New bundles carry their exact
        //    stack, including dedicated/single-tenant hosts (#197); legacy bundles may still select
        //    a fallback stack, but cannot be stored without the full security scope and verify shape.
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
        do {
            try bundle.validateVerifiedCredential(verify)
        } catch let error as DeviceBundle.CredentialValidationError {
            // Fail before touching either Keychain account or the persisted routing tuple. A
            // non-master token can still be dangerously broad, stale, revoked, or unrelated to the
            // one-time bundle; missing verification fields are not interpreted as safe defaults.
            set("verify", .failed(error.description))
            bundleError = error.description
            return false
        } catch {
            set("verify", .failed("The enrollment credential could not be validated."))
            bundleError = "The enrollment credential could not be validated."
            return false
        }

        let routing: JazzArchiveEnrollmentRouting?
        do {
            routing = try bundle.archiveEnrollmentRouting(
                verifiedStackURL: stack,
                verifiedProjectId: String(verify.owner.id))
        } catch let error as DeviceBundle.ArchiveBindingError {
            set("verify", .failed(error.description))
            bundleError = error.description
            return false
        } catch {
            set("verify", .failed("The archive enrollment binding is invalid."))
            bundleError = "The enrollment bundle does not match its verified token."
            return false
        }

        let streamEndpoint: String?
        if let supplied = bundle.streamEndpoint {
            guard let normalized = StreamEndpoint.normalize(supplied) else {
                set("stream", .failed("The bundle carried an invalid Stream endpoint."))
                bundleError = "The enrollment bundle contains an invalid Stream endpoint."
                return false
            }
            streamEndpoint = normalized
        } else {
            streamEndpoint = nil
        }

        // 3. Persist the secret half first, with rollback, then replace the entire non-secret
        // routing tuple in one UserDefaults value. There is no point where another main-actor task
        // can observe a new token paired with old archive routing.
        let previousToken = (try? Keychain.get(account: Keychain.Account.kbcToken)) ?? nil
        let previousStream = (try? Keychain.get(account: Keychain.Account.streamEndpoint)) ?? nil
        do {
            try Keychain.set(bundle.token, account: Keychain.Account.kbcToken)
            if let streamEndpoint {
                try Keychain.set(streamEndpoint, account: Keychain.Account.streamEndpoint)
            } else {
                try Keychain.delete(account: Keychain.Account.streamEndpoint)
            }
        } catch {
            restoreKeychain(previousToken, account: Keychain.Account.kbcToken)
            restoreKeychain(previousStream, account: Keychain.Account.streamEndpoint)
            set("verify", .failed("Keychain: \(error)"))
            bundleError = "Could not store the enrollment secrets; the prior enrollment was kept."
            return false
        }
        applyIdentity(stack: stack, verify: verify)
        applyArchiveEnrollment(routing)
        set("verify", .ok)

        set("stream", .running)
        if streamEndpoint != nil {
            set("stream", .ok)
        } else if AgentSettings.shared.deliveryPolicy.usesLiveCompatibilityProjection {
            // A scoped bundle without an endpoint and none stored: fall back to the manual URL field.
            needsStreamURL = true
            set("stream", .failed("The bundle carried no stream endpoint — paste the OTLP URL below."))
        } else if routing != nil {
            // Whole-archive delivery does not need a Stream endpoint. Capture and review remain
            // offline; the archive uploader uses the separately provisioned control-plane URL.
            set("stream", .ok)
        } else {
            set("stream", .failed("Import an updated bundle with Jazz Archive routing."))
            bundleError = "This legacy bundle cannot enable confirmed Jazz Archive delivery."
        }
        connected = AgentSettings.shared.deliveryPolicy.usesLiveCompatibilityProjection
            ? hasStreamEndpoint : hasArchiveConfiguration
        if connected { onEndpointStored?() }
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
        if let routing = settings.archiveEnrollmentRouting {
            guard routing.projectId == String(verify.owner.id),
                KeboolaStack.normalize(routing.stackURL) == KeboolaStack.normalize(stack)
            else {
                lastError =
                    "Stored archive enrollment does not match the verified token — import a new bundle."
                connected = false
                return
            }
            do {
                try routing.validateVerifiedCredential(verify)
            } catch let error as DeviceBundle.CredentialValidationError {
                // Positively identified stale, revoked, or over-broad credentials must not remain
                // resident after upgrade/relaunch. Canonical local archives remain untouched.
                try? Keychain.delete(account: Keychain.Account.kbcToken)
                lastError = "\(error.description) Import a newly rotated bundle."
                connected = false
                return
            } catch {
                try? Keychain.delete(account: Keychain.Account.kbcToken)
                lastError = "Stored enrollment security validation failed — import a new bundle."
                connected = false
                return
            }
        }
        applyIdentity(stack: stack, verify: verify)
        connected = settings.deliveryPolicy.usesLiveCompatibilityProjection
            ? hasStreamEndpoint : settings.hasArchiveDeliveryConfiguration
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
        settings.archiveEnrollmentRouting = nil
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

    /// Persist only non-secret delivery routing from an updated enrollment bundle. Legacy bundles
    /// omit this block; existing routing is retained and new queued archives remain reconnect-bound
    /// when no prior complete block exists.
    private func applyArchiveEnrollment(_ routing: JazzArchiveEnrollmentRouting?) {
        let settings = AgentSettings.shared
        settings.archiveEnrollmentRouting = routing
        guard let routing else { return }
        let priorAreaId = settings.lastAreaId
        let priorAreaName = settings.lastAreaName
        settings.lastAreaId = routing.scope.areaId
        if routing.scope.areaId == CaptureScope.generalAreaId {
            settings.lastAreaName = CaptureScope.generalAreaName
        } else if priorAreaId != routing.scope.areaId || priorAreaName.isEmpty {
            settings.lastAreaName = routing.scope.areaId
        }
    }

    private func restoreKeychain(_ value: String?, account: String) {
        if let value, !value.isEmpty {
            try? Keychain.set(value, account: account)
        } else {
            try? Keychain.delete(account: account)
        }
    }
}
