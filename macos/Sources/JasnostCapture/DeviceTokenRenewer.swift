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
    /// An open backoff window. Every trigger respects it, so the escalating retry schedule is real
    /// rather than silently capped at the poll interval.
    private var backoffUntil: Date?
    /// True once this credential has been positively refused; only a re-enrollment clears it.
    private var isStopped = false
    /// The credential all of the above applies to. A different id in the Keychain means the
    /// credential was replaced, so every attempt counter resets without a relaunch.
    private var observedTokenId: String?

    var isRunning: Bool { pollTimer != nil }

    // MARK: - Lifecycle

    /// Begin scheduling. Idempotent, so a reconnect may call it without checking.
    /// `kickOff` exists for tests that need the timers without an immediate attempt.
    func start(kickOff: Bool = true) {
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

        guard kickOff else { return }
        Task { @MainActor in await self.renew(trigger: .launch) }
    }

    /// Stand down completely: no timer, no wake or reachability observer, no session. Called when
    /// the app terminates and when network authority is revoked (disconnect, a removed master
    /// token, a credential that failed re-verification) — there is no longer a credential to renew,
    /// and a poll that keeps running would only re-derive that fact every minute.
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
        backoffUntil = nil
        consecutiveFailures = 0
        isStopped = false
        observedTokenId = nil
        lastAttemptAt = nil
        // A deliberately revoked enrollment is not a renewal failure: the connection surface owns
        // that message, so this one goes quiet.
        publish(.inactive, tokenId: nil, expiresAt: nil)
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
            // Unreadable is not the same as unusable: a locked or busy credential store retries,
            // while bytes that no longer decode into this enrollment are terminal. Either way the
            // outcome is surfaced — uploads are about to stop.
            handle(
                JazzDeviceTokenRenewalFailure.credentialRead(error),
                retryAfter: nil,
                tokenId: nil,
                expiresAt: nil)
            return
        }
        guard let envelope else {
            // No signed enrollment on this Mac (legacy raw token, or not connected yet).
            resetAttemptState(for: nil)
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

        // Every counter, backoff window and refusal belongs to one credential. A replaced
        // credential (a re-enrollment, a device-bound redemption) starts from scratch.
        if observedTokenId != tokenId { resetAttemptState(for: tokenId) }
        guard !isStopped else { return }
        guard expiresAt > now else {
            // An expired credential cannot authenticate its own renewal; only re-enrollment helps.
            isStopped = true
            publish(
                .stopped(.reenrollmentRequired("the stored credential expired")),
                tokenId: tokenId,
                expiresAt: expiresAt)
            return
        }

        // The schedule is measured from a persisted anchor, never from the current instant: a due
        // moment recomputed as a fraction of the time still left would recede forever.
        let anchor = JazzDeviceTokenRenewalPolicy.anchor(
            existing: AgentSettings.shared.deviceTokenRenewalAnchor,
            tokenId: tokenId,
            now: now)
        if AgentSettings.shared.deviceTokenRenewalAnchor != anchor {
            AgentSettings.shared.deviceTokenRenewalAnchor = anchor
        }
        let due = JazzDeviceTokenRenewalPolicy.due(anchor: anchor, expiresAt: expiresAt)
        if trigger != .backoff {
            guard JazzDeviceTokenRenewalPolicy.shouldAttempt(
                due: due,
                lastAttemptAt: lastAttemptAt,
                backoffUntil: backoffUntil,
                now: now)
            else {
                // An open backoff window already publishes its own next attempt; a trigger must not
                // overwrite it with an earlier-looking schedule.
                let waitingOutBackoff = backoffUntil.map { now < $0 } ?? false
                if !waitingOutBackoff {
                    publish(
                        .scheduled(
                            at: JazzDeviceTokenRenewalPolicy.nextAttempt(
                                due: due,
                                lastAttemptAt: lastAttemptAt,
                                backoffUntil: backoffUntil)),
                        tokenId: tokenId,
                        expiresAt: expiresAt)
                }
                return
            }
        }

        let renewalRequest: JazzDeviceTokenRenewalRequest
        let client: DeviceTokenRenewalHTTPClient
        do {
            // Structural: this enrollment cannot express a renewal request at all. Retrying the
            // same stored authority would fail identically.
            renewalRequest = try JazzDeviceTokenRenewalRequest(routeBinding: envelope.routeBinding)
            client = try self.client(for: envelope.routeBinding)
        } catch {
            isStopped = true
            publish(
                .stopped(
                    .reenrollmentRequired("this enrollment cannot request an unattended renewal")),
                tokenId: tokenId,
                expiresAt: expiresAt)
            return
        }

        let credential: JazzArchiveScopedDeviceCredential
        do {
            credential = try SignedDeviceCredentialKeychain.vault.archiveCredential(
                for: envelope.routeBinding,
                now: now)
        } catch {
            // A credential-store read that fails is usually transient; only a positively terminal
            // state stops the schedule (classified in Core).
            handle(
                JazzDeviceTokenRenewalFailure.credentialRead(error),
                retryAfter: nil,
                tokenId: tokenId,
                expiresAt: expiresAt)
            return
        }

        attemptInFlight = true
        lastAttemptAt = now
        backoffUntil = nil
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
            isStopped = true
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
        // The grant's arrival IS this credential's anchor, and it carries the server's own lead
        // time — the legacy fraction is only for credentials this Mac did not mint.
        let anchor = JazzDeviceTokenRenewalAnchor(
            tokenId: grant.tokenId,
            heldSince: now,
            renewAfterSeconds: grant.renewAfterSeconds)
        AgentSettings.shared.deviceTokenRenewalAnchor = anchor
        if grant.renewAfterSeconds == nil {
            NSLog(
                "jasnost: device token renewed without a server lead time; "
                    + "falling back to the legacy fraction")
        }
        resetAttemptState(for: grant.tokenId)
        let due = JazzDeviceTokenRenewalPolicy.due(
            anchor: anchor,
            expiresAt: grant.expiresAtDate)
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
        tokenId: String?,
        expiresAt: Date?
    ) {
        guard case let .retryable(reason) = disposition else {
            isStopped = true
            observedTokenId = tokenId
            backoffUntil = nil
            NSLog(
                "jasnost: device token renewal stopped: tokenId=%@ outcome=%@",
                tokenId ?? "unknown",
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
        // Every trigger honours this window, so the escalating schedule is not silently truncated
        // to the poll interval.
        backoffUntil = nextAttemptAt
        observedTokenId = tokenId
        NSLog(
            "jasnost: device token renewal retrying: tokenId=%@ attempt=%d nextAttempt=%@",
            tokenId ?? "unknown",
            consecutiveFailures,
            Timestamps.iso8601(nextAttemptAt))
        publish(
            .retrying(nextAttemptAt: nextAttemptAt, reason: reason),
            tokenId: tokenId,
            expiresAt: expiresAt)
        scheduleRetry(after: delay)
    }

    /// Forget every per-credential counter. Called when the observed credential changes — a
    /// re-enrollment must not inherit the previous credential's refusal, backoff window or
    /// attempt count.
    private func resetAttemptState(for tokenId: String?) {
        observedTokenId = tokenId
        consecutiveFailures = 0
        backoffUntil = nil
        isStopped = false
        lastAttemptAt = nil
        retryTimer?.invalidate()
        retryTimer = nil
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
