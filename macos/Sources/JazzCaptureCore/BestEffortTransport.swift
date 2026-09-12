import Foundation

/// Volatile transport ownership only. NOT capture/enrollment authority, an archive spool, or a
/// completeness ledger. Callers reserve before encoding already-masked payloads using existing
/// encoders. No files, network calls, timers, Tasks, credentials or canonical schema changes here.
/// Production activation must remain behind CaptureStartIntent + coordinated server authority.
public final class BestEffortTransport: @unchecked Sendable {
    public struct Limits: Sendable {
        public let units: Int, bytes: Int, partBytes: Int, encodingParts: Int
        public let inFlight: Int, inFlightBytes: Int, attempts: Int
        public let age: TimeInterval, attemptTime: TimeInterval, backoff: TimeInterval,
            backoffCap: TimeInterval
        public init(
            units: Int = 64, bytes: Int = 16 * 1024 * 1024,
            partBytes: Int = 4 * 1024 * 1024, encodingParts: Int = 4,
            inFlight: Int = 2, inFlightBytes: Int = 8 * 1024 * 1024,
            attempts: Int = 3, age: TimeInterval = 30, attemptTime: TimeInterval = 10,
            backoff: TimeInterval = 1, backoffCap: TimeInterval = 8
        ) throws {
            guard (1...4096).contains(units), (1...256 * 1024 * 1024).contains(bytes),
                partBytes > 0, partBytes <= bytes, encodingParts > 0, encodingParts <= 2 * units,
                inFlight > 0, inFlight <= 2 * units, inFlightBytes >= partBytes,
                inFlightBytes <= bytes,
                (1...16).contains(attempts),
                [age, attemptTime, backoff, backoffCap].allSatisfy({
                    $0.isFinite && $0 > 0 && $0 <= 86400
                }),
                attemptTime <= age, backoff <= backoffCap
            else { throw Failure.invalidLimits }
            self.units = units
            self.bytes = bytes
            self.partBytes = partBytes
            self.encodingParts = encodingParts
            self.inFlight = inFlight
            self.inFlightBytes = inFlightBytes
            self.attempts = attempts
            self.age = age
            self.attemptTime = attemptTime
            self.backoff = backoff
            self.backoffCap = backoffCap
        }
    }
    public enum Failure: Error { case invalidLimits }
    public enum Component: CaseIterable, Sendable { case event, media }
    public enum Fence: Sendable { case startup, pause, stop, lock, sleep, revoked, clock }
    public enum Disposition: Equatable, Sendable {
        case notExpected, pending, hopAccepted, unavailable, unknown
    }
    public enum Result: Equatable, Sendable {
        case accepted, rejected, uncertain, partial
        /// Only an adapter's explicit retryable response, never a lost/partial ACK.
        case retryable(after: TimeInterval?)
        case unauthorized
    }
    public struct Ticket: Equatable, Sendable { fileprivate let value: UUID }
    public struct Attempt: Sendable {
        public let id: UUID, unitID: UUID, generation: UUID
        public let component: Component, payload: Data, number: Int, deadline: TimeInterval
    }
    public struct Report: Sendable {
        public let unitID: UUID, generation: UUID, event: Disposition, media: Disposition
        /// Even two hop ACKs are not archive/analysis completeness or an exact global loss count.
        public var coverageUnknown: Bool { true }
    }
    public struct Snapshot: Sendable {
        public let units: Int, reservedBytes: Int, encodingParts: Int, inFlight: Int,
            inFlightBytes: Int
        public let reports: Int, reportOverflow: Bool, fence: Fence?, cancellations: [UUID]
        public let encodingCancellations: [Ticket]
        public var temporaryFileBytes: Int { 0 }
        public var coverageUnknown: Bool { true }
    }
    private enum Phase { case encoding, queued, flight, done }
    private final class Part {
        var phase: Phase, budget: Int, data: Data?, attempt: UUID?, tries = 0
        var ready: TimeInterval = 0, deadline: TimeInterval = 0, cancel = false
        var disposition: Disposition
        var uncertainDelivery = false
        init(_ budget: Int) {
            self.budget = budget
            phase = budget == 0 ? .done : .encoding
            disposition = budget == 0 ? .notExpected : .pending
        }
    }
    private final class Unit {
        let id: UUID, ticket = Ticket(value: UUID()), generation: UUID, expires: TimeInterval
        let event: Part, media: Part
        init(id: UUID, generation: UUID, expires: TimeInterval, event: Int, media: Int) {
            self.id = id
            self.generation = generation
            self.expires = expires
            self.event = Part(event)
            self.media = Part(media)
        }
        func part(_ component: Component) -> Part { component == .event ? event : media }
        var parts: [Part] { [event, media] }
    }
    public let limits: Limits
    private let lock = NSLock()
    // ponytail: bounded O(units) scans, no per-offer Task/mailbox or unbounded index/history.
    private var units: [Unit] = [], reports: [Report] = []
    private var generation: UUID?, lastGeneration: UUID?, lastTime: TimeInterval = 0
    private var fence: Fence? = .startup
    private var reportOverflow = false

