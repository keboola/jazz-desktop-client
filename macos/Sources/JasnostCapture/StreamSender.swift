import Foundation
import JasnostCaptureCore

/// Spool-draining background sender — the ONLY thing that talks to the Keboola Data Stream.
/// CaptureController appends batches to the EventSpool and nudges; this actor drains the
/// spool in per-session FIFO order and POSTs OTLP/JSON. A signed liveCompatibility item is
/// journaled only after every destination pinned from its signed enrollment generation
/// acknowledges the exact payload persisted beside the event. Archive-only enrollment requires
/// Jazz alone; a signed legacy endpoint requires both legacy Data Stream and Jazz. Legacy-only
/// sessions retain their original one-destination behavior.
/// The spool IS the retry queue: there is no in-memory requeue, so a crash or an offline
/// week loses nothing (leftovers ship on the next launch via ``start()``'s initial drain).
///
/// A session's `capture-session` span ships to `/v1/traces` once the session has `endedAt`
/// set AND all its batches are journaled (``EventSpool/sessionsAwaitingSpan()``), and is
/// marked sent durably so relaunches never duplicate it.
actor StreamSender {
    /// Sender state for the UI (menu/status). Published through ``setStatusHandler(_:)``.
    struct Status: Equatable, Sendable {
        /// Unsent batch files across all sessions (the durable backlog).
        var pendingCount = 0
        var lastSendAt: Date?
        var lastError: String?
        var isSending = false
    }

    /// Backoff bounds for send failures: 1s doubling to 60s, plus 0–25% random jitter so
    /// relaunched agents don't synchronize their retries against a recovering stream.
    private enum Backoff {
        static let initial: TimeInterval = 1
        static let max: TimeInterval = 60
    }
    /// Whole-call budget for one OTLP POST (small JSON payloads).
    private static let postTimeout: TimeInterval = 30
    private static let postSession: JazzCredentialSafeHTTPSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = postTimeout
        configuration.timeoutIntervalForResource = postTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return JazzCredentialSafeHTTPSession(configuration: configuration)
    }()

    private let spool: EventSpool
    /// Where to POST (`<endpoint>/v1/logs|traces`). The URL embeds the stream secret, so it
    /// comes from the Keychain via this provider and is never logged or kept in a property.
    private let endpoint: @Sendable () -> String?
    /// Reads the scoped signed token only when one native request is about to run. The provider
    /// never participates in legacy/off-mode sends.
    private let credentialProvider: any JazzArchiveCredentialProvider
    private let serviceName: String

    private var status = Status()
    private var onStatus: (@Sendable (Status) -> Void)?
    private var loopTask: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var nudged = false
    private var backoff = Backoff.initial

    init(
        spool: EventSpool,
        endpoint: @escaping @Sendable () -> String?,
        credentialProvider: any JazzArchiveCredentialProvider,
        serviceName: String = OtlpMapper.defaultServiceName
    ) {
        self.spool = spool
        self.endpoint = endpoint
        self.credentialProvider = credentialProvider
        self.serviceName = serviceName
    }

    /// Register the UI callback (invoked on every status change, starting immediately).
    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        onStatus = handler
        handler(status)
    }

    func currentStatus() -> Status { status }

    /// Batches + spans still waiting to ship — lets shutdown wait (bounded) for a drain.
    func pendingWork() -> Int {
        spool.deliveryBatches().count + spool.sessionsAwaitingSpan().count
    }

    /// Start the drain loop. Call once at launch — leftovers from a crash/offline period
    /// ship immediately, before any new capture begins.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await run() }
    }

    /// Wake the loop (new batch appended, session ended, or settings changed).
    func nudge() {
        nudged = true
        wake?.resume()
        wake = nil
    }

    // MARK: - Loop

    private func run() async {
        while !Task.isCancelled {
            let allShipped = await drainOnce()
            if allShipped {
                backoff = Backoff.initial
                // Anything appended during the drain? Loop again; otherwise sleep on a nudge.
                if spool.deliveryBatches().isEmpty && spool.sessionsAwaitingSpan().isEmpty {
                    await waitForNudge()
                }
            } else {
                // Exponential backoff with jitter, slept in short slices so a nudge breaks it
                // promptly. Without this, a nudge during the sleep only sets `nudged` (it can't
                // interrupt Task.sleep), so a batch queued while offline — or the very first
                // drain on a fresh install, which fails until onboarding stores the endpoint and
                // calls nudge() — would wait out the full (up to 60s) backoff before shipping.
                let jitter = backoff * Double.random(in: 0...0.25)
                let total = backoff + jitter
                let slice: TimeInterval = 0.25
                var slept: TimeInterval = 0
                while slept < total && !nudged && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                    slept += slice
                }
                if nudged {
                    // Fresh data or a just-configured endpoint — retry now and reset the curve.
                    nudged = false
                    backoff = Backoff.initial
                } else {
                    backoff = min(backoff * 2, Backoff.max)
                }
            }
        }
    }

    private func waitForNudge() async {
        if nudged {
            nudged = false
            return
        }
        // Actor isolation makes this race-free: nudge() can only run once we suspend.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in wake = c }
        nudged = false
    }

    /// One full drain pass. Returns false on the first send failure (the caller backs off
    /// — per-session FIFO must not skip past a failed batch); true when everything that was
    /// pending got shipped.
    private func drainOnce() async -> Bool {
        let batches = spool.deliveryBatches()
        let spans = spool.sessionsAwaitingSpan()
        publish {
            $0.pendingCount = batches.count
            $0.isSending = !(batches.isEmpty && spans.isEmpty)
        }
        guard !batches.isEmpty || !spans.isEmpty else { return true }

        for batch in batches {
            let events = spool.readEvents(batch)
            let meta = spool.sessionMeta(sessionId: batch.sessionId)
            let binding = meta?.liveCanonicalBinding
            let live = spool.readLiveProjection(batch)
            // A fully-corrupt/empty batch file ships nothing; journal it so it can never
            // wedge the legacy queue. Canonical projection batches fail closed and stay durable.
            guard !events.isEmpty else {
                if binding != nil || live != nil {
                    publish {
                        $0.lastError = "canonical live projection event is unreadable"
                        $0.isSending = false
                    }
                    return false
                }
                try? spool.markSent(batch)
                continue
            }
            let context = sessionContext(for: batch.sessionId)
            let logRecords: [Otlp.LogRecord]
            if let binding {
                guard events.count == 1, let live, live.binding == binding else {
                    publish {
                        $0.lastError = "canonical live projection sidecar is missing or invalid"
                        $0.isSending = false
                    }
                    return false
                }
                logRecords = JazzLiveOtlpProjection.logRecords(
                    event: events[0],
                    batch: live,
                    context: context)
            } else {
                guard live == nil else {
                    publish {
                        $0.lastError = "canonical live projection session binding is unavailable"
                        $0.isSending = false
                    }
                    return false
                }
                logRecords = events.map { OtlpMapper.logRecord(for: $0, in: context) }
            }
            guard
                let body = try? JSONEncoder().encode(
                    OtlpMapper.logsRequest(logRecords: logRecords, in: context))
            else {
                if binding != nil {
                    publish {
                        $0.lastError = "canonical live projection could not be encoded"
                        $0.isSending = false
                    }
                    return false
                }
                // Encoding legacy Codable models cannot realistically fail; journal rather than
                // wedge the compatibility queue.
                try? spool.markSent(batch)
                continue
            }
            if let routeBinding = meta?.liveRouteBinding {
                let persistedBody: Data
                do {
                    persistedBody = try spool.prepareLiveDeliveryPayload(
                        body,
                        for: batch)
                } catch {
                    publish {
                        $0.lastError = "canonical live payload persistence failed"
                        $0.isSending = false
                    }
                    return false
                }
                var delivery = spool.liveDeliveryState(batch)
                if delivery.requires(.legacy) && !delivery.legacyAccepted {
                    if let error = await postLegacy(signal: .logs, body: persistedBody) {
                        publish {
                            $0.lastError = error
                            $0.isSending = false
                        }
                        return false
                    }
                    do {
                        try spool.markLiveDeliveryAccepted(.legacy, for: batch)
                    } catch {
                        publish {
                            $0.lastError = "legacy acknowledgement persistence failed"
                            $0.isSending = false
                        }
                        return false
                    }
                    delivery = spool.liveDeliveryState(batch)
                }
                if delivery.requires(.jazz) && !delivery.jazzAccepted {
                    if let error = await postJazz(
                        signal: .logs,
                        body: persistedBody,
                        routeBinding: routeBinding,
                        expectedCanonicalItems: logRecords.count)
                    {
                        publish {
                            $0.lastError = error
                            $0.isSending = false
                        }
                        return false
                    }
                    do {
                        try spool.markLiveDeliveryAccepted(.jazz, for: batch)
                    } catch {
                        publish {
                            $0.lastError = "Jazz acknowledgement persistence failed"
                            $0.isSending = false
                        }
                        return false
                    }
                }
            } else if let error = await postLegacy(signal: .logs, body: body) {
                publish {
                    $0.lastError = error
                    $0.isSending = false
                }
                return false
            }
            do {
                try spool.markSent(batch)
            } catch {
                // Disk trouble journaling the batch: stop the pass and back off — an
                // immediate re-drain would re-POST the same (already accepted) batch in a
                // hot loop. The duplicate on the next pass is the lesser evil vs data loss.
                publish {
                    $0.lastError = "journal move failed: \(error)"
                    $0.isSending = false
                }
                return false
            }
            publish {
                $0.lastSendAt = Date()
                $0.lastError = nil
                $0.pendingCount = max(0, $0.pendingCount - 1)
            }
        }

        // Spans ship once a session has ended and all its batches are journaled — recompute,
        // because the batch sends above may have just completed more sessions.
        for meta in spool.sessionsAwaitingSpan() {
            guard let endedAt = meta.endedAt else { continue }
            let context = OtlpMapper.SessionContext(
                sessionId: meta.sessionId, traceId: meta.traceId, spanId: meta.spanId,
                startedAt: meta.startedAt, kind: meta.kind, user: meta.user,
                instanceName: meta.instanceName, areaId: meta.areaId, areaName: meta.areaName,
                serviceName: serviceName)
            let traceRequest: Otlp.ExportTraceServiceRequest
            switch (meta.liveCanonicalBinding, meta.liveCaptureCommit) {
            case let (binding?, commit?):
                guard let liveRequest = try? OtlpMapper.liveTraceRequest(
                    in: context,
                    endedAt: endedAt,
                    binding: binding,
                    captureCommit: commit)
                else {
                    publish {
                        $0.lastError = "canonical CaptureCommit projection is invalid"
                        $0.isSending = false
                    }
                    return false
                }
                traceRequest = liveRequest
            case (nil, nil):
                traceRequest = OtlpMapper.traceRequest(in: context, endedAt: endedAt)
            case (.some, nil), (nil, .some):
                publish {
                    $0.lastError = "canonical live projection commit binding is incomplete"
                    $0.isSending = false
                }
                return false
            }
            guard let body = try? JSONEncoder().encode(traceRequest) else {
                // Encoding Codable models cannot realistically fail; mark sent rather than
                // wedge the loop on a span that can never ship.
                try? spool.markSpanSent(sessionId: meta.sessionId)
                continue
            }
            if let routeBinding = meta.liveRouteBinding {
                let persistedBody: Data
                do {
                    persistedBody = try spool.prepareLiveSpanDeliveryPayload(
                        sessionId: meta.sessionId,
                        candidate: body)
                } catch {
                    publish {
                        $0.lastError = "canonical live span persistence failed"
                        $0.isSending = false
                    }
                    return false
                }
                var delivery = spool.liveSpanDeliveryState(
                    sessionId: meta.sessionId)
                if delivery.requires(.legacy) && !delivery.legacyAccepted {
                    if let error = await postLegacy(
                        signal: .traces,
                        body: persistedBody)
                    {
                        publish {
                            $0.lastError = error
                            $0.isSending = false
                        }
                        return false
                    }
                    do {
                        try spool.markLiveSpanDeliveryAccepted(
                            .legacy,
                            sessionId: meta.sessionId)
                    } catch {
                        publish {
                            $0.lastError = "legacy span acknowledgement persistence failed"
                            $0.isSending = false
                        }
                        return false
                    }
                    delivery = spool.liveSpanDeliveryState(
                        sessionId: meta.sessionId)
                }
                if delivery.requires(.jazz) && !delivery.jazzAccepted {
                    if let error = await postJazz(
                        signal: .traces,
                        body: persistedBody,
                        routeBinding: routeBinding,
                        expectedCanonicalItems: 1)
                    {
                        publish {
                            $0.lastError = error
                            $0.isSending = false
                        }
                        return false
                    }
                    do {
                        try spool.markLiveSpanDeliveryAccepted(
                            .jazz,
                            sessionId: meta.sessionId)
                    } catch {
                        publish {
                            $0.lastError = "Jazz span acknowledgement persistence failed"
                            $0.isSending = false
                        }
                        return false
                    }
                }
            } else if let error = await postLegacy(signal: .traces, body: body) {
                publish {
                    $0.lastError = error
                    $0.isSending = false
                }
                return false
            }
            do {
                try spool.markSpanSent(sessionId: meta.sessionId)
            } catch {
                // Same hot-loop guard as markSent above: back off instead of re-POSTing.
                publish {
                    $0.lastError = "span marker write failed: \(error)"
                    $0.isSending = false
                }
                return false
            }
            publish {
                $0.lastSendAt = Date()
                $0.lastError = nil
            }
        }
        publish { $0.isSending = false }
        return true
    }

    /// OTLP context from the persisted spool meta. Missing/corrupt meta gets a synthesized
    /// replacement (fresh ids, persisted back) so a damaged meta.json can never strand a
    /// session's events — they still ship, just under a fresh trace.
    private func sessionContext(for sessionId: String) -> OtlpMapper.SessionContext {
        let meta: EventSpool.SessionMeta
        if let existing = spool.sessionMeta(sessionId: sessionId) {
            meta = existing
        } else {
            meta = EventSpool.SessionMeta(
                sessionId: sessionId, traceId: OtlpIds.traceId(), spanId: OtlpIds.spanId(),
                startedAt: Timestamps.iso8601(), user: "")
            try? spool.createSession(meta)
        }
        return OtlpMapper.SessionContext(
            sessionId: meta.sessionId, traceId: meta.traceId, spanId: meta.spanId,
            startedAt: meta.startedAt, kind: meta.kind, user: meta.user,
            instanceName: meta.instanceName, areaId: meta.areaId, areaName: meta.areaName,
            serviceName: serviceName)
    }

    private func postLegacy(
        signal: JazzLiveCompatibilitySignal,
        body: Data
    ) async -> String? {
        guard let raw = endpoint(), !raw.isEmpty else {
            return "Stream endpoint not configured — connect Keboola in Settings"
        }
        let base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        return await Self.postLegacyURL(
            base + "/v1/" + signal.rawValue,
            body: body)
    }

    /// Resolve the token for every attempt, bind it to the exact session-pinned signed archive
    /// route, and refuse redirects through the credential-safe session.
    private func postJazz(
        signal: JazzLiveCompatibilitySignal,
        body: Data,
        routeBinding: JazzArchiveUploadRouteBinding,
        expectedCanonicalItems: Int
    ) async -> String? {
        do {
            let plan = try JazzLiveCompatibilityRequestPlan(
                routeBinding: routeBinding,
                signal: signal)
            let credential = try await credentialProvider.credential(
                for: routeBinding)
            let request = try plan.request(
                body: body,
                credential: credential,
                timeout: Self.postTimeout)
            let (responseData, response) = try await Self.postSession.boundedData(
                for: request,
                maximumResponseBytes: 64 * 1_024)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return "Jazz live HTTP \(code)"
            }
            _ = try JazzLiveCompatibilityAcceptance(
                responseData: responseData,
                expectedPayload: body,
                expectedCanonicalItems: expectedCanonicalItems)
            return nil
        } catch let error as URLError {
            return "Jazz live send failed (URLError \(error.code.rawValue))"
        } catch JazzArchiveUploadError.credentialExpired {
            return "Jazz live credential expired"
        } catch JazzArchiveUploadError.credentialUnavailable {
            return "Jazz live credential unavailable"
        } catch JazzArchiveUploadError.credentialBindingMismatch {
            return "Jazz live route authority mismatch"
        } catch {
            return "Jazz live send failed"
        }
    }

    /// POST one legacy OTLP/JSON payload. Returns nil on 2xx, else a short error string WITHOUT
    /// the URL or response body — the endpoint path embeds the stream secret and neither server
    /// reflections nor Foundation diagnostics may reach logs/UI.
    private static func postLegacyURL(_ urlString: String, body: Data) async -> String? {
        guard let url = URL(string: urlString) else { return "invalid stream endpoint URL" }
        var req = URLRequest(url: url, timeoutInterval: postTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (_, response) = try await postSession.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return "stream HTTP \(code)"
            }
            return nil
        } catch {
            // NEVER interpolate error.localizedDescription here: for connection failures it can
            // embed the failing URL, whose path carries the stream secret, and this string is
            // shown verbatim in the menu-bar status. Surface only the URLError code.
            if let urlError = error as? URLError {
                return "stream send failed (URLError \(urlError.code.rawValue))"
            }
            return "stream send failed"
        }
    }

    private func publish(_ mutate: (inout Status) -> Void) {
        mutate(&status)
        onStatus?(status)
    }
}
