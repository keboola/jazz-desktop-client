import Foundation

/// Inactive-by-default concrete worker for BestEffortTransport. No Keychain access, enrollment,
/// File preparation, archive IO, or capture activation. Requests must already have scoped authority.
public final class BestEffortTransportDriver: @unchecked Sendable {
    public struct Media: Sendable {
        public let request: URLRequest
        public let maximumBytes: Int
        public let expiresAt: TimeInterval
        /// Runs only after reservation on the bounded encoder queue. Must bound its own working
        /// set and return only after physical encoding/read ends. Cancellation is advisory.
        public let encode: @Sendable (Int, @escaping @Sendable () -> Bool) throws -> Data
        public init(
            request: URLRequest, maximumBytes: Int, expiresAt: TimeInterval,
            encode: @escaping @Sendable (Int, @escaping @Sendable () -> Bool) throws -> Data
        ) {
            self.request = request
            self.maximumBytes = maximumBytes
            self.expiresAt = expiresAt
            self.encode = encode
        }
    }
    public enum Failure: Error { case invalidRequest, oversizedEncoding }
    private final class Encoding: Operation, @unchecked Sendable {
        let ticket: BestEffortTransport.Ticket
        let component: BestEffortTransport.Component
        let encode: @Sendable (@escaping @Sendable () -> Bool) throws -> Data
        var output: Data?
        init(
            ticket: BestEffortTransport.Ticket, component: BestEffortTransport.Component,
            encode: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> Data
        ) {
            self.ticket = ticket
            self.component = component
            self.encode = encode
        }
        override func main() {
            guard !isCancelled else { return }
            autoreleasepool { output = try? encode { [weak self] in self?.isCancelled ?? true } }
        }
    }
    private let gate = NSLock()
    private let transport: BestEffortTransport
    private let session: JazzCredentialSafeHTTPSession
    private let eventRequest: URLRequest
    private let authorityDeadline: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let encoders = OperationQueue()
    private var encoding: [UUID: Encoding] = [:]
    private var uploads: [UUID: URLSessionUploadTask] = [:]
    private var mediaRequests: [UUID: (request: URLRequest, expiresAt: TimeInterval)] = [:]
    private var reports: [BestEffortTransport.Report] = []
    private var reportOverflow = false
    private var generation: UUID?
    private var timer: DispatchSourceTimer?
    private var revocationHandler: (@MainActor @Sendable (UUID) -> Void)?
    private var notifiedRevocation = false

