import Foundation
import JasnostCaptureCore

/// Durable background uploader for narration audio — the blob analogue of ``StreamSender``.
/// It reads its work from the on-disk ``NarrationSpool`` (not an in-memory queue), so a
/// relaunch resumes pending uploads. For each staged clip it:
///   1. uploads the m4a to Keboola Files (each call re-prepares, so the GCS token is fresh —
///      safe to retry across an offline→online transition or a restart),
///   2. appends the `narration` ActivityEvent to the ``EventSpool`` (the record can only exist
///      once the upload returns a file id), and nudges the OTLP sender to ship it,
///   3. removes the clip from the narration spool.
///
/// A failed upload is KEPT on disk and retried with backoff — never dropped. Only
/// ``NarrationSpool/enforceRetention(maxBytes:maxAge:now:)`` (disk full / too old) can drop a
/// clip, and that is surfaced. This is the durability the events path already has, extended to
/// the audio.
actor NarrationUploader {
    /// Uploader state for the UI (menu). Published through ``setStatusHandler(_:)``.
    struct Status: Equatable, Sendable {
        /// Clips still staged on disk waiting to upload (the durable backlog).
        var pendingCount = 0
        var lastError: String?
        var isUploading = false
    }

    /// Backoff for upload failures: 2s doubling to 60s, plus 0–25% jitter so relaunched agents
    /// don't synchronize retries against a recovering network.
    private enum Backoff {
        static let initial: TimeInterval = 2
        static let max: TimeInterval = 60
    }

    private let spool: NarrationSpool
    private let eventSpool: EventSpool
    /// Nudge the OTLP sender after a narration record lands, so it ships promptly.
    private let onRecordAppended: @Sendable () async -> Void

    /// The Keboola stack base URL — settable so a re-connect to a different stack takes effect
    /// without recreating the uploader. The Files client is built per drain pass from this.
    private var stackURL: String
    private var status = Status()
    private var onStatus: (@Sendable (Status) -> Void)?
    /// Notified once a clip's narration record lands: ``(sessionId, labelId, label, audioFileId)``.
    /// Drives the LIVE BDM workshop canvas (the segment's audio is now in Files, ready to transcribe
    /// into a turn). Optional — uploads work the same with no listener.
    private var onSegmentReady: (@Sendable (String, String, String, String) -> Void)?
    private var loopTask: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var nudged = false
    private var backoff = Backoff.initial

    init(
        spool: NarrationSpool,
        eventSpool: EventSpool,
        stackURL: String,
        onRecordAppended: @escaping @Sendable () async -> Void
    ) {
        self.spool = spool
        self.eventSpool = eventSpool
        self.stackURL = stackURL
        self.onRecordAppended = onRecordAppended
    }

    /// Register the UI callback (invoked on every status change, starting immediately).
    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        onStatus = handler
        // Reflect the on-disk backlog right away (a relaunch with pending clips should show it).
        status.pendingCount = spool.pending().count
        handler(status)
    }

    /// Register the live-segment callback (a clip's narration record landed in Files).
    func setSegmentReadyHandler(_ handler: @escaping @Sendable (String, String, String, String) -> Void)
    {
        onSegmentReady = handler
    }

    /// Point future uploads at a (possibly new) stack — called when capture (re)starts.
    func setStackURL(_ url: String) { stackURL = url }

    func currentStatus() -> Status { status }

    /// Clips still staged on disk — lets shutdown wait (bounded) for a drain.
    func pending() -> Int { spool.pending().count }

    /// Start the drain loop. Call once at launch — clips left over from a crash/offline period
    /// upload immediately, before any new capture begins.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await run() }
    }

    /// Wake the loop (a new clip was staged, or capture reconnected).
    func nudge() {
        nudged = true
        wake?.resume()
        wake = nil
    }

    /// Stage a freshly-recorded clip durably and wake the loop. Returns the clips retention
    /// evicted (oldest-first, disk full / too old) so the caller can warn the user; an empty
    /// array means nothing was dropped. Staging the audio is what makes it crash-safe — the
    /// upload itself can then take as long as it needs.
    func enqueue(
        audioURL: URL, meta: NarrationSpool.PendingNarration
    ) -> [NarrationSpool.PendingNarration] {
        do {
            try spool.stage(audioURL: audioURL, meta: meta)
        } catch {
            // Could not even stage (disk error): the temp file is still the caller's. Surface
            // it rather than silently losing the clip.
            publish { $0.lastError = "Narration: could not save audio to disk (\(error))" }
            return []
        }
        let evicted = spool.enforceRetention()
        publish {
            $0.pendingCount = spool.pending().count
            if $0.lastError?.hasPrefix("Narration upload") == true { $0.lastError = nil }
        }
        nudge()
        return evicted
    }

    // MARK: - Loop

    private func run() async {
        while !Task.isCancelled {
            let allDone = await drainOnce()
            if allDone {
                backoff = Backoff.initial
                if spool.pending().isEmpty { await waitForNudge() }
            } else {
                // Exponential backoff with jitter, slept in short slices so a nudge breaks it
                // promptly (a clip staged — or the network recovering — shouldn't wait out the
                // full curve). Mirrors StreamSender.
                let jitter = backoff * Double.random(in: 0...0.25)
                let total = backoff + jitter
                let slice: TimeInterval = 0.25
                var slept: TimeInterval = 0
                while slept < total && !nudged && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                    slept += slice
                }
                if nudged {
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

    /// One full drain pass. Returns false on the first upload failure (so the loop backs off —
    /// the clip stays on disk); true when everything staged got shipped. The per-clip flow is
    /// idempotent: dedup-check first (reuse an already-uploaded copy, clean up dangling
    /// leftovers), and on a failed PUT delete the just-created file id — so retries can run
    /// forever without piling up empty/duplicate Storage records.
    private func drainOnce() async -> Bool {
        let items = spool.pending()
        publish {
            $0.pendingCount = items.count
            $0.isUploading = !items.isEmpty
        }
        guard !items.isEmpty else { return true }

        let client = KeboolaClient(stackURL: stackURL)
        for item in items {
            // 1. Idempotence: is this clip already in Keboola? A retry/restart — or a previous
            //    attempt whose PUT landed but whose response we lost — must not re-upload it.
            //    Find by the unique `label:<id>` tag, reuse the first COMPLETE copy, and clean
            //    up DANGLING leftovers from earlier failed attempts.
            if let fileId = await resolveExistingUpload(client: client, item: item) {
                recordAndRemove(fileId: fileId, item: item)
                await onRecordAppended()
                publish {
                    $0.pendingCount = max(0, $0.pendingCount - 1)
                    $0.lastError = nil
                }
                continue
            }

            guard let data = try? Data(contentsOf: item.audioURL) else {
                spool.remove(item)  // unreadable blob — can never ship, don't wedge the loop
                continue
            }

            // 2. Fresh upload: prepare a slot, then PUT the bytes on the idle-based session.
            let prepared: KeboolaAPI.FilesPrepare
            do {
                prepared = try await client.prepareFile(
                    name: fileName(item), tags: tags(item), isPermanent: true)
            } catch {
                publish { markRetrying(&$0) }  // calm "waiting to retry"; keep audio on disk
                return false
            }
            guard let gcs = prepared.gcsUploadParams else {
                // Non-GCP stack / malformed prepare: clean up the empty slot and stop.
                try? await client.deleteFile(id: prepared.id)
                publish {
                    $0.lastError = "Narration: stack returned no GCS upload params"
                    $0.isUploading = false
                }
                return false
            }
            do {
                try await KeboolaClient.uploadLargeBlobToGCS(
                    data: data, params: gcs, contentType: NarrationRecorder.mimeType)
                recordAndRemove(fileId: prepared.id, item: item)
                await onRecordAppended()
                publish {
                    $0.pendingCount = max(0, $0.pendingCount - 1)
                    $0.lastError = nil
                }
            } catch {
                // PUT failed: delete the dangling file id we just minted so retries never pile
                // up empty records (the exact bug that produced the duplicates), and keep the
                // audio on disk. The audio is safe, not lost (contrast the old give-up-delete).
                NSLog(
                    "jasnost: narration upload deferred (kept on disk, cleaned slot \(prepared.id)): \(error)"
                )
                try? await client.deleteFile(id: prepared.id)
                publish { markRetrying(&$0) }
                return false
            }
        }
        publish { $0.isUploading = false }
        return true
    }

    /// Find an already-uploaded copy of this clip and clean up dangling leftovers. Returns a
    /// COMPLETE file id to reuse, or nil when a fresh upload is needed. The impure part lives
    /// here (list by `label:<id>`, HEAD each candidate's signed GCS URL); the decision is the
    /// pure, unit-tested ``NarrationDedup/decide(_:)``. Candidates are listed oldest-first so
    /// the earliest complete copy wins stably across retries.
    private func resolveExistingUpload(
        client: KeboolaClient, item: NarrationSpool.StagedNarration
    ) async -> Int? {
        let listed = await client.listFiles(tags: ["narration", "label:\(item.meta.labelId)"])
        guard !listed.isEmpty else { return nil }
        let oldestFirst = listed.sorted { ($0.created ?? "") < ($1.created ?? "") }
        var probed: [NarrationDedup.Candidate] = []
        for file in oldestFirst {
            guard let url = file.url else {
                // No signed URL to probe → uncertain (don't reuse or delete on a guess).
                probed.append(NarrationDedup.Candidate(fileId: file.id, present: nil))
                continue
            }
            let exists = await KeboolaClient.gcsObjectExists(signedURL: url)
            probed.append(NarrationDedup.Candidate(fileId: file.id, present: exists))
        }
        let decision = NarrationDedup.decide(probed)
        for id in decision.danglingToDelete { try? await client.deleteFile(id: id) }
        return decision.reuseFileId
    }

    /// Build the `narration` record (carrying the file id + the sequence reserved at label-end,
    /// so it sorts right after its `label_end` boundary even when shipped much later) and drop
    /// the clip from the spool. The OTLP sender ships the record next; even if the session span
    /// already shipped, it lands as a log under the same trace.
    private func recordAndRemove(fileId: Int, item: NarrationSpool.StagedNarration) {
        let event = ActivityEvent(
            sessionId: item.meta.sessionId,
            eventId: Identifiers.eventId(
                sessionId: item.meta.sessionId, sequence: item.meta.sequence),
            sequence: item.meta.sequence,
            timestamp: Timestamps.iso8601(),
            eventType: EventType.narration.rawValue,
            url: "app://session",
            audioFileId: String(fileId),
            labelId: item.meta.labelId,
            label: item.meta.label,
            // The segment's resolved Process (Guided capture) rides the narration record too,
            // so the audio ties to its process like every other event in the segment.
            processId: item.meta.processId,
            process: item.meta.processName
        )
        do {
            try eventSpool.appendBatch(sessionId: item.meta.sessionId, events: [event])
            spool.remove(item)  // drop the clip ONLY once its record is durably written
            // Live BDM: the audio is in Files and its record is durable — let the live workshop
            // canvas run a turn for this segment (no-op when nobody is listening / not live).
            onSegmentReady?(
                item.meta.sessionId, item.meta.labelId, item.meta.label, String(fileId))
        } catch {
            // Event-spool write failed (disk trouble): keep the clip staged. The next drain
            // pass's dedup finds the already-uploaded file, reuses it (no re-upload, no
            // duplicate), and retries just this record append.
            NSLog("jasnost: narration record append failed, will retry next pass: \(error)")
        }
    }

    private func fileName(_ item: NarrationSpool.StagedNarration) -> String {
        "jasnost-\(item.meta.sessionId)-\(item.meta.labelId)-narration.m4a"
    }

    private func tags(_ item: NarrationSpool.StagedNarration) -> [String] {
        [
            "jasnost", "session:\(item.meta.sessionId)",
            "label:\(item.meta.labelId)", "narration",
        ]
    }

    /// The shared "upload deferred, audio safe on disk" status mutation (used for prepare and
    /// PUT failures alike) — calm wording because the clip is durable, not lost.
    private func markRetrying(_ status: inout Status) {
        status.lastError = "Narration upload waiting to retry (offline?) — audio safe on disk"
        status.isUploading = false
    }

    private func publish(_ mutate: (inout Status) -> Void) {
        mutate(&status)
        onStatus?(status)
    }
}
