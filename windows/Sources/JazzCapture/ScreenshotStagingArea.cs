using System.IO;
using System.Security.Cryptography;
using JazzCaptureCore.Journal;

namespace JazzCapture;

/// <summary>Whether <see cref="ScreenshotStagingArea.Stage"/> admitted a new entry.</summary>
public enum ScreenshotStageResult
{
    /// <summary>The bytes were written and the entry is now pending upload.</summary>
    Staged,

    /// <summary>
    /// Nothing is admitted: no entry for this artifact id exists in <see cref="ScreenshotStagingArea"/>
    /// once <see cref="ScreenshotStagingArea.Stage"/> returns this. This screenshot's own bytes
    /// alone are larger than <see cref="ScreenshotDeliverySettings.StagingByteCeiling"/>, outstanding
    /// deletion debt alone leaves no room for it, the write itself failed, or (Finding 1, #74 review,
    /// ninth pass) evicting to make room for it stalled -- froze a good entry into debt instead of
    /// freeing capacity. The first two and the write failure never touch disk for this artifact id;
    /// the stalled-eviction case does write the bytes and then deletes them again as part of rolling
    /// the admission back -- see <see cref="ScreenshotStagingArea.Stage"/>'s own remarks for why.
    /// </summary>
    Refused,
}

/// <summary>
/// One screenshot handed to the background uploader: the request identity and the GCS federation
/// target it needs, without the bytes (which the worker re-reads and re-verifies from disk through
/// <see cref="ScreenshotStagingArea.TryReadBytes"/>).
/// </summary>
public sealed record StagedScreenshotHandle(
    string ArtifactId,
    ScreenshotPrepareResult Prepared,
    ScreenshotFilesRequest Request);

/// <summary>Cheap, non-secret projection of staging area occupancy for the tray to display.</summary>
public readonly record struct ScreenshotStagingStatus(int PendingCount);

/// <summary>
/// The non-durable staging area for prepare-early screenshot delivery: exact bytes on disk, GCS
/// federation credentials in managed memory only, bounded by both total size and age, and wiped at
/// every process launch.
/// </summary>
/// <remarks>
/// <para>
/// This is deliberately not the closed <c>codex/68-screenshot-files</c> branch's durable spool.
/// That branch persisted delivery intent (including, transitively, enough to reconstruct a WAL) so a
/// crash could be recovered from. Issue #73 accepts eventual inconsistency instead, across three
/// distinct crash windows rather than one. Bytes land in this staging area (<see cref="Stage"/>
/// returns <see cref="ScreenshotStageResult.Staged"/>) strictly before
/// <c>ScreenshotDeliveryPreparer.Prepare</c> wakes the background uploader and returns the Files id
/// for the capture engine to stamp onto the outgoing event and emit -- see that type's own remarks
/// for the exact sequencing. A crash before <see cref="Stage"/> ever completes leaves an unused
/// Files allocation that nothing references and nothing will ever clean up (a staging *refusal*, as
/// opposed to a crash, does delete that allocation with a bounded best-effort call, but a crash
/// pre-empts that entirely). A crash after <see cref="Stage"/> succeeds but before the event is
/// emitted lands while the background uploader may already be racing the capture thread to that
/// same event -- the crash then either reproduces the same unused allocation, or, if the upload won
/// that race, leaves an orphan object in Keboola Files that no emitted event will ever reference.
/// Only a crash after the event has already been emitted produces the case this codebase talks
/// about most, a dangling <c>screenshot_id</c> on an event that already went out -- an outcome the
/// Jazz processor already tolerates by dropping a failed screenshot download and continuing. All
/// three are accepted, not defects: there is nothing to recover *to*, and no journal, WAL,
/// tombstone, quarantine state, or startup reconciliation exists in this type.
/// </para>
/// <para>
/// <b>Bytes vs. credentials.</b> One staged entry is a file under
/// <see cref="ScreenshotDeliverySettings.StagingDirectory"/> holding the exact screenshot bytes,
/// named by <see cref="Key"/> of the artifact id (the same hashing idea the closed branch's
/// <c>ArtifactDeliveryQueue.Key</c> used, so a hostile or path-shaped artifact id can never escape
/// the directory), plus an in-memory record of the <see cref="ScreenshotPrepareResult"/> (GCS
/// bucket/key/access token) and the <see cref="ScreenshotFilesRequest"/> needed to re-verify and
/// upload it. The in-memory record is the sole authority: a byte file with no matching in-memory
/// entry is garbage by definition, which is exactly what <see cref="CleanAtLaunch"/> removes, and a
/// missing/expired federation credential can never be recovered from disk because it was never
/// written there -- see the "no secrets on disk" test in
/// <c>ScreenshotStagingAreaTests.NoFederationCredentialFieldEverReachesDisk</c>.
/// </para>
/// <para>
/// <b>Thread safety.</b> <see cref="Stage"/> runs on the capture engine's own worker thread, inside
/// the engine's <c>_gate</c> lock, synchronously with the capture path (see
/// <c>CaptureEngine.ObserveWithArtifact</c>). <see cref="Drain"/>, <see cref="TryReadBytes"/>,
/// <see cref="Remove"/>, <see cref="RecordRetry"/>, <see cref="EvictExpired"/> and
/// <see cref="DrainPendingEvictions"/> run from <see cref="ScreenshotDeliveryWorker"/> on a
/// background task. All of them take the single
/// <see cref="_gate"/> lock around both the in-memory dictionaries (<see cref="_entries"/> and
/// <see cref="_deletionDebt"/>) and the (small, screenshot-sized) file I/O; screenshots are staged
/// at ordinary capture cadence, not in a hot loop, so one coarse lock is simpler and safer than
/// splitting file I/O out from under it and is not a measured bottleneck.
/// </para>
/// </remarks>
public sealed class ScreenshotStagingArea
{
    private const string FileExtension = ".bin";

