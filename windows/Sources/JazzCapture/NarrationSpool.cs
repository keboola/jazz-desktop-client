using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using JazzCaptureCore.Journal;

namespace JazzCapture;

/// <summary>Whether <see cref="NarrationSpool.Stage"/> admitted a new clip.</summary>
public enum NarrationSpoolAdmission
{
    /// <summary>The pair was written durably and the clip is now pending upload.</summary>
    Staged,

    /// <summary>
    /// Nothing was admitted, and -- exactly like <see cref="EventSpool"/> and unlike
    /// <see cref="ScreenshotStagingArea"/> -- this is always counted (see
    /// <see cref="NarrationSpool.DrainPendingRefusals"/>). A refused clip is a narration row that
    /// will now never exist for that label at all.
    /// </summary>
    Refused,
}

/// <summary>The outcome of reading a staged clip's blob back off disk.</summary>
public enum NarrationBlobRead
{
    /// <summary>The bytes were read and matched both the recorded length and the digest in the
    /// blob's own file name.</summary>
    Ok,

    /// <summary>
    /// Positive evidence that what is on disk is not what was staged -- a length or digest
    /// mismatch, or an entry this spool no longer knows about. Deliberately does <em>not</em> remove
    /// the entry itself (see <see cref="NarrationSpool.ReadBlob"/>'s own remarks): the caller must
    /// spool the amendment-2 row first and only then call <see cref="NarrationSpool.Remove"/>, so a
    /// crash cannot land between the pair being deleted and the row being emitted.
    /// </summary>
    Corrupt,

    /// <summary>
    /// The blob could not be stat'd or read <em>right now</em>. Not evidence of corruption -- an
    /// antivirus scanner holding a just-written file is the common case on Windows -- so the entry
    /// is kept and the upload is retried later. See <see cref="EventSpool"/>'s own remarks on the
    /// identical distinction.
    /// </summary>
    Unavailable,
}

/// <summary>Cheap, non-secret projection of spool occupancy for the tray to display.</summary>
public readonly record struct NarrationSpoolStatus(int PendingCount);

/// <summary>
/// The durable sidecar for one staged narration clip: everything needed to rebuild its
/// <c>narration</c> event and <c>SessionContext</c> once a Files id exists, without which the record
/// cannot be built at all -- see <see cref="NarrationSpool"/>'s own remarks on why this, and not just
/// the clip's bytes, has to survive a crash or a relaunch.
/// </summary>
/// <param name="SessionId">The capture session's <c>ArchiveIdentity.SessionId</c> (<c>"s-" + UUIDv7</c>).</param>
/// <param name="ArchiveId">Archive identity of the capture the clip belongs to.</param>
/// <param name="CaptureId">Capture identity of the recording the clip belongs to.</param>
/// <param name="ArtifactId">
/// The journal-assigned artifact identity -- never a Files id -- used for the Files <c>artifact:</c>
/// tag, exactly as the screenshot path already uses it.
/// </param>
/// <param name="EventId">The narration event's own <c>eventId</c> (<c>sessionId + "-" + sequence</c>).</param>
/// <param name="Sequence">The narration event's own per-session sequence.</param>
/// <param name="Timestamp">The event's timestamp: the clip's own <c>StartedAt</c>, not write time.</param>
/// <param name="LabelId">The closed label's id.</param>
/// <param name="Label">The closed label's declared text.</param>
/// <param name="MediaType">IANA media type of the blob (<c>audio/wav</c>).</param>
/// <param name="Sha256">Lowercase hex SHA-256 of the blob -- always the digest actually staged, never a caller's claim.</param>
/// <param name="ByteLength">Length of the blob -- always the length actually staged.</param>
/// <param name="StagedAt">
/// RFC 3339 instant this pair was staged, stamped from the host's own clock at <see cref="NarrationSpool.Stage"/>
/// time. This -- never the file system's <c>LastWriteTimeUtc</c> and never "now" -- is what
/// <see cref="NarrationSpool"/> reads back at adoption, so retention stays honest across a relaunch.
/// </param>
/// <param name="TraceId">The session's trace id. Minted once per capture in memory and persisted nowhere else.</param>
/// <param name="SpanId">The session's span id. Same reason as <paramref name="TraceId"/>.</param>
/// <param name="SessionStartedAt">The session's own start instant (<c>CaptureEngine.StartedAt</c>).</param>
/// <param name="User">The captured user, projected as <c>enduser.id</c>.</param>
/// <param name="InstanceName">The recording machine, projected as <c>host.name</c>.</param>
/// <param name="ServiceName">Resource <c>service.name</c>.</param>
/// <param name="FilesId">
/// <see langword="null"/> until <see cref="NarrationSpool.TryStampFilesId"/> durably records the
/// upload's result -- the upload's actual commit point (issue #84, §2.6 step 4). Once set, adoption
/// skips prepare and upload entirely and re-enters directly at spooling the event, so a crash after
/// the stamp can produce at most one duplicate row, never a second upload or a second id.
/// </param>
public sealed record PendingNarration(
    string SessionId,
    string ArchiveId,
    string CaptureId,
    string ArtifactId,
    string EventId,
    int Sequence,
    string Timestamp,
    string? LabelId,
    string? Label,
    string MediaType,
    string Sha256,
    long ByteLength,
    string StagedAt,
    string TraceId,
    string SpanId,
    string SessionStartedAt,
    string User,
    string InstanceName,
    string ServiceName,
    long? FilesId);

/// <summary>One staged narration pair handed to <see cref="NarrationDeliveryWorker"/>.</summary>
public sealed record StagedNarrationHandle(string Key, string SessionId, string FileName, PendingNarration Meta);

