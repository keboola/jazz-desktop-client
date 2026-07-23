import Combine
import Foundation
import JasnostCaptureCore
import JasnostEnrollmentSecurity

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
    private enum CredentialTransitionError: Error {
        case settingsPersistence
    }

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
    private let signedEnrollmentImporter: SignedEnrollmentImporter

    static func initialSteps() -> [Step] {
        [
            Step(id: "verify", label: "Verify token (detect stack, project, identity)", state: .pending),
            Step(id: "stream", label: "Resolve the Data Stream endpoint", state: .pending),
        ]
    }

    /// Signed state wins over legacy projections. Corruption is not interpreted as absence.
    var hasStoredToken: Bool {
        do {
            if try SignedDeviceCredentialKeychain.vault.envelope() != nil { return true }
            return Keychain.has(account: Keychain.Account.kbcToken)
        } catch {
            return false
        }
    }

    /// A signed explicit-null endpoint is authoritative. Storage-token expiry is deliberately not
    /// consulted because the stream path secret is a separate credential.
    var hasStreamEndpoint: Bool {
        do {
            return try SignedDeviceCredentialKeychain.vault.streamEndpoint(
                legacyEndpoint: Keychain.get(account: Keychain.Account.streamEndpoint)) != nil
        } catch {
            return false
        }
    }

    var hasArchiveConfiguration: Bool {
        do {
            guard let envelope = try SignedDeviceCredentialKeychain.vault.envelope() else {
                return false
            }
            return envelope.routeBinding.hasSignedAuthority
        } catch {
            return false
        }
    }

    init(signedEnrollmentImporter: SignedEnrollmentImporter = .production()) {
        self.signedEnrollmentImporter = signedEnrollmentImporter
        // The atomic envelope is authoritative even when a crash left UI projections stale.
        // Corruption blocks all legacy fallback.
        let settings = AgentSettings.shared
        do {
            if let envelope = try SignedDeviceCredentialKeychain.vault.envelope() {
                connected = settings.deliveryPolicy.usesLiveCompatibilityProjection
                    ? try envelope.signedStreamEndpoint() != nil
                    : envelope.routeBinding.hasSignedAuthority
            } else {
                connected = settings.deliveryPolicy.usesLiveCompatibilityProjection
                    && Keychain.has(account: Keychain.Account.kbcToken)
                    && Keychain.has(account: Keychain.Account.streamEndpoint)
            }
        } catch {
            connected = false
        }
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
            _ = revokeNetworkAuthority()
            set(
                "verify",
                .failed("Master tokens are not allowed on a device — import an enrollment bundle."))
            return
        }
        let settings = AgentSettings.shared
        let previousStack = settings.kbcStackURL
        let previousToken = (try? Keychain.get(account: Keychain.Account.kbcToken)) ?? nil
        let previousStream = (try? Keychain.get(account: Keychain.Account.streamEndpoint)) ?? nil
        let signedEnvelopePresent: Bool
        do {
            signedEnvelopePresent =
                try SignedDeviceCredentialKeychain.vault.envelope() != nil
        } catch {
            set("verify", .failed("Stored signed enrollment is invalid; disconnect it first."))
            return
        }
        do {
            for operation in JazzLegacyCredentialTransitionPlan.operations(
                signedEnvelopePresent: signedEnvelopePresent)
            {
                switch operation {
                case .deleteRawToken:
                    try Keychain.delete(account: Keychain.Account.kbcToken)
                case .deleteRawStream:
                    try Keychain.delete(account: Keychain.Account.streamEndpoint)
                case .setVerifiedStack:
                    guard settings.commitKBCStackURL(stack) else {
                        throw CredentialTransitionError.settingsPersistence
                    }
                case .setRawToken:
                    try Keychain.set(token, account: Keychain.Account.kbcToken)
                case .deleteSignedEnvelope:
                    // Final signed→legacy authority commit. Every legacy field is complete first.
                    try SignedDeviceCredentialKeychain.vault.replace(with: nil)
                }
            }
        } catch {
            restoreFailedLegacyTransition(
                previousStack: previousStack,
                previousToken: previousToken,
                previousStream: previousStream,
                signedEnvelopeWasPresent: signedEnvelopePresent)
            set("verify", .failed("Keychain: \(error)"))
            return
        }
        settings.archiveEnrollmentRouting = nil
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

        do {
            if try SignedDeviceCredentialKeychain.vault.envelope() != nil {
                streamURLError =
                    "This device uses signed enrollment; import a newer signed generation to change live delivery."
                set("stream", .failed("A signed enrollment cannot inherit a manual Stream URL."))
                return false
            }
        } catch {
            streamURLError =
                "Stored signed enrollment is unavailable; import a new signed bundle before configuring live delivery."
            set("stream", .failed("Signed enrollment state is invalid."))
            return false
        }

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

    /// Import a signed one-time enrollment bundle (ADR 0005): first authenticate its complete v2
    /// authority tuple against the code-signed issuer/key policy and durable replay ledger, then
    /// refuse a mistakenly-issued master token via the live `tokens/verify` check (contract 1).
    /// The token-bearing request closure cannot run before signature/time/replay admission. Secrets
    /// then enter the SAME Keychain accounts the raw paste path uses. Never echoes either secret.
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

        // 1. Authenticate the flattened JWS and durably admit its generation BEFORE the closure is
        // allowed to observe the token. No trust anchor, unsigned JSON, tampering, expiry, rollback
        // or generation collision can reach `tokens/verify`.
        set("verify", .running)
        let authorization: AuthorizedSignedDeviceBundle
        let tokenVerification: (String, KeboolaAPI.TokenVerify)?
        do {
            (authorization, tokenVerification) = try await signedEnrollmentImporter.authorizeThen(
                text
            ) { authorized in
                await KeboolaClient.verifyToken(
                    token: authorized.payload.token,
                    stacks: [authorized.payload.stackURL])
            }
        } catch let error as SignedEnrollmentError {
            set("verify", .failed(error.description))
            bundleError = error.description
            return false
        } catch {
            set("verify", .failed("The signed enrollment bundle could not be authenticated."))
            bundleError = "The signed enrollment bundle could not be authenticated."
            return false
        }
        let bundle = authorization.bundle

        // 2. Verify the exact finite, narrow credential (contract 1) against the one signed stack.
        // A network/offline failure leaves the signed admission idempotently retryable and every
        // local archive/delivery queue untouched.
        guard let (stack, verify) = tokenVerification else {
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

        let streamEndpoint: String?
        if let supplied = bundle.streamEndpoint {
            guard let normalized = StreamEndpoint.normalize(supplied),
                StreamEndpoint.isSecureSignedEndpoint(normalized)
            else {
                set("stream", .failed("The bundle carried an invalid Stream endpoint."))
                bundleError = "The enrollment bundle contains an invalid Stream endpoint."
                return false
            }
            streamEndpoint = normalized
        } else {
            streamEndpoint = nil
        }

        let routing: JazzArchiveEnrollmentRouting
        let signedCredentialEnvelope: JazzSignedDeviceCredentialEnvelope
        do {
            guard
                let verifiedRouting = try bundle.archiveEnrollmentRouting(
                    verifiedStackURL: stack,
                    verifiedProjectId: String(verify.owner.id))
            else {
                throw DeviceBundle.ArchiveBindingError.incompleteRouting
            }
            let authority = try JazzArchiveSignedEnrollmentAuthority(
                issuer: authorization.payload.issuer,
                audience: authorization.payload.audience,
                bundleId: authorization.payload.bundleId,
                generation: authorization.payload.generation,
                envelopeDigest: authorization.envelopeDigest)
            routing = verifiedRouting.bindingSignedAuthority(authority)
            let routeBinding = try routing.signedUploadRouteBinding()
            signedCredentialEnvelope = try JazzSignedDeviceCredentialEnvelope(
                token: bundle.token,
                expiresAt: bundle.expiresAt,
                routeBinding: routeBinding,
                enrollmentRouting: routing,
                streamSourceId: authorization.payload.streamSourceId,
                streamEndpoint: streamEndpoint)
        } catch let error as DeviceBundle.ArchiveBindingError {
            set("verify", .failed(error.description))
            bundleError = error.description
            return false
        } catch let error as JazzArchiveUploadError {
            set("verify", .failed(error.description))
            bundleError = "The signed enrollment authority is invalid."
            return false
        } catch {
            set("verify", .failed("The archive enrollment binding is invalid."))
            bundleError = "The enrollment bundle does not match its verified token."
            return false
        }

        // 3. The one atomic Keychain replacement is the FIRST network-authority write. A crash
        // before it exposes the old complete tuple (or genuine legacy absence); a crash after it
        // exposes the new KBC/archive/stream tuple. Every write below is a repairable projection.
        do {
            try SignedDeviceCredentialKeychain.vault.replace(
                with: signedCredentialEnvelope)
        } catch {
            set("verify", .failed("Keychain: \(error)"))
            bundleError = "Could not store the enrollment secrets; the prior enrollment was kept."
            return false
        }
        repairSignedKeychainProjections(signedCredentialEnvelope)
        applyIdentity(stack: stack, verify: verify)
        applyArchiveEnrollment(routing)
        set("verify", .ok)

        set("stream", .running)
        if streamEndpoint != nil {
            set("stream", .ok)
        } else if AgentSettings.shared.deliveryPolicy.usesLiveCompatibilityProjection {
            // Explicit null is part of signed authority. It cannot inherit a prior/manual secret.
            needsStreamURL = false
            set(
                "stream",
                .failed("Import a newer signed generation with a Stream endpoint for live delivery."))
        } else {
            // Whole-archive delivery does not need a Stream endpoint. Capture and review remain
            // offline; the archive uploader uses the separately provisioned control-plane URL.
            set("stream", .ok)
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

        let signedEnvelope: JazzSignedDeviceCredentialEnvelope?
        do {
            signedEnvelope = try SignedDeviceCredentialKeychain.vault.envelope()
        } catch {
            lastError = "Stored signed enrollment is unavailable — import a new bundle."
            connected = false
            return
        }

        let legacyToken =
            signedEnvelope == nil
            ? ((try? Keychain.get(account: Keychain.Account.kbcToken)) ?? nil)
            : nil
        guard signedEnvelope != nil || legacyToken?.isEmpty == false else { return }
        isRunning = true
        defer { isRunning = false }

        let settings = AgentSettings.shared
        let verification: (stackURL: String, verify: KeboolaAPI.TokenVerify)?
        let authoritativeRouting: JazzArchiveEnrollmentRouting?
        if let signedEnvelope {
            do {
                let authority = try signedEnvelope.keboolaCredential()
                verification = await authority.withValue { token in
                    await KeboolaClient.verifyToken(
                        token: token,
                        stacks: [authority.stackURL])
                }
                authoritativeRouting = signedEnvelope.enrollmentRouting
            } catch {
                lastError = "Stored signed enrollment expired — import a newly rotated bundle."
                connected = false
                return
            }
        } else {
            let stacks = KeboolaStack.verificationCandidates(
                preferred: settings.kbcStackURL,
                known: AgentSettings.knownStacks.map(\.url))
            verification = await KeboolaClient.verifyToken(
                token: legacyToken ?? "",
                stacks: stacks)
            authoritativeRouting = settings.archiveEnrollmentRouting
        }

        guard let (stack, verify) = verification
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
            _ = revokeNetworkAuthority()
            lastError = "Stored master token removed — import a device enrollment bundle."
            connected = false
            return
        }
        if let routing = authoritativeRouting {
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
                _ = revokeNetworkAuthority()
                lastError = "\(error.description) Import a newly rotated bundle."
                connected = false
                return
            } catch {
                _ = revokeNetworkAuthority()
                lastError = "Stored enrollment security validation failed — import a new bundle."
                connected = false
                return
            }
        }
        applyIdentity(stack: stack, verify: verify)
        if signedEnvelope != nil {
            // Repair a stale UserDefaults projection after a crash immediately following the
            // atomic Keychain commit. Network authority never depended on this repair.
            repairSignedKeychainProjections(signedEnvelope!)
            applyArchiveEnrollment(authoritativeRouting)
        }
        connected = settings.deliveryPolicy.usesLiveCompatibilityProjection
            ? hasStreamEndpoint : hasArchiveConfiguration
        lastError = nil
    }

    // MARK: - Disconnect

    /// Forget everything provisioned locally: both Keychain secrets and the detected
    /// project identity. (The remote Data Stream is left intact — tearing it down is an
    /// explicit, separate action so a disconnect never destroys captured data.)
    func disconnect() {
        // Clear legacy projections first, then remove the signed tuple as the commit to absence.
        // A crash before the final operation leaves signed authority intact; after it no legacy
        // credential can spring back into use.
        guard revokeNetworkAuthority() else {
            lastError = "Could not fully remove the stored enrollment."
            connected = hasArchiveConfiguration || hasStreamEndpoint
            return
        }
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

    private func repairSignedKeychainProjections(
        _ envelope: JazzSignedDeviceCredentialEnvelope
    ) {
        if let credential = try? envelope.keboolaCredential() {
            credential.withValue {
                try? Keychain.set($0, account: Keychain.Account.kbcToken)
            }
        }
        if let endpoint = try? envelope.signedStreamEndpoint() {
            try? Keychain.set(endpoint, account: Keychain.Account.streamEndpoint)
        } else {
            try? Keychain.delete(account: Keychain.Account.streamEndpoint)
        }
    }

    /// Signed authority is removed only after both legacy projections are gone. This ordering keeps
    /// every interruption on one side of a complete old-or-absent network tuple.
    @discardableResult
    private func revokeNetworkAuthority() -> Bool {
        do {
            try Keychain.delete(account: Keychain.Account.kbcToken)
            try Keychain.delete(account: Keychain.Account.streamEndpoint)
            try SignedDeviceCredentialKeychain.vault.replace(with: nil)
            return true
        } catch {
            return false
        }
    }

    private func restoreKeychain(_ value: String?, account: String) {
        if let value, !value.isEmpty {
            try? Keychain.set(value, account: account)
        } else {
            try? Keychain.delete(account: account)
        }
    }

    private func restoreFailedLegacyTransition(
        previousStack: String,
        previousToken: String?,
        previousStream: String?,
        signedEnvelopeWasPresent: Bool
    ) {
        if signedEnvelopeWasPresent {
            // The final envelope deletion did not happen, so signed authority masks projections.
            guard AgentSettings.shared.commitKBCStackURL(previousStack) else {
                try? Keychain.delete(account: Keychain.Account.kbcToken)
                try? Keychain.delete(account: Keychain.Account.streamEndpoint)
                return
            }
            restoreKeychain(previousToken, account: Keychain.Account.kbcToken)
            restoreKeychain(previousStream, account: Keychain.Account.streamEndpoint)
            return
        }

        // Recreate the old legacy pair through a credential-free gap: no raw token may be present
        // while its stack is being restored.
        try? Keychain.delete(account: Keychain.Account.kbcToken)
        try? Keychain.delete(account: Keychain.Account.streamEndpoint)
        guard AgentSettings.shared.commitKBCStackURL(previousStack) else {
            // A tokenless state is safer than reviving the old token against an uncertain stack.
            return
        }
        restoreKeychain(previousToken, account: Keychain.Account.kbcToken)
        restoreKeychain(previousStream, account: Keychain.Account.streamEndpoint)
    }
}
