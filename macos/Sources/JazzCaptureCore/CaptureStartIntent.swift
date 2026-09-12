import Foundation

/// Local intent only; never emitted into an archive. The run guard is committed BEFORE startup.
/// An abnormal exit (including a failed Pause write) therefore requires explicit Resume, rather
/// than trusting stale unpaused bytes. Only a positively settled clean shutdown may clear it.
@MainActor
public final class CaptureStartIntent {
    private struct Document: Codable {
        var version = 1
        var userPaused: Bool
        var runGuard: Bool
    }

    public private(set) var continuous: Bool
    public private(set) var userPaused = false
    public private(set) var requiresResume = false
    public private(set) var storageError: String?
    public private(set) var recoveryReady = false
    public private(set) var isStarting = false
    /// In-memory original recording intent; never restored by relaunch or reconnect.
    public private(set) var isArmed = false
    public private(set) var isRotating = false
    public private(set) var generation = UUID() {
        didSet { fenceBestEffortDelivery(userPaused ? .pause : .stop) }
    }
    private var bestEffortDelivery: BestEffortTransportDriver?
    public var onBestEffortRevocation: (() -> Void)?

    /// Stages a disarmed adapter only. No app call site constructs/attaches one yet; coordinated
    /// authority must precede any future explicit driver start. Never enrolls or starts capture.
    public func attachBestEffortDelivery(_ driver: BestEffortTransportDriver) -> Bool {
        guard bestEffortDelivery == nil, !isArmed, !isStarting, !isRotating,
            driver.snapshot.fence != nil, driver.snapshot.units == 0
        else { return false }
        bestEffortDelivery = driver
        driver.onRevocation { [weak self] token in
            guard let self, self.generation == token else { return }
            _ = self.beginShutdown(deliveryFence: .revoked)
            self.onBestEffortRevocation?()
        }
        return true
    }
    public func fenceBestEffortDelivery(_ reason: BestEffortTransport.Fence = .stop) {
        bestEffortDelivery?.suspend(reason)
    }
    public var bestEffortIsQuiescent: Bool {
        guard let driver = bestEffortDelivery else { return true }
        let usage = driver.adapterUsage
        return driver.snapshot.units == 0 && usage.encoders == 0 && usage.uploads == 0
    }
    private let file: URL
    private let durability: JazzArchiveFilesystemDurability

    public init(root: URL, continuous: Bool, durability: JazzArchiveFilesystemDurability) {
        self.continuous = continuous
        self.file = root.appendingPathComponent("capture-intent.json")
        self.durability = durability
        do {
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch CocoaError.fileReadNoSuchFile { return }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            userPaused = document.userPaused
            requiresResume = document.runGuard && !userPaused
        } catch {
            storageError = String(describing: error)
        }
    }

    public func completeRecovery(succeeded: Bool) { recoveryReady = succeeded }

    public var idleStatus: String {
        if storageError != nil { return "Capture blocked — intent storage failed; repair storage and reopen Jazz" }
        if userPaused { return continuous ? "Paused by you" : "Stopped by you" }
        if requiresResume { return "Capture safety check — explicit Resume required after reopening" }
        if !recoveryReady { return "Capture blocked — local recovery not complete" }
        return continuous ? "Continuous capture ready" : "Idle"
    }

    /// Synchronous claim: repeated clicks cannot queue independent starts before a Task runs.
    public func requestStart(explicit: Bool) -> UUID? {
        guard !isStarting, !isRotating, !isArmed, storageError == nil, bestEffortIsQuiescent else {
            return nil
        }
        guard explicit || (continuous && !userPaused && !requiresResume) else { return nil }
        guard persist(userPaused: false, runGuard: true) else { return nil }
        userPaused = false
        requiresResume = false
        generation = UUID()
        isStarting = true
        return generation
    }

    public func permitsStart(_ token: UUID) -> Bool {
        isStarting && token == generation && !userPaused && storageError == nil
            && bestEffortIsQuiescent
    }