/// <summary>
/// The durable, bounded, ordered on-disk spool for pending narration clips -- a blob-plus-sidecar
/// pair per clip, written synchronously on the capture path, before the clip's <c>narration</c> event
/// exists at all.
/// </summary>
/// <remarks>
/// <para>
/// <b>Modelled on <see cref="EventSpool"/> (#84 plan §3.6), not on <see cref="ScreenshotStagingArea"/>.</b>
/// <see cref="EventSpool"/> already solves durability across a relaunch for a settings.json-free,
/// bounded, ACL-protected, adopted-not-wiped area -- exactly what this needs -- and its internals
/// (the coarse lock, adoption instead of wipe, oldest-first eviction, deletion-debt accounting,
/// leasing, own-file-name filtering, reparse hardening) are ported here largely unchanged. Four
/// deltas make this a <em>pair</em> spool rather than a single-file one:
/// </para>
/// <list type="number">
/// <item><description>
/// <b>A pair, not a file.</b> The blob is written first; the sidecar, written second and
/// atomically, is the commit marker. <see cref="AdoptAtLaunch"/> accepts only a complete, parsable
/// pair -- a blob with no sidecar, a sidecar with no blob, and an unparsable sidecar are all
/// <em>swept</em> (charging deletion debt on a failed delete), not merely skipped, so the byte
/// ceiling's own accounting stays honest.
/// </description></item>
/// <item><description>
/// <b><see cref="TryStampFilesId"/> rewrites the sidecar atomically, and never the blob.</b> This is
/// the upload's actual commit point (issue #84, §2.6 step 4): once a clip's sidecar carries a
/// <see cref="PendingNarration.FilesId"/>, a crash before the event is finally spooled re-enters
/// directly at the spool step on the next launch -- no second prepare, no second upload, no second
/// Files id (R4, R5 of the #84 plan: a narration row carries no <c>eventId</c>/<c>sequence</c> on the
/// wire, so two different Files ids for one clip would be unreconcilable downstream).
/// </description></item>
/// <item><description>
/// <b><see cref="Stage"/> takes a <see cref="ReadOnlySpan{T}"/>, never an owned copy.</b> A clip can
/// be tens of megabytes; <see cref="Durability.ReplaceAtomic(string, ReadOnlySpan{byte})"/> and
/// <see cref="SHA256.HashData(ReadOnlySpan{byte})"/> both accept a span directly, so this type never
/// allocates a second copy of the blob at all (R1 of the #84 plan) -- stricter than the plan's own
/// "zero its one working array" wording, since there ends up being no working array to zero.
/// </description></item>
/// <item><description>
/// <b><see cref="RecordRetry"/> never drops an entry.</b> Exactly like <see cref="EventSpool"/> and
/// unlike <see cref="ScreenshotStagingArea"/>: a narration clip is not a decoration on the record, it
/// <em>is</em> the record, so a retryable upload failure retries indefinitely until it succeeds, is
/// classified terminal by <see cref="NarrationDeliveryWorker"/>, or ages out of one of the two
/// bounds below.
/// </description></item>
/// </list>
/// <para>
/// <b>Why the sidecar exists at all (issue #84, §2.1).</b> A narration event cannot be built at
/// capture time: <c>audio_file_id</c> does not exist yet, and the session's <c>traceId</c>/<c>spanId</c>
/// are minted fresh in memory per capture and persisted nowhere else in this process. So the durable
/// unit is a pair -- the exact clip bytes, plus everything needed to rebuild the event and its
/// <c>SessionContext</c> once a Files id exists -- exactly macOS's <c>NarrationSpool.PendingNarration</c>,
/// for the identical reason its own header gives: "the record can't exist until then".
/// </para>
/// <para>
/// <b>Layout.</b>
/// <code>
/// %LOCALAPPDATA%\Jazz\spool\narration\        &lt;- CurrentUserOnlyAcl.ApplyDirectory, once, in the ctor
///     s-0193f0c1-.../
///         0000000042.&lt;64 hex sha256&gt;.narration.audio    &lt;- exact clip bytes
///         0000000042.&lt;64 hex sha256&gt;.narration.json     &lt;- sidecar; the commit marker
/// </code>
/// The digest is in the blob's own file name for the same reason <see cref="EventSpool"/>'s is:
/// exact-byte integrity becomes verifiable after a restart with no in-memory record at all.
/// </para>
/// <para>
/// <b>Bounding and eviction: every loss is visible, exactly as <see cref="EventSpool"/>'s is.</b>
/// <see cref="NarrationDeliverySettings.MaximumClipBytes"/> bounds one clip;
/// <see cref="NarrationDeliverySettings.SpoolByteCeiling"/> and
/// <see cref="NarrationDeliverySettings.SpoolRetention"/> bound the whole spool, oldest-first. A
/// discarded clip here is a stronger loss than a discarded event: no narration row will ever be
/// emitted for that label at all, because the row cannot exist without the audio it would have cited.
/// </para>
/// <para>
/// <b>Thread safety.</b> <see cref="Stage"/> runs on the capture engine's own worker thread, inside
/// the engine's lock, synchronously with the capture path. Every other member runs from
/// <see cref="NarrationDeliveryWorker"/> on a background task. All of them take one coarse
/// <see cref="_gate"/> lock around both the in-memory dictionaries and the (large, but capture-rare
/// -- once per closed label, not once per click) file I/O.
/// </para>
/// </remarks>
public sealed class NarrationSpool
{
    private const string BlobExtension = ".narration.audio";
    private const string SidecarExtension = ".narration.json";
    private const int SequenceDigitCount = 10;
    private const int DigestHexLength = 64;
    private const string TemporarySuffix = ".tmp";
    private const string SessionDirectoryPrefix = "s-";