    public func onRevocation(_ handler: @escaping @MainActor @Sendable (UUID) -> Void) {
        gate.withLock { revocationHandler = handler }
    }
    private func notifyRevocation(_ token: UUID?) {
        guard let token, !notifiedRevocation, let handler = revocationHandler else { return }
        notifiedRevocation = true
        // At most one MainActor notification per owner, outside all locks; never per offer/tick.
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(token) } }
    }

    public init(
        limits: BestEffortTransport.Limits, eventRequest: URLRequest,
        authorityDeadline: TimeInterval,
        configuration: URLSessionConfiguration = .ephemeral, delegateQueue: OperationQueue? = nil,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        automaticallySchedule: Bool = true
    ) throws {
        guard Self.valid(eventRequest, method: "POST"), authorityDeadline.isFinite,
            authorityDeadline > now()
        else { throw Failure.invalidRequest }
        self.authorityDeadline = authorityDeadline
        self.transport = BestEffortTransport(limits: limits)
        self.eventRequest = eventRequest
        self.now = now
        configuration.timeoutIntervalForResource = limits.attemptTime
        configuration.httpMaximumConnectionsPerHost = limits.inFlight
        self.session = JazzCredentialSafeHTTPSession(
            configuration: configuration, delegateQueue: delegateQueue)
        encoders.maxConcurrentOperationCount = limits.encodingParts
        encoders.qualityOfService = .utility
        if automaticallySchedule {
            // One coalescing timer, never a task/mailbox per rejected capture offer.
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "jazz.best-effort.tick"))
            timer.schedule(
                deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }
    deinit {
        timer?.cancel()
        session.invalidateAndCancel()
    }

    /// Explicit intent AND coordinated server authority are prerequisites, not granted here.
    public func startExplicitly(generation token: UUID) -> Bool {
        gate.withLock {
            guard now() < authorityDeadline, encoding.isEmpty, uploads.isEmpty,
                transport.startExplicitly(generation: token, now: now())
            else { return false }
            generation = token
            return true
        }
    }

    /// Reserve before encoding. Validates a bounded fixed-shape OTLP model without constructing
    /// JSON bytes; oversize input is not retained. Media working-set ownership is its encoder's.
    @discardableResult
    public func offer(
        unitID: UUID, generation token: UUID, logs: Otlp.ExportLogsServiceRequest,
        media: Media? = nil
    ) -> Bool {
        guard gate.try() else { return false }
        defer { gate.unlock() }
        guard generation == token, now() < authorityDeadline,
            let eventBytes = BestEffortLogEncoding.maximumBytes(
                logs, limit: transport.limits.partBytes),
            media == nil
                || (Self.valid(media!.request, method: "PUT")
                    && media!.maximumBytes > 0 && media!.maximumBytes <= transport.limits.partBytes
                    && media!.expiresAt.isFinite && now() < media!.expiresAt),
            !reports.contains(where: { $0.unitID == unitID }),
            let ticket = transport.reserve(
                unitID: unitID, eventBytes: eventBytes,
                mediaBytes: media?.maximumBytes ?? 0, generation: token, now: now())
        else { return false }
        collectReports()
        if let media { mediaRequests[unitID] = (media.request, media.expiresAt) }
        // Compact after reservation, before retaining the model on a worker. Tiny array/string
        // views must not keep a caller's oversized backing allocations alive in our queue.
        let logs = BestEffortLogEncoding.compact(logs)
        schedule(ticket, component: .event) { cancelled in
            guard !cancelled() else { throw CancellationError() }
            // Existing OTLP model/mapper, no new wire shape.
            let data = try JSONEncoder().encode(logs)
            guard data.count <= eventBytes else { throw Failure.oversizedEncoding }
            return data
        }
        if let media {
            schedule(ticket, component: .media) { cancelled in
                let data = try media.encode(media.maximumBytes, cancelled)
                guard data.count <= media.maximumBytes else { throw Failure.oversizedEncoding }
                return data
            }
        }
        return true
    }

    /// Called by the single timer and physical completions; also deterministic with an injected clock.
    public func tick() { gate.withLock { pump() } }

    public func suspend(_ reason: BestEffortTransport.Fence) {
        gate.withLock {
            generation = nil
            transport.suspend(reason)
            cancelOwners(transport.snapshot)
            collectReports()
        }
    }
    public var snapshot: BestEffortTransport.Snapshot { gate.withLock { transport.snapshot } }
    public var adapterUsage:
        (
            encoders: Int, uploads: Int, responseBytes: Int, peakResponseBytes: Int, reports: Int,
            overflow: Bool
        )
    {
        gate.withLock {
            let usage = session.boundedResponseUsage
            return (
                encoding.count, uploads.count, usage.bytes, usage.peakBytes, reports.count,
                reportOverflow || transport.snapshot.reportOverflow
            )
        }
    }
    public func drainReports() -> [BestEffortTransport.Report] {
        gate.withLock {
            collectReports()
            defer { reports.removeAll(keepingCapacity: true) }
            return reports
        }
    }

    private func schedule(
        _ ticket: BestEffortTransport.Ticket,
        component: BestEffortTransport.Component,
        encode: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> Data
    ) {
        let id = UUID()
        let operation = Encoding(ticket: ticket, component: component, encode: encode)
        encoding[id] = operation
        operation.completionBlock = { [self, weak operation] in
            // Operation.main has actually returned. cancel()/deadline alone never gets here.
            guard let operation else { return }
            gate.withLock {
                let data = operation.isCancelled ? nil : operation.output
                operation.output = nil
                transport.finishEncoding(ticket, component: component, data: data, now: now())
                encoding.removeValue(forKey: id)
                pump()
            }
        }
        encoders.addOperation(operation)
    }
    private func pump() {
        if now() >= authorityDeadline {
            notifyRevocation(generation)
            generation = nil
            transport.suspend(.revoked)
        }
        if let generation {
            cancelOwners(transport.advance(generation: generation, now: now()))
        } else {
            cancelOwners(transport.snapshot)
        }
        if transport.snapshot.fence == .clock {
            notifyRevocation(generation)
            generation = nil
        }
        collectReports()
        guard let generation else { return }
        var failed: [(UUID, BestEffortTransport.Result)] = []
        while transport.withNextAttempt(
            generation: generation, now: now(),
            start: { attempt in
                // Only URLSession registration/resume under the atomic start lock. No callbacks,
                // credentials, disk, async continuations or arbitrary caller closures run here.
                guard now() < authorityDeadline else {
                    failed.append((attempt.id, .unauthorized))
                    return
                }
                let media = mediaRequests[attempt.unitID]
                if attempt.component == .media, media == nil || now() >= media!.expiresAt {
                    failed.append((attempt.id, .rejected))
                    return
                }
                var request = attempt.component == .event ? eventRequest : media!.request
                request.timeoutInterval = max(0.001, attempt.deadline - now())
                do {
                    let task = try session.makeBoundedUpload(
                        for: request, from: attempt.payload,
                        maximumResponseBytes: BestEffortOTLPAcknowledgement.maximumBytes
                    ) { [self] result in
                        gate.withLock {
                            uploads.removeValue(forKey: attempt.id)
                            let outcome = Self.classify(result, component: attempt.component)
                            if outcome == .unauthorized, self.generation == attempt.generation {
                                notifyRevocation(self.generation)
                            }
                            transport.finishAttempt(attempt.id, result: outcome, now: now())
                            pump()
                        }
                    }
                    uploads[attempt.id] = task
                    if now() < authorityDeadline
                        && (attempt.component == .event || now() < media!.expiresAt)
                    {
                        task.resume()
                    } else {
                        task.cancel()
                    }
                } catch { failed.append((attempt.id, .uncertain)) }
            })
        {}
        for (id, result) in failed { transport.finishAttempt(id, result: result, now: now()) }
        collectReports()
    }
    private func cancelOwners(_ snapshot: BestEffortTransport.Snapshot) {
        for id in snapshot.cancellations { uploads[id]?.cancel() }
        for operation in encoding.values
        where snapshot.encodingCancellations.contains(operation.ticket) {
            operation.cancel()
        }
    }
    private func collectReports() {
        for report in transport.drainReports() {
            mediaRequests.removeValue(forKey: report.unitID)
            if reports.count == transport.limits.units {
                reports.removeFirst()
                reportOverflow = true
            }
            reports.append(report)
        }
    }
    private static func valid(_ request: URLRequest, method: String) -> Bool {
        let headers = request.allHTTPHeaderFields ?? [:]
        let forbidden = Set([
            "host", "content-length", "transfer-encoding", "connection", "proxy-authorization",
            "cookie",
        ])
        guard headers.count <= 64,
            !headers.keys.contains(where: { forbidden.contains($0.lowercased()) })
        else { return false }
        var headerBytes = 0
        for (key, value) in headers {
            headerBytes += key.utf8.prefix(16385).count + value.utf8.prefix(16385).count
            if headerBytes > 16384 { return false }
        }
        guard let url = request.url,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "https", parts.host?.isEmpty == false, parts.user == nil,
            parts.password == nil, parts.fragment == nil, url.absoluteString.utf8.count <= 8192,
            request.httpMethod == method, request.httpBody == nil, request.httpBodyStream == nil
        else { return false }
        return true
    }
    private static func classify(
        _ result: Result<(Data, URLResponse), Error>,
        component: BestEffortTransport.Component
    ) -> BestEffortTransport.Result {
        guard case .success((let data, let response)) = result,
            let http = response as? HTTPURLResponse
        else { return .uncertain }
        let header = http.value(forHTTPHeaderField: "Retry-After")
        // Invalid/date-form values are conservatively non-retryable, never shortened. Date-form
        // support needs an injected wall-clock mapping; monotonic scheduling must not guess it.
        let retryAfter: TimeInterval? = header.map { value in
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
                ? Double(value) ?? .nan : .nan
        }
        if component == .media, [200, 201, 204].contains(http.statusCode) { return .accepted }
        return BestEffortOTLPAcknowledgement.classify(
            status: http.statusCode, body: data, retryAfter: retryAfter)
    }
}

