using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="ScreenshotStagingArea"/> is the non-durable half of issue #73's prepare-early
/// screenshot delivery: bytes on disk, GCS federation credentials in managed memory only, wiped at
/// every launch, and bounded by both size and age so an offline stretch cannot fill the disk. These
/// tests are the acceptance criteria for that design, not smoke tests -- in particular
/// <see cref="NoFederationCredentialFieldEverReachesDisk"/> exists specifically to catch a future
/// "helpful" metadata sidecar that would leak a secret at rest.
/// </summary>
public sealed class ScreenshotStagingAreaTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-staging-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void CleanAtLaunchRemovesFilesLeftByADeadProcess()
    {
        Directory.CreateDirectory(root);
        string leftover = Path.Combine(root, "leftover-from-a-crashed-process.bin");
        File.WriteAllBytes(leftover, [1, 2, 3, 4]);

        var area = new ScreenshotStagingArea(Settings());

        Assert.False(File.Exists(leftover));
        Assert.Equal(0, area.Status.PendingCount);
        Assert.Empty(Directory.EnumerateFiles(root));
    }

    [Fact]
    public void CleanAtLaunchToleratesALockedFileWithoutFailingTheSweep()
    {
        Directory.CreateDirectory(root);
        string locked = Path.Combine(root, "locked.bin");
        string normal = Path.Combine(root, "normal.bin");
        File.WriteAllBytes(locked, [9, 9]);
        File.WriteAllBytes(normal, [9, 9]);

        using FileStream handle = new(locked, FileMode.Open, FileAccess.Read, FileShare.None);

        ScreenshotStagingArea? area = null;
        Exception? thrown = Record.Exception(() => area = new ScreenshotStagingArea(Settings()));

        Assert.Null(thrown);
        Assert.NotNull(area);
        Assert.False(File.Exists(normal));
        Assert.True(File.Exists(locked), "A file this process cannot delete must be left alone, not crash the sweep.");
    }

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, eighth pass): <see cref="ScreenshotStagingArea.CleanAtLaunch"/>
    /// used to swallow a failed <see cref="Directory.EnumerateFiles(string)"/> call and simply
    /// <c>return</c>, as if the sweep had found nothing -- letting construction succeed having run no
    /// cleanup and recorded no debt for whatever is actually sitting on disk, past
    /// <see cref="ScreenshotDeliverySettings.StagingByteCeiling"/>, because a directory this instance
    /// cannot even list can never be bounded by either the byte ceiling or the age sweep. This
    /// provokes a genuine, real <see cref="DirectoryNotFoundException"/> (itself an
    /// <see cref="IOException"/>) by deleting the staging directory out from under an
    /// already-constructed area and then calling <see cref="ScreenshotStagingArea.CleanAtLaunch"/>
    /// directly -- the exact method whose behaviour changed, and a real OS mechanism rather than a
    /// mock or a seam.
    /// </summary>
    /// <remarks>
    /// This calls <c>CleanAtLaunch</c> directly rather than reproducing the failure through a second
    /// <c>new ScreenshotStagingArea(...)</c> call, because a literal "construct once and watch
    /// enumeration itself fail" repro is not reachable without a race:
    /// <see cref="CurrentUserOnlyAcl.ApplyDirectory"/> unconditionally re-grants the current user full
    /// control over the directory immediately before <c>CleanAtLaunch</c> runs, inside the very same
    /// constructor call, so there is no non-racy way to leave the directory listable to
    /// <c>ApplyDirectory</c> but not to the <c>Directory.EnumerateFiles</c> call that follows moments
    /// later. <c>CleanAtLaunch</c> has exactly one production caller -- the constructor, confirmed by
    /// inspection -- and that call is not wrapped in any try/catch of its own, so an exception thrown
    /// from here propagates identically out of <c>new ScreenshotStagingArea(...)</c> in production,
    /// straight into the guard <c>App.OnStartup</c> already wraps that call in for exactly
    /// <see cref="IOException"/>/<see cref="UnauthorizedAccessException"/>.
    /// </remarks>
    [Fact]
    public void CleanAtLaunchLetsAnUnenumerableDirectoryEscapeInsteadOfSwallowingIt()
    {
        var area = new ScreenshotStagingArea(Settings());

        Directory.Delete(root, recursive: true);

        Assert.Throws<DirectoryNotFoundException>(() => area.CleanAtLaunch());
    }

    [Fact]
    public void StagingPastTheByteCeilingEvictsOldestFirst()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 2200), clock.Now);

        byte[] a = new byte[1000];
        byte[] b = new byte[1000];
        byte[] c = new byte[1200];

        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(a, "art-a"), a));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(b, "art-b"), b));
        clock.Advance(TimeSpan.FromSeconds(1));

        // Admitting c (1200) alongside a+b (2000) would total 3200, over the 2200 ceiling; the
        // oldest entry (a) must be evicted first, leaving exactly b+c (2200).
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(c, "art-c"), c));

        Assert.Equal(2, area.Status.PendingCount);
        var remaining = area.Drain().Select(h => h.ArtifactId).ToHashSet();
        Assert.Equal(new HashSet<string> { "art-b", "art-c" }, remaining);
        Assert.False(File.Exists(PathFor("art-a")));
        Assert.True(File.Exists(PathFor("art-b")));
        Assert.True(File.Exists(PathFor("art-c")));
    }

    /// <summary>
    /// Regression coverage for Finding 2 (#74 review, fourth pass). <see cref="ScreenshotStagingArea.Stage"/>
    /// used to run its byte-ceiling eviction loop before publishing the new bytes, so a write failure
    /// (disk pressure, a transient filesystem error) meant already-staged, already-deliverable
    /// screenshots had been destroyed for an admission that never actually happened. This forces a
    /// genuine OS write failure -- no seam, no mock -- the same way
    /// <see cref="RedirectedAncestorIsRejectedBeforeDirectoryCreation"/> already provokes a real
    /// <see cref="UnauthorizedAccessException"/> elsewhere in this suite: it pre-creates a directory
    /// at the exact path the new entry would be written to, so <c>Durability.ReplaceAtomic</c>'s
    /// final rename genuinely fails. Both previously staged entries must survive untouched and still
    /// readable, nothing must be recorded as evicted, and the failed entry must never appear staged.
    /// </summary>
    [Fact]
    public void AWriteFailureDuringStageEvictsNothingAndLeavesExistingEntriesIntactAndReadable()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 2200), clock.Now);
        byte[] a = new byte[1000];
        byte[] b = new byte[1000];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(a, "art-a"), a));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(b, "art-b"), b));
        clock.Advance(TimeSpan.FromSeconds(1));

        // Occupy "art-c"'s destination path with a directory before staging it: admitting c (1200)
        // alongside a+b (2000) would total 3200, over the 2200 ceiling, so a successful stage would
        // have to evict "art-a" first -- exactly the scenario where the old, pre-write eviction
        // ordering would have destroyed a perfectly good entry for an admission that was always
        // going to fail.
        byte[] c = new byte[1200];
        string blockedPath = PathFor("art-c");
        Directory.CreateDirectory(blockedPath);

        ScreenshotStageResult result = area.Stage(Prepared(), Request(c, "art-c"), c);

        Assert.Equal(ScreenshotStageResult.Refused, result);
        Assert.Equal(2, area.Status.PendingCount);
        Assert.Empty(area.DrainPendingEvictions());
        Assert.True(area.TryReadBytes("art-a", out byte[] readA));
        Assert.Equal(a, readA);
        Assert.True(area.TryReadBytes("art-b", out byte[] readB));
        Assert.Equal(b, readB);
        Assert.DoesNotContain("art-c", area.Drain().Select(h => h.ArtifactId));
    }

    [Fact]
    public void AnEntryLargerThanTheByteCeilingIsRefusedRatherThanAdmitted()
    {
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 100));
        byte[] tooBig = new byte[101];

        ScreenshotStageResult result = area.Stage(Prepared(), Request(tooBig, "art-huge"), tooBig);

        Assert.Equal(ScreenshotStageResult.Refused, result);
        Assert.Equal(0, area.Status.PendingCount);
        Assert.False(File.Exists(PathFor("art-huge")));
    }

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, sixth pass): <see cref="ScreenshotStagingArea.Remove"/>
    /// used to drop the in-memory entry and then swallow a failed delete entirely, so a blob this
    /// process could not delete became invisible to the byte ceiling -- an offline stretch could
    /// then grow the staging directory past its configured cap within one long-running process. This
    /// provokes a genuine OS deletion failure, not a seam: holding "art-a"'s staged file open with
    /// <see cref="FileShare.None"/> from a second handle makes <see cref="File.Delete(string)"/>
    /// throw a real sharing-violation <see cref="IOException"/> when <see cref="ScreenshotStagingArea.Remove"/>
    /// tries it, exactly the "antivirus scan" scenario described in this type's own remarks. The
    /// handle is released in a <c>finally</c> so it never survives a failing assertion.
    /// </summary>
    [Fact]
    public void ABlobWhoseDeletionFailsStillCountsAgainstTheByteCeiling()
    {
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 1500));
        byte[] a = new byte[1000];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(a, "art-a"), a));

        // A using declaration: the handle is released via Dispose as soon as it goes out of scope
        // at the end of this method, including when an assertion below throws, so this never leaves
        // a locked file (or a process holding it) behind after a failing test.
        using FileStream lockedHandle = new(PathFor("art-a"), FileMode.Open, FileAccess.Read, FileShare.None);

        // "Uploaded" (or otherwise terminally handled) while its file happens to be locked: the
        // in-memory entry is dropped, but the 1000 bytes stay on disk because the delete fails.
        area.Remove("art-a");
        Assert.Equal(0, area.Status.PendingCount);
        Assert.True(File.Exists(PathFor("art-a")), "The locked file must still be on disk after a failed delete.");

        // Without debt accounting, this 600-byte entry would be the only thing counted (0 pending
        // entries) and would fit easily under the 1500 ceiling. With the still-on-disk 1000 bytes
        // counted as debt, 600 + 1000 = 1600 exceeds the ceiling and nothing is evictable to make
        // room (debt is not an entry), so this must be refused.
        byte[] b = new byte[600];
        ScreenshotStageResult result = area.Stage(Prepared(), Request(b, "art-b"), b);

        Assert.Equal(ScreenshotStageResult.Refused, result);
        Assert.False(File.Exists(PathFor("art-b")), "A refusal must never write anything to disk.");
    }

    /// <summary>
    /// Companion to <see cref="ABlobWhoseDeletionFailsStillCountsAgainstTheByteCeiling"/>: once the
    /// lock is released, the next sweep (here, <see cref="ScreenshotStagingArea.EvictExpired"/>,
    /// which <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/> calls on every background pass)
    /// retries the deletion, succeeds, and drops the debt -- freeing the ceiling back up for an
    /// admission that was refused moments before.
    /// </summary>
    [Fact]
    public void DebtIsClearedOnceDeletionSucceedsAndTheCeilingFreesUpAgain()
    {
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 1500));
        byte[] a = new byte[1000];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(a, "art-a"), a));
        byte[] b = new byte[600];

        // Every Stage call retries outstanding debt as part of its own EvictExpiredLocked sweep
        // (see that method's remarks), so the lock must still be held for this first, refused
        // attempt -- otherwise the retry inside this very call would clear the debt before the
        // ceiling check ever saw it, and the refusal this test is pinning would never happen.
        using (FileStream lockedHandle = new(PathFor("art-a"), FileMode.Open, FileAccess.Read, FileShare.None))
        {
            area.Remove("art-a");
            Assert.Equal(ScreenshotStageResult.Refused, area.Stage(Prepared(), Request(b, "art-b"), b));
        }

        // The lock is released now. Nothing has retried the delete yet -- Stage's own retry only
        // runs on a Stage call, and none has happened since the lock came off -- so debt is still
        // outstanding and the ceiling is still full.
        area.EvictExpired();
        Assert.False(File.Exists(PathFor("art-a")), "The retried delete must have actually removed the file.");

        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(b, "art-b"), b));
        Assert.Equal(1, area.Status.PendingCount);
    }

    /// <summary>
    /// The core regression test for Finding 1 (#74 review, ninth pass). Before this fix, an eviction
    /// whose <see cref="File.Delete(string)"/> failed converted its target into deletion debt --
    /// freeing zero capacity -- yet <see cref="ScreenshotStagingArea.Stage"/>'s eviction loop kept
    /// running anyway, since <c>TotalBytesLocked</c> staying flat still left it over the ceiling. With
    /// two more real, deletable entries staged, the old loop would have gone on to destroy them too,
    /// chasing capacity that debt alone can never yield, and then still admitted the new entry over
    /// the ceiling regardless (the post-loop refusal having been deliberately removed for the leased-
    /// entry case in an earlier pass). This provokes a genuine <see cref="IOException"/> the same way
    /// <see cref="ABlobWhoseDeletionFailsStillCountsAgainstTheByteCeiling"/> does -- a real
    /// <see cref="FileShare.None"/> lock, not a seam -- so the very first eviction attempt (the
    /// oldest entry, "art-a") stalls, and pins that the sweep stops right there: the new entry is
    /// refused and its own just-written bytes are rolled back, "art-b" is never touched at all and
    /// stays fully staged and readable, and exactly one eviction (the stalled one) is ever reported.
    /// </summary>
    [Fact]
    public void AStageThatWouldNeedToEvictAnUndeletableEntryRefusesAndRollsBack()
    {
        const long ceiling = 1500;
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(byteCeiling: ceiling), clock.Now);
        byte[] a = new byte[500];
        byte[] b = new byte[500];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(a, "art-a"), a));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(b, "art-b"), b));
        clock.Advance(TimeSpan.FromSeconds(1));

        // A using declaration: released at the end of this method (including on a failing
        // assertion), exactly like the equivalent handle in
        // ABlobWhoseDeletionFailsStillCountsAgainstTheByteCeiling.
        using FileStream lockedHandle = new(PathFor("art-a"), FileMode.Open, FileAccess.Read, FileShare.None);

        // Admitting c (700) alongside a+b (1000) totals 1700, over the 1500 ceiling -- a successful
        // stage would have to evict "art-a" (the oldest) first. Its file is locked, so that eviction
        // can only ever turn it into debt, never free any capacity.
        byte[] c = new byte[700];
        ScreenshotStageResult result = area.Stage(Prepared(), Request(c, "art-c"), c);

        Assert.Equal(ScreenshotStageResult.Refused, result);
        Assert.False(File.Exists(PathFor("art-c")), "A refused admission must roll back the bytes it wrote.");

        // "art-b" was never touched: it is still a real, staged, readable entry, not merely bytes
        // left on disk as debt.
        Assert.Equal(1, area.Status.PendingCount);
        Assert.True(area.TryReadBytes("art-b", out byte[] readB));
        Assert.Equal(b, readB);

        // Exactly one eviction happened -- the stalled attempt on "art-a" -- proving the sweep
        // stopped there rather than grinding on to "art-b" next.
        Assert.Equal("art-a", Assert.Single(area.DrainPendingEvictions()));

        // The directory is left at or under the ceiling: "art-a"'s 500 (still on disk, now debt)
        // plus "art-b"'s 500 is 1000, comfortably under 1500 -- not 1700 or more, which admitting
        // "art-c" over the ceiling (or destroying "art-b" for nothing) would have produced.
        long totalOnDisk = Directory.GetFiles(root).Sum(file => new FileInfo(file).Length);
        Assert.True(totalOnDisk <= ceiling, $"Expected at most {ceiling} bytes on disk, found {totalOnDisk}.");
    }

    /// <summary>
    /// Companion to <see cref="AStageThatWouldNeedToEvictAnUndeletableEntryRefusesAndRollsBack"/>,
    /// pinning the no-progress guard itself (Finding 1, #74 review, ninth pass) rather than the
    /// refusal it leads to: with two good entries sitting behind the one stalled, undeletable oldest
    /// entry, the sweep must still stop after that single stalled attempt rather than continuing on
    /// to evict either of the two entries that follow it merely because the ceiling is still
    /// (apparently) not satisfied.
    /// </summary>
    [Fact]
    public void AnEvictionSweepThatFreesNothingDoesNotGoOnToDestroyFurtherEntries()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 2200), clock.Now);
        byte[] a = new byte[500];
        byte[] b = new byte[500];
        byte[] c = new byte[500];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(a, "art-a"), a));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(b, "art-b"), b));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(c, "art-c"), c));
        clock.Advance(TimeSpan.FromSeconds(1));

        using FileStream lockedHandle = new(PathFor("art-a"), FileMode.Open, FileAccess.Read, FileShare.None);

        // a+b+c (1500) + d (1200) = 2700, over the 2200 ceiling. Evicting "art-a" alone (locked,
        // stalls) can never satisfy that -- a pre-fix sweep would have gone on to evict "art-b" and
        // then "art-c" for real, destroying both to chase capacity debt can never yield.
        byte[] d = new byte[1200];
        ScreenshotStageResult result = area.Stage(Prepared(), Request(d, "art-d"), d);

        Assert.Equal(ScreenshotStageResult.Refused, result);
        Assert.False(File.Exists(PathFor("art-d")), "A refused admission must roll back the bytes it wrote.");

        // Only "art-a" was ever evicted; "art-b" and "art-c" are untouched.
        Assert.Equal("art-a", Assert.Single(area.DrainPendingEvictions()));
        Assert.Equal(2, area.Status.PendingCount);
        Assert.True(area.TryReadBytes("art-b", out byte[] readB));
        Assert.Equal(b, readB);
        Assert.True(area.TryReadBytes("art-c", out byte[] readC));
        Assert.Equal(c, readC);
    }

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, sixth pass): <see cref="ScreenshotStagingArea.PathFor"/>
    /// derives a deterministic path from the artifact id, so a re-stage of the same id writes to the
    /// exact path a prior failed deletion left debt for. That debt must be cleared by the re-stage's
    /// own successful write, not left to double-count those bytes against the ceiling forever.
    /// </summary>
    [Fact]
    public void ReStagingTheSameArtifactIdClearsThatPathsDebtRatherThanDoubleCounting()
    {
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 1500));
        byte[] original = new byte[1000];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(original, "art-a"), original));

        using (FileStream lockedHandle = new(PathFor("art-a"), FileMode.Open, FileAccess.Read, FileShare.None))
        {
            area.Remove("art-a");
        }

        // Debt now stands at 1000 for "art-a"'s path (the lock above has since been released, but
        // nothing has retried the delete yet).
        byte[] replacement = new byte[300];
        Assert.Equal(
            ScreenshotStageResult.Staged,
            area.Stage(Prepared(), Request(replacement, "art-a"), replacement));

        // If the re-stage above had not cleared "art-a"'s debt, it would still count 1000 bytes that
        // no longer exist (the write just replaced them), and this 1000-byte "art-b" would be
        // refused: 1000 (art-b) + 300 (art-a, now a real entry) + 1000 (stale debt) = 2300 > 1500,
        // with nothing further evictable. With the debt correctly cleared, only the two real entries
        // count (1300), leaving room.
        byte[] b = new byte[1000];
        ScreenshotStageResult result = area.Stage(Prepared(), Request(b, "art-b"), b);

        Assert.Equal(ScreenshotStageResult.Staged, result);
        Assert.Equal(2, area.Status.PendingCount);
    }

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, sixth pass): <see cref="ScreenshotStagingArea.CleanAtLaunch"/>
    /// must not just tolerate a file it cannot delete (already covered by
    /// <see cref="CleanAtLaunchToleratesALockedFileWithoutFailingTheSweep"/>) -- it must also seed
    /// deletion debt for it, so a fresh process still accounts for bytes an earlier, now-dead process
    /// left behind. The companion "clears debt it could" half is pinned by asserting no debt is
    /// seeded for the sibling file that <c>CleanAtLaunch</c> does manage to delete in the same sweep.
    /// </summary>
    [Fact]
    public void CleanAtLaunchSeedsDebtForAFileItCannotDeleteAndClearsDebtForOneItCan()
    {
        Directory.CreateDirectory(root);
        string lockedLeftover = Path.Combine(root, "locked-leftover.bin");
        string deletableLeftover = Path.Combine(root, "deletable-leftover.bin");
        File.WriteAllBytes(lockedLeftover, new byte[700]);
        File.WriteAllBytes(deletableLeftover, new byte[500]);

        using (FileStream lockedHandle = new(lockedLeftover, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var area = new ScreenshotStagingArea(Settings(byteCeiling: 1000));

            Assert.True(File.Exists(lockedLeftover), "The locked leftover must survive CleanAtLaunch.");
            Assert.False(File.Exists(deletableLeftover), "The unlocked leftover must be removed by CleanAtLaunch.");

            // If CleanAtLaunch had wrongly seeded debt for the deletable leftover too (700 + 500 =
            // 1200), this 250-byte entry would be refused against the 1000 ceiling. Seeding only the
            // locked leftover's 700 bytes leaves exactly enough room (250 + 700 = 950).
            byte[] small = new byte[250];
            Assert.Equal(
                ScreenshotStageResult.Staged,
                area.Stage(Prepared(), Request(small, "art-small"), small));

            // Now pin the "seeds debt" half directly: a second entry that only fits if the locked
            // leftover's 700 bytes are NOT counted must be refused.
            area.Remove("art-small");
            byte[] tooMuchWithDebt = new byte[400];
            Assert.Equal(
                ScreenshotStageResult.Refused,
                area.Stage(Prepared(), Request(tooMuchWithDebt, "art-too-much"), tooMuchWithDebt));
        }

        // The lock is released now; nothing has retried the delete yet.
    }

    /// <summary>
    /// Regression coverage for the #74 review: a byte-ceiling eviction removes an already-staged,
    /// already-prepared entry (its Files id already stamped on an emitted event), so it must be
    /// surfaced through <see cref="ScreenshotStagingArea.DrainPendingEvictions"/> exactly like an age
    /// eviction. This is distinct from a <see cref="ScreenshotStageResult.Refused"/> admission, which
    /// never touches any existing entry -- see
    /// <see cref="ARefusalForBeingLargerThanTheWholeCeilingIsNotRecordedAsAnEviction"/>.
    /// </summary>
    [Fact]
    public void AByteCeilingEvictionOfAStagedEntryIsRecordedAsAPendingEviction()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 2200), clock.Now);
        byte[] a = new byte[1000];
        byte[] b = new byte[1000];
        byte[] c = new byte[1200];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(a, "art-a"), a));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(b, "art-b"), b));
        clock.Advance(TimeSpan.FromSeconds(1));

        // Admitting c evicts the oldest entry (a) to make room, exactly as
        // StagingPastTheByteCeilingEvictsOldestFirst already pins.
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(c, "art-c"), c));

        Assert.Equal("art-a", Assert.Single(area.DrainPendingEvictions()));
        // The list is drained, not merely peeked: a second call finds nothing left to report.
        Assert.Empty(area.DrainPendingEvictions());
    }

    /// <summary>
    /// A refusal happens before anything is staged (see <see cref="Stage"/>'s ordering: the
    /// larger-than-ceiling check runs before any eviction loop), so it must never be conflated with
    /// evicting an existing, already-prepared entry -- the caller
    /// (<c>ScreenshotDeliveryPreparer.Prepare</c>) already returns <see langword="null"/> for a
    /// refusal without ever stamping a Files id, so there is nothing dangling to report here.
    /// </summary>
    [Fact]
    public void ARefusalForBeingLargerThanTheWholeCeilingIsNotRecordedAsAnEviction()
    {
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 100));
        byte[] small = new byte[10];
        byte[] tooBig = new byte[101];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(small, "art-small"), small));

        ScreenshotStageResult result = area.Stage(Prepared(), Request(tooBig, "art-huge"), tooBig);

        Assert.Equal(ScreenshotStageResult.Refused, result);
        Assert.Equal(1, area.Status.PendingCount);
        Assert.Empty(area.DrainPendingEvictions());
    }

    [Fact]
    public void EvictExpiredRemovesEntriesOlderThanRetentionUsingTheInjectedClockNotRealSleeping()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(retention: TimeSpan.FromHours(1)), clock.Now);
        byte[] bytes = ScreenshotBytes.TinyJpeg;

        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, "art-stale"), bytes));
        Assert.Equal(1, area.Status.PendingCount);

        clock.Advance(TimeSpan.FromHours(1) + TimeSpan.FromSeconds(1));
        area.EvictExpired();

        Assert.Equal(0, area.Status.PendingCount);
        Assert.False(File.Exists(PathFor("art-stale")));
    }

    /// <summary>
    /// Companion to <see cref="AByteCeilingEvictionOfAStagedEntryIsRecordedAsAPendingEviction"/>: an
    /// age eviction also removes an already-staged, already-prepared entry, driven entirely by the
    /// injected clock rather than real sleeping.
    /// </summary>
    [Fact]
    public void AnAgeEvictionOfAStagedEntryIsRecordedAsAPendingEviction()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(retention: TimeSpan.FromHours(1)), clock.Now);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, "art-stale"), bytes));

        clock.Advance(TimeSpan.FromHours(1) + TimeSpan.FromSeconds(1));
        area.EvictExpired();

        Assert.Equal("art-stale", Assert.Single(area.DrainPendingEvictions()));
    }

    [Fact]
    public void StageItselfOpportunisticallyEvictsExpiredEntriesBeforeAdmittingANewOne()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(retention: TimeSpan.FromMinutes(1)), clock.Now);
        byte[] stale = ScreenshotBytes.TinyJpeg;
        byte[] fresh = ScreenshotBytes.TinyJpeg;

        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(stale, "art-stale"), stale));
        clock.Advance(TimeSpan.FromMinutes(2));

        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(fresh, "art-fresh"), fresh));

        Assert.Equal(1, area.Status.PendingCount);
        Assert.Equal("art-fresh", Assert.Single(area.Drain()).ArtifactId);
    }

    [Fact]
    public void TimeUntilNextDueIsNullWhenNothingIsStaged()
    {
        var area = new ScreenshotStagingArea(Settings());

        Assert.Null(area.TimeUntilNextDue);
    }

    [Fact]
    public void TimeUntilNextDueIsZeroForAFreshlyStagedEntry()
    {
        var area = new ScreenshotStagingArea(Settings());
        byte[] bytes = ScreenshotBytes.TinyJpeg;

        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, "art-fresh"), bytes));

        Assert.Equal(TimeSpan.Zero, area.TimeUntilNextDue);
    }

    [Fact]
    public void TimeUntilNextDueReflectsTheBackoffComputedByRecordRetry()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(), clock.Now);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        const string artifactId = "art-retry-due";
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, artifactId), bytes));

        Assert.True(area.RecordRetry(artifactId));

        TimeSpan expected = ScreenshotUploadRetryPolicy.Delay(1, artifactId, Settings());
        Assert.Equal(expected, area.TimeUntilNextDue);
    }

    [Fact]
    public void TimeUntilNextDueIsTheMinimumAcrossSeveralStagedEntries()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(), clock.Now);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, "art-soon"), bytes));
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, "art-later"), bytes));

        // Both entries are freshly staged (due immediately); pushing one out with RecordRetry
        // leaves the other as the sole immediately-due entry, so the minimum must track it.
        Assert.True(area.RecordRetry("art-later"));

        Assert.Equal(TimeSpan.Zero, area.TimeUntilNextDue);
    }

    [Fact]
    public void TimeUntilNextDueClampsToZeroRatherThanGoingNegativeOnceDue()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var area = new ScreenshotStagingArea(Settings(), clock.Now);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        const string artifactId = "art-overdue";
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, artifactId), bytes));
        Assert.True(area.RecordRetry(artifactId));

        TimeSpan backoff = ScreenshotUploadRetryPolicy.Delay(1, artifactId, Settings());
        clock.Advance(backoff + TimeSpan.FromMinutes(1));

        Assert.Equal(TimeSpan.Zero, area.TimeUntilNextDue);
    }

    [Fact]
    public void NoFederationCredentialFieldEverReachesDisk()
    {
        const string bucketSentinel = "sentinel-bucket-must-never-be-persisted";
        const string keySentinel = "sentinel-key/must-never-be-persisted";
        const string tokenSentinel = "sentinel-access-token-must-never-be-persisted-XYZ789";

        var area = new ScreenshotStagingArea(Settings());
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        var prepared = new ScreenshotPrepareResult(999, bucketSentinel, keySentinel, tokenSentinel);

        Assert.Equal(
            ScreenshotStageResult.Staged,
            area.Stage(prepared, Request(bytes, "art-secret-check"), bytes));

        foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            // Latin1 maps every byte value 1:1 to a char, so a substring search over it finds an
            // ASCII sentinel regardless of the file's real encoding -- this is a byte-content
            // check, not a text-decoding one.
            string content = Encoding.Latin1.GetString(File.ReadAllBytes(file));
            Assert.DoesNotContain(bucketSentinel, content, StringComparison.Ordinal);
            Assert.DoesNotContain(keySentinel, content, StringComparison.Ordinal);
            Assert.DoesNotContain(tokenSentinel, content, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void StagedBytesReadBackExactlyAndMatchTheRecordedDigest()
    {
        var area = new ScreenshotStagingArea(Settings());
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        ScreenshotFilesRequest request = Request(bytes, "art-roundtrip");

        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        Assert.True(area.TryReadBytes("art-roundtrip", out byte[] readBack));
        Assert.Equal(bytes, readBack);
        Assert.Equal(request.Sha256, Convert.ToHexString(SHA256.HashData(readBack)).ToLowerInvariant());
    }

    [Fact]
    public void ACorruptedStagedFileFailsVerificationAndIsDroppedRatherThanRetriedForever()
    {
        var area = new ScreenshotStagingArea(Settings());
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, "art-corrupt"), bytes));

        File.WriteAllBytes(PathFor("art-corrupt"), [0xDE, 0xAD]);

        Assert.False(area.TryReadBytes("art-corrupt", out _));
        Assert.Equal(0, area.Status.PendingCount);
        Assert.Empty(area.Drain());
    }

    /// <summary>
    /// Regression coverage for Finding 5 (#74 review): <see cref="ScreenshotStagingArea.TryReadBytes"/>
    /// used to call <see cref="File.ReadAllBytes(string)"/> before checking the recorded
    /// <c>ByteLength</c>, so a staged file replaced or corrupted with a much larger payload was
    /// allocated in full -- under <c>_gate</c>, which the capture path also takes -- before being
    /// rejected. The on-disk file here is tens of megabytes larger than the tiny recorded length,
    /// so this pins the length bound itself rather than merely the digest check that runs after
    /// it.
    /// </summary>
    [Fact]
    public void AStagedFileMuchLargerThanTheRecordedLengthIsRejectedAndDropped()
    {
        var area = new ScreenshotStagingArea(Settings());
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bytes, "art-oversized"), bytes));

        byte[] muchLarger = new byte[bytes.Length + (20 * 1024 * 1024)];
        File.WriteAllBytes(PathFor("art-oversized"), muchLarger);

        Assert.False(area.TryReadBytes("art-oversized", out _));
        Assert.Equal(0, area.Status.PendingCount);
        Assert.Empty(area.Drain());
    }

    [Fact]
    public void TheStagingDirectoryAndItsFilesAreCurrentUserOnly()
    {
        var area = new ScreenshotStagingArea(Settings());
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        area.Stage(Prepared(), Request(bytes, "art-acl"), bytes);

        AssertCurrentUserOnly(new DirectoryInfo(root).GetAccessControl());
        foreach (string file in Directory.GetFiles(root))
        {
            AssertCurrentUserOnly(new FileInfo(file).GetAccessControl());
        }
    }

    /// <summary>
    /// Adapted from the closed <c>codex/68-screenshot-files</c> branch's
    /// <c>RedirectedAncestorIsRejectedBeforeDirectoryCreation</c>, using a directory junction
    /// instead of <see cref="Directory.CreateSymbolicLink"/>. The #72 review's finding D6 was that
    /// four tests on that branch silently <c>return</c>ed (asserting nothing) when a symbolic link
    /// could not be created without elevation or Developer Mode -- exactly the failure mode this
    /// machine hits (verified: <c>Directory.CreateSymbolicLink</c> throws "Administrator privilege
    /// required" here). A directory junction is also a reparse point
    /// (<see cref="FileAttributes.ReparsePoint"/> is set on it, which is all
    /// <see cref="CurrentUserOnlyAcl.RejectReparse"/> checks for) but, unlike a symbolic link,
    /// Windows lets an unprivileged process create one -- so this test exercises the real OS
    /// mechanism with no skip and no silent no-op.
    /// </summary>
    [Fact]
    public void RedirectedAncestorIsRejectedBeforeDirectoryCreation()
    {
        string parent = Path.Combine(Path.GetTempPath(), "jazz-staging-junction-parent-" + Guid.NewGuid().ToString("N"));
        string external = Path.Combine(Path.GetTempPath(), "jazz-staging-junction-external-" + Guid.NewGuid().ToString("N"));
        string redirected = Path.Combine(parent, "redirected");
        Directory.CreateDirectory(parent);
        Directory.CreateDirectory(external);
        try
        {
            CreateJunction(redirected, external);

            var settings = Settings() with { StagingDirectory = Path.Combine(redirected, "screenshots") };
            Assert.Throws<UnauthorizedAccessException>(() => new ScreenshotStagingArea(settings));
            Assert.Empty(Directory.EnumerateFileSystemEntries(external));
        }
        finally
        {
            if (Directory.Exists(redirected)) Directory.Delete(redirected);
            if (Directory.Exists(parent)) Directory.Delete(parent, recursive: true);
            if (Directory.Exists(external)) Directory.Delete(external, recursive: true);
        }
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            try { Directory.Delete(root, recursive: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    private string PathFor(string artifactId) =>
        Path.Combine(root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(artifactId))).ToLowerInvariant() + ".bin");

    private ScreenshotDeliverySettings Settings(
        long? byteCeiling = null,
        TimeSpan? retention = null) => new()
    {
        StagingDirectory = root,
        StagingByteCeiling = byteCeiling ?? 256L * 1024 * 1024,
        StagingRetention = retention ?? TimeSpan.FromHours(24),
    };

    private static ScreenshotPrepareResult Prepared() => new(1, "bucket", "prefix/object.bin", "fake-federation");

    private static ScreenshotFilesRequest Request(byte[] bytes, string artifactId) => new(
        ArchiveId: "a",
        CaptureId: "c",
        SessionId: "s",
        ArtifactId: artifactId,
        MediaType: "image/jpeg",
        Sha256: Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
        ByteLength: bytes.Length);

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

    /// <summary>
    /// Finding 5 (#74 review, second pass): the previous version of this helper called
    /// <c>WaitForExit</c> once and then asserted, so a timeout left the assertion failing without
    /// ever terminating the process -- exactly the unbounded-helper-wait failure mode
    /// <c>README.md</c>'s guardrails (the "Put a timeout around every ... helper-process wait" rule)
    /// exist to catch. On a timeout this now kills the exact process this call started (its tree,
    /// since <c>cmd.exe</c> spawns <c>mklink</c> as a child), waits for that kill to actually take,
    /// and only then fails -- never matching by process name, and never leaving a helper process (or
    /// the temporary directories it may still be holding open) running past a failed test.
    /// </summary>
    private static void CreateJunction(string link, string target)
    {
        var info = new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{target}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        using Process process = Process.Start(info)!;
        if (!process.WaitForExit(10_000))
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Raced with the process exiting on its own between the WaitForExit timeout above
                // and this call; there is nothing left to kill.
            }

            // Wait for the kill to actually take before failing, per the same rule: a timed-out
            // helper must be confirmed gone, not merely asked to stop. The wait's own return value
            // is what confirms that -- issuing Kill() does not itself guarantee the process (or its
            // mklink child) has actually exited by the time this method unwinds (Finding 5, #74
            // review, third pass).
            bool confirmedTerminated = process.WaitForExit(5_000);
            Assert.Fail(confirmedTerminated
                ? "mklink /J timed out after 10s; the helper process was terminated rather than left running."
                : "mklink /J timed out after 10s, and the helper process could not be confirmed terminated after being killed.");
        }

        Assert.True(
            process.ExitCode == 0,
            "mklink /J failed to create a directory junction; this test needs a real reparse point, not a skip.");
    }

    private sealed class MutableClock
    {
        private DateTimeOffset _now;

        public MutableClock(DateTimeOffset start) => _now = start;

        public DateTimeOffset Now() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
