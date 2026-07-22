import Foundation

/// Durable on-disk spool for narration audio — the blob analogue of ``EventSpool``. A
/// recorded clip is staged here BEFORE any upload and removed only AFTER the upload succeeds
/// and its `narration` ActivityEvent is appended to the event spool, so a crash or an offline
/// period never drops the audio: it re-uploads on the next launch (each upload re-prepares its
/// own short-lived GCS credentials, so a leftover blob is always re-uploadable).
///
/// Layout under a configurable directory (default `~/.jasnost/spool/narration`, a reserved
/// sibling of the event spool's session dirs, like `shots/`):
///
///     <dir>/<sessionId>/<labelId>.m4a     the audio blob
///     <dir>/<sessionId>/<labelId>.json    sidecar: everything needed to build the `narration`
///                                         ActivityEvent AFTER the upload returns a file id
///                                         (the record can't exist until then) — sequence,
///                                         labelId, label, audio start time, staged time
///
/// Unlike the screenshot staging dir this is NEVER cleaned at launch (a leftover blob is the
/// whole point). Retention is bounded by total size and age so an indefinite offline stretch
/// of hour-long recordings can't fill the disk; eviction drops the OLDEST first and returns
/// what it dropped so the caller can surface it. `pending()` is corruption-tolerant — an
/// unparsable sidecar or a sidecar with no blob is skipped, never thrown.
public final class NarrationSpool {
    /// Sidecar metadata persisted next to each blob: everything (besides the file id, which the
    /// upload mints) needed to build the `narration` ActivityEvent once the upload succeeds.
    public struct PendingNarration: Codable, Equatable, Sendable {
        public var sessionId: String
        public var labelId: String
        public var label: String
        /// Sequence reserved for the narration record at label-end, so the record sorts right
        /// after the `label_end` boundary it belongs to even when uploaded much later.
        public var sequence: Int
        /// ISO-8601 audio start (timeline alignment; mirrors the recorder's start time).
        public var startedAt: String
        /// ISO-8601 time the blob was staged — the retention clock (age-based eviction).
        public var stagedAt: String
        /// The segment's resolved Process (Guided capture), stamped onto the `narration`
        /// record as `process.id`/`process.name` like `labelId`/`label`. nil when the label
        /// was free text (Explore). Optional so sidecars staged before this field decode fine.
        public var processId: String?
        public var processName: String?

        public init(
            sessionId: String, labelId: String, label: String, sequence: Int,
            startedAt: String, stagedAt: String,
            processId: String? = nil, processName: String? = nil
        ) {
            self.sessionId = sessionId
            self.labelId = labelId
            self.label = label
            self.sequence = sequence
            self.startedAt = startedAt
            self.stagedAt = stagedAt
            self.processId = processId
            self.processName = processName
        }
    }

    /// One staged clip ready to upload: its sidecar metadata + the on-disk audio URL.
    public struct StagedNarration: Equatable, Sendable {
        public let meta: PendingNarration
        public let audioURL: URL

        public init(meta: PendingNarration, audioURL: URL) {
            self.meta = meta
            self.audioURL = audioURL
        }
    }

    /// Total-size ceiling for staged audio; the oldest blobs are evicted past this so an
    /// indefinite offline stretch can't fill the disk. ~2 GB ≈ many hours of mono AAC.
    public static let maxTotalBytes = 2 * 1024 * 1024 * 1024
    /// Age ceiling: a clip that never uploaded in this long is evicted. Comfortably survives an
    /// "offline week"; not forever.
    public static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    public let root: URL

    private let fileManager = FileManager.default
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private static let decoder = JSONDecoder()