    private readonly string _directory;
    private readonly NarrationDeliverySettings _settings;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();

    /// <summary>Keyed by <c>"&lt;sessionId&gt;/&lt;stem&gt;"</c>. Guarded by <see cref="_gate"/>.</summary>
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);

    /// <summary>Keys currently leased by <see cref="TryLease"/>, excluded from both eviction sweeps.</summary>
    private readonly HashSet<string> _leased = new(StringComparer.Ordinal);

    /// <summary>Keys evicted by the byte ceiling or the age bound since the last
    /// <see cref="DrainPendingEvictions"/> call.</summary>
    private readonly List<string> _pendingEvictions = new();

    /// <summary>Keys refused by <see cref="Stage"/> since the last <see cref="DrainPendingRefusals"/>
    /// call. Always counted -- see <see cref="NarrationSpoolAdmission.Refused"/>'s own remarks.</summary>
    private readonly List<string> _pendingRefusals = new();

    /// <summary>
    /// Keys of an incomplete or unparsable pair discovered at <see cref="AdoptAtLaunch"/> -- a blob
    /// with no sidecar, a sidecar with no blob, or a sidecar this spool could not parse -- since the
    /// last <see cref="DrainPendingVerificationFailures"/> call. Kept separate from
    /// <see cref="_pendingRefusals"/> because no live <see cref="Entry"/> (and therefore no lease, no
    /// upload attempt) ever existed for these: unlike a live <see cref="Stage"/> refusal or a
    /// terminal upload failure, there is nothing here <see cref="NarrationDeliveryWorker"/> could
    /// ever have emitted a row for, since the sidecar -- the only thing that could rebuild the event
    /// -- is exactly what is missing or broken.
    /// </summary>
    private readonly List<string> _pendingVerificationFailures = new();

    /// <summary>
    /// Bytes a deletion could not free, keyed by file path, exactly like <see cref="EventSpool"/>'s
    /// own deletion debt. Both the blob and the sidecar of one pair can each independently owe debt.
    /// </summary>
    private readonly Dictionary<string, long> _deletionDebt = new(StringComparer.Ordinal);

    public NarrationSpool(NarrationDeliverySettings settings, Func<DateTimeOffset>? clock = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        _settings = settings;
        _directory = settings.SpoolDirectory;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);

        CurrentUserOnlyAcl.ApplyDirectory(_directory);
        AdoptAtLaunch();
    }

    /// <summary>Pending clips right now. Cheap, non-secret; safe for the tray to poll.</summary>
    public NarrationSpoolStatus Status
    {
        get { lock (_gate) { return new NarrationSpoolStatus(_entries.Count); } }
    }

    /// <summary>How long until the earliest staged clip's next attempt is due, or
    /// <see langword="null"/> when nothing is staged.</summary>
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

                DateTimeOffset now = _clock();
                DateTimeOffset earliest = _entries.Values.Min(entry => entry.NextAttemptAt);
                TimeSpan remaining = earliest - now;
                return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
            }
        }
    }

    /// <summary>
    /// How long until specifically <paramref name="key"/>'s own next attempt is due, or
    /// <see langword="null"/> if the key no longer exists (e.g. removed or evicted in the narrow
    /// window between the caller observing it and this call).
    /// </summary>
    /// <remarks>
    /// <b>Why this exists, distinct from <see cref="TimeUntilNextDue"/> (issue #84 review finding).</b>
    /// <see cref="NarrationDeliveryWorker"/> stops its whole pass at the first retryable failure
    /// (§2.6), but <see cref="TimeUntilNextDue"/> reports the earliest due time across <em>every</em>
    /// staged clip -- including ones the pass never reached this time because it stopped early. Any
    /// never-yet-attempted clip still sits at <see cref="DateTimeOffset.MinValue"/>, so returning
    /// <see cref="TimeUntilNextDue"/> right after a halt would resolve to <see cref="TimeSpan.Zero"/>
    /// for as long as any other untouched clip exists, making <c>DeliveryDrainScheduler</c> re-enter
    /// near-instantly and attempt a <em>different</em> clip immediately -- defeating the entire point
    /// of stopping the pass, which is to avoid a second expensive network attempt right after the
    /// first one just failed. The worker calls this instead, naming the one entry that actually
    /// halted the pass, so the scheduler waits out that entry's own just-scheduled backoff before
    /// trying anything else.
    /// </remarks>
    public TimeSpan? TimeUntilNextAttempt(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out Entry entry))
            {
                return null;
            }

            DateTimeOffset now = _clock();
            TimeSpan remaining = entry.NextAttemptAt - now;
            return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
        }
    }

    /// <summary>
    /// How long until the oldest evictable (unleased) staged clip would age past
    /// <see cref="NarrationDeliverySettings.SpoolRetention"/> -- capped at
    /// <see cref="NarrationDeliverySettings.UploadBackoffCeiling"/> -- or <see langword="null"/> when
    /// nothing is spooled. See <see cref="EventSpool.TimeUntilNextExpiry"/>'s own remarks: the
    /// identical reasoning and the identical safety argument (this is always read immediately after
    /// <see cref="EvictExpired"/> in the same drain pass, so what remains is never already due).
    /// </summary>
    public TimeSpan? TimeUntilNextExpiry
    {
        get
        {
            lock (_gate)
            {
                List<Entry> evictable = _entries.Values.Where(entry => !_leased.Contains(Key(entry))).ToList();
                if (evictable.Count == 0)
                {
                    return null;
                }

                DateTimeOffset now = _clock();
                DateTimeOffset oldestStagedAt = evictable.Min(entry => ParseStagedAt(entry.Meta, now));
                TimeSpan age = now > oldestStagedAt ? now - oldestStagedAt : TimeSpan.Zero;
                TimeSpan remaining = _settings.SpoolRetention - age;
                if (remaining <= TimeSpan.Zero)
                {
                    return TimeSpan.FromMilliseconds(1);
                }

                return remaining < _settings.UploadBackoffCeiling ? remaining : _settings.UploadBackoffCeiling;
            }
        }
    }

    /// <summary>Whether at least one staged clip has failed at least one upload attempt.</summary>
    public bool AnyRetrying
    {
        get { lock (_gate) { return _entries.Values.Any(entry => entry.Attempt > 0); } }
    }

    /// <summary>
    /// Admits one narration clip: enforces <see cref="NarrationDeliverySettings.MaximumClipBytes"/>
    /// and <see cref="NarrationDeliverySettings.SpoolByteCeiling"/> (evicting oldest-first, then
    /// refusing -- and counting the refusal -- if it still does not fit) before writing the blob
    /// durably, then the sidecar durably and atomically as the commit marker.
    /// </summary>
    /// <param name="pending">
    /// Everything needed to rebuild the event once a Files id exists. <see cref="PendingNarration.Sha256"/>,
    /// <see cref="PendingNarration.ByteLength"/> and <see cref="PendingNarration.FilesId"/> are always
    /// overwritten from <paramref name="blob"/> and <see langword="null"/> respectively, regardless of
    /// what the caller passed, so the sidecar can never disagree with the bytes actually on disk.
    /// </param>
    /// <param name="blob">The exact clip bytes, read from the caller's descriptor exactly once.</param>
    public NarrationSpoolAdmission Stage(PendingNarration pending, ReadOnlySpan<byte> blob)
    {
        ArgumentNullException.ThrowIfNull(pending);
        ArgumentException.ThrowIfNullOrWhiteSpace(pending.SessionId);
        if (!IsSessionDirectoryName(pending.SessionId))
        {
            throw new ArgumentException(
                "Session id must have the ArchiveIdentity.SessionId shape (\"s-\" + a UUIDv7).",
                nameof(pending));
        }

        string digestHex = Convert.ToHexString(SHA256.HashData(blob)).ToLowerInvariant();
        PendingNarration meta = pending with { Sha256 = digestHex, ByteLength = blob.Length, FilesId = null };

        lock (_gate)
        {
            DateTimeOffset now = _clock();
            EvictExpiredLocked(now);

            if (blob.Length > _settings.MaximumClipBytes || blob.Length > _settings.SpoolByteCeiling)
            {
                return Refuse(StemPrefix(meta.SessionId, meta.Sequence, digestHex));
            }

            string sessionDirectory = Path.Combine(_directory, meta.SessionId);
            string stem = UniqueStem(meta.SessionId, meta.Sequence, digestHex);
            string key = meta.SessionId + "/" + stem;
            string blobPath = Path.Combine(sessionDirectory, stem + BlobExtension);
            string sidecarPath = Path.Combine(sessionDirectory, stem + SidecarExtension);

            long debtExcludingThisPair = _deletionDebt.Count == 0
                ? 0
                : _deletionDebt
                    .Where(pair => pair.Key != blobPath && pair.Key != sidecarPath)
                    .Sum(pair => pair.Value);
            if (blob.Length + debtExcludingThisPair > _settings.SpoolByteCeiling)
            {
                return Refuse(key);
            }

            try
            {
                CurrentUserOnlyAcl.RejectReparse(blobPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                return Refuse(key);
            }

            // The blob first, durably, before the sidecar exists at all: a crash here leaves an
            // unreferenced blob with no sidecar, which the next launch's AdoptAtLaunch sweeps as
            // garbage. This mirrors the journal's own "bytes before the record that cites them" rule.
            try
            {
                Durability.ReplaceAtomic(blobPath, blob);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                SweepInterruptedTemporariesLocked(sessionDirectory);
                return Refuse(key);
            }

            try
            {
                CurrentUserOnlyAcl.RejectReparse(blobPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                TryDeleteOrRecordDebt(blobPath, blob.Length);
                return Refuse(key);
            }

            try
            {
                CurrentUserOnlyAcl.SetFileAcl(blobPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // Best-effort only, matching every other per-file ACL call in this codebase.
            }

            // The sidecar is written second and is the commit marker (issue #84, §2.1): only once it
            // exists, atomically, does this pair become an adoptable, deliverable clip.
            byte[] sidecarBytes = SerializeSidecar(meta);
            try
            {
                CurrentUserOnlyAcl.RejectReparse(sidecarPath);
                Durability.ReplaceAtomic(sidecarPath, sidecarBytes);
                CurrentUserOnlyAcl.RejectReparse(sidecarPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                SweepInterruptedTemporariesLocked(sessionDirectory);
                TryDeleteOrRecordDebt(sidecarPath, sidecarBytes.LongLength);
                TryDeleteOrRecordDebt(blobPath, blob.Length);
                return Refuse(key);
            }

            try
            {
                CurrentUserOnlyAcl.SetFileAcl(sidecarPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
            }

            Durability.TryFlushDirectoryChain(sessionDirectory, _directory);

            _deletionDebt.Remove(blobPath);
            _deletionDebt.Remove(sidecarPath);

            _entries[key] = new Entry(meta, stem, blobPath, sidecarPath, Attempt: 0, NextAttemptAt: DateTimeOffset.MinValue);

            // Evict oldest-first until back under the ceiling. EvictOldestLocked refuses to touch a
            // stamped entry (R5) or the pair just admitted, so it can legitimately run out of room to
            // make -- either immediately (nothing evictable at all) or after evicting everything it
            // is allowed to. Either way, if we are still over the ceiling once eviction can make no
            // further progress, the admission itself must be refused: silently admitting over-ceiling
            // would either orphan a stamped clip's Files object (never touched here) or simply grow
            // the spool past its configured bound (issue #84 review finding, M1).
            long projected = TotalBytesLocked();
            while (projected > _settings.SpoolByteCeiling)
            {
                long beforeEviction = projected;
                if (!EvictOldestLocked(protectedKey: key))
                {
                    break;
                }

                long afterEviction = TotalBytesLocked();
                if (afterEviction >= beforeEviction)
                {
                    break;
                }

                projected = afterEviction;
            }

            if (projected > _settings.SpoolByteCeiling)
            {
                _entries.Remove(key);
                TryDeleteOrRecordDebt(sidecarPath, sidecarBytes.LongLength);
                TryDeleteOrRecordDebt(blobPath, blob.Length);
                return Refuse(key);
            }

            return NarrationSpoolAdmission.Staged;
        }
    }

    /// <summary>Snapshot of clips due for an upload attempt right now, oldest first.</summary>
    /// <remarks>
    /// No per-session FIFO restriction, unlike <see cref="EventSpool.Drain"/>: narration clips are
    /// large and few (one per closed label, not one per click), so
    /// <see cref="NarrationDeliveryWorker"/> deliberately stops its whole pass at the first retryable
    /// failure (issue #84, §2.6) rather than skipping ahead to other sessions, which is what makes a
    /// session-scoped ordering guarantee unnecessary here.
    /// </remarks>
    public IReadOnlyList<StagedNarrationHandle> Drain()
    {
        lock (_gate)
        {
            DateTimeOffset now = _clock();
            return _entries
                .Where(pair => pair.Value.NextAttemptAt <= now)
                .OrderBy(pair => pair.Value.Meta.StagedAt, StringComparer.Ordinal)
                .Select(pair => new StagedNarrationHandle(pair.Key, pair.Value.Meta.SessionId, pair.Value.Stem, pair.Value.Meta))
                .ToList();
        }
    }

    /// <summary>Attempts to lease <paramref name="key"/> so neither eviction sweep will pick it
    /// until <see cref="Release"/> is called. See <see cref="EventSpool.TryLease"/>'s own remarks.</summary>
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
    /// Reads the staged blob back and verifies its length and SHA-256 against the digest parsed out
    /// of its own file name. A mismatch returns <see langword="false"/> and leaves the pair staged
    /// (see <see cref="ReadBlob"/>'s own remarks on why removal is deliberately not done here).
    /// </summary>
    public bool TryReadBlob(string key, out byte[] blob) => ReadBlob(key, out blob) == NarrationBlobRead.Ok;

    /// <summary>The three-way form of <see cref="TryReadBlob"/>. See <see cref="EventSpool.ReadBody"/>'s
    /// own remarks on why "could not read right now" must never be treated as corruption.</summary>
    /// <remarks>
    /// <b>A <see cref="NarrationBlobRead.Corrupt"/> result deliberately does not remove the pair
    /// itself</b> (fix for a review finding, otherwise real: this used to call <c>RemoveLocked</c>
    /// directly, which deleted both files -- including the sidecar, the only thing that could ever
    /// rebuild the event -- before <see cref="NarrationDeliveryWorker"/> ever got a chance to spool
    /// the amendment-2 row for this terminal cause. That inverted the "spool before remove" ordering
    /// every other terminal cause already honours, and a crash in the resulting window could lose
    /// the row entirely). The caller is responsible for removal, exactly like every other terminal
    /// classification: <see cref="NarrationDeliveryWorker"/> spools the row with
    /// <c>AudioFileId</c> null first, then calls <see cref="Remove"/>.
    /// </remarks>
    public NarrationBlobRead ReadBlob(string key, out byte[] blob)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out Entry entry))
            {
                blob = Array.Empty<byte>();
                return NarrationBlobRead.Corrupt;
            }

            long actualLength;
            try
            {
                actualLength = new FileInfo(entry.BlobPath).Length;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                blob = Array.Empty<byte>();
                return NarrationBlobRead.Unavailable;
            }

            if (actualLength != entry.Meta.ByteLength)
            {
                blob = Array.Empty<byte>();
                return NarrationBlobRead.Corrupt;
            }

            byte[] data;
            try
            {
                data = File.ReadAllBytes(entry.BlobPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                blob = Array.Empty<byte>();
                return NarrationBlobRead.Unavailable;
            }

            // Verified against the digest encoded in the blob's own file name -- fixed at Stage
            // time and never rewritten -- not against entry.Meta.Sha256 (review finding: the
            // sidecar is a mutable JSON document TryStampFilesId rewrites, so trusting its own
            // claimed digest would accept a blob and sidecar that had been corrupted or swapped
            // together while the name, the one thing this spool itself never rewrites, still said
            // otherwise). This is the same anchor EventSpool.ReadBody verifies against.
            if (data.LongLength != entry.Meta.ByteLength
                || !string.Equals(
                    Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant(),
                    DigestFromStem(entry.Stem),
                    StringComparison.Ordinal))
            {
                CryptographicOperations.ZeroMemory(data);
                blob = Array.Empty<byte>();
                return NarrationBlobRead.Corrupt;
            }

            blob = data;
            return NarrationBlobRead.Ok;
        }
    }

    /// <summary>
    /// Rewrites the sidecar atomically with <paramref name="filesId"/> stamped in. Never rewrites
    /// the blob. This is the upload's actual commit point (issue #84, §2.6 step 4): once this
    /// returns <see langword="true"/>, a crash before the event is spooled re-enters directly at the
    /// spool step, never re-uploading and never minting a second Files id.
    /// </summary>
    /// <returns>
    /// <see langword="false"/> when the key no longer exists, or the rewrite itself failed (a
    /// transient I/O or ACL problem) -- either way, the caller must treat this exactly like any
    /// other retryable failure and must not proceed to spool the event.
    /// </returns>
    public bool TryStampFilesId(string key, long filesId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out Entry entry))
            {
                return false;
            }

            PendingNarration stamped = entry.Meta with { FilesId = filesId };
            byte[] sidecarBytes = SerializeSidecar(stamped);
            try
            {
                Durability.ReplaceAtomic(entry.SidecarPath, sidecarBytes);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                return false;
            }

            Durability.TryFlushDirectoryChain(
                Path.GetDirectoryName(entry.SidecarPath) ?? _directory, _directory);
            _entries[key] = entry with { Meta = stamped };
            return true;
        }
    }

    /// <summary>
    /// Removes a staged pair -- used once its event has been durably spooled (§2.6 step 5), or once
    /// the clip is being dropped on terminal upload failure (amendment 2). Deletes the <b>sidecar
    /// first, then the blob</b> (§2.6 step 7): this ordering is what bounds a crash in this window to
    /// at most one duplicate row rather than a second upload, exactly the guarantee
    /// <see cref="TryStampFilesId"/>'s own remarks describe.
    /// </summary>
    public void Remove(string key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        lock (_gate)
        {
            RemoveLocked(key);
        }
    }

    /// <summary>
    /// Records one more failed upload attempt for <paramref name="key"/>. Never removes the entry --
    /// see this type's own remarks on why a narration clip has no attempt budget. A no-op if the key
    /// no longer exists.
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
            TimeSpan delay = NarrationUploadRetryPolicy.Delay(attempt, key, _settings);
            _entries[key] = entry with { Attempt = attempt, NextAttemptAt = _clock() + delay };
        }
    }

    /// <summary>Evicts every entry older than <see cref="NarrationDeliverySettings.SpoolRetention"/>,
    /// independent of the byte ceiling.</summary>
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

    /// <summary>Returns every key refused by <see cref="Stage"/> since the last call, and clears the
    /// internal list.</summary>
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

    /// <summary>Returns every key of an incomplete or unparsable pair discovered at
    /// <see cref="AdoptAtLaunch"/> since the last call, and clears the internal list. See
    /// <see cref="_pendingVerificationFailures"/>'s own remarks.</summary>
    public IReadOnlyList<string> DrainPendingVerificationFailures()
    {
        lock (_gate)
        {
            if (_pendingVerificationFailures.Count == 0)
            {
                return Array.Empty<string>();
            }

            string[] failures = _pendingVerificationFailures.ToArray();
            _pendingVerificationFailures.Clear();
            return failures;
        }
    }

    private NarrationSpoolAdmission Refuse(string key)
    {
        _pendingRefusals.Add(key);
        return NarrationSpoolAdmission.Refused;
    }

    /// <summary>
    /// Re-enrols every complete, parsable pair a previous process left behind. A blob-without-sidecar,
    /// a sidecar-without-blob, and an unparsable sidecar are all swept, charging deletion debt on a
    /// failed delete, exactly as <see cref="EventSpool.AdoptAtLaunch"/> sweeps its own equivalents --
    /// the byte ceiling's accounting must stay honest even for a pair adoption can never make sense
    /// of. A directory or file this instance could not itself have written is left entirely alone; a
    /// failure to enumerate escapes rather than being swallowed, matching
    /// <see cref="EventSpool.AdoptAtLaunch"/>'s identical, deliberate choice.
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
                    CurrentUserOnlyAcl.RejectReparse(sessionDirectory);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    continue;
                }

                List<string> files;
                try
                {
                    files = Directory.EnumerateFiles(sessionDirectory).ToList();
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    continue;
                }

                AdoptSessionDirectory(sessionId, sessionDirectory, files);
            }

            DateTimeOffset now = _clock();
            EvictExpiredLocked(now);

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

    private void AdoptSessionDirectory(string sessionId, string sessionDirectory, List<string> files)
    {
        var blobs = new Dictionary<string, string>(StringComparer.Ordinal);
        var sidecars = new Dictionary<string, string>(StringComparer.Ordinal);

        foreach (string file in files)
        {
            try
            {
                // Leaf-only reparse check, matching EventSpool.AdoptFile: the root and this file's
                // own session directory are already verified by the time this runs.
                CurrentUserOnlyAcl.RejectReparseLeaf(file);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            string fileName = Path.GetFileName(file);
            if (TryParsePublishedName(fileName, BlobExtension, out string blobStem))
            {
                blobs[blobStem] = file;
                continue;
            }

            if (TryParsePublishedName(fileName, SidecarExtension, out string sidecarStem))
            {
                sidecars[sidecarStem] = file;
                continue;
            }

            if (IsInterruptedTemporaryFileName(fileName, out long length))
            {
                SweepFileLocked(file, length);
                continue;
            }

            // Not a name this spool could have written; not this sweep's to touch or count.
        }

        foreach (string stem in blobs.Keys.Union(sidecars.Keys, StringComparer.Ordinal))
        {
            bool hasBlob = blobs.TryGetValue(stem, out string? blobPath);
            bool hasSidecar = sidecars.TryGetValue(stem, out string? sidecarPath);

            string adoptionKey = sessionId + "/" + stem;

            if (hasBlob && hasSidecar)
            {
                // A parsed sidecar must also agree with the two things this spool itself never
                // trusts the sidecar's own word for: which session it belongs to (the containing
                // directory name, not the mutable JSON field) and what the blob actually hashes to
                // (the stem's own digest, not entry.Meta.Sha256 -- see ReadBlob's identical
                // reasoning). A parsed-but-disagreeing sidecar is treated exactly like an
                // unparsable one (review finding): adopting it anyway would let a moved, copied, or
                // corrupted pair be silently attributed to the wrong session, or bypass the
                // filename's own integrity anchor entirely.
                if (TryParseSidecar(sidecarPath!, out PendingNarration meta)
                    && string.Equals(meta.SessionId, sessionId, StringComparison.Ordinal)
                    && string.Equals(meta.Sha256, DigestFromStem(stem), StringComparison.Ordinal))
                {
                    _entries[adoptionKey] = new Entry(meta, stem, blobPath!, sidecarPath!, Attempt: 0, NextAttemptAt: DateTimeOffset.MinValue);
                    continue;
                }

                // Unparsable, or parsed but inconsistent with its own directory/file name: sweep
                // both, since neither half means anything trustworthy without the other (issue #84,
                // §3.6 delta 1). Counted -- not merely swept silently -- so this loss is as visible
                // as every other one, even though (unlike a terminal upload
                // failure under amendment 2) no row can ever be built for it.
                _pendingVerificationFailures.Add(adoptionKey);
                SweepFileLocked(sidecarPath!, MeasureLength(sidecarPath!));
                SweepFileLocked(blobPath!, MeasureLength(blobPath!));
                continue;
            }

            _pendingVerificationFailures.Add(adoptionKey);
            if (hasBlob)
            {
                SweepFileLocked(blobPath!, MeasureLength(blobPath!));
            }

            if (hasSidecar)
            {
                SweepFileLocked(sidecarPath!, MeasureLength(sidecarPath!));
            }
        }
    }

    private long MeasureLength(string path)
    {
        try
        {
            return new FileInfo(path).Length;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return _settings.SpoolByteCeiling;
        }
    }

    private void SweepFileLocked(string path, long length) => TryDeleteOrRecordDebt(path, length);

    private void EvictExpiredLocked(DateTimeOffset now)
    {
        RetryDeletionDebtLocked();

        // A stamped entry (Meta.FilesId is not null) is excluded from both eviction sweeps -- see
        // EvictOldestLocked's own remarks (issue #84 review finding, R5).
        foreach (string key in _entries
            .Where(pair => !_leased.Contains(pair.Key)
                && pair.Value.Meta.FilesId is null
                && now - ParseStagedAt(pair.Value.Meta, now) > _settings.SpoolRetention)
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

    /// <summary>Evicts the oldest evictable (unleased, and never <paramref name="protectedKey"/>) pair,
    /// deleting the sidecar first then the blob, matching <see cref="Remove"/>'s own ordering.</summary>
    /// <summary>
    /// Evicts the oldest evictable (unleased, unprotected, and -- issue #84 review finding, R5 --
    /// <b>never already-stamped</b>) entry, if any.
    /// </summary>
    /// <remarks>
    /// A stamped entry (<see cref="PendingNarration.FilesId"/> is not null) has already been
    /// successfully uploaded to Keboola Files; only its own event still needs to reach the event
    /// spool, which costs no network and no disk space this bound exists to protect. Evicting it
    /// anyway would permanently orphan the Files object it already uploaded -- exactly the outcome
    /// the durable <c>filesId</c> stamp exists to prevent -- while losing a row that was fully
    /// rebuildable from the sidecar at zero further cost. The accepted trade-off: if every remaining
    /// evictable entry is stamped, a new admission that needs the room is refused instead (a visible,
    /// counted loss) rather than silently orphaning an already-uploaded Files object.
    /// </remarks>
    private bool EvictOldestLocked(string? protectedKey)
    {
        DateTimeOffset now = _clock();
        string? oldest = _entries
            .Where(pair => !_leased.Contains(pair.Key)
                && pair.Key != protectedKey
                && pair.Value.Meta.FilesId is null)
            .OrderBy(pair => ParseStagedAt(pair.Value.Meta, now))
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

    private void RemoveLocked(string key) => RemoveLocked(key, measuredBlobLength: null);

    private void RemoveLocked(string key, long? measuredBlobLength)
    {
        if (_entries.Remove(key, out Entry entry))
        {
            byte[] sidecarBytes = SerializeSidecar(entry.Meta);
            // Sidecar first (§2.6 step 7): see this type's own remarks on Remove for why this exact
            // ordering is what bounds a crash to at most one duplicate row.
            TryDeleteOrRecordDebt(entry.SidecarPath, sidecarBytes.LongLength);
            TryDeleteOrRecordDebt(entry.BlobPath, measuredBlobLength ?? entry.Meta.ByteLength);
            TryRemoveIfEmpty(Path.GetDirectoryName(entry.BlobPath));
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
        }
    }

    private long TotalBytesLocked() =>
        _entries.Values.Sum(entry => entry.Meta.ByteLength) + _deletionDebt.Values.Sum(bytes => bytes);

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

        if (IsInterruptedTemporaryFileName(Path.GetFileName(path), out _))
        {
            _deletionDebt[path] = byteLength;
            return;
        }

        string quarantinePath = path + "." + Guid.NewGuid().ToString() + TemporarySuffix;
        try
        {
            File.Move(path, quarantinePath);
            Durability.TryFlushDirectoryChain(Path.GetDirectoryName(path) ?? _directory, _directory);
            _deletionDebt.Remove(path);
            _deletionDebt[quarantinePath] = byteLength;
            return;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }

        _deletionDebt[path] = byteLength;
    }

    private void SweepInterruptedTemporariesLocked(string sessionDirectory)
    {
        List<string> files;
        try
        {
            files = Directory.EnumerateFiles(sessionDirectory).ToList();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return;
        }

        foreach (string file in files)
        {
            if (!IsInterruptedTemporaryFileName(Path.GetFileName(file), out long length))
            {
                continue;
            }

            TryDeleteOrRecordDebt(file, length);
        }
    }

    private static string Key(Entry entry) => entry.Meta.SessionId + "/" + entry.Stem;

    private static byte[] SerializeSidecar(PendingNarration meta) => JsonSerializer.SerializeToUtf8Bytes(meta);

    private static bool TryParseSidecar(string path, out PendingNarration meta)
    {
        meta = null!;
        try
        {
            byte[] bytes = File.ReadAllBytes(path);
            PendingNarration? parsed = JsonSerializer.Deserialize<PendingNarration>(bytes);
            if (parsed is null
                || string.IsNullOrWhiteSpace(parsed.SessionId)
                || string.IsNullOrWhiteSpace(parsed.Sha256)
                || parsed.Sha256.Length != DigestHexLength)
            {
                return false;
            }

            meta = parsed;
            return true;
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or JsonException
            or NotSupportedException)
        {
            return false;
        }
    }

    /// <summary>
    /// <see cref="PendingNarration.StagedAt"/>, parsed as an RFC 3339 instant. A sidecar this spool
    /// itself wrote always parses; a defensive fallback to <paramref name="now"/> exists only so a
    /// hypothetical malformed value already adopted in memory cannot throw out of an eviction sweep --
    /// it can never make an entry look artificially old and evicted early, since falling back to now
    /// means it looks perfectly fresh instead.
    /// </summary>
    private static DateTimeOffset ParseStagedAt(PendingNarration meta, DateTimeOffset now) =>
        DateTimeOffset.TryParse(
            meta.StagedAt,
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out DateTimeOffset parsed)
            ? parsed
            : now;

    private string UniqueStem(string sessionId, int sequence, string digestHex)
    {
        string paddedSequence = (sequence >= 0 ? sequence : 0).ToString("D10", CultureInfo.InvariantCulture);
        for (int suffix = 0; ; suffix++)
        {
            string sequenceAndSuffix = suffix == 0
                ? paddedSequence
                : paddedSequence + "-" + suffix.ToString(CultureInfo.InvariantCulture);
            string key = sessionId + "/" + sequenceAndSuffix + "." + digestHex;
            if (!_entries.ContainsKey(key))
            {
                return sequenceAndSuffix + "." + digestHex;
            }
        }
    }

    private static string StemPrefix(string sessionId, int sequence, string digestHex) =>
        sessionId + "/" + (sequence >= 0 ? sequence : 0).ToString("D10", CultureInfo.InvariantCulture) + "." + digestHex;

    private static bool IsSessionDirectoryName(string name) =>
        name.StartsWith(SessionDirectoryPrefix, StringComparison.Ordinal)
        && IsCanonicalUuid(name.AsSpan(SessionDirectoryPrefix.Length));

    /// <summary>The exact published shape for one of the two extensions this spool writes:
    /// <c>&lt;10 digits&gt;[-&lt;digits&gt;].&lt;64 lowercase hex&gt;</c> plus that extension.</summary>
    private static bool TryParsePublishedName(string fileName, string extension, out string stem)
    {
        stem = string.Empty;
        if (!fileName.EndsWith(extension, StringComparison.Ordinal))
        {
            return false;
        }

        string candidate = fileName[..^extension.Length];
        if (!IsStemShape(candidate))
        {
            return false;
        }

        stem = candidate;
        return true;
    }

    private static bool IsStemShape(string stem)
    {
        ReadOnlySpan<char> name = stem;
        if (name.Length < SequenceDigitCount || !IsAllAsciiDigits(name[..SequenceDigitCount]))
        {
            return false;
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
                return false;
            }

            index = digitsEnd;
        }

        if (index >= name.Length || name[index] != '.')
        {
            return false;
        }

        ReadOnlySpan<char> digest = name[(index + 1)..];
        return digest.Length == DigestHexLength && IsLowercaseHex(digest);
    }

    /// <summary>
    /// The 64-lowercase-hex digest encoded in the trailing segment of a stem already known to have
    /// <see cref="IsStemShape"/>'s shape -- the integrity anchor <see cref="ReadBlob"/> verifies
    /// against, exactly like <see cref="EventSpool"/> parses one out of its own file name. Never
    /// called on a stem that has not already passed <see cref="IsStemShape"/> (every stem that
    /// reaches <see cref="Entry"/> has, whether minted by <see cref="UniqueStem"/> or accepted by
    /// <see cref="TryParsePublishedName"/> at adoption).
    /// </summary>
    private static string DigestFromStem(string stem) => stem[^DigestHexLength..];

    /// <summary>Whether <paramref name="fileName"/> is one interrupted atomic write's
    /// <c>.&lt;uuid&gt;.tmp</c> suffix still attached to either published extension.</summary>
    private static bool IsInterruptedTemporaryFileName(string fileName, out long length)
    {
        length = 0;
        foreach (string extension in new[] { BlobExtension, SidecarExtension })
        {
            int marker = fileName.IndexOf(extension + ".", StringComparison.Ordinal);
            if (marker < 0)
            {
                continue;
            }

            string candidateStem = fileName[..marker];
            if (!IsStemShape(candidateStem))
            {
                continue;
            }

            ReadOnlySpan<char> rest = fileName.AsSpan(marker + extension.Length);
            if (rest.Length == 0 || rest[0] != '.' || !rest.EndsWith(TemporarySuffix, StringComparison.Ordinal))
            {
                continue;
            }

            if (IsCanonicalUuid(rest[1..^TemporarySuffix.Length]))
            {
                return true;
            }
        }

        return false;
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
            bool matches = shape[index] == '-' ? value[index] == '-' : IsLowercaseHexDigit(value[index]);
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
        PendingNarration Meta,
        string Stem,
        string BlobPath,
        string SidecarPath,
        int Attempt,
        DateTimeOffset NextAttemptAt);
}
