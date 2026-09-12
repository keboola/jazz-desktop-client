using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="EventSpool"/> is the durable half of issue #48: exact <c>/v1/logs</c> request bytes on
/// disk, adopted (not wiped) at every launch, bounded by both total size and age, with every
/// eviction and refusal counted rather than silently discarded. These tests are the acceptance
/// criteria the #48 plan lists in its own §5 test plan, ported from the idioms
/// <see cref="ScreenshotStagingAreaTests"/> already established for the sibling type this one is
/// modelled on.
/// </summary>
public sealed class EventSpoolTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-spool-events-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            try { Directory.Delete(root, recursive: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    [Fact]
    public void SpooledBodiesSurviveARelaunchByteForByte()
    {
        var area = new EventSpool(Settings());
        string session = SessionId();
        byte[] a = Body("a");
        byte[] b = Body("b");
        byte[] c = Body("c");

        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, a));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 2, b));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 3, c));

        // Construct a second EventSpool over the same directory -- a relaunch, not a reused
        // instance -- per the house style for durability tests.
        var reopened = new EventSpool(Settings());

        Assert.Equal(3, reopened.Status.PendingCount);
        var handles = reopened.Drain();
        Assert.Equal(3, handles.Count);
        foreach (SpooledEventHandle handle in handles)
        {
            Assert.True(reopened.TryReadBody(handle.Key, out byte[] readBack));
            // Assert.Contains(readBack, new[] { a, b, c }) would use byte[]'s reference equality --
            // TryReadBody always returns a freshly allocated array, so that assertion could never
            // fail even if the persisted bytes were wrong (review finding: a byte-exactness test that
            // did not test byte-exactness). Compare contents instead.
            Assert.Contains(new[] { a, b, c }, candidate => candidate.SequenceEqual(readBack));
        }
    }

    [Fact]
    public void ABodyCorruptedBetweenProcessesFailsTheFilenameDigestAndIsDropped()
    {
        var area = new EventSpool(Settings());
        string session = SessionId();
        byte[] original = Body("original");
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, original));

        string file = Assert.Single(Directory.EnumerateFiles(Path.Combine(root, session)));
        byte[] corrupted = new byte[original.Length];
        Array.Copy(original, corrupted, original.Length);
        corrupted[0] ^= 0xFF;
        File.WriteAllBytes(file, corrupted);

        // Adoption itself does not verify content -- only TryReadBody re-derives the digest -- so a
        // relaunch still counts this as pending until it is actually read back.
        var reopened = new EventSpool(Settings());
        Assert.Equal(1, reopened.Status.PendingCount);

        SpooledEventHandle handle = Assert.Single(reopened.Drain());
        Assert.False(reopened.TryReadBody(handle.Key, out _));
        Assert.Equal(0, reopened.Status.PendingCount);
    }

    [Fact]
    public void AnInterruptedAtomicWriteLeavesNoAdoptableEntry()
    {
        string session = SessionId();
        Directory.CreateDirectory(Path.Combine(root, session));
        string temporary = Path.Combine(
            root, session, "0000000001." + Sha256Hex(Body("x")) + ".otlp.json.0199c0de-dead-7abc-8def-000000000001.tmp");
        File.WriteAllBytes(temporary, [1, 2, 3]);

        var area = new EventSpool(Settings());

        Assert.Equal(0, area.Status.PendingCount);
        Assert.False(File.Exists(temporary));
    }

    [Fact]
    public void DrainIsPerSessionFifoAcrossSessionsAndAcrossARelaunch()
    {
        string sessionOne = Identifiers.Prefixed("s");
        string sessionTwo = Identifiers.Prefixed("s");
        // Order the two labels by their actual ordinal sort, rather than assuming call order: session
        // directory order is what "sort(session dirs) then sort(files)" actually depends on.
        (string earlier, string later) = string.CompareOrdinal(sessionOne, sessionTwo) < 0
            ? (sessionOne, sessionTwo)
            : (sessionTwo, sessionOne);

        var area = new EventSpool(Settings());
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(earlier, 1, Body("A1")));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(earlier, 2, Body("A2")));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(later, 5, Body("B5")));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(later, 6, Body("B6")));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(later, 7, Body("B7")));

        void AssertOrder(EventSpool spool)
        {
            var order = spool.Drain().Select(handle => (handle.SessionId, handle.FileName)).ToList();
            Assert.Equal(5, order.Count);
            Assert.All(order.Take(2), entry => Assert.Equal(earlier, entry.SessionId));
            Assert.All(order.Skip(2), entry => Assert.Equal(later, entry.SessionId));
            Assert.True(string.CompareOrdinal(order[0].FileName, order[1].FileName) < 0);
            Assert.True(string.CompareOrdinal(order[2].FileName, order[3].FileName) < 0);
            Assert.True(string.CompareOrdinal(order[3].FileName, order[4].FileName) < 0);
        }

        AssertOrder(area);
        AssertOrder(new EventSpool(Settings()));
    }

    [Fact]
    public void TwoEventsWithNoSequenceBothSurviveUnderDistinctNames()
    {
        var area = new EventSpool(Settings());
        string session = SessionId();

        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, null, Body("null-seq-1")));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, null, Body("null-seq-2")));

        Assert.Equal(2, area.Status.PendingCount);
        var fileNames = Directory.EnumerateFiles(Path.Combine(root, session)).Select(Path.GetFileName).ToList();
        Assert.Equal(2, fileNames.Count);
        Assert.Contains(fileNames, name => name!.StartsWith("0000000000.", StringComparison.Ordinal));
        Assert.Contains(fileNames, name => name!.StartsWith("0000000000-1.", StringComparison.Ordinal));
    }

    /// <summary>
    /// Regression coverage for a defect found in adversarial review: <see cref="EventSpool.Drain"/>
    /// used to filter each entry independently against <c>NextAttemptAt &lt;= now</c>, so once a
    /// session's earliest entry was retried (moving its own <c>NextAttemptAt</c> into the future), a
    /// later, never-yet-attempted entry of the *same* session (still at
    /// <see cref="DateTimeOffset.MinValue"/>) would pass that filter on the very next call and be
    /// returned as due -- breaking per-session FIFO across passes, not merely within one.
    /// </summary>
    [Fact]
    public void DrainNeverReturnsALaterEntryOfASessionWhoseEarlierEntryIsStillBackingOff()
    {
        var area = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, Body("first")));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 2, Body("second")));

        SpooledEventHandle first = Assert.Single(area.Drain(), handle => handle.FileName.StartsWith("0000000001", StringComparison.Ordinal));
        area.RecordRetry(first.Key);

        IReadOnlyList<SpooledEventHandle> due = area.Drain();

        Assert.Empty(due);
    }

    /// <summary>
    /// Companion to <see cref="DrainNeverReturnsALaterEntryOfASessionWhoseEarlierEntryIsStillBackingOff"/>:
    /// <see cref="EventSpool.TimeUntilNextDue"/> must reflect the session's blocked head, not a
    /// later entry that merely happens to still be at its default (unset) due time -- otherwise the
    /// drain scheduler would busy-loop at zero backoff even though nothing can actually be attempted.
    /// </summary>
    [Fact]
    public void TimeUntilNextDueReflectsTheSessionsBlockedHeadNotALaterUnattemptedEntry()
    {
        var area = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, Body("first")));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 2, Body("second")));

        SpooledEventHandle first = Assert.Single(area.Drain(), handle => handle.FileName.StartsWith("0000000001", StringComparison.Ordinal));
        area.RecordRetry(first.Key);

        Assert.NotEqual(TimeSpan.Zero, area.TimeUntilNextDue);
    }

    [Fact]
    public void AnEventRetriesIndefinitelyAndOnlyLeavesTheSpoolByABound()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new EventSpool(Settings(retention: TimeSpan.FromHours(1)), clock.Now);
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, Body("retry-me")));
        string key = Assert.Single(area.Drain()).Key;

        for (int attempt = 0; attempt < 50; attempt++)
        {
            area.RecordRetry(key);
            clock.Advance(TimeSpan.FromSeconds(1));
        }

        Assert.Equal(1, area.Status.PendingCount);
        Assert.Empty(area.DrainPendingEvictions());

        clock.Advance(TimeSpan.FromHours(1));
        area.EvictExpired();

        Assert.Equal(0, area.Status.PendingCount);
        Assert.Equal(key, Assert.Single(area.DrainPendingEvictions()));
    }

    [Fact]
    public void PastTheByteCeilingTheOldestEntriesAreEvictedAndReported()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new EventSpool(Settings(byteCeiling: 800), clock.Now);
        string session = SessionId();
        byte[] a = new byte[300];
        byte[] b = new byte[300];
        byte[] c = new byte[300];

        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, a));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 2, b));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 3, c));

        Assert.Equal(2, area.Status.PendingCount);
        IReadOnlyList<string> evicted = area.DrainPendingEvictions();
        Assert.Single(evicted);
    }

    [Fact]
    public void ARefusedAdmissionIsReportedAsAnUndeliveredEventNotSilentlyDiscarded()
    {
        var area = new EventSpool(Settings(maximumBodyBytes: 10));
        string session = SessionId();
        byte[] tooBig = new byte[11];

        EventSpoolAdmission result = area.Spool(session, 1, tooBig);

        Assert.Equal(EventSpoolAdmission.Refused, result);
        Assert.Equal(0, area.Status.PendingCount);
        Assert.False(Directory.Exists(Path.Combine(root, session)), "A refusal must never write anything to disk.");
        Assert.Single(area.DrainPendingRefusals());
    }

    [Fact]
    public void ABlobWhoseDeletionFailsStillCountsAgainstTheByteCeiling()
    {
        var area = new EventSpool(Settings(byteCeiling: 1500));
        string session = SessionId();
        byte[] a = new byte[1000];
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, a));
        string key = Assert.Single(area.Drain()).Key;
        string path = Path.Combine(root, session, key.Split('/')[1]);

        // A using declaration, not a using block: the lock must still be held when Spool below runs
        // its own EvictExpiredLocked-driven debt retry, exactly like the ScreenshotStagingAreaTests
        // analogue this test is modelled on.
        using FileStream lockedHandle = new(path, FileMode.Open, FileAccess.Read, FileShare.None);
        area.Remove(key);

        Assert.Equal(0, area.Status.PendingCount);
        Assert.True(File.Exists(path), "The locked file must still be on disk after a failed delete.");

        byte[] b = new byte[600];
        Assert.Equal(EventSpoolAdmission.Refused, area.Spool(session, 2, b));
    }

    /// <summary>
    /// Regression coverage for review findings on <c>TryDeleteOrRecordDebt</c>: an in-memory-only
    /// deletion debt does not survive a restart, so an event this type already decided is gone
    /// (here, acknowledged and removed) but whose file could not actually be deleted used to be
    /// silently re-adopted as pending -- and re-deliverable -- on the very next relaunch. A read-only
    /// file cannot be deleted by <see cref="File.Delete(string)"/> but *can* still be renamed by
    /// <see cref="File.Move(string, string)"/> on NTFS, which forces exactly the delete-fails/
    /// rename-succeeds path <c>TryDeleteOrRecordDebt</c>'s quarantine step exists for, without a real
    /// file-lock race.
    /// </summary>
    [Fact]
    public void ARemovedEntryWhoseFileCannotBeDeletedIsQuarantinedRatherThanResurrectedOnRelaunch()
    {
        var area = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, Body("undeletable")));
        string key = Assert.Single(area.Drain()).Key;
        string sessionDirectory = Path.Combine(root, session);
        string path = Path.Combine(sessionDirectory, key.Split('/')[1]);

        File.SetAttributes(path, FileAttributes.ReadOnly);
        try
        {
            area.Remove(key);

            Assert.Equal(0, area.Status.PendingCount);
            Assert.False(
                File.Exists(path),
                "The original published-looking name must be gone -- deleted outright, or quarantined under a name AdoptAtLaunch does not recognize as a published event.");

            // The guarantee that actually matters: a fresh EventSpool over the same directory (a
            // relaunch) must not resurrect this event as pending, regardless of which of the two
            // TryDeleteOrRecordDebt outcomes (plain delete, or delete-fails/rename-succeeds) actually
            // happened on this machine.
            var reopened = new EventSpool(Settings());
            Assert.Equal(0, reopened.Status.PendingCount);
        }
        finally
        {
            if (Directory.Exists(sessionDirectory))
            {
                foreach (string leftover in Directory.EnumerateFiles(sessionDirectory, "*", SearchOption.AllDirectories))
                {
                    File.SetAttributes(leftover, FileAttributes.Normal);
                }
            }
        }
    }

    [Fact]
    public void EvictExpiredRemovesEntriesOlderThanRetentionUsingTheInjectedClock()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new EventSpool(Settings(retention: TimeSpan.FromHours(1)), clock.Now);
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, Body("stale")));

        clock.Advance(TimeSpan.FromHours(1) + TimeSpan.FromSeconds(1));
        area.EvictExpired();

        Assert.Equal(0, area.Status.PendingCount);
        Assert.Single(area.DrainPendingEvictions());
    }

    /// <summary>
    /// Regression coverage for R5 (#48 plan): adoption must derive an entry's age from the file's own
    /// <c>LastWriteTimeUtc</c>, not from "now" -- resetting it to "now" on every relaunch would mean
    /// a machine that restarts daily never ages anything out, making <see cref="EventDeliverySettings.SpoolRetention"/>
    /// fiction. This backdates one file's real filesystem timestamp -- an injected clock cannot fake
    /// <c>LastWriteTimeUtc</c>, since that is set by the OS, not by this type -- so the adopting
    /// process has no continuity with whatever clock (real or injected) wrote the file originally.
    /// </summary>
    [Fact]
    public void AdoptionEvictsWhatIsOverTheCeilingOrPastRetentionAndReportsIt()
    {
        var area = new EventSpool(Settings(retention: TimeSpan.FromMinutes(30)));
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 1, Body("expired-by-age")));
        Assert.Equal(EventSpoolAdmission.Spooled, area.Spool(session, 2, Body("still-fresh")));

        string sessionDirectory = Path.Combine(root, session);
        string firstFile = Directory.EnumerateFiles(sessionDirectory)
            .OrderBy(name => name, StringComparer.Ordinal)
            .First();
        File.SetLastWriteTimeUtc(firstFile, DateTime.UtcNow - TimeSpan.FromHours(2));

        var reopened = new EventSpool(Settings(retention: TimeSpan.FromMinutes(30)));

        Assert.Equal(1, reopened.Status.PendingCount);
        Assert.Single(reopened.DrainPendingEvictions());
    }

    [Fact]
    public void TheSpoolDirectoryAndItsFilesAreCurrentUserOnly()
    {
        var area = new EventSpool(Settings());
        string session = SessionId();
        area.Spool(session, 1, Body("acl"));

        AssertCurrentUserOnly(new DirectoryInfo(root).GetAccessControl());
        foreach (string file in Directory.EnumerateFiles(Path.Combine(root, session)))
        {
            AssertCurrentUserOnly(new FileInfo(file).GetAccessControl());
        }
    }

    /// <summary>
    /// Adapted from <see cref="ScreenshotStagingAreaTests.RedirectedAncestorIsRejectedBeforeDirectoryCreation"/>,
    /// using the same directory-junction mechanism (a symbolic link needs elevation or Developer
    /// Mode this machine does not have; a junction does not).
    /// </summary>
    [Fact]
    public void ARedirectedAncestorIsRejectedBeforeDirectoryCreation()
    {
        string parent = Path.Combine(Path.GetTempPath(), "jazz-spool-junction-parent-" + Guid.NewGuid().ToString("N"));
        string external = Path.Combine(Path.GetTempPath(), "jazz-spool-junction-external-" + Guid.NewGuid().ToString("N"));
        string redirected = Path.Combine(parent, "redirected");
        Directory.CreateDirectory(parent);
        Directory.CreateDirectory(external);
        try
        {
            CreateJunction(redirected, external);

            var settings = Settings() with { SpoolDirectory = Path.Combine(redirected, "events") };
            Assert.Throws<UnauthorizedAccessException>(() => new EventSpool(settings));
            Assert.Empty(Directory.EnumerateFileSystemEntries(external));
        }
        finally
        {
            if (Directory.Exists(redirected)) Directory.Delete(redirected);
            if (Directory.Exists(parent)) Directory.Delete(parent, recursive: true);
            if (Directory.Exists(external)) Directory.Delete(external, recursive: true);
        }
    }

    /// <summary>
    /// Regression coverage for a review finding: the launch sweep validated only the spool root, so
    /// a reparse point named like a session id ("s-&lt;uuid&gt;") passed
    /// <c>EventSpool.IsSessionDirectoryName</c> and was enumerated and adopted from exactly like a
    /// real session directory -- reading, and potentially deleting or queuing for upload, files that
    /// live entirely outside the spool.
    /// </summary>
    [Fact]
    public void AJunctionNamedLikeASessionDirectoryIsNeverEnumeratedOrTouched()
    {
        _ = new EventSpool(Settings());
        string sessionId = SessionId();
        string redirectedSessionDirectory = Path.Combine(root, sessionId);
        string external = Path.Combine(Path.GetTempPath(), "jazz-spool-junction-session-external-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(external);
        string canary = Path.Combine(external, "0000000001." + Sha256Hex(Body("canary")) + ".otlp.json");
        File.WriteAllBytes(canary, Body("canary"));
        try
        {
            CreateJunction(redirectedSessionDirectory, external);

            // A relaunch (a fresh EventSpool over the same root) is what actually re-runs
            // AdoptAtLaunch's enumeration against the junction.
            var reopened = new EventSpool(Settings());

            Assert.Equal(0, reopened.Status.PendingCount);
            Assert.True(
                File.Exists(canary),
                "A file outside the spool must never be touched, let alone deleted, by adoption.");
            Assert.Single(Directory.EnumerateFiles(external));
        }
        finally
        {
            if (Directory.Exists(redirectedSessionDirectory)) Directory.Delete(redirectedSessionDirectory);
            if (Directory.Exists(external)) Directory.Delete(external, recursive: true);
        }
    }

    private static void AssertCurrentUserOnly(FileSystemSecurity security)
    {
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User!;
        Assert.True(security.AreAccessRulesProtected);
        Assert.All(
            security.GetAccessRules(includeExplicit: true, includeInherited: true, typeof(SecurityIdentifier))
                .Cast<FileSystemAccessRule>(),
            rule =>
            {
                Assert.Equal(current, rule.IdentityReference);
                Assert.Equal(AccessControlType.Allow, rule.AccessControlType);
                Assert.Equal(FileSystemRights.FullControl, rule.FileSystemRights & FileSystemRights.FullControl);
            });
    }

    private static void CreateJunction(string link, string target)
    {
        var info = new System.Diagnostics.ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{target}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        using System.Diagnostics.Process process = System.Diagnostics.Process.Start(info)!;
        if (!process.WaitForExit(10_000))
        {
            try { process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }

            bool confirmedTerminated = process.WaitForExit(5_000);
            Assert.Fail(confirmedTerminated
                ? "mklink /J timed out after 10s; the helper process was terminated rather than left running."
                : "mklink /J timed out after 10s, and the helper process could not be confirmed terminated after being killed.");
        }

        Assert.True(
            process.ExitCode == 0,
            "mklink /J failed to create a directory junction; this test needs a real reparse point, not a skip.");
    }

    private string SessionId() => Identifiers.Prefixed("s");

    private static byte[] Body(string marker) => System.Text.Encoding.UTF8.GetBytes(
        "{\"resourceLogs\":[],\"marker\":\"" + marker + "\"}");

    private static string Sha256Hex(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private EventDeliverySettings Settings(
        long? byteCeiling = null,
        TimeSpan? retention = null,
        long? maximumBodyBytes = null) => new()
    {
        SpoolDirectory = root,
        SpoolByteCeiling = byteCeiling ?? 32L * 1024 * 1024,
        SpoolRetention = retention ?? TimeSpan.FromHours(48),
        MaximumBodyBytes = maximumBodyBytes ?? 1L * 1024 * 1024,
    };

    private sealed class MutableClock
    {
        private DateTimeOffset _now;

        public MutableClock(DateTimeOffset start) => _now = start;

        public DateTimeOffset Now() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