/// Conservative JSON expansion bound for the existing nonrecursive OTLP model. Rejects huge
/// arrays/strings before JSONEncoder allocates output. No new encoder or altered wire mapping.
enum BestEffortLogEncoding {
    static func compact(_ logs: Otlp.ExportLogsServiceRequest) -> Otlp.ExportLogsServiceRequest {
        func string(_ s: String) -> String { String(decoding: Array(s.utf8), as: UTF8.self) }
        func value(_ v: Otlp.AnyValue) -> Otlp.AnyValue {
            if case .string(let s) = v { return .string(string(s)) }
            return v
        }
        func attributes(_ a: [Otlp.KeyValue]) -> [Otlp.KeyValue] {
            a.map { .init(key: string($0.key), value: value($0.value)) }
        }
        return .init(
            resourceLogs: logs.resourceLogs.map { resource in
                .init(
                    resource: .init(attributes: attributes(resource.resource.attributes)),
                    scopeLogs: resource.scopeLogs.map { scope in
                        .init(
                            scope: .init(name: string(scope.scope.name)),
                            logRecords: scope.logRecords.map { record in
                                .init(
                                    timeUnixNano: string(record.timeUnixNano),
                                    observedTimeUnixNano: string(record.observedTimeUnixNano),
                                    severityText: string(record.severityText),
                                    severityNumber: record.severityNumber,
                                    traceId: string(record.traceId), spanId: string(record.spanId),
                                    body: value(record.body),
                                    attributes: attributes(record.attributes))
                            })
                    })
            })
    }
    static func maximumBytes(_ logs: Otlp.ExportLogsServiceRequest, limit: Int) -> Int? {
        var remaining = limit
        func charge(_ n: Int) throws {
            guard n >= 0, n <= remaining else {
                throw BestEffortTransportDriver.Failure.oversizedEncoding
            }
            remaining -= n
        }
        func string(_ s: String) throws {
            // At most six JSON bytes per UTF8 byte (control-character escaping).
            let count = s.utf8.prefix(remaining / 6 + 1).count
            try charge(count * 6)
        }
        func value(_ v: Otlp.AnyValue) throws {
            try charge(64)
            if case .string(let s) = v { try string(s) }
            if case .double(let d) = v, !d.isFinite {
                throw BestEffortTransportDriver.Failure.oversizedEncoding
            }
        }
        func attributes(_ pairs: [Otlp.KeyValue]) throws {
            guard pairs.count <= remaining / 256 else {
                throw BestEffortTransportDriver.Failure.oversizedEncoding
            }
            for pair in pairs {
                try charge(256)
                try string(pair.key)
                try value(pair.value)
            }
        }
        do {
            try charge(128)
            guard logs.resourceLogs.count <= remaining / 256 else { return nil }
            for resource in logs.resourceLogs {
                try charge(256)
                try attributes(resource.resource.attributes)
                guard resource.scopeLogs.count <= remaining / 256 else { return nil }
                for scope in resource.scopeLogs {
                    try charge(256)
                    try string(scope.scope.name)
                    guard scope.logRecords.count <= remaining / 512 else { return nil }
                    for record in scope.logRecords {
                        try charge(512)
                        for s in [
                            record.timeUnixNano, record.observedTimeUnixNano, record.severityText,
                            record.traceId, record.spanId,
                        ] { try string(s) }
                        try value(record.body)
                        try attributes(record.attributes)
                    }
                }
            }
            return limit - remaining
        } catch { return nil }
    }
}
