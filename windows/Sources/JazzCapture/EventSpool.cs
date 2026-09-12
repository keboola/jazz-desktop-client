using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using JazzCaptureCore.Journal;

namespace JazzCapture;

/// <summary>Whether <see cref="EventSpool.Spool"/> admitted a new event.</summary>
public enum EventSpoolAdmission
{
    /// <summary>The bytes were written durably and the event is now pending delivery.</summary>
    Spooled,

    /// <summary>
    /// Nothing was admitted, and -- unlike <see cref="ScreenshotStageResult.Refused"/> -- this is
    /// always counted (see <see cref="EventSpool.DrainPendingRefusals"/>). A refused screenshot
    /// leaves an event with no <c>screenshot_id</c>, tolerated downstream; a refused *event* is the
    /// loss issue #48 exists to make visible rather than allow.
    /// </summary>
    Refused,
}

/// <summary>Cheap, non-secret projection of spool occupancy for the tray to display.</summary>
public readonly record struct EventSpoolStatus(int PendingCount);

/// <summary>
/// One spooled event handed to the delivery worker: its lookup key, the session it belongs to (so
/// the worker can stop a pass at the first retryable failure for that session without skipping
/// ahead -- see <see cref="EventDeliveryWorker"/>), and its file name.
/// </summary>
public sealed record SpooledEventHandle(string Key, string SessionId, string FileName);

/// <summary>
/// The durable, bounded, ordered on-disk spool for exact <c>/v1/logs</c> request bodies -- one file
/// per event, written synchronously on the capture path before the event is considered delivered.
/// </summary>
/// <remarks>
/// <para>
/// <b>Modelled on <see cref="ScreenshotStagingArea"/>, not a reuse of <see cref="JazzCaptureCore.Delivery.ArchiveDeliveryQueue"/>.</b>
/// The archive queue's per-item cost is three forced disk barriers designed for one item per
/// confirmed capture, its identity is an <c>ar-</c> archive id enforced at the filesystem boundary,
/// its durable record is contract material pinned by a JSON schema, and its projection target is a
/// finalized archive directory that an in-flight event does not have. <see cref="ScreenshotStagingArea"/>
/// already solves every problem an event spool has -- exact bytes under
/// <see cref="Durability.ReplaceAtomic"/>, a hashed, escape-proof path, a byte ceiling with
/// oldest-first eviction, an independent age bound, deletion-debt accounting, leasing, read-back
/// verification, an ACL-protected root, and a pending-list drained by the worker rather than a
/// callback under the lock. The delta from that type is exactly this: adoption instead of wipe-at-
/// launch (an OTLP body needs no credential to re-send -- the capability is the URL, so a surviving
/// file is still fully deliverable), identity by <c>&lt;sessionId&gt;/&lt;fileName&gt;</c> instead of
/// a hashed artifact id (giving free per-session FIFO), no attempt budget for a retryable transport
/// failure, and a refusal that <b>is</b> counted rather than silently discarded.
/// </para>
/// <para>
/// <b>Durability posture: the journal's, not stricter, not looser -- and the body, not the
/// bookkeeping.</b> One <see cref="Durability.ReplaceAtomic"/> per event, synchronously, on the
/// capture path, plus a directory-chain flush -- matching exactly what <c>CaptureJournal.AppendWal</c>
/// already does twice per observation on the same thread. Attempt counts, backoff watermarks, lease
/// state and the abandoned tally live in memory only: after a crash there is nothing useful to
/// resume *to* -- a body that was in flight is either already at the server (a duplicate, tolerated
/// by at-least-once delivery) or not (retry from attempt zero) -- so persisting "this was attempt 3"
/// would only make the first post-restart retry slower.
/// </para>
/// <para>
/// <b>One file, not two; the body, not the <c>ActivityEvent</c>.</b> The file *is* the exact
/// <c>/v1/logs</c> request body -- no sidecar, no record document. macOS spools the
/// <c>ActivityEvent</c> and rebuilds the request, but issue #48's acceptance is "exact bytes survive
/// retry/restart" and its non-goals explicitly list "rebuilding bytes on retry". The body is also
/// self-contained: it already carries the resource attributes, <c>traceId</c>, <c>spanId</c>,
/// <c>enduser.id</c> and <c>host.name</c>, so nothing about the in-memory <c>SessionContext</c> (its
/// trace and span ids are minted fresh per capture and persisted nowhere) needs to survive here.
/// </para>
/// <para>
/// <b>Why the digest is in the filename.</b> <see cref="ScreenshotStagingArea"/> verifies read-back
/// against a digest kept in its in-memory <c>Entry</c>, which only works within one process. Putting
/// the SHA-256 in the name makes exact-byte integrity verifiable *after a restart*, with no sidecar,
/// the same idea as the journal's own content-addressed blob layout. It also bounds a redirected-
/// directory sweep to files this component could itself have written, exactly as
/// <see cref="ScreenshotStagingArea"/>'s own file-name filter does.
/// </para>
/// <para>
/// <b>Why <c>&lt;sessionId&gt;/&lt;sequence:D10&gt;</c> for ordering.</b> Every <see cref="ActivityEvent"/>
/// carries a non-null, strictly increasing per-session <see cref="ActivityEvent.Sequence"/> in
/// ordinary operation. Zero-padded to 10 digits, ordinal filename order equals numeric order.
/// Session directories are named <c>ArchiveIdentity.SessionId</c> (<c>"s-" + UuidV7()</c>), whose
/// lexicographic order equals millisecond order, and captures never overlap -- so
/// <c>sort(session dirs) then sort(files)</c> is per-session FIFO across restarts. A <c>Sequence</c>
/// of <see langword="null"/> would be a producer defect; dropping is not an option, so (matching
/// macOS verbatim) it is padded as zero and a filename collision appends <c>-1</c>, <c>-2</c>, ...
/// until unique. <b>Accepted, narrow quirk:</b> because <c>-</c> (0x2D) sorts before <c>.</c>
/// (0x2E) in ordinal comparison, a collision-suffixed name can sort *before* the entry it collided
/// with, so relative order between two same-sequence (i.e. both-null-sequence) entries is not
/// guaranteed FIFO. This cannot affect the normal, non-defective case (strictly increasing
/// sequences never collide), and downstream ordering never depends on local file arrival order
/// anyway: the log record carries its own <c>sequence</c> and <c>timeUnixNano</c>.
/// </para>
/// <para>
/// <b>At-least-once, per-session FIFO.</b> An entry is deleted only after a 2xx; a crash between the
/// 2xx and the delete replays that one event. The duplicate is deterministic (<c>eventId</c> is
/// <c>sessionId + "-" + sequence</c>, projected onto both rows), so the two are byte-identical and
/// joinable. <see cref="Drain"/> returns due entries sorted by session then by file name;
/// <see cref="EventDeliveryWorker"/> is what stops a pass at the first retryable failure for a given
/// session so a later event of that session is never delivered ahead of an earlier one still being
/// retried.
/// </para>
/// <para>
/// <b>No attempt budget for retryable failures -- the deliberate divergence from <see cref="ScreenshotStagingArea"/>.</b>
/// <see cref="ScreenshotStagingArea.RecordRetry"/> drops after a bounded number of attempts because a
/// screenshot is cheap to lose and its dangling id is tolerated. An event is not a decoration on the
/// record; it *is* the record downstream. So <see cref="RecordRetry"/> never removes an entry: a
/// retryable failure retries indefinitely, and the entry leaves only by succeeding, by a terminal
/// classification from the worker, or by one of the two bounds below.
/// </para>
/// <para>
/// <b>Bounding and eviction: every loss is visible.</b> <see cref="EventDeliverySettings.SpoolByteCeiling"/>
/// and <see cref="EventDeliverySettings.SpoolRetention"/> bound the spool exactly as
/// <see cref="ScreenshotDeliverySettings"/>' pair bounds screenshot staging, with oldest-first
/// eviction (a permanently dead endpoint must not freeze the spool on its first ceiling forever).
/// The three lists this type exposes -- <see cref="DrainPendingEvictions"/>,
/// <see cref="DrainPendingRefusals"/>, plus the worker's own terminal <c>Dropped</c> classification --
/// are the only way a loss becomes visible; nothing here calls a caller-supplied callback itself,
/// and never while <see cref="_gate"/> is held or from <see cref="Spool"/>, which runs on the capture
/// path. <b>This is where the screenshot precedent is deliberately inverted:</b> a refusal here is
/// always counted, because a refused event is exactly the silent loss this issue exists to close.
/// </para>
/// <para>
/// <b>Thread safety.</b> <see cref="Spool"/> runs on the capture engine's own worker thread, inside
/// the engine's lock, synchronously with the capture path. <see cref="Drain"/>,
/// <see cref="TryReadBody"/>, <see cref="Remove"/>, <see cref="RecordRetry"/>,
/// <see cref="EvictExpired"/> and the two drain-pending methods run from <see cref="EventDeliveryWorker"/>
/// on a background task. All of them take one coarse lock (<see cref="_gate"/>) around both the
/// in-memory dictionaries and the small file I/O -- events are spooled at capture cadence, not in a
/// hot loop, so one lock is simpler and safer than splitting file I/O out from under it.
/// </para>
/// </remarks>
public sealed class EventSpool
{
    private const string FileExtension = ".otlp.json";
    private const int SequenceDigitCount = 10;
    private const int DigestHexLength = 64;
    private const string TemporarySuffix = ".tmp";
    private const string SessionDirectoryPrefix = "s-";