    /// The same awaited orchestration is used by CaptureController and deferred-source tests.
    /// There is no suspension between the final eligibility check and physical source admission.
    public func runStart(
        _ token: UUID,
        recovery: () async -> Bool,
        prepare: () async -> Bool,
        enable: () -> Bool,
        abort: () async -> Void,
        eligible: () -> Bool = { true }
    ) async -> Bool {
        defer { isStarting = false }
        isArmed = false
        guard permitsStart(token) else { return false }
        let recovered = await recovery()
        guard recovered, recoveryReady, permitsStart(token), !Task.isCancelled, eligible(), permitsStart(token) else { return false }
        let prepared = await prepare()
        guard prepared, recoveryReady, permitsStart(token), !Task.isCancelled, eligible(), permitsStart(token) else {
            await abort()
            return false
        }
        if enable(), permitsStart(token) {
            isArmed = true
            return true
        }
        await abort()
        return false
    }

    /// Claim before scheduling, coalescing timer/byte triggers. Changing generation fences old
    /// callbacks and label reopeners without manufacturing an explicit Start or new notice.
    public func requestRotation(reason: CaptureChunkBoundary.Reason = .duration,
        hasOpenSpan: Bool = false) -> UUID?
    {
        guard isArmed, !isStarting, !isRotating, !userPaused, recoveryReady,
            storageError == nil else { return nil }
        guard CaptureChunkBoundary.permitsContinuation(reason: reason, hasOpenSpan: hasOpenSpan) else {
            _ = beginShutdown()
            return nil
        }
        isRotating = true
        generation = UUID()
        return generation
    }

    /// Reuses the caller's serialized local close and normal runStart preparation. The close
    /// closure must prove BOTH committed local state and actual physical return, never a timeout.
    public func runRotation(_ token: UUID, close: () async -> Bool,
        eligible: () -> Bool, start: (UUID) async -> Bool) async -> Bool
    {
        defer { isRotating = false }
        guard isRotating, token == generation else { return false }
        let closed = await close()
        guard closed, bestEffortIsQuiescent, isArmed, token == generation, !userPaused,
            recoveryReady,
            storageError == nil, !Task.isCancelled, eligible(), token == generation
        else { isArmed = false; return false }
        isStarting = true
        let started = await start(token)
        guard started, token == generation, isArmed, !userPaused, recoveryReady,
            storageError == nil, !Task.isCancelled, eligible(), token == generation
        else { isArmed = false; return false }
        return true
    }

    /// Invalidates a pending start BEFORE persistence or any asynchronous drain.
    public func pause() {
        isArmed = false
        userPaused = true
        generation = UUID()
        _ = persist(userPaused: true, runGuard: true)
    }

    /// Mode changes never undo Pause. Leaving continuous mode is a Stop, not a conversion of
    /// an active continuous recording into an implicitly user-started manual session.
    public func setContinuous(_ enabled: Bool) {
        guard continuous != enabled else { return }
        continuous = enabled
        if !enabled { pause() }
    }

    /// Quit is not a user Pause. The caller must stop sources and positively settle startup and
    /// close before restoring eligibility, and must not restore after a timeout/uncertain close.
    public func beginShutdown(deliveryFence: BestEffortTransport.Fence = .stop) -> UUID {
        isArmed = false
        generation = UUID()
        fenceBestEffortDelivery(deliveryFence)
        return generation
    }

    public func finishShutdown(_ token: UUID, settled: Bool, physicallyQuiescent: Bool) {
        // The caller holds source admission CLOSED while proving actual operation return and
        // committed local close. A logical timeout or an open-gate snapshot is not this proof.
        guard settled, physicallyQuiescent, bestEffortIsQuiescent, !isStarting, token == generation,
            continuous,
            !userPaused, !requiresResume, storageError == nil, recoveryReady
        else { return }
        _ = persist(userPaused: false, runGuard: false)
    }

    @discardableResult
    private func persist(userPaused: Bool, runGuard: Bool) -> Bool {
        do {
            let root = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(Document(userPaused: userPaused, runGuard: runGuard))
                .write(to: file, options: .atomic)
            try durability.synchronizeRegularFile(file, permissions: 0o600)
            try durability.synchronizeDirectory(root)
            try durability.synchronizeDirectory(root.deletingLastPathComponent())
            return true
        } catch {
            storageError = String(describing: error)
            return false
        }
    }
}
