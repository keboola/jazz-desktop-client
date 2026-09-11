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
    /// The entry does not fit even after evicting every other staged entry --
    /// <see cref="ScreenshotDeliverySettings.StagingByteCeiling"/> is smaller than this one
    /// screenshot. Nothing was written or admitted.
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
/// crash could be recovered from. Issue #73 accepts eventual inconsistency instead: the activity
/// event carrying (or not carrying) a <c>screenshot_id</c> has already been emitted by the time
/// anything is staged here, so losing staged bytes to a crash only means a dangling Files id -- an
/// outcome the Jazz processor already tolerates. There is therefore nothing to recover *to*, and no
/// journal, WAL, tombstone, quarantine state, or startup reconciliation exists in this type.
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
/// <see cref="Remove"/>, <see cref="RecordRetry"/> and <see cref="EvictExpired"/> run from
/// <see cref="ScreenshotDeliveryWorker"/> on a background task. All of them take the single
/// <see cref="_gate"/> lock around both the in-memory dictionary and the (small, screenshot-sized)
/// file I/O; screenshots are staged at ordinary capture cadence, not in a hot loop, so one coarse
/// lock is simpler and safer than splitting file I/O out from under it and is not a measured
/// bottleneck.
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
    /// Creates the staging area, protecting and (if necessary) creating its root directory, then
    /// running <see cref="CleanAtLaunch"/> once. Nothing has been staged into a fresh instance yet,
    /// so any bytes found on disk at this point belong to a previous, now-dead process whose
    /// in-memory credentials are gone -- exactly the definition of garbage this design accepts.
    /// </summary>
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
    /// Deletes every file currently in the staging directory and drops any in-memory entries (there
    /// should be none yet when this runs from the constructor). Tolerates a missing directory and a
    /// per-file delete failure -- a locked file, an <see cref="IOException"/>, or an
    /// <see cref="UnauthorizedAccessException"/> -- without failing the sweep: a file this process
    /// cannot delete must not stop the client from starting.
    /// </summary>
    public void CleanAtLaunch()
    {
        lock (_gate)
        {
            _entries.Clear();

            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(_directory).ToList();
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException)
            {
                return;
            }

            foreach (string file in files)
            {
                try
                {
                    File.Delete(file);
                }
                catch (Exception exception) when (exception is IOException
                    or UnauthorizedAccessException)
                {
                    // A scanner or another handle holds the file; leave it and keep sweeping. It
                    // has no in-memory entry either way, so it can never be uploaded.
                }
            }
        }
    }

    /// <summary>
    /// Admits one screenshot: enforces <see cref="ScreenshotDeliverySettings.StagingByteCeiling"/>
    /// (evicting oldest-first, then refusing if it still does not fit) and
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
                // Can never fit even alone; refuse without evicting anything else for it.
                return ScreenshotStageResult.Refused;
            }

            long projected = TotalBytesLocked() + array.LongLength;
            while (projected > _settings.StagingByteCeiling && _entries.Count > 0)
            {
                EvictOldestLocked();
                projected = TotalBytesLocked() + array.LongLength;
            }

            if (projected > _settings.StagingByteCeiling)
            {
                return ScreenshotStageResult.Refused;
            }

            string path = PathFor(request.ArtifactId);
            // A leftover file at this exact path can only be a stale write for the same artifact
            // id within this process's lifetime (CleanAtLaunch already wiped anything older than
            // this process); WriteAtomic requires the destination not to exist, so clear it first.
            TryDeleteFile(path);

            try
            {
                Durability.WriteAtomic(path, array);
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException)
            {
                return ScreenshotStageResult.Refused;
            }

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
    /// SHA-256 against the entry's own recorded values. A mismatch -- antivirus truncation, disk
    /// corruption, a missing file -- drops the entry (there is nothing to rehydrate from; this is
    /// not a durable spool) and returns <see langword="false"/>.
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
    /// staged.
    /// </summary>
    public void EvictExpired()
    {
        lock (_gate)
        {
            EvictExpiredLocked(_clock());
        }
    }

    private void EvictExpiredLocked(DateTimeOffset now)
    {
        foreach (string artifactId in _entries
            .Where(pair => now - pair.Value.StagedAt > _settings.StagingRetention)
            .Select(pair => pair.Key)
            .ToList())
        {
            RemoveLocked(artifactId);
        }
    }

    private void EvictOldestLocked()
    {
        string? oldest = _entries
            .OrderBy(pair => pair.Value.StagedAt)
            .Select(pair => pair.Key)
            .FirstOrDefault();
        if (oldest is not null)
        {
            RemoveLocked(oldest);
        }
    }

    private void RemoveLocked(string artifactId)
    {
        if (_entries.Remove(artifactId, out Entry entry))
        {
            TryDeleteFile(entry.Path);
        }
    }

    private long TotalBytesLocked() => _entries.Values.Sum(entry => entry.Request.ByteLength);

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

    private static void TryDeleteFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException)
        {
            // Best-effort; a file we cannot delete is not a reason to fail the caller.
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
