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
    public private(set) var generation = UUID()
    private var sourcesWereEnabled = false
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
        guard !isStarting, storageError == nil else { return nil }
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
    }

    /// The same awaited orchestration is used by CaptureController and deferred-source tests.
    /// There is no suspension between the final eligibility check and physical source admission.
    public func runStart(
        _ token: UUID,
        recovery: () async -> Bool,
        prepare: () async -> Bool,
        enable: () -> Bool,
        abort: () async -> Void
    ) async -> Bool {
        defer { isStarting = false }
        guard permitsStart(token) else { return false }
        let recovered = await recovery()
        guard recovered, recoveryReady, permitsStart(token), !Task.isCancelled else { return false }
        let prepared = await prepare()
        guard prepared, recoveryReady, permitsStart(token), !Task.isCancelled else {
            await abort()
            return false
        }
        if enable() {
            sourcesWereEnabled = true
            return true
        }
        await abort()
        return false
    }

    /// Invalidates a pending start BEFORE persistence or any asynchronous drain.
    public func pause() {
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
    public func beginShutdown() -> UUID {
        generation = UUID()
        return generation
    }

    public func finishShutdown(_ token: UUID, settled: Bool) {
        // M2b1 cannot prove native quiescence after source admission. Even a clean quit after
        // recording retains the guard until M2b2 supplies that proof; never use a logical timeout.
        guard settled, !sourcesWereEnabled, !isStarting, token == generation, continuous,
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
