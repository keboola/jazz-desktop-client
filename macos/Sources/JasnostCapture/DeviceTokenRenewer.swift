import AppKit
import Foundation
import JasnostCaptureCore
import Network

/// Keeps the enrolled device credential alive without anyone doing anything.
///
/// A device token lives about an hour. This service renews it a little before expiry (the server
/// says how much earlier — the client never invents that policy), survives an offline stretch with
/// full-jitter backoff, and stops with a visible menu-bar line when only a re-enrollment can help.
///
/// Ordering, and why it is safe:
/// 1. Every attempt re-reads the credential tuple from the Keychain, so a manual re-enrollment
///    mid-backoff is picked up on the next attempt with no coordination.
/// 2. The renewed tuple replaces the previous one in ONE atomic credential-store write. Uploads
///    read their token per request through the same vault, so an in-flight upload either used the
///    old complete tuple or will read the new complete tuple — never a mixture. An upload already
///    on the wire with the superseded token retries through its own queue.
/// 3. If that write fails, the old credential is kept and the attempt is retryable: the server's
///    grace window keeps the presented credential renewal-valid for the next attempt.
///
/// Nothing here logs the token value — only its id, its expiry, the outcome, and the next attempt.
@MainActor
final class DeviceTokenRenewer {
    /// Why an attempt is running. Trigger-driven attempts respect the once-a-minute floor; a
    /// backoff retry carries its own delay and therefore bypasses it.
    private enum Trigger {
        case launch
        case timer
        case wake
        case reachability
        case backoff
    }

    /// Slow re-poke, like the update check: the schedule decides, this only asks "is it due yet?".
    private static let pollInterval: TimeInterval = 60

    private(set) var status = JazzDeviceTokenRenewalStatus()
    /// Fired on the main actor whenever ``status`` changes, so the menu rebuilds.
    var onStatusChange: (() -> Void)?

    private var pollTimer: Timer?
    private var retryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true

    private var client: DeviceTokenRenewalHTTPClient?
    private var clientEndpoint: String?