    private readonly string _directory;
    private readonly ScreenshotDeliverySettings _settings;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();

    /// <summary>Keyed by artifact id. Guarded by <see cref="_gate"/>.</summary>
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);

    /// <summary>
    /// Artifact ids currently leased by <see cref="TryLease"/> and not yet released by
    /// <see cref="Release"/>, guarded by <see cref="_gate"/>. Neither <see cref="EvictOldestLocked"/>
    /// nor <see cref="EvictExpiredLocked"/> will ever pick an id in this set -- see
    /// <see cref="TryLease"/>'s own remarks (Finding 4, #74 review) for why that is what
    /// guarantees a leased artifact reaches exactly one terminal outcome. In practice this holds at
    /// most one id at a time: <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/> processes its
    /// due entries strictly sequentially, leasing the one it is about to attempt immediately before
    /// attempting it and releasing it immediately after, regardless of outcome.
    /// </summary>
    private readonly HashSet<string> _leased = new(StringComparer.Ordinal);

    /// <summary>
    /// Artifact ids evicted by <see cref="EvictOldestLocked"/> or <see cref="EvictExpiredLocked"/>
    /// since the last <see cref="DrainPendingEvictions"/> call, guarded by <see cref="_gate"/>. An
    /// eviction here always removed an already-staged, already-prepared entry -- one whose Files id
    /// has already been stamped on an emitted event -- so unlike a <see cref="Remove"/> after a
    /// successful upload or an explicit drop, nothing else in the process otherwise learns that this
    /// id is now dangling. This list exists to carry that fact out to a caller that can safely report
    /// it (<see cref="ScreenshotDeliveryWorker"/>, on its own background task) without this type ever
    /// invoking a caller-supplied callback itself -- in particular never while <see cref="_gate"/> is
    /// held, and never from <see cref="Stage"/>, which runs on the capture path under the capture
    /// engine's own lock (see <c>CaptureEngine.ObserveWithArtifact</c> and
    /// <see cref="ScreenshotDeliveryPreparer.Prepare"/>) where a blocking callback would stall
    /// capture. A byte-ceiling eviction can therefore happen here well before it is drained and
    /// reported; that is fine, since the same successful <c>Stage</c> call already nudges the
    /// scheduler (<see cref="ScreenshotDeliveryPreparer.Prepare"/>'s own <c>_nudge()</c>), so a drain
    /// pass -- and with it, a drain of this list -- follows promptly.
    /// </summary>
    private readonly List<string> _pendingEvictions = new();

    /// <summary>
    /// Bytes that a deletion could not free, keyed by the file path <see cref="TryDeleteOrRecordDebt"/>
    /// failed to delete (from <see cref="RemoveLocked"/>) or that <see cref="CleanAtLaunch"/> could
    /// not remove during its own sweep. Guarded by <see cref="_gate"/>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Why this exists (Finding 1, #74 review, sixth pass).</b> <see cref="RemoveLocked"/> used to
    /// drop the in-memory <see cref="Entry"/> and then call a best-effort delete that silently
    /// swallowed <see cref="IOException"/>/<see cref="UnauthorizedAccessException"/> (an antivirus
    /// scan, a transient sharing violation). A file that failed to delete that way stayed on disk
    /// with no bookkeeping left anywhere -- invisible to both <see cref="ScreenshotDeliverySettings.StagingByteCeiling"/>
    /// and <see cref="EvictExpiredLocked"/>'s age sweep -- so repeated terminal outcomes could grow
    /// the staging directory past its configured cap within one long-running process, exactly the
    /// disk-cap guarantee issue #73 exists to provide. This dictionary is the fix: the bytes, and the
    /// pending deletion, are tracked until the deletion actually succeeds.
    /// </para>
    /// <para>
    /// <b>Counted, not entries.</b> <see cref="TotalBytesLocked"/> adds this dictionary's values on
    /// top of every staged entry's own byte length, because the whole point is that these bytes are
    /// really still on disk. But debt is not an entry: it is never returned by <see cref="Drain"/>,
    /// never leasable through <see cref="TryLease"/>, never picked by <see cref="EvictOldestLocked"/>
    /// or <see cref="EvictExpiredLocked"/>'s own age sweep, and never produces a
    /// <see cref="ScreenshotDeliveryOutcome"/> -- it is pure accounting plus a pending deletion,
    /// retried by <see cref="RetryDeletionDebtLocked"/> on every sweep that already runs.
    /// </para>
    /// <para>
    /// <b>Bounded growth.</b> A path only ever enters this dictionary as <see cref="PathFor"/>'s own
    /// output, and <see cref="PathFor"/> derives it deterministically, one path per artifact id (see
    /// <see cref="Key"/>). Debt therefore cannot grow faster or larger than the set of distinct
    /// artifact ids this process has ever staged or swept at launch -- it never grows per attempt,
    /// per retry, or per sweep, only per previously-unseen path.
    /// </para>
    /// <para>
    /// <b>Honest back-pressure when debt is permanent.</b> If a file can genuinely never be deleted
    /// for the life of the process (not merely a transient lock), its bytes stay counted here
    /// forever, and the byte ceiling eventually fills with real, undeletable bytes. <see cref="Stage"/>
    /// checks this up front, before writing or evicting anything for the new entry: if the new
    /// entry cannot fit next to outstanding debt alone, no amount of evicting other, still-evictable
    /// entries changes that either, since eviction can never free debt -- debt is not an entry
    /// <see cref="EvictOldestLocked"/> can pick. <see cref="Stage"/> therefore starts returning
    /// <see cref="ScreenshotStageResult.Refused"/> for new entries once debt alone occupies enough
    /// of the ceiling. That is the correct outcome, not a defect: the disk really is occupied by
    /// bytes this process cannot remove, and the ceiling exists to reflect exactly that. The only
    /// reset is the same one every other non-durable guarantee in this type already relies on --
    /// <see cref="CleanAtLaunch"/> at the next process launch, which clears this dictionary outright
    /// and reseeds it only for what it, itself, still cannot delete.
    /// </para>
    /// </remarks>
    private readonly Dictionary<string, long> _deletionDebt = new(StringComparer.Ordinal);

    /// <summary>
    /// Creates the staging area, protecting and (if necessary) creating its root directory, then
    /// running <see cref="CleanAtLaunch"/> once. Nothing has been staged into a fresh instance yet,
    /// so any bytes found on disk at this point belong to a previous, now-dead process whose
    /// in-memory credentials are gone -- exactly the definition of garbage this design accepts.
    /// </summary>
    /// <param name="settings">The operational bounds for this staging area.</param>
    /// <param name="clock">Overrides the wall clock used for staleness and backoff; defaults to
    /// <see cref="DateTimeOffset.UtcNow"/>.</param>
    public ScreenshotStagingArea(ScreenshotDeliverySettings settings, Func<DateTimeOffset>? clock = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        _settings = settings;
        _directory = settings.StagingDirectory;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);

        // Create and protect the root exactly once, per the #72 review's finding D1: the directory
        // ACL is applied here and nowhere else in this type.
        CurrentUserOnlyAcl.ApplyDirectory(_directory);
        CleanAtLaunch();
    }

    /// <summary>Pending entries right now. Cheap, non-secret; safe for the tray to poll.</summary>
    public ScreenshotStagingStatus Status
    {
        get { lock (_gate) { return new ScreenshotStagingStatus(_entries.Count); } }
    }

    /// <summary>
    /// How long until the earliest staged entry's <c>NextAttemptAt</c> is due, or
    /// <see langword="null"/> when nothing is staged. A relative span, computed against
    /// <see cref="_clock"/> inside <see cref="_gate"/>, rather than an absolute time -- callers of
    /// this (namely <see cref="ScreenshotDeliveryScheduler"/>) have no clock of their own and should
    /// not gain one just to interpret this value. A due time already in the past clamps to
    /// <see cref="TimeSpan.Zero"/> rather than going negative, so it can be handed straight to a
    /// delay function.
    /// </summary>
    /// <remarks>
    /// Cheap, non-secret, pure -- no I/O, modelled on <see cref="Status"/> above -- so it is safe to
    /// call once per drain pass from a background loop. It is a standalone property rather than a
    /// second field on <see cref="ScreenshotStagingStatus"/> because that struct is a tray-facing
    /// "how much is pending" projection; a scheduling concern like "when is more work due" is a
    /// different kind of question with a different (and much more churny) caller, so keeping it
    /// separate avoids stretching one struct to mean two things.
    /// </remarks>
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
    /// Returns every artifact id evicted (by the byte ceiling or by age) since the last call, and
    /// clears the internal list. Cheap, in-memory, no I/O -- safe for
    /// <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/> to call once per drain pass on its own
    /// background task, which is where these ids are actually reported as a terminal
    /// <see cref="ScreenshotDeliveryOutcome.Evicted"/> outcome. An empty result is the common case
    /// (most drain passes evict nothing) and allocates nothing.
    /// </summary>
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

    /// <summary>
    /// Deletes every file currently in the staging directory and drops any in-memory entries (there
    /// should be none yet when this runs from the constructor). Tolerates a per-file delete failure
    /// -- a locked file, an <see cref="IOException"/>, or an <see cref="UnauthorizedAccessException"/>
    /// -- without failing the sweep: a file this process cannot delete must not stop the client from
    /// starting. Also clears any deletion debt (see <see cref="_deletionDebt"/>) from a previous
    /// instance, then seeds a fresh record for any file this very sweep could not delete -- so a file
    /// this process cannot remove is still accounted for by a fresh process, not merely by the one
    /// that first failed to delete it.
    /// </summary>
    /// <remarks>
    /// <b>Enumerating the directory is not tolerated the same way (Finding 1, #74 review, eighth
    /// pass).</b> A failure to even list the directory's contents -- <see cref="IOException"/> or
    /// <see cref="UnauthorizedAccessException"/> from <see cref="Directory.EnumerateFiles(string)"/>
    /// -- used to be swallowed here too, returning as if the sweep had simply found nothing. That let
    /// construction succeed having run no cleanup and recorded no debt for whatever is actually on
    /// disk: new screenshots would then be staged alongside stale bytes this instance can never see,
    /// past <see cref="ScreenshotDeliverySettings.StagingByteCeiling"/>, because neither the ceiling
    /// nor the age sweep can bound a directory they cannot enumerate. So this exception is left to
    /// escape instead. The constructor has no try/catch of its own, so it propagates out of
    /// <c>new ScreenshotStagingArea(...)</c> -- straight into the guard <c>App.OnStartup</c> already
    /// wraps that call in for exactly this pair of exception types (see its own remarks), which
    /// leaves <c>_screenshotStaging</c> null, disables screenshot delivery, and lets local capture
    /// start regardless. Failing closed is correct here, unlike the per-file case above: a single
    /// stuck file is still fully accounted for by <see cref="_deletionDebt"/>, but a directory this
    /// instance cannot even list can never be accounted for at all, by either bound.
    /// </remarks>
    public void CleanAtLaunch()
    {
        lock (_gate)
        {
            _entries.Clear();
            _pendingEvictions.Clear();
            _deletionDebt.Clear();

            List<string> files = Directory.EnumerateFiles(_directory).ToList();

            foreach (string file in files)
            {
                // Read the length before attempting the delete: if the delete below fails, this is
                // the only chance to learn how many bytes are being left behind for the debt record.
                // A length that cannot be read falls back to the whole StagingByteCeiling rather
                // than to zero (Finding 2, #74 review, eighth pass): we would have no idea how large
                // the file is, and guessing "nothing" would defeat the very bound this setting exists
                // to enforce -- a full ceiling of new screenshots could still be admitted on top of an
                // arbitrarily large stale file. Guessing the ceiling instead only pauses screenshot
                // delivery until the file becomes deletable, and RetryDeletionDebtLocked drops the
                // record the moment it does.
                //
                // This is defence in depth rather than a path with a known trigger. FileInfo.Length
                // is backed by GetFileAttributesEx, which does not open the file, so neither the
                // file's own ACL nor the FileShare.None lock that makes the delete below fail will
                // block it -- both verified rather than assumed. What is left is a delete-or-rename
                // race against the enumeration above, and in that case File.Delete succeeds on the
                // already-missing name, so no debt is recorded at all. The fallback costs one token
                // either way; it is here so the accounting cannot be wrong if it is ever reached.
                long length = _settings.StagingByteCeiling;
                try
                {
                    length = new FileInfo(file).Length;
                }
                catch (Exception exception) when (exception is IOException
                    or UnauthorizedAccessException)
                {
                }

                try
                {
                    File.Delete(file);
                }
                catch (Exception exception) when (exception is IOException
                    or UnauthorizedAccessException)
                {
                    // A scanner or another handle holds the file; leave it and keep sweeping. It
                    // has no in-memory entry either way, so it can never be uploaded -- but
                    // (Finding 1, #74 review, sixth pass) it is still real bytes on disk, so seed
                    // debt for it rather than letting the fresh process silently under-count what
                    // this very sweep just failed to remove. RetryDeletionDebtLocked (piggybacked
                    // on the next EvictExpiredLocked sweep) keeps trying.
                    _deletionDebt[file] = length;
                }
            }
        }
    }

    /// <summary>
    /// Admits one screenshot: enforces <see cref="ScreenshotDeliverySettings.StagingByteCeiling"/>
    /// (evicting oldest-first, then refusing if it still does not fit -- including when outstanding
    /// deletion debt alone would not fit; see <see cref="_deletionDebt"/>) and
    /// <see cref="ScreenshotDeliverySettings.StagingRetention"/> (evicting anything already expired)
    /// before writing the bytes durably and recording the credentials in memory only.
    /// </summary>
    public ScreenshotStageResult Stage(
        ScreenshotPrepareResult prepared,
        ScreenshotFilesRequest request,
        ReadOnlyMemory<byte> bytes)
    {
        ArgumentNullException.ThrowIfNull(prepared);
        ArgumentNullException.ThrowIfNull(request);

        byte[] array = bytes.ToArray();
        lock (_gate)
        {
            DateTimeOffset now = _clock();
            EvictExpiredLocked(now);

            if (array.LongLength > _settings.StagingByteCeiling)
            {
                // Can never fit even alone; refuse without evicting anything else for it, and
                // without ever touching disk for it.
                return ScreenshotStageResult.Refused;
            }

            string path = PathFor(request.ArtifactId);

            // Finding 1 (#74 review, sixth pass): outstanding deletion debt for every other path
            // (see _deletionDebt's own remarks) can never be freed by EvictOldestLocked -- debt is
            // not an entry it can pick. So if this new entry cannot fit even next to that debt
            // alone, no amount of evicting other, still-evictable entries below will ever change
            // that either, and refusing now -- before writing anything or evicting a single other
            // entry -- is exactly the same principle Finding 2 already applies to a same-call write
            // failure: never destroy a good entry in service of an admission that was always going
            // to fail. Debt already tracked for this exact path is excluded, since a successful
            // write to it (a re-stage of the same artifact id) is about to clear that debt below.
            long debtExcludingThisPath = _deletionDebt.Count == 0
                ? 0
                : _deletionDebt.Where(pair => pair.Key != path).Sum(pair => pair.Value);
            if (array.LongLength + debtExcludingThisPath > _settings.StagingByteCeiling)
            {
                // This is the "Stage starts refusing" back-pressure described on _deletionDebt's own
                // remarks: once permanently-undeletable bytes alone occupy the ceiling, this is the
                // correct outcome, not a bug -- the disk really is that occupied, and the only reset
                // is CleanAtLaunch at the next process launch.
                return ScreenshotStageResult.Refused;
            }

            // Finding 2 (#74 review, fourth pass): publish the new bytes before evicting anything
            // else to make room for them, not after. The previous ordering evicted first and wrote
            // second, so a write failure (disk pressure, a transient filesystem error) meant
            // already-staged, already-deliverable screenshots had been destroyed for an admission
            // that never actually happened -- for nothing, since their Files ids were already on
            // emitted events and this would have left them dangling with no chance of ever being
            // delivered. StagingByteCeiling is our own logical accounting bound, not a physical disk
            // constraint, so momentarily holding the new bytes on disk alongside every
            // not-yet-evicted entry (between the write below and the eviction loop further down) is
            // acceptable: nothing observes, or depends on, that intermediate over-ceiling state.
            // Durability.ReplaceAtomic is what makes this safe to reorder: it writes to a temporary
            // file in the same directory, fsyncs it, and only then renames it over the destination,
            // deleting the temporary file on any failure along the way -- so a failure here leaves
            // the destination exactly as it was before this call (nonexistent for a new artifact id,
            // or still holding this artifact's previous bytes for a re-stage of one still pending)
            // and never a partial file.
            bool hadExistingEntry = _entries.TryGetValue(request.ArtifactId, out Entry existingEntry);
            if (hadExistingEntry)
            {
                // A re-stage of an artifact id that is still staged reuses the same path (see
                // PathFor). Pull its bookkeeping out of _entries before writing: left in place, it
                // would both double-count against the ceiling below (it is being replaced, not
                // added to) and be eligible for EvictOldestLocked to pick as "oldest" -- which would
                // delete the file this call just wrote, since eviction and this artifact id share a
                // path. It is restored below if the write fails, since ReplaceAtomic guarantees the
                // existing bytes on disk are untouched in that case.
                _entries.Remove(request.ArtifactId);
            }

            try
            {
                Durability.ReplaceAtomic(path, array);
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException)
            {
                if (hadExistingEntry)
                {
                    _entries[request.ArtifactId] = existingEntry;
                }

                return ScreenshotStageResult.Refused;
            }

            // Finding 1 (#74 review, sixth pass): a re-stage of the same artifact id writes to this
            // exact path (PathFor is deterministic per artifact id), and the write above just
            // succeeded -- so any deletion debt still outstanding for this path no longer describes
            // anything real; it was for bytes this write already overwrote. Clear it here rather
            // than double-counting those bytes against the ceiling forever.
            _deletionDebt.Remove(path);

            try
            {
                CurrentUserOnlyAcl.ApplyFile(path);
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException)
            {
                // Best-effort per-file ACL: the directory ACL already protects inherited access: a
                // file that could not be re-protected is still no more exposed than the directory
                // it lives in, and stopping the capture path over this would be worse.
            }

            // The write already succeeded, so it is now safe to evict older entries to make room
            // for it -- unlike evicting before the write, this can never throw away a screenshot in
            // service of an admission that did not pan out.
            long projected = TotalBytesLocked() + array.LongLength;
            bool evictionStalled = false;
            while (projected > _settings.StagingByteCeiling)
            {
                long beforeEviction = TotalBytesLocked();
                if (!EvictOldestLocked())
                {
                    break;
                }

                long afterEviction = TotalBytesLocked();
                if (afterEviction >= beforeEviction)
                {
                    // Finding 1 (#74 review, ninth pass): EvictOldestLocked just picked an entry
                    // whose File.Delete failed -- RemoveLocked converted it straight into deletion
                    // debt of the very same size (see _deletionDebt's own remarks), so
                    // TotalBytesLocked (entries plus debt) did not move. That eviction freed no
                    // capacity at all, and evicting further entries after it would only destroy more
                    // deliverable screenshots for the exact same zero gain. Stop the sweep the
                    // instant it stalls like this, rather than grinding through every remaining
                    // entry hoping for a different outcome.
                    evictionStalled = true;
                    break;
                }

                projected = afterEviction + array.LongLength;
            }

            // Finding 4 (#74 review, second pass): EvictOldestLocked refuses to pick a leased entry
            // (see TryLease's remarks), so the loop above can also stop with projected still over the
            // ceiling because nothing evictable remains at all -- not because an eviction stalled,
            // but because everything left that could still be evicted already has been, and what
            // remains is either this new entry itself or an entry the worker is actively uploading
            // right now. That case is left to admit exactly as it always has: refusing a legitimate
            // new screenshot just because one older entry happens to be mid-upload would be worse
            // than the alternative of admitting it and letting the ceiling be exceeded until that one
            // upload finishes. That overrun is bounded by the leased entries' total size -- at most
            // one entry, since ScreenshotDeliveryWorker.DrainOnceAsync processes its due entries
            // strictly sequentially and leases only the one it is actively attempting -- and bounded
            // in time by ScreenshotDeliverySettings.UploadCallBudget, after which that upload
            // attempt concludes, its lease is released, and the next Stage call (or the next
            // opportunistic EvictExpiredLocked sweep) can evict it normally.
            //
            // Finding 1 (#74 review, ninth pass): a *stalled* eviction is different from that leased
            // case and must not be treated the same way. It frees no capacity whatsoever -- it only
            // converts a deliverable entry into permanent-until-retried debt -- so admitting anyway
            // here would let a transient antivirus lock both destroy good screenshots AND leave the
            // directory persistently over its configured cap. So this case alone refuses. The write
            // above already succeeded, so refusing means rolling it back: delete the file this call
            // just wrote (the only I/O the rollback performs) and leave _entries exactly as it is --
            // still without this artifact id, whether or not a previous entry for it existed, since
            // that previous entry's on-disk bytes were already overwritten by the write above and no
            // longer match its own bookkeeping; restoring the stale bookkeeping would just leave a
            // ticking TryReadBytes verification failure instead of a clean refusal. A byte-ceiling
            // eviction can therefore now only ever survive alongside a successful admission: either
            // every eviction this call performed actually freed capacity and the call is Staged, or
            // one of them stalled and the call refused and rolled itself back -- there is no longer a
            // path where this call destroys a good entry for real and still returns Refused.
            if (projected > _settings.StagingByteCeiling && evictionStalled)
            {
                try
                {
                    File.Delete(path);
                }
                catch (Exception exception) when (exception is IOException
                    or UnauthorizedAccessException)
                {
                    // Best-effort only, and deliberately NOT recorded as deletion debt: this file
                    // was never admitted as a staged entry -- Stage is about to return Refused, and
                    // _entries was never given this artifact id -- so there is nothing previously
                    // accounted for it to convert into debt for. Recording debt here would grow the
                    // ceiling's permanent accounting for an admission that never actually happened,
                    // rather than for a screenshot this type ever actually staged. The bytes are
                    // orphaned on disk instead, exactly the kind of unrecoverable-by-design leftover
                    // CleanAtLaunch already sweeps up at the next process launch (see this type's own
                    // remarks on accepted crash-window garbage).
                }

                return ScreenshotStageResult.Refused;
            }

            _entries[request.ArtifactId] = new Entry(
                request,
                prepared,
                path,
                StagedAt: now,
                Attempt: 0,
                NextAttemptAt: DateTimeOffset.MinValue);
            return ScreenshotStageResult.Staged;
        }
    }

    /// <summary>
    /// Snapshot of entries due for an upload attempt right now (their backoff, if any, has
    /// elapsed), oldest first.
    /// </summary>
    public IReadOnlyList<StagedScreenshotHandle> Drain()
    {
        lock (_gate)
        {
            DateTimeOffset now = _clock();
            return _entries.Values
                .Where(entry => entry.NextAttemptAt <= now)
                .OrderBy(entry => entry.StagedAt)
                .Select(entry => new StagedScreenshotHandle(entry.Request.ArtifactId, entry.Prepared, entry.Request))
                .ToList();
        }
    }

    /// <summary>
    /// Reads the staged bytes for <paramref name="artifactId"/> back and verifies their length and
    /// SHA-256 against the entry's own recorded values. The length is checked first, against the
    /// file's metadata alone, before any of its contents are read into memory -- a file replaced or
    /// corrupted with a much larger payload is rejected without the read this bound exists to
    /// avoid. A mismatch -- antivirus truncation, disk corruption, a missing file, a wrong size --
    /// drops the entry (there is nothing to rehydrate from; this is not a durable spool) and returns
    /// <see langword="false"/>.
    /// </summary>
    public bool TryReadBytes(string artifactId, out byte[] bytes)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        lock (_gate)
        {
            if (!_entries.TryGetValue(artifactId, out Entry entry))
            {
                bytes = Array.Empty<byte>();
                return false;
            }

            // Reject by length before allocating anything: a file that was replaced or corrupted
            // with a much larger payload must never be read into memory just to find out it
            // doesn't match. FileInfo.Length is a metadata query, not a read of the file's
            // contents, so this stays cheap even for a huge mismatching file (Finding 5, #74
            // review).
            long actualLength;
            try
            {
                actualLength = new FileInfo(entry.Path).Length;
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException)
            {
                RemoveLocked(artifactId);
                bytes = Array.Empty<byte>();
                return false;
            }

            if (actualLength != entry.Request.ByteLength)
            {
                RemoveLocked(artifactId);
                bytes = Array.Empty<byte>();
                return false;
            }

            byte[] data;
            try
            {
                data = File.ReadAllBytes(entry.Path);
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException)
            {
                RemoveLocked(artifactId);
                bytes = Array.Empty<byte>();
                return false;
            }

            if (data.LongLength != entry.Request.ByteLength
                || !string.Equals(
                    Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant(),
                    entry.Request.Sha256,
                    StringComparison.Ordinal))
            {
                RemoveLocked(artifactId);
                bytes = Array.Empty<byte>();
                return false;
            }

            bytes = data;
            return true;
        }
    }

    /// <summary>Removes a staged entry -- used both after a successful upload and after a terminal
    /// (<see cref="FilesDeliveryOutcome.Dropped"/>) failure. Deletes the byte file and drops the
    /// in-memory record; nothing else, no tombstone.</summary>
    public void Remove(string artifactId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        lock (_gate)
        {
            RemoveLocked(artifactId);
        }
    }

    /// <summary>
    /// Attempts to lease <paramref name="artifactId"/> so that, until <see cref="Release"/> is
    /// called for the same id, neither <see cref="EvictOldestLocked"/> (the byte ceiling) nor
    /// <see cref="EvictExpiredLocked"/> (age) will ever pick it.
    /// </summary>
    /// <returns>
    /// <see langword="true"/> if <paramref name="artifactId"/> was still staged and is now leased;
    /// <see langword="false"/> if it no longer exists -- already removed by a prior pass, never
    /// staged at all, or (Finding 4, #74 review, third pass) evicted by a concurrent
    /// <see cref="Stage"/> call in the window between <see cref="Drain"/>'s snapshot and this call.
    /// A caller that receives <see langword="false"/> must not attempt the entry at all: the
    /// eviction that won the race already queued it into <see cref="_pendingEvictions"/>, so
    /// attempting it anyway (and reporting, say, a read-back failure) would give the same artifact
    /// a second, conflicting terminal outcome -- see <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/>
    /// for where a failed lease is skipped rather than attempted, and released nothing in its own
    /// <c>finally</c> block.
    /// </returns>
    /// <remarks>
    /// <b>Why (Finding 4, #74 review).</b> <see cref="Drain"/> hands out a snapshot
    /// under <see cref="_gate"/>, but <see cref="ScreenshotDeliveryWorker"/> then processes each
    /// handle outside it -- the capture path calling <see cref="Stage"/> in the meantime could
    /// evict the very entry the worker is about to attempt, giving that one artifact two terminal
    /// outcomes (the worker's own, plus a later <see cref="DrainPendingEvictions"/> report). The
    /// second pass narrowed but did not close this: leasing immediately before attempting still
    /// leaves the gap between <see cref="Drain"/>'s snapshot and the lease call itself open to
    /// exactly the same race, just on a much smaller window. Returning whether the lease actually
    /// took, and having the caller skip an entry it lost the race for entirely, makes the race
    /// impossible by construction rather than merely narrower: an entry that is leased cannot be
    /// evicted, and an entry that could not be leased is never attempted, so there is no longer any
    /// window in which both a lease and an eviction can apply to the same entry.
    /// </remarks>
    public bool TryLease(string artifactId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        lock (_gate)
        {
            if (!_entries.ContainsKey(artifactId))
            {
                return false;
            }

            _leased.Add(artifactId);
            return true;
        }
    }

    /// <summary>
    /// Releases a lease taken by <see cref="TryLease"/>. Always harmless to call -- including for an id
    /// that was never leased, or one <see cref="ScreenshotDeliveryWorker"/> has already removed (a
    /// successful upload, a terminal drop, or a failed read-back verification all remove the entry,
    /// via <see cref="Remove"/> or internally, before this runs from the caller's own <c>finally</c>
    /// block) -- releasing is bookkeeping only and is never itself a reported outcome.
    /// </summary>
    public void Release(string artifactId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        lock (_gate)
        {
            _leased.Remove(artifactId);
        }
    }

    /// <summary>
    /// Records one more failed upload attempt for <paramref name="artifactId"/>. When the total
    /// attempt count reaches <see cref="ScreenshotDeliverySettings.UploadAttempts"/> the entry is
    /// dropped (the Files id from prepare is left dangling; that is issue #73's accepted outcome)
    /// and this returns <see langword="false"/>. Otherwise the entry stays staged with its next
    /// attempt time computed by <see cref="ScreenshotUploadRetryPolicy.Delay"/>, and this returns
    /// <see langword="true"/>.
    /// </summary>
    public bool RecordRetry(string artifactId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        lock (_gate)
        {
            if (!_entries.TryGetValue(artifactId, out Entry entry))
            {
                return false;
            }

            int attempt = entry.Attempt + 1;
            if (attempt >= _settings.UploadAttempts)
            {
                RemoveLocked(artifactId);
                return false;
            }

            TimeSpan delay = ScreenshotUploadRetryPolicy.Delay(attempt, artifactId, _settings);
            _entries[artifactId] = entry with { Attempt = attempt, NextAttemptAt = _clock() + delay };
            return true;
        }
    }

    /// <summary>
    /// Evicts every entry older than <see cref="ScreenshotDeliverySettings.StagingRetention"/>,
    /// independent of the size bound. <see cref="Stage"/> already does this at admission time; the
    /// background drain loop also calls this directly so a small number of screenshots stuck
    /// retrying against a dead endpoint do not linger indefinitely just because nothing new is ever
    /// staged. Every id evicted here was already staged (its Files id already stamped on an emitted
    /// event), so it is recorded for <see cref="DrainPendingEvictions"/> exactly like a
    /// byte-ceiling eviction from <see cref="EvictOldestLocked"/>.
    /// </summary>
    public void EvictExpired()
    {
        lock (_gate)
        {
            EvictExpiredLocked(_clock());
        }
    }

    /// <summary>
    /// Finding 4 (#74 review, second pass): a leased entry (see <see cref="TryLease"/>) is excluded
    /// here exactly like it is excluded from <see cref="EvictOldestLocked"/>, for the same reason --
    /// it is being actively attempted by <see cref="ScreenshotDeliveryWorker"/> right now, and
    /// removing it out from under that attempt would give it a second, conflicting terminal outcome.
    /// In practice the worker leases an entry only for the span of one upload attempt, well inside
    /// this entry's own retention window, so this exclusion is not expected to ever postpone a real
    /// age eviction -- it exists for the same-by-construction guarantee, not because age evictions
    /// commonly race with an in-flight upload.
    /// </summary>
    /// <remarks>
    /// Also retries every outstanding deletion debt (Finding 1, #74 review, sixth pass; see
    /// <see cref="RetryDeletionDebtLocked"/>). This method is called from both places that already
    /// sweep the staging area on their own -- <see cref="Stage"/>, on the capture path, and
    /// <see cref="EvictExpired"/>, from <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/> on its
    /// own background task -- so piggybacking the retry here gets it retried at least as often as
    /// either sweep already runs, with no new timer.
    /// </remarks>
    private void EvictExpiredLocked(DateTimeOffset now)
    {
        RetryDeletionDebtLocked();

        foreach (string artifactId in _entries
            .Where(pair => !_leased.Contains(pair.Key) && now - pair.Value.StagedAt > _settings.StagingRetention)
            .Select(pair => pair.Key)
            .ToList())
        {
            RemoveLocked(artifactId);
            _pendingEvictions.Add(artifactId);
        }
    }

    /// <summary>
    /// Retries every currently-tracked deletion debt (see <see cref="_deletionDebt"/>) once, dropping
    /// the record for any file that actually gets deleted this time. Called from
    /// <see cref="EvictExpiredLocked"/> so it rides along on the two sweeps that already run --
    /// see that method's own remarks -- rather than a dedicated timer, which issue #73/#74 forbid
    /// for this codebase's other periodic concerns and which would be equally unwarranted here.
    /// </summary>
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
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException)
            {
                // Still can't delete it; leave the debt in place for the next sweep.
            }
        }
    }

    /// <summary>
    /// Evicts the oldest evictable (i.e. unleased -- see <see cref="TryLease"/>) entry, if any.
    /// </summary>
    /// <returns>
    /// <see langword="true"/> if an entry was evicted, <see langword="false"/> if every remaining
    /// entry is leased (or none remain at all) -- the caller in <see cref="Stage"/> uses this to
    /// stop its eviction loop rather than spin when nothing more can be freed.
    /// </returns>
    private bool EvictOldestLocked()
    {
        string? oldest = _entries
            .Where(pair => !_leased.Contains(pair.Key))
            .OrderBy(pair => pair.Value.StagedAt)
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

    private void RemoveLocked(string artifactId)
    {
        if (_entries.Remove(artifactId, out Entry entry))
        {
            TryDeleteOrRecordDebt(entry.Path, entry.Request.ByteLength);
        }

        // RemoveLocked commonly runs for a still-leased id: ScreenshotDeliveryWorker calls
        // Remove/RecordRetry for the artifact it is handling before its own finally block calls
        // Release for it (see DrainOnceAsync). Clearing the lease here too, rather than waiting for
        // that later Release, keeps _leased consistent with _entries at every point in between --
        // an id no longer staged is never left "leased" in the meantime -- and makes the later
        // Release a harmless no-op exactly as its own remarks promise.
        _leased.Remove(artifactId);
    }

    /// <summary>
    /// Total bytes the byte ceiling must account for: every staged entry's own length, plus every
    /// outstanding deletion debt's length (Finding 1, #74 review, sixth pass -- see
    /// <see cref="_deletionDebt"/>). A blob whose deletion failed is still real bytes on disk, so the
    /// ceiling must see it exactly as if it were still an entry, even though it no longer is one.
    /// </summary>
    private long TotalBytesLocked() =>
        _entries.Values.Sum(entry => entry.Request.ByteLength) + _deletionDebt.Values.Sum(bytes => bytes);

    private string PathFor(string artifactId) => Path.Combine(_directory, Key(artifactId) + FileExtension);

    /// <summary>
    /// Lowercase hex SHA-256 of the UTF-8 artifact id, exactly the idea the closed
    /// <c>codex/68-screenshot-files</c> branch used for
    /// <c>ArtifactDeliveryQueue.Key(artifactId)</c>: a hostile or path-shaped artifact id can never
    /// escape <see cref="_directory"/>.
    /// </summary>
    private static string Key(string artifactId) =>
        Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(artifactId)))
            .ToLowerInvariant();

    /// <summary>
    /// Best-effort delete for a file whose in-memory entry has already been removed. A file we
    /// cannot delete right now is still not a reason to fail the caller (Remove/RecordRetry/eviction
    /// all continue exactly as before), but (Finding 1, #74 review, sixth pass) it must not simply
    /// vanish from the byte ceiling's accounting -- so a failed delete records <paramref name="byteLength"/>
    /// as debt (see <see cref="_deletionDebt"/>) instead of being silently forgotten.
    /// </summary>
    private void TryDeleteOrRecordDebt(string path, long byteLength)
    {
        try
        {
            File.Delete(path);

            // This path ordinarily has no debt to clear yet -- removing unconditionally is simply
            // harmless in that common case, and correct on the rarer one where a previous call to
            // this same method already recorded debt for it and this call is the retry that finally
            // succeeds.
            _deletionDebt.Remove(path);
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException)
        {
            _deletionDebt[path] = byteLength;
        }
    }

    private readonly record struct Entry(
        ScreenshotFilesRequest Request,
        ScreenshotPrepareResult Prepared,
        string Path,
        DateTimeOffset StagedAt,
        int Attempt,
        DateTimeOffset NextAttemptAt);
}