    public init(limits: Limits) { self.limits = limits }

    /// Only explicit intent with fresh authority may call this; network recovery never does.
    /// Revocation/invalid clock require a new owner, not reactivation of this instance.
    public func startExplicitly(generation token: UUID, now: TimeInterval) -> Bool {
        lock.withLock {
            guard units.isEmpty, generation == nil, token != lastGeneration,
                fence != .revoked, fence != .clock, clock(now)
            else { return false }
            generation = token
            lastGeneration = token
            fence = nil
            return true
        }
    }

    /// Capture-thread handoff: never waits for a lock, allocates payloads, performs IO, or launches
    /// work. nil means NOT admitted (including contention): caller must not encode/schedule it.
    /// Reserve both encoded byte ceilings first. Raw encoder/capture allocations are caller-owned.
    public func reserve(
        unitID: UUID, eventBytes: Int, mediaBytes: Int = 0,
        generation token: UUID, now: TimeInterval
    ) -> Ticket? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        guard generation == token, clock(now), eventBytes > 0, mediaBytes >= 0,
            eventBytes <= limits.partBytes, mediaBytes <= limits.partBytes,
            !units.contains(where: { $0.id == unitID }),
            !reports.contains(where: { $0.unitID == unitID })
        else { return nil }
        expire(now)
        let needed = eventBytes + mediaBytes
        guard needed <= limits.bytes else { return nil }
        let encoders = mediaBytes == 0 ? 1 : 2
        guard snapshotLocked().encodingParts + encoders <= limits.encodingParts else { return nil }
        while units.count >= limits.units || snapshotLocked().reservedBytes > limits.bytes - needed
        {
            // Never reclaim a live encoder or HTTP owner, even when cancellation timed out.
            guard
                let victim = units.first(where: {
                    $0.parts.allSatisfy { $0.phase == .queued || $0.phase == .done }
                })
            else { return nil }
            for part in victim.parts where part.phase == .queued { settle(part, .unavailable) }
            retire()
        }
        let unit = Unit(
            id: unitID, generation: token, expires: now + limits.age, event: eventBytes,
            media: mediaBytes)
        units.append(unit)
        return unit.ticket
    }

    /// Encoder's actual return (on a worker, not the capture callback). nil means encoding failed.
    /// Keeps ownership charged through expiry/fencing until this return. Copies only visible bytes
    /// so a tiny Data slice cannot retain an arbitrarily large backing allocation inside the queue.
    public func finishEncoding(
        _ ticket: Ticket, component: Component, data: Data?, now: TimeInterval
    ) {
        lock.withLock {
            guard let unit = units.first(where: { $0.ticket == ticket }) else { return }
            let part = unit.part(component)
            guard part.phase == .encoding else { return }
            _ = clock(now)
            expire(now)
            guard generation == unit.generation, !part.cancel, now < unit.expires,
                let data, !data.isEmpty, data.count <= part.budget
            else {
                settle(part, .unavailable)
                retire()
                return
            }
            part.data = data.withUnsafeBytes { Data($0) }
            part.budget = data.count
            part.ready = now
            part.phase = .queued
        }
    }

    /// Worker-only atomic admission/start boundary. start must only register/resume a bounded
    /// non-blocking IO operation, never await, block, or reenter this object. Starting under the
    /// same lock as suspend prevents a dequeued operation from starting after the fence.
    /// The adapter must release via finishAttempt ONLY on actual IO return, not cancel()/timeout.
    @discardableResult
    public func withNextAttempt(generation token: UUID, now: TimeInterval, start: (Attempt) -> Void)
        -> Bool
    {
        lock.withLock {
            guard generation == token, clock(now) else { return false }
            expire(now)
            let usage = snapshotLocked()
            guard usage.inFlight < limits.inFlight else { return false }
            for unit in units {
                for component in Component.allCases {
                    let part = unit.part(component)
                    guard part.phase == .queued, part.ready <= now,
                        part.budget <= limits.inFlightBytes - usage.inFlightBytes,
                        let payload = part.data
                    else { continue }
                    part.phase = .flight
                    part.tries += 1
                    part.attempt = UUID()
                    part.deadline = min(unit.expires, now + limits.attemptTime)
                    start(
                        Attempt(
                            id: part.attempt!, unitID: unit.id, generation: token,
                            component: component, payload: payload, number: part.tries,
                            deadline: part.deadline))
                    return true
                }
            }
            return false
        }
    }

    public func finishAttempt(_ id: UUID, result: Result, now: TimeInterval) {
        lock.withLock {
            guard
                let unit = units.first(where: {
                    $0.parts.contains { $0.attempt == id && $0.phase == .flight }
                }),
                let part = unit.parts.first(where: { $0.attempt == id && $0.phase == .flight })
            else { return }
            _ = clock(now)
            expire(now)
            // Even an ACK after a privacy/deadline fence cannot publish into a new generation.
            if result == .unauthorized { suspendLocked(.revoked) }
            guard generation == unit.generation, !part.cancel, now < part.deadline else {
                settle(part, .unknown)
                retire()
                return
            }
            switch result {
            case .accepted: settle(part, .hopAccepted)
            case .rejected: settle(part, .unavailable)
            case .uncertain, .partial, .unauthorized: settle(part, .unknown)
            case .retryable(let after):
                // Retry permission is not proof an upstream receiver accepted nothing.
                part.uncertainDelivery = true
                guard after == nil || (after!.isFinite && after! >= 0) else {
                    settle(part, .unknown)
                    retire()
                    return
                }
                let delay = max(
                    after ?? 0,
                    min(limits.backoffCap, limits.backoff * pow(2, Double(part.tries - 1))))
                guard part.tries < limits.attempts, now + delay < unit.expires else {
                    settle(part, .unavailable)
                    retire()
                    return
                }
                part.phase = .queued
                part.attempt = nil
                part.ready = now + delay
            }
            retire()
        }
    }

    /// Invalidates pending work synchronously; returns cancellation requests, NOT proof of return.
    @discardableResult
    public func suspend(_ reason: Fence) -> [UUID] {
        lock.withLock {
            suspendLocked(reason)
            return snapshotLocked().cancellations
        }
    }
    @discardableResult
    public func advance(generation token: UUID, now: TimeInterval) -> Snapshot {
        lock.withLock {
            guard generation == token else { return snapshotLocked() }
            _ = clock(now)
            expire(now)
            return snapshotLocked()
        }
    }
    public var snapshot: Snapshot { lock.withLock { snapshotLocked() } }
    public func drainReports() -> [Report] {
        lock.withLock {
            let result = reports
            reports.removeAll(keepingCapacity: true)
            return result
        }
    }

    private func clock(_ now: TimeInterval) -> Bool {
        guard now.isFinite, now >= lastTime else {
            suspendLocked(.clock)
            return false
        }
        lastTime = now
        return true
    }
    private func suspendLocked(_ reason: Fence) {
        generation = nil
        if fence != .revoked && fence != .clock { fence = reason }
        for unit in units {
            for part in unit.parts {
                if part.phase == .queued {
                    settle(part, .unavailable)
                } else if part.phase == .encoding || part.phase == .flight {
                    part.cancel = true
                }
            }
        }
        retire()
    }
    private func expire(_ now: TimeInterval) {
        for unit in units {
            for part in unit.parts {
                if part.phase == .flight && now >= part.deadline { part.cancel = true }
                if now >= unit.expires {
                    if part.phase == .queued {
                        settle(part, .unavailable)
                    } else if part.phase == .encoding || part.phase == .flight {
                        part.cancel = true
                    }
                }
            }
        }
        retire()
    }
    private func settle(_ part: Part, _ disposition: Disposition) {
        part.phase = .done
        part.disposition =
            disposition == .unavailable && part.uncertainDelivery ? .unknown : disposition
        part.data = nil
        part.budget = 0
        part.attempt = nil
    }
    private func retire() {
        for unit in units where unit.parts.allSatisfy({ $0.phase == .done }) {
            if reports.count == limits.units {
                reports.removeFirst()
                reportOverflow = true
            }
            reports.append(
                Report(
                    unitID: unit.id, generation: unit.generation, event: unit.event.disposition,
                    media: unit.media.disposition))
        }
        units.removeAll { $0.parts.allSatisfy { $0.phase == .done } }
    }
    private func snapshotLocked() -> Snapshot {
        let parts = units.flatMap { $0.parts }
        return Snapshot(
            units: units.count, reservedBytes: parts.reduce(0) { $0 + $1.budget },
            encodingParts: parts.filter { $0.phase == .encoding }.count,
            inFlight: parts.filter { $0.phase == .flight }.count,
            inFlightBytes: parts.filter { $0.phase == .flight }.reduce(0) { $0 + $1.budget },
            reports: reports.count, reportOverflow: reportOverflow, fence: fence,
            cancellations: parts.filter { $0.phase == .flight && $0.cancel }.compactMap {
                $0.attempt
            },
            encodingCancellations: units.filter {
                $0.parts.contains { $0.phase == .encoding && $0.cancel }
            }.map { $0.ticket })
    }
}