    private var attemptInFlight = false
    private var consecutiveFailures = 0
    private var lastAttemptAt: Date?
    /// The credential a terminal refusal applies to. A different id in the Keychain means the user
    /// re-enrolled, so renewal resumes without a relaunch.
    private var stoppedTokenId: String?

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.renew(trigger: .timer) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.renew(trigger: .wake) }
            }
        }

        // Reachability regained is the other moment a lapsed schedule must catch up: a laptop that
        // was offline past its renewal point should rotate the instant it has a network again.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let regained = satisfied && !self.lastPathSatisfied
                self.lastPathSatisfied = satisfied
                if regained { await self.renew(trigger: .reachability) }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor

        Task { @MainActor in await self.renew(trigger: .launch) }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        pathMonitor?.cancel()
        pathMonitor = nil
        client?.invalidate()
        client = nil
        clientEndpoint = nil
    }

    /// Renew now if the schedule says so. Safe to call from anywhere, as often as anything likes.
    func renewIfDue() async {
        await renew(trigger: .timer)
    }

    // MARK: - The attempt

    private func renew(trigger: Trigger, now: Date = Date()) async {
        guard !attemptInFlight else { return }

        let envelope: JazzSignedDeviceCredentialEnvelope?
        do {
            envelope = try SignedDeviceCredentialKeychain.vault.envelope()
        } catch {
            // Present but unreadable is never permission to keep quiet: uploads are about to stop.
            publish(
                .stopped(
                    .reenrollmentRequired("the stored enrollment could not be read")),
                tokenId: nil,
                expiresAt: nil)
            return
        }
        guard let envelope else {
            // No signed enrollment on this Mac (legacy raw token, or not connected yet).
            stoppedTokenId = nil
            publish(.inactive, tokenId: nil, expiresAt: nil)
            return
        }

        let routing = envelope.enrollmentRouting
        let tokenId = routing.tokenId
        guard let expiresAt = routing.expiresAtDate else {
            publish(
                .stopped(.reenrollmentRequired("the stored credential has no readable expiry")),
                tokenId: tokenId,
                expiresAt: nil)
            return
        }

        // A refusal is remembered per credential. Importing a new bundle clears it.
        if let stoppedTokenId {
            guard stoppedTokenId != tokenId else { return }
            self.stoppedTokenId = nil
            consecutiveFailures = 0
        }
        guard expiresAt > now else {
            // An expired credential cannot authenticate its own renewal; only re-enrollment helps.
            stoppedTokenId = tokenId
            publish(
                .stopped(.reenrollmentRequired("the stored credential expired")),
                tokenId: tokenId,
                expiresAt: expiresAt)
            return
        }

        let due = JazzDeviceTokenRenewalPolicy.due(
            anchor: AgentSettings.shared.deviceTokenRenewalAnchor,
            tokenId: tokenId,
            expiresAt: expiresAt,
            now: now)
        if trigger != .backoff {
            guard JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due,
                lastAttemptAt: lastAttemptAt,
                now: now)
            else {
                publish(
                    .scheduled(
                        at: JazzDeviceTokenRenewalPolicy.nextAttempt(
                            due: due,
                            lastAttemptAt: lastAttemptAt)),
                    tokenId: tokenId,
                    expiresAt: expiresAt)
                return
            }
        }

        let renewalRequest: JazzDeviceTokenRenewalRequest
        let credential: JazzArchiveScopedDeviceCredential
        let client: DeviceTokenRenewalHTTPClient
        do {
            renewalRequest = try JazzDeviceTokenRenewalRequest(routeBinding: envelope.routeBinding)
            credential = try SignedDeviceCredentialKeychain.vault.archiveCredential(
                for: envelope.routeBinding,
                now: now)
            client = try self.client(for: envelope.routeBinding)
        } catch {
            stoppedTokenId = tokenId
            publish(
                .stopped(
                    .reenrollmentRequired("this enrollment cannot request an unattended renewal")),
                tokenId: tokenId,
                expiresAt: expiresAt)
            return
        }

        attemptInFlight = true
        lastAttemptAt = now
        retryTimer?.invalidate()
        retryTimer = nil
        publish(.renewing, tokenId: tokenId, expiresAt: expiresAt)
        let outcome = await client.renew(
            request: renewalRequest,
            credential: credential,
            routing: routing,
            now: now)
        attemptInFlight = false

        switch outcome {
        case let .renewed(grant):
            commit(grant, replacing: envelope, at: Date())
        case let .failed(disposition, retryAfter):
            handle(disposition, retryAfter: retryAfter, tokenId: tokenId, expiresAt: expiresAt)
        }
    }

    /// Verify-then-swap. The credential store write is the commit point; every write after it is a
    /// repairable projection of the same tuple.
    private func commit(
        _ grant: JazzDeviceTokenRenewalGrant,
        replacing envelope: JazzSignedDeviceCredentialEnvelope,
        at now: Date
    ) {
        let renewed: JazzSignedDeviceCredentialEnvelope
        do {
            renewed = try envelope.renewed(with: grant)
        } catch {
            // The grant is well-formed but would change this device's authority. Nothing is
            // written, and retrying cannot help.
            stoppedTokenId = envelope.enrollmentRouting.tokenId
            publish(
                .stopped(
                    .reenrollmentRequired(
                        "the renewed credential did not match this enrollment")),
                tokenId: envelope.enrollmentRouting.tokenId,
                expiresAt: envelope.enrollmentRouting.expiresAtDate)
            return
        }
        do {
            try SignedDeviceCredentialKeychain.vault.replace(with: renewed)
        } catch {
            // The old credential is intact and still current server-side within the grace window,
            // so the identical request may simply be replayed.
            handle(
                JazzDeviceTokenRenewalFailure.transport("the renewed credential could not be stored"),
                retryAfter: nil,
                tokenId: envelope.enrollmentRouting.tokenId,
                expiresAt: envelope.enrollmentRouting.expiresAtDate)
            return
        }
        SignedDeviceCredentialKeychain.repairProjections(renewed)
        AgentSettings.shared.archiveEnrollmentRouting = renewed.enrollmentRouting
        AgentSettings.shared.deviceTokenRenewalAnchor = JazzDeviceTokenRenewalAnchor(
            tokenId: grant.tokenId,
            issuedAt: now,
            renewAfterSeconds: grant.renewAfterSeconds)
        if grant.renewAfterSeconds == nil {
            NSLog(
                "jasnost: device token renewed without a server lead time; "
                    + "falling back to the legacy fraction")
        }
        consecutiveFailures = 0
        stoppedTokenId = nil
        let due = JazzDeviceTokenRenewalPolicy.due(
            anchor: AgentSettings.shared.deviceTokenRenewalAnchor,
            tokenId: grant.tokenId,
            expiresAt: grant.expiresAtDate,
            now: now)
        NSLog(
            "jasnost: device token renewed: tokenId=%@ expiresAt=%@ nextRenewal=%@",
            grant.tokenId,
            grant.expiresAt,
            Timestamps.iso8601(due))
        publish(.scheduled(at: due), tokenId: grant.tokenId, expiresAt: grant.expiresAtDate)
    }

    private func handle(
        _ disposition: JazzDeviceTokenRenewalDisposition,
        retryAfter: TimeInterval?,
        tokenId: String,
        expiresAt: Date?
    ) {
        guard case let .retryable(reason) = disposition else {
            stoppedTokenId = tokenId
            NSLog(
                "jasnost: device token renewal stopped: tokenId=%@ outcome=%@",
                tokenId,
                "\(disposition)")
            publish(.stopped(disposition), tokenId: tokenId, expiresAt: expiresAt)
            return
        }
        let delay = max(
            retryAfter
                ?? JazzDeviceTokenRenewalPolicy.backoffDelay(
                    attempt: consecutiveFailures,
                    randomFraction: Double.random(in: 0..<1)),
            1)
        consecutiveFailures += 1
        let nextAttemptAt = Date().addingTimeInterval(delay)
        NSLog(
            "jasnost: device token renewal retrying: tokenId=%@ attempt=%d nextAttempt=%@",
            tokenId,
            consecutiveFailures,
            Timestamps.iso8601(nextAttemptAt))
        publish(
            .retrying(nextAttemptAt: nextAttemptAt, reason: reason),
            tokenId: tokenId,
            expiresAt: expiresAt)
        scheduleRetry(after: delay)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.renew(trigger: .backoff) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// One session per ingest authority. A rotated enrollment that moves the route builds a new
    /// client and cancels the old one rather than reusing a session pinned to the previous host.
    private func client(
        for routeBinding: JazzArchiveUploadRouteBinding
    ) throws -> DeviceTokenRenewalHTTPClient {
        if let client, clientEndpoint == routeBinding.ingestEndpoint { return client }
        client?.invalidate()
        let created = try DeviceTokenRenewalHTTPClient(routeBinding: routeBinding)
        client = created
        clientEndpoint = routeBinding.ingestEndpoint
        return created
    }

    private func publish(
        _ phase: JazzDeviceTokenRenewalPhase,
        tokenId: String?,
        expiresAt: Date?
    ) {
        let updated = JazzDeviceTokenRenewalStatus(
            phase: phase,
            tokenId: tokenId,
            expiresAt: expiresAt)
        guard updated != status else { return }
        status = updated
        onStatusChange?()
    }
}