    public init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jasnost/spool/narration", isDirectory: true)
    ) {
        self.root = directory
    }

    // MARK: - Staging

    /// Move a freshly-recorded clip into the durable spool and write its sidecar. The recorder
    /// writes to a temp file; this relocates it (cross-volume safe — temp lives under /var) so
    /// it survives a quit. An existing blob for the same label is replaced.
    @discardableResult
    public func stage(audioURL: URL, meta: PendingNarration) throws -> StagedNarration {
        let dir = sessionDir(meta.sessionId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(meta.labelId).m4a")
        if fileManager.fileExists(atPath: dest.path) {
            try? fileManager.removeItem(at: dest)
        }
        do {
            try fileManager.moveItem(at: audioURL, to: dest)
        } catch {
            // moveItem usually handles cross-volume by copying, but fall back explicitly so a
            // temp-on-a-different-volume setup can never lose the clip we were asked to keep.
            try fileManager.copyItem(at: audioURL, to: dest)
            try? fileManager.removeItem(at: audioURL)
        }
        let sidecar = dir.appendingPathComponent("\(meta.labelId).json")
        try Self.encoder.encode(meta).write(to: sidecar, options: .atomic)
        return StagedNarration(meta: meta, audioURL: dest)
    }

    // MARK: - Draining

    /// All staged clips that still have both a parsable sidecar and an on-disk blob, in upload
    /// order (session, then the reserved sequence). Corruption-tolerant: a damaged sidecar or a
    /// sidecar with no blob is skipped; never throws.
    public func pending() -> [StagedNarration] {
        var out: [StagedNarration] = []
        for sessionId in listSessionIds() {
            let dir = sessionDir(sessionId)
            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for url in entries where url.pathExtension == "json" {
                guard
                    let data = try? Data(contentsOf: url),
                    let meta = try? Self.decoder.decode(PendingNarration.self, from: data)
                else { continue }  // corrupt sidecar: skip
                let audio = dir.appendingPathComponent("\(meta.labelId).m4a")
                guard fileManager.fileExists(atPath: audio.path) else { continue }  // no blob
                out.append(StagedNarration(meta: meta, audioURL: audio))
            }
        }
        return out.sorted {
            ($0.meta.sessionId, $0.meta.sequence, $0.meta.labelId)
                < ($1.meta.sessionId, $1.meta.sequence, $1.meta.labelId)
        }
    }

    /// Remove a clip once it has shipped (blob + sidecar), pruning an emptied session dir.
    public func remove(_ item: StagedNarration) {
        let dir = sessionDir(item.meta.sessionId)
        try? fileManager.removeItem(at: item.audioURL)
        try? fileManager.removeItem(at: dir.appendingPathComponent("\(item.meta.labelId).json"))
        if let entries = try? fileManager.contentsOfDirectory(atPath: dir.path), entries.isEmpty {
            try? fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Retention

    /// Bytes of audio currently staged (blobs only; sidecars are tiny).
    public func totalBytes() -> Int {
        pending().reduce(0) { $0 + fileSize($1.audioURL) }
    }

    /// Drop the OLDEST clips until the spool is within both ceilings (age then total size),
    /// returning what was evicted so the caller can warn the user. Best-effort: a clip whose
    /// staged time is unparsable is kept (never evicted on a clock we can't read). The limits
    /// are parameters (defaulting to the configured ceilings) so tests can exercise eviction
    /// without mutating global state.
    @discardableResult
    public func enforceRetention(
        maxBytes: Int = NarrationSpool.maxTotalBytes,
        maxAge: TimeInterval = NarrationSpool.maxAge,
        now: Date = Date()
    ) -> [PendingNarration] {
        let items = pending().sorted { $0.meta.stagedAt < $1.meta.stagedAt }  // oldest first
        var evicted: [PendingNarration] = []

        // 1. Age — anything staged longer ago than maxAge.
        var survivors: [StagedNarration] = []
        for item in items {
            if let staged = Timestamps.parse(item.meta.stagedAt),
                now.timeIntervalSince(staged) > maxAge
            {
                remove(item)
                evicted.append(item.meta)
            } else {
                survivors.append(item)
            }
        }

        // 2. Size — evict oldest survivors until total is within budget.
        var total = survivors.reduce(0) { $0 + fileSize($1.audioURL) }
        var idx = 0
        while total > maxBytes && idx < survivors.count {
            let item = survivors[idx]
            total -= fileSize(item.audioURL)
            remove(item)
            evicted.append(item.meta)
            idx += 1
        }
        return evicted
    }

    // MARK: - Internals

    private func sessionDir(_ sessionId: String) -> URL {
        root.appendingPathComponent(sessionId, isDirectory: true)
    }

    private func listSessionIds() -> [String] {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return entries.compactMap { url in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                ? url.lastPathComponent : nil
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