/// Hop-local OTLP/JSON classification, not JazzLiveCompatibilityAcceptance or canonical authority.
/// A bounded network adapter must cap bytes WHILE reading too; this parser cannot undo an
/// unbounded URLSession.data(for:) allocation. No raw error text/credentials are retained.
public enum BestEffortOTLPAcknowledgement {
    public static let maximumBytes = 65_536
    public static func classify(status: Int, body: Data, retryAfter: TimeInterval? = nil)
        -> BestEffortTransport.Result
    {
        if status == 401 || status == 403 { return .unauthorized }
        if [429, 502, 503, 504].contains(status) { return .retryable(after: retryAfter) }
        if [400, 404, 413, 415, 422].contains(status) { return .rejected }
        guard status == 200 else { return .uncertain }
        guard body.count <= maximumBytes,
            case .object(let root)? = try? JSONDecoder().decode(
                JazzArchiveJSONValue.self, from: body)
        else { return .uncertain }
        guard let partial = root["partialSuccess"] else { return .accepted }
        guard case .object(let fields) = partial else { return .uncertain }
        guard let rejected = fields["rejectedLogRecords"] else { return .accepted }
        let count: Int64?
        switch rejected {
        case .integer(let n): count = n
        case .unsignedInteger(let n): count = Int64(exactly: n)
        case .string(let s):
            count = !s.isEmpty && s.utf8.allSatisfy({ (48...57).contains($0) }) ? Int64(s) : nil
        default: count = nil
        }
        guard let count, count >= 0 else { return .uncertain }
        return count == 0 ? .accepted : .partial
    }
}