    private readonly string _directory;
    private readonly EventDeliverySettings _settings;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();

    /// <summary>Keyed by <c>"&lt;sessionId&gt;/&lt;fileName&gt;"</c>. Guarded by <see cref="_gate"/>.</summary>
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);

    /// <summary>Keys currently leased by <see cref="TryLease"/>, excluded from both eviction sweeps,
    /// exactly like <see cref="ScreenshotStagingArea"/>'s own lease set.</summary>
    private readonly HashSet<string> _leased = new(StringComparer.Ordinal);

    /// <summary>Keys evicted by the byte ceiling or the age bound since the last
    /// <see cref="DrainPendingEvictions"/> call. Guarded by <see cref="_gate"/>.</summary>
    private readonly List<string> _pendingEvictions = new();

    /// <summary>
    /// Keys refused by <see cref="Spool"/> since the last <see cref="DrainPendingRefusals"/> call.
    /// Guarded by <see cref="_gate"/>. Unlike <see cref="ScreenshotStagingArea"/>, where a refusal is
    /// deliberately *not* recorded as an eviction (<c>ScreenshotStagingAreaTests.ARefusalForBeingLargerThanTheWholeCeilingIsNotRecordedAsAnEviction</c>
    /// is correct there), an event refusal is always counted here: a refused screenshot leaves an
    /// event with no <c>screenshot_id</c>, tolerated downstream, while a refused *event* is the exact
    /// silent loss this issue exists to make visible.
    /// </summary>
    private readonly List<string> _pendingRefusals = new();

    /// <summary>
    /// Bytes that a deletion could not free, keyed by file path, exactly like
    /// <see cref="ScreenshotStagingArea"/>'s own deletion debt. Counted by <see cref="TotalBytesLocked"/>
    /// on top of every live entry's own length, retried by <see cref="RetryDeletionDebtLocked"/> on
    /// every sweep that already runs, and reset only by process restart (<see cref="AdoptAtLaunch"/>
    /// re-seeds it only for what that very sweep still cannot delete).
    /// </summary>
    private readonly Dictionary<string, long> _deletionDebt = new(StringComparer.Ordinal);

    /// <summary>
    /// Creates the spool, protecting and (if necessary) creating its root directory, then adopting
    /// every event a previous process left behind.
    /// </summary>
    public EventSpool(EventDeliverySettings settings, Func<DateTimeOffset>? clock = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        _settings = settings;
        _directory = settings.SpoolDirectory;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);

        // Protect the root exactly once, per the same finding ScreenshotStagingArea's own
        // constructor remarks cite: the directory ACL is applied here and nowhere else in this
        // type. Session subdirectories created later inherit this DACL.
        CurrentUserOnlyAcl.ApplyDirectory(_directory);
        AdoptAtLaunch();
    }

    /// <summary>Pending entries right now. Cheap, non-secret; safe for the tray to poll.</summary>
    public EventSpoolStatus Status
    {
        get { lock (_gate) { return new EventSpoolStatus(_entries.Count); } }
    }

    /// <summary>
    /// How long until the earliest spooled entry's next attempt is due, or <see langword="null"/>
    /// when nothing is spooled. See <see cref="ScreenshotStagingArea.TimeUntilNextDue"/>'s own
    /// remarks -- this is the identical idea, ported verbatim.
    /// </summary>
    public TimeSpan? TimeUntilNextDue
    {
        get
        {
            lock (_gate)
            {
                if (_entries.Count == 0)
                {
                    return null;
                }

                // Per-session FIFO (see Drain's own remarks): a session's later entries are not
                // actionable before its earliest one, so only each session's own head entry -- not
                // every entry -- can ever be "next due". Computing the minimum over every entry
                // (including ones a retrying head is blocking) would report a due time of
                // effectively zero for as long as any session has an unattempted tail sitting behind
                // a backing-off head, which starves the drain loop's own backoff of any effect.
                DateTimeOffset now = _clock();
                DateTimeOffset earliest = HeadEntriesLocked().Min(entry => entry.NextAttemptAt);
                TimeSpan remaining = earliest - now;
                return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
            }
        }
    }

    /// <summary>Whether at least one spooled entry has failed at least one send attempt and is
    /// waiting out a retry backoff -- drives the tray's <c>Retrying</c> vs <c>Sending</c> distinction.</summary>
    public bool AnyRetrying
    {
        get { lock (_gate) { return _entries.Values.Any(entry => entry.Attempt > 0); } }
    }

    /// <summary>
    /// Admits one event body, enforcing <see cref="EventDeliverySettings.MaximumBodyBytes"/> and
    /// <see cref="EventDeliverySettings.SpoolByteCeiling"/> (evicting oldest-first, then refusing --
    /// and counting the refusal -- if it still does not fit) before writing the bytes durably.
    /// </summary>
    /// <param name="sessionId">The capture session's <c>ArchiveIdentity.SessionId</c>.</param>
    /// <param name="sequence">The event's own per-session sequence, or <see langword="null"/> for a
    /// producer defect -- see this type's own remarks on the padding and collision behaviour.</param>
    /// <param name="body">The exact <c>/v1/logs</c> request body bytes.</param>
    public EventSpoolAdmission Spool(string sessionId, int? sequence, ReadOnlyMemory<byte> body)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        if (!IsSessionDirectoryName(sessionId))
        {
            // AdoptAtLaunch only ever descends into a directory shaped like a session id (see
            // IsSessionDirectoryName); a caller passing anything else would write files this spool
            // could stage today but would never adopt, count, or age out after a restart -- an
            // unbounded, un-swept leak in a directory the installer deliberately never removes.
            // ArchiveIdentity.SessionId is always "s-" + UuidV7(), so this can only ever reject a
            // caller defect, never a legitimate session.
            throw new ArgumentException(
                "Session id must have the ArchiveIdentity.SessionId shape (\"s-\" + a UUIDv7).",
                nameof(sessionId));
        }

        byte[] array = body.ToArray();
        string digestHex = Convert.ToHexString(SHA256.HashData(array)).ToLowerInvariant();
        string paddedSequence = (sequence ?? 0).ToString("D10", CultureInfo.InvariantCulture);

        lock (_gate)
        {
            DateTimeOffset now = _clock();
            EvictExpiredLocked(now);

            if (array.LongLength > _settings.MaximumBodyBytes || array.LongLength > _settings.SpoolByteCeiling)
            {
                return Refuse(SessionKeyPrefix(sessionId, paddedSequence, digestHex));
            }

            string sessionDirectory = Path.Combine(_directory, sessionId);
            string fileName = UniqueFileName(sessionId, paddedSequence, digestHex);
            string key = sessionId + "/" + fileName;
            string path = Path.Combine(sessionDirectory, fileName);

            long debtExcludingThisPath = _deletionDebt.Count == 0
                ? 0
                : _deletionDebt.Where(pair => pair.Key != path).Sum(pair => pair.Value);
            if (array.LongLength + debtExcludingThisPath > _settings.SpoolByteCeiling)
            {
                // Matches ScreenshotStagingArea.Stage's identical reasoning: outstanding debt for
                // every other path can never be freed by EvictOldestLocked, so refusing now -- before
                // writing or evicting anything -- is the same principle as never destroying a good
                // entry in service of an admission that was always going to fail.
                return Refuse(key);
            }

            try
            {
                CurrentUserOnlyAcl.RejectReparse(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                return Refuse(key);
            }

            try
            {
                Durability.ReplaceAtomic(path, array);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                return Refuse(key);
            }

            try
            {
                CurrentUserOnlyAcl.RejectReparse(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // The write above already landed real bytes at path under a published-looking name
                // (review finding: a best-effort delete here used to leave that file adoptable as a
                // legitimate pending event on the next relaunch, despite this call returning Refused
                // and counting the loss -- a refused event that could later be delivered anyway,
                // omitted from the accounting the whole time). TryDeleteOrRecordDebt durably
                // quarantines the file instead of merely retrying the same delete once: see that
                // method's own remarks.
                TryDeleteOrRecordDebt(path, array.LongLength);
                return Refuse(key);
            }

            try
            {
                CurrentUserOnlyAcl.SetFileAcl(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // Best-effort only, matching ScreenshotStagingArea.Stage: the directory ACL already
                // protects inherited access, so a file that could not be re-protected is still no
                // more exposed than the directory it lives in.
            }

            Durability.TryFlushDirectoryChain(sessionDirectory, _directory);

            // The write above just succeeded, so any debt still outstanding for this exact path no
            // longer describes anything real -- it was for bytes this write just overwrote (matches
            // ScreenshotStagingArea.Stage's identical clear after its own ReplaceAtomic). Without
            // this, a path that once failed to delete and is then re-admitted under the same name
            // (only reachable if two spooled bodies happen to land on the same sequence+digest,
            // itself only reachable for byte-identical re-spools) would double-count those bytes
            // against the ceiling forever.
            _deletionDebt.Remove(path);

            _entries[key] = new Entry(sessionId, fileName, path, array.LongLength, now, Attempt: 0, NextAttemptAt: DateTimeOffset.MinValue);

            long projected = TotalBytesLocked();
            bool evictionStalled = false;
            bool evictedSomething = false;
            while (projected > _settings.SpoolByteCeiling)
            {
                long beforeEviction = TotalBytesLocked();
                if (!EvictOldestLocked(protectedKey: key))
                {
                    break;
                }

                long afterEviction = TotalBytesLocked();
                if (afterEviction >= beforeEviction)
                {
                    // Mirrors ScreenshotStagingArea.Stage's ninth-pass fix: an eviction whose delete
                    // failed converted a live entry into debt of the same size, freeing zero
                    // capacity, so the sweep must stop rather than grind through further entries
                    // chasing capacity debt can never yield.
                    evictionStalled = true;
                    break;
                }

                evictedSomething = true;
                projected = afterEviction;
            }

            if (projected > _settings.SpoolByteCeiling && evictionStalled && !evictedSomething)
            {
                // Nothing was actually destroyed to make room, so this admission is rolled back --
                // the twelfth-pass fix ScreenshotStagingArea.Stage documents at length. Removed
                // directly rather than through RemoveLocked because this entry was never counted as
                // successfully admitted from the caller's point of view (Spool returns Refused, not
                // Spooled) -- but the bytes were nonetheless just written for real by ReplaceAtomic
                // above, so a failed delete here is exactly the same durable-orphan risk the post-
                // write reparse check above has. An earlier version of this comment argued a failed
                // delete here must *not* be charged to debt, reasoning the spool never took
                // ownership of these bytes; that was backwards (a review finding): the bytes are
                // physically on disk either way, so charging TryDeleteOrRecordDebt's quarantine path
                // is what keeps the ceiling's own accounting honest and keeps AdoptAtLaunch from ever
                // re-admitting this exact file as a legitimate pending event after a relaunch.
                _entries.Remove(key);
                TryDeleteOrRecordDebt(path, array.LongLength);
                return Refuse(key);
            }

            return EventSpoolAdmission.Spooled;
        }
    }

    /// <summary>
    /// Snapshot of entries due for a send attempt right now, ordered by session directory then by
    /// file name -- per-session FIFO, exactly as this type's own remarks describe.
    /// </summary>
    /// <remarks>
    /// <b>The FIFO guarantee holds across passes, not only within one (fix for a defect found in
    /// review, otherwise real).</b> A naive per-entry <c>NextAttemptAt &lt;= now</c> filter is not
    /// enough: once a session's earliest entry is retried, its own <c>NextAttemptAt</c> moves into
    /// the future and it drops out of *this* filter, while a later, never-yet-attempted entry of the
    /// same session (whose <c>NextAttemptAt</c> is still <see cref="DateTimeOffset.MinValue"/>) would
    /// still pass it -- on the very next pass, with a fresh worker-side halted-session set that knows
    /// nothing about the previous pass's retry, letting that later event be delivered ahead of the
    /// one still backing off. This method instead walks each session in file-name order and stops at
    /// the first entry that is not yet due, so nothing after a session's own blocked head is ever
    /// returned as due, in this call or any other, until that head is dealt with (acknowledged,
    /// terminally dropped, or evicted).
    /// </remarks>
    public IReadOnlyList<SpooledEventHandle> Drain()
    {
        lock (_gate)
        {
            DateTimeOffset now = _clock();
            var due = new List<SpooledEventHandle>();
            foreach (IGrouping<string, Entry> session in _entries.Values
                .GroupBy(entry => entry.SessionId)
                .OrderBy(group => group.Key, StringComparer.Ordinal))
            {
                foreach (Entry entry in session.OrderBy(entry => entry.FileName, StringComparer.Ordinal))
                {
                    if (entry.NextAttemptAt > now)
                    {
                        // This session's earliest still-present entry is not due yet; nothing later
                        // in the same session may be attempted ahead of it, so stop considering this
                        // session entirely for this call, even if a later entry's own NextAttemptAt
                        // (never having failed yet) would otherwise qualify.
                        break;
                    }

                    due.Add(new SpooledEventHandle(entry.SessionId + "/" + entry.FileName, entry.SessionId, entry.FileName));
                }
            }

            return due;
        }
    }

    /// <summary>
    /// Each session's own earliest surviving entry (by file name), the only one that can ever be
    /// "next" for that session under per-session FIFO. Shared by <see cref="Drain"/>'s reasoning and
    /// <see cref="TimeUntilNextDue"/>.
    /// </summary>
    private IEnumerable<Entry> HeadEntriesLocked() =>
        _entries.Values
            .GroupBy(entry => entry.SessionId)
            .Select(group => group.OrderBy(entry => entry.FileName, StringComparer.Ordinal).First());

    /// <summary>Attempts to lease <paramref name="key"/> so neither eviction sweep will pick it until
    /// <see cref="Release"/> is called. See <see cref="ScreenshotStagingArea.TryLease"/>'s own remarks
    /// for why a lost race must be skipped entirely rather than attempted.</summary>
    public bool TryLease(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            if (!_entries.ContainsKey(key))
            {
                return false;
            }

            _leased.Add(key);
            return true;
        }
    }

    /// <summary>Releases a lease. Always harmless, including for a key already removed.</summary>
    public void Release(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            _leased.Remove(key);
        }
    }

    /// <summary>
    /// Reads the spooled body back and verifies its length and SHA-256 against the digest parsed
    /// out of its own file name -- the property that makes exact-byte integrity verifiable after a
    /// restart, with no in-memory record to check against. A mismatch drops the entry (there is
    /// nothing to rehydrate from) and returns <see langword="false"/>.
    /// </summary>
    public bool TryReadBody(string key, out byte[] body)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out Entry entry))
            {
                body = Array.Empty<byte>();
                return false;
            }

            long actualLength;
            try
            {
                actualLength = new FileInfo(entry.Path).Length;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                RemoveLocked(key);
                body = Array.Empty<byte>();
                return false;
            }

            if (actualLength != entry.Length)
            {
                RemoveLocked(key, actualLength);
                body = Array.Empty<byte>();
                return false;
            }

            byte[] data;
            try
            {
                data = File.ReadAllBytes(entry.Path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                RemoveLocked(key);
                body = Array.Empty<byte>();
                return false;
            }

            if (!TryParseDigest(entry.FileName, out string expectedDigest)
                || !string.Equals(
                    Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant(),
                    expectedDigest,
                    StringComparison.Ordinal))
            {
                RemoveLocked(key, data.LongLength);
                body = Array.Empty<byte>();
                return false;
            }

            body = data;
            return true;
        }
    }

    /// <summary>Removes a spooled entry -- used after a successful send and after a terminal
    /// (dropped) classification. Deletes the file, and the session directory too once it is empty.</summary>
    public void Remove(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            RemoveLocked(key);
        }
    }

    /// <summary>
    /// Records one more failed send attempt for <paramref name="key"/>, scheduling its next attempt
    /// with <see cref="EventStreamRetryPolicy.Delay"/>. Never removes the entry: see this type's own
    /// remarks on why an event has no attempt budget. A no-op if the key no longer exists (e.g. it
    /// was evicted in the narrow race window between <see cref="Drain"/>'s snapshot and this call).
    /// </summary>
    public void RecordRetry(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out Entry entry))
            {
                return;
            }

            int attempt = entry.Attempt + 1;
            TimeSpan delay = EventStreamRetryPolicy.Delay(attempt, key, _settings);
            _entries[key] = entry with { Attempt = attempt, NextAttemptAt = _clock() + delay };
        }
    }

    /// <summary>Evicts every entry older than <see cref="EventDeliverySettings.SpoolRetention"/>,
    /// independent of the size bound. See <see cref="ScreenshotStagingArea.EvictExpired"/>'s own
    /// remarks -- the identical idea, ported verbatim.</summary>
    public void EvictExpired()
    {
        lock (_gate)
        {
            EvictExpiredLocked(_clock());
        }
    }

    /// <summary>Returns every key evicted (by the byte ceiling or by age) since the last call, and
    /// clears the internal list.</summary>
    public IReadOnlyList<string> DrainPendingEvictions()
    {
        lock (_gate)
        {
            if (_pendingEvictions.Count == 0)
            {
                return Array.Empty<string>();
            }

            string[] evicted = _pendingEvictions.ToArray();
            _pendingEvictions.Clear();
            return evicted;
        }
    }

    /// <summary>Returns every key refused by <see cref="Spool"/> since the last call, and clears the
    /// internal list. Unlike an eviction, a refused key was never written to disk.</summary>
    public IReadOnlyList<string> DrainPendingRefusals()
    {
        lock (_gate)
        {
            if (_pendingRefusals.Count == 0)
            {
                return Array.Empty<string>();
            }

            string[] refused = _pendingRefusals.ToArray();
            _pendingRefusals.Clear();
            return refused;
        }
    }

    private EventSpoolAdmission Refuse(string key)
    {
        _pendingRefusals.Add(key);
        return EventSpoolAdmission.Refused;
    }

    /// <summary>
    /// Re-enrols every event a previous process left behind, instead of wiping them the way
    /// <see cref="ScreenshotStagingArea.CleanAtLaunch"/> does -- see this type's own remarks on why
    /// that is safe and correct here. A directory or file this instance could not itself have
    /// written is left entirely alone; a failure to enumerate escapes rather than being swallowed
    /// (matching <c>ScreenshotStagingArea.CleanAtLaunch</c>'s identical, deliberate choice), because
    /// a directory this instance cannot even list can never be bounded by either the byte ceiling or
    /// the age sweep.
    /// </summary>
    private void AdoptAtLaunch()
    {
        lock (_gate)
        {
            CurrentUserOnlyAcl.RejectReparse(_directory);

            foreach (string sessionDirectory in Directory.EnumerateDirectories(_directory))
            {
                string sessionId = Path.GetFileName(sessionDirectory);
                if (!IsSessionDirectoryName(sessionId))
                {
                    continue;
                }

                try
                {
                    // Reject a session directory that is itself a reparse point, exactly as the root
                    // above and every published file path in Spool already are (review finding: a
                    // junction named like a session id -- "s-<uuid>" -- passes IsSessionDirectoryName,
                    // and without this check the enumeration below would read, adopt, and later
                    // delete or queue for upload files that live outside the spool entirely). Unlike a
                    // reparse failure at the root -- fatal to the whole spool, since there is nothing
                    // left to adopt into -- one bad session directory must not stop every other
                    // session's genuine events from being adopted, so this only skips this one
                    // directory rather than escaping the constructor.
                    CurrentUserOnlyAcl.RejectReparse(sessionDirectory);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    continue;
                }

                List<string> files;
                try
                {
                    // Materialized eagerly, inside the try: Directory.EnumerateFiles is lazy, so an
                    // I/O failure partway through (the directory removed, or made unreadable,
                    // between the reparse check above and this enumeration) would otherwise surface
                    // from inside the foreach below, past any catch wrapped only around the call
                    // itself.
                    files = Directory.EnumerateFiles(sessionDirectory).ToList();
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    // A session directory that passed both the name and reparse checks can still
                    // become unreadable before this enumeration runs (review finding: this used to
                    // have no guard at all, so a fault here propagated straight out of the
                    // constructor, turning one bad session directory into a total spool outage for
                    // the life of the process -- exactly the blast radius the reparse check just
                    // above exists to avoid). Skip just this directory, like every other guard here.
                    continue;
                }

                foreach (string file in files)
                {
                    AdoptFile(sessionId, file);
                }

                TryRemoveIfEmpty(sessionDirectory);
            }

            DateTimeOffset now = _clock();
            EvictExpiredLocked(now);

            // Bound adopted state to the ceiling exactly as a live Spool call would, with the same
            // stall guard Spool's own eviction loop uses: an eviction whose delete failed converts a
            // live entry into debt of the same size, freeing zero capacity, so chasing further
            // entries after that would only destroy more deliverable events for no gain.
            while (TotalBytesLocked() > _settings.SpoolByteCeiling)
            {
                long before = TotalBytesLocked();
                if (!EvictOldestLocked(protectedKey: null))
                {
                    break;
                }

                if (TotalBytesLocked() >= before)
                {
                    break;
                }
            }
        }
    }

    private void AdoptFile(string sessionId, string file)
    {
        try
        {
            // Reparse status was checked for the root and, now, for this file's own session
            // directory -- but never for the file itself (review finding). Without this, a
            // reparse-point file with an otherwise valid published name would be handed straight to
            // AdoptPublishedFile, whose FileInfo.Length and later File.ReadAllBytes both follow the
            // link, letting bytes outside the spool root be read, counted, and -- once drained --
            // POSTed as an event. Matches the same check Spool already performs on a path before
            // ever writing to it.
            CurrentUserOnlyAcl.RejectReparse(file);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Leave it entirely alone, exactly like a name this sweep does not recognize at all --
            // this is not this component's own file to adopt, sweep, or count.
            return;
        }

        string fileName = Path.GetFileName(file);
        if (IsPublishedFileName(fileName))
        {
            AdoptPublishedFile(sessionId, fileName, file);
            return;
        }

        if (IsInterruptedTemporaryFileName(fileName))
        {
            // An interrupted atomic write left this behind (Durability.Publish's own
            // "<name>.<uuid>.tmp" then rename); this component's own garbage, safe to sweep exactly
            // like ScreenshotStagingArea.CleanAtLaunch sweeps its equivalent.
            long length = _settings.SpoolByteCeiling;
            try
            {
                length = new FileInfo(file).Length;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
            }

            TryDeleteOrRecordDebt(file, length);
            return;
        }

        // Not a name this spool could have written; not this sweep's to touch or to count.
    }

    private void AdoptPublishedFile(string sessionId, string fileName, string file)
    {
        long length;
        DateTime lastWriteUtc;
        try
        {
            var info = new FileInfo(file);
            length = info.Length;
            lastWriteUtc = info.LastWriteTimeUtc;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Cannot safely re-enrol a file this instance cannot even stat. Best-effort clean it up;
            // a failed delete still counts against the ceiling (at the same conservative fallback
            // ScreenshotStagingArea.CleanAtLaunch uses when it cannot measure a file either), rather
            // than letting an unaccountable file silently defeat the byte ceiling.
            TryDeleteOrRecordDebt(file, _settings.SpoolByteCeiling);
            return;
        }

        // SpooledAt comes from LastWriteTimeUtc, not "now": resetting it on every launch would mean
        // a machine restarting daily never ages anything out, making SpoolRetention fiction.
        var spooledAt = new DateTimeOffset(DateTime.SpecifyKind(lastWriteUtc, DateTimeKind.Utc));
        string key = sessionId + "/" + fileName;
        _entries[key] = new Entry(sessionId, fileName, file, length, spooledAt, Attempt: 0, NextAttemptAt: DateTimeOffset.MinValue);
    }

    private void EvictExpiredLocked(DateTimeOffset now)
    {
        RetryDeletionDebtLocked();

        foreach (string key in _entries
            .Where(pair => !_leased.Contains(pair.Key) && now - pair.Value.SpooledAt > _settings.SpoolRetention)
            .Select(pair => pair.Key)
            .ToList())
        {
            RemoveLocked(key);
            _pendingEvictions.Add(key);
        }
    }

    private void RetryDeletionDebtLocked()
    {
        if (_deletionDebt.Count == 0)
        {
            return;
        }

        foreach (string path in _deletionDebt.Keys.ToList())
        {
            try
            {
                File.Delete(path);
                _deletionDebt.Remove(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    /// <summary>Evicts the oldest evictable (unleased, and never <paramref name="protectedKey"/> --
    /// the entry this very <see cref="Spool"/> call just wrote) entry, if any.</summary>
    private bool EvictOldestLocked(string? protectedKey)
    {
        string? oldest = _entries
            .Where(pair => !_leased.Contains(pair.Key) && pair.Key != protectedKey)
            .OrderBy(pair => pair.Value.SpooledAt)
            .Select(pair => pair.Key)
            .FirstOrDefault();
        if (oldest is null)
        {
            return false;
        }

        RemoveLocked(oldest);
        _pendingEvictions.Add(oldest);
        return true;
    }

    private void RemoveLocked(string key) => RemoveLocked(key, measuredLength: null);

    private void RemoveLocked(string key, long? measuredLength)
    {
        if (_entries.Remove(key, out Entry entry))
        {
            TryDeleteOrRecordDebt(entry.Path, measuredLength ?? entry.Length);
            TryRemoveIfEmpty(Path.GetDirectoryName(entry.Path));
        }

        _leased.Remove(key);
    }

    private void TryRemoveIfEmpty(string? sessionDirectory)
    {
        if (sessionDirectory is null)
        {
            return;
        }

        try
        {
            if (Directory.Exists(sessionDirectory) && !Directory.EnumerateFileSystemEntries(sessionDirectory).Any())
            {
                Directory.Delete(sessionDirectory);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Best-effort only: an empty directory that cannot be removed right now costs nothing
            // but a little disk clutter, and is retried the next time it is empty again.
        }
    }

    /// <summary>
    /// O(n) in the number of live entries, like every other locked-scan helper in this type
    /// (<see cref="EvictOldestLocked"/>'s ordering, <see cref="EvictExpiredLocked"/>'s filter,
    /// <see cref="UniqueFileName"/>'s count) -- an accepted cost inherited verbatim from
    /// <see cref="ScreenshotStagingArea"/>'s identical <c>TotalBytesLocked</c>/<c>EvictOldestLocked</c>
    /// shape (that type's own scans are the same complexity class). At this type's bounds (32 MiB /
    /// a few KB per body, so on the order of 5,000-15,000 entries), a handful of LINQ passes over an
    /// in-memory collection of that size cost microseconds, not milliseconds -- well under the other
    /// budgets already tolerated on this same capture path (e.g. the UI Automation resolver's own
    /// hundreds-of-milliseconds timeout). Revisit only if the byte ceiling is ever raised by an order
    /// of magnitude or more.
    /// </summary>
    private long TotalBytesLocked() =>
        _entries.Values.Sum(entry => entry.Length) + _deletionDebt.Values.Sum(bytes => bytes);

    /// <summary>
    /// Deletes <paramref name="path"/>, and durably quarantines it when the delete itself fails,
    /// rather than leaving an in-memory debt entry as the only record of the failure (review
    /// findings: a deletion failure used to either resurrect an already-decided-gone event --
    /// acknowledged, terminally dropped, verification-failed, or evicted -- as pending on the next
    /// relaunch, since <see cref="_deletionDebt"/> does not survive a restart; or, at two rollback
    /// sites in <see cref="Spool"/>, leave a fully published-looking file on disk while the event was
    /// already reported refused). Every caller here has either already deleted, or is trying to
    /// delete, bytes whose *published* file name <see cref="AdoptAtLaunch"/> would otherwise re-admit
    /// as a legitimate pending event on the next launch.
    /// </summary>
    /// <remarks>
    /// Renaming the file into the exact shape <c>Durability.Publish</c>'s own interrupted write
    /// leaves behind (<c>&lt;published-name&gt;.&lt;uuid&gt;.tmp</c>, recognized by
    /// <see cref="IsInterruptedTemporaryFileName"/>) converts an undeletable file into a durable
    /// tombstone with no new sidecar format or schema: <see cref="AdoptFile"/> already treats that
    /// exact shape as this component's own garbage to retry-delete or charge to debt, never as a
    /// pending event, on this launch and every subsequent one. Only when both the delete and the
    /// rename fail (the residual case -- for example, the whole directory has become inaccessible)
    /// does this fall back to charging debt against the original, still-published-looking path,
    /// exactly as before this fix; that residual gap is bounded by
    /// <see cref="RetryDeletionDebtLocked"/> retrying the plain delete on every sweep this same
    /// process already runs, and only outlives the process if the underlying failure itself does.
    /// </remarks>
    private void TryDeleteOrRecordDebt(string path, long byteLength)
    {
        try
        {
            File.Delete(path);
            _deletionDebt.Remove(path);
            return;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }

        string quarantinePath = path + "." + Guid.NewGuid().ToString() + TemporarySuffix;
        try
        {
            File.Move(path, quarantinePath);
            // A crash immediately after the rename lands, before this flush, could still leave the
            // rename unpersisted and the original published-looking name visible again on the very
            // next launch (review finding) -- match Durability.ReplaceAtomic's own directory-chain
            // flush after its own rename, rather than treating this one as durable without one.
            Durability.TryFlushDirectoryChain(Path.GetDirectoryName(path) ?? _directory, _directory);
            _deletionDebt.Remove(path);
            // The quarantined file still occupies real disk space until it can actually be deleted --
            // exactly like debt already tracks -- but now the file's own *shape*, not an in-memory
            // dictionary, is what keeps AdoptAtLaunch from ever re-admitting it, so the debt entry
            // moves to the new name rather than the old one.
            _deletionDebt[quarantinePath] = byteLength;
            return;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }

        _deletionDebt[path] = byteLength;
    }

    /// <summary>
    /// Builds the destination file name for a new event, appending a numeric collision suffix (right
    /// after the zero-padded sequence, before the digest) when an entry already claims this same
    /// sequence value -- regardless of that entry's own digest. See this type's own remarks: since
    /// the digest differs for two events with genuinely different content, this only ever triggers
    /// in the null-<c>Sequence</c> producer-defect case, where every affected event pads to the same
    /// base name.
    /// </summary>
    private string UniqueFileName(string sessionId, string paddedSequence, string digestHex)
    {
        int collisions = _entries.Keys.Count(existing => SharesSequencePrefix(existing, sessionId, paddedSequence));
        return collisions == 0
            ? paddedSequence + "." + digestHex + FileExtension
            : paddedSequence + "-" + collisions.ToString(CultureInfo.InvariantCulture) + "." + digestHex + FileExtension;
    }

    private bool SharesSequencePrefix(string existingKey, string sessionId, string paddedSequence)
    {
        string prefix = sessionId + "/";
        if (!existingKey.StartsWith(prefix, StringComparison.Ordinal))
        {
            return false;
        }

        string fileName = existingKey[prefix.Length..];
        return fileName.Length >= SequenceDigitCount
            && fileName.AsSpan(0, SequenceDigitCount).SequenceEqual(paddedSequence);
    }

    private static string SessionKeyPrefix(string sessionId, string paddedSequence, string digestHex) =>
        sessionId + "/" + paddedSequence + "." + digestHex + FileExtension;

    private static bool IsSessionDirectoryName(string name)
    {
        if (!name.StartsWith(SessionDirectoryPrefix, StringComparison.Ordinal))
        {
            return false;
        }

        return IsCanonicalUuid(name.AsSpan(SessionDirectoryPrefix.Length));
    }

    /// <summary>
    /// The exact published shape: <c>&lt;10 digits&gt;[-&lt;digits&gt;].&lt;64 lowercase hex&gt;.otlp.json</c>.
    /// </summary>
    private static bool IsPublishedFileName(string fileName) => TryParseDigest(fileName, out _);

    /// <summary>The published shape with one interrupted atomic write's ".&lt;uuid&gt;.tmp" suffix
    /// still attached (<c>Durability.Publish</c> appends "." + UuidV7() + ".tmp" to the destination
    /// name before its rename).</summary>
    private static bool IsInterruptedTemporaryFileName(string fileName)
    {
        int publishedLength = LengthOfPublishedPrefix(fileName);
        if (publishedLength < 0)
        {
            return false;
        }

        ReadOnlySpan<char> rest = fileName.AsSpan(publishedLength);
        if (rest.Length == 0 || rest[0] != '.' || !rest.EndsWith(TemporarySuffix, StringComparison.Ordinal))
        {
            return false;
        }

        return IsCanonicalUuid(rest[1..^TemporarySuffix.Length]);
    }

    /// <summary>Parses the 64-character lowercase hex digest out of a file name of the exact
    /// published shape, or returns <see langword="false"/> if the name does not have that shape.</summary>
    private static bool TryParseDigest(string fileName, out string digestHex)
    {
        int prefixLength = LengthOfPublishedPrefix(fileName);
        if (prefixLength < 0 || prefixLength != fileName.Length)
        {
            digestHex = string.Empty;
            return false;
        }

        // LengthOfPublishedPrefix already validated the whole name; the digest is the fixed-position
        // 64-hex-character segment between the sequence(+suffix) and the trailing ".otlp.json".
        int dot = fileName.IndexOf('.', SequenceDigitCount);
        digestHex = fileName.Substring(dot + 1, DigestHexLength);
        return true;
    }

    /// <summary>
    /// Returns the length of the exact published shape's prefix -- everything through the trailing
    /// <c>.otlp.json</c> -- if <paramref name="fileName"/> starts with that shape, or -1 otherwise.
    /// The whole name is this length exactly for a normal published file; a longer name may still be
    /// this shape plus an interrupted-write suffix, which <see cref="IsInterruptedTemporaryFileName"/>
    /// checks separately.
    /// </summary>
    private static int LengthOfPublishedPrefix(string fileName)
    {
        ReadOnlySpan<char> name = fileName;
        if (name.Length < SequenceDigitCount || !IsAllAsciiDigits(name[..SequenceDigitCount]))
        {
            return -1;
        }

        int index = SequenceDigitCount;
        if (index < name.Length && name[index] == '-')
        {
            int digitsStart = index + 1;
            int digitsEnd = digitsStart;
            while (digitsEnd < name.Length && char.IsAsciiDigit(name[digitsEnd]))
            {
                digitsEnd++;
            }

            if (digitsEnd == digitsStart)
            {
                return -1;
            }

            index = digitsEnd;
        }

        const int SuffixLength = 1 + DigestHexLength + 10; // "." + 64 hex + ".otlp.json" (10 chars)
        if (index + SuffixLength > name.Length || name[index] != '.')
        {
            return -1;
        }

        ReadOnlySpan<char> digest = name.Slice(index + 1, DigestHexLength);
        if (!IsLowercaseHex(digest))
        {
            return -1;
        }

        int afterDigest = index + 1 + DigestHexLength;
        if (!name[afterDigest..].StartsWith(FileExtension, StringComparison.Ordinal))
        {
            return -1;
        }

        return afterDigest + FileExtension.Length;
    }

    private static bool IsCanonicalUuid(ReadOnlySpan<char> value)
    {
        ReadOnlySpan<char> shape = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
        if (value.Length != shape.Length)
        {
            return false;
        }

        for (int index = 0; index < shape.Length; index++)
        {
            bool matches = shape[index] == '-'
                ? value[index] == '-'
                : IsLowercaseHexDigit(value[index]);
            if (!matches)
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsAllAsciiDigits(ReadOnlySpan<char> value)
    {
        foreach (char character in value)
        {
            if (!char.IsAsciiDigit(character))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsLowercaseHex(ReadOnlySpan<char> value)
    {
        foreach (char character in value)
        {
            if (!IsLowercaseHexDigit(character))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsLowercaseHexDigit(char character) =>
        char.IsAsciiDigit(character) || character is >= 'a' and <= 'f';

    private readonly record struct Entry(
        string SessionId,
        string FileName,
        string Path,
        long Length,
        DateTimeOffset SpooledAt,
        int Attempt,
        DateTimeOffset NextAttemptAt);
}
