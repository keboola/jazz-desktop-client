using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="NarrationSpool"/> is the durable pair spool issue #84 introduces: a blob-plus-sidecar
/// per narration clip, adopted (not wiped) at every launch, bounded by both total size and age, with
/// the sidecar as the write's commit marker. Modelled on <see cref="EventSpoolTests"/>' own idioms;
/// the four deltas from that type's own behaviour (pairs, the FilesId stamp, span-based staging, no
/// attempt budget) are each exercised here.
/// </summary>
public sealed class NarrationSpoolTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-spool-narration-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            try { Directory.Delete(root, recursive: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    [Fact]
    public void PairsSurviveARelaunchByteForByte()
    {
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        byte[] clipA = NarrationBytes.TinyClip(4);
        byte[] clipB = NarrationBytes.TinyClip(8);

        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), clipA));
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 2), clipB));

        // A relaunch, not a reused instance -- per the house style for durability tests.
        var reopened = new NarrationSpool(Settings());

        Assert.Equal(2, reopened.Status.PendingCount);
        var handles = reopened.Drain();
        Assert.Equal(2, handles.Count);
        foreach (StagedNarrationHandle handle in handles)
        {
            Assert.True(reopened.TryReadBlob(handle.Key, out byte[] readBack));
            Assert.Contains(new[] { clipA, clipB }, candidate => candidate.SequenceEqual(readBack));
            // Everything the sidecar needs to rebuild the event and its SessionContext must survive
            // too, not just the bytes.
            Assert.Equal("trace-1", handle.Meta.TraceId);
            Assert.Equal("span-1", handle.Meta.SpanId);
            Assert.Equal(session, handle.Meta.SessionId);
        }
    }

    /// <summary>
    /// Adoption must read <see cref="PendingNarration.StagedAt"/> from the sidecar, never from the
    /// blob's own <c>LastWriteTimeUtc</c> and never from "now" -- otherwise a machine restarting
    /// daily would never age anything out, making <see cref="NarrationDeliverySettings.SpoolRetention"/>
    /// fiction (issue #84, §3.6).
    /// </summary>
    [Fact]
    public void AdoptionHonoursTheSidecarsOwnStagedAtNotTheFileSystemTimestamp()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        string session = SessionId();
        var spool = new NarrationSpool(Settings(retention: TimeSpan.FromMinutes(1)));
        DateTimeOffset stagedAt = clock.Now();
        Assert.Equal(
            NarrationSpoolAdmission.Staged,
            spool.Stage(Pending(session, 1, stagedAt: stagedAt), NarrationBytes.TinyClip()));

        // Touch the blob's own file-system timestamp far into the "future" relative to StagedAt --
        // if adoption ever used LastWriteTimeUtc instead of the sidecar, this clip would look brand
        // new and never age out.
        string blobPath = Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.audio").Single();
        File.SetLastWriteTimeUtc(blobPath, DateTime.UtcNow);

        var reopened = new NarrationSpool(Settings(retention: TimeSpan.FromMinutes(1)), () => stagedAt + TimeSpan.FromMinutes(2));
        reopened.EvictExpired();

        Assert.Equal(0, reopened.Status.PendingCount);
        Assert.Contains(session + "/0000000001." + Sha256Hex(NarrationBytes.TinyClip()), reopened.DrainPendingEvictions());
    }

    [Fact]
    public void ABlobWithNoSidecarIsSweptAtAdoptionAndReportedAsAVerificationFailure()
    {
        string session = SessionId();
        Directory.CreateDirectory(Path.Combine(root, session));
        byte[] clip = NarrationBytes.TinyClip();
        string orphanBlob = Path.Combine(root, session, "0000000001." + Sha256Hex(clip) + ".narration.audio");
        File.WriteAllBytes(orphanBlob, clip);

        var spool = new NarrationSpool(Settings());

        Assert.Equal(0, spool.Status.PendingCount);
        Assert.False(File.Exists(orphanBlob), "A blob with no sidecar is garbage -- nothing references bytes with no way to rebuild the event.");
        Assert.Contains(session + "/0000000001." + Sha256Hex(clip), spool.DrainPendingVerificationFailures());
    }

    [Fact]
    public void ASidecarWithNoBlobIsSweptAtAdoptionAndReportedAsAVerificationFailure()
    {
        string session = SessionId();
        Directory.CreateDirectory(Path.Combine(root, session));
        byte[] clip = NarrationBytes.TinyClip();
        string orphanSidecar = Path.Combine(root, session, "0000000001." + Sha256Hex(clip) + ".narration.json");
        File.WriteAllText(orphanSidecar, "{}");

        var spool = new NarrationSpool(Settings());

        Assert.Equal(0, spool.Status.PendingCount);
        Assert.False(File.Exists(orphanSidecar));
        Assert.Contains(session + "/0000000001." + Sha256Hex(clip), spool.DrainPendingVerificationFailures());
    }

    [Fact]
    public void AnUnparsableSidecarSweepsBothFilesAndReportsAVerificationFailure()
    {
        var seed = new NarrationSpool(Settings());
        string session = SessionId();
        byte[] clip = NarrationBytes.TinyClip();
        Assert.Equal(NarrationSpoolAdmission.Staged, seed.Stage(Pending(session, 1), clip));

        string sidecarPath = Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.json").Single();
        File.WriteAllText(sidecarPath, "{ not json");

        var reopened = new NarrationSpool(Settings());

        Assert.Equal(0, reopened.Status.PendingCount);
        Assert.False(File.Exists(sidecarPath));
        Assert.Empty(Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.audio"));
        Assert.NotEmpty(reopened.DrainPendingVerificationFailures());
    }

    /// <summary>
    /// Review finding (Copilot round 2): a sidecar otherwise consistent with its own directory and
    /// stem digest, but claiming a non-positive <see cref="PendingNarration.FilesId"/>, must not be
    /// adopted as "already stamped" -- zero or negative is never a real Keboola Files id (see
    /// <see cref="NarrationSpool.TryStampFilesId"/>'s own guard), and trusting it would emit a
    /// non-empty, invalid <c>audio_file_id</c> without ever having uploaded anything.
    /// </summary>
    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void ASidecarClaimingANonPositiveFilesIdIsNotAdoptedAsAlreadyStamped(long invalidFilesId)
    {
        var seed = new NarrationSpool(Settings());
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, seed.Stage(Pending(session, 1), NarrationBytes.TinyClip()));

        string sidecarPath = Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.json").Single();
        System.Text.Json.Nodes.JsonNode node = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(sidecarPath))!;
        node["FilesId"] = invalidFilesId;
        File.WriteAllText(sidecarPath, node.ToJsonString());

        var reopened = new NarrationSpool(Settings());

        Assert.Equal(0, reopened.Status.PendingCount);
        Assert.False(File.Exists(sidecarPath));
        Assert.NotEmpty(reopened.DrainPendingVerificationFailures());
    }

    /// <summary>
    /// Review finding (Copilot round 2): a sidecar missing a field <c>ArtifactFilesRequest</c>
    /// requires (here, <see cref="PendingNarration.MediaType"/>) must be treated as unparsable at
    /// adoption, not silently admitted only to have every future prepare attempt fail with
    /// <c>FilesPrepareFailureKind.InvalidRequest</c> and retry forever.
    /// </summary>
    [Fact]
    public void ASidecarMissingMediaTypeIsNotAdoptedAndIsReportedAsAVerificationFailure()
    {
        var seed = new NarrationSpool(Settings());
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, seed.Stage(Pending(session, 1), NarrationBytes.TinyClip()));

        string sidecarPath = Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.json").Single();
        System.Text.Json.Nodes.JsonNode node = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(sidecarPath))!;
        node["MediaType"] = "";
        File.WriteAllText(sidecarPath, node.ToJsonString());

        var reopened = new NarrationSpool(Settings());

        Assert.Equal(0, reopened.Status.PendingCount);
        Assert.False(File.Exists(sidecarPath));
        Assert.NotEmpty(reopened.DrainPendingVerificationFailures());
    }

    [Theory]
    [InlineData(".narration.audio")]
    [InlineData(".narration.json")]
    public void AnInterruptedAtomicWriteLeavesNoAdoptableEntry(string extension)
    {
        string session = SessionId();
        Directory.CreateDirectory(Path.Combine(root, session));
        string temporary = Path.Combine(
            root, session, "0000000001." + Sha256Hex(NarrationBytes.TinyClip()) + extension
                + ".0199c0de-dead-7abc-8def-000000000001.tmp");
        File.WriteAllBytes(temporary, [1, 2, 3]);

        var spool = new NarrationSpool(Settings());

        Assert.Equal(0, spool.Status.PendingCount);
        Assert.False(File.Exists(temporary));
    }

    [Fact]
    public void TryStampFilesIdRewritesOnlyTheSidecarAndSurvivesARelaunch()
    {
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        byte[] clip = NarrationBytes.TinyClip();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), clip));
        string key = Assert.Single(spool.Drain()).Key;
        string blobPath = Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.audio").Single();
        byte[] blobBeforeStamp = File.ReadAllBytes(blobPath);

        Assert.True(spool.TryStampFilesId(key, 4242));

        Assert.Equal(blobBeforeStamp, File.ReadAllBytes(blobPath));

        var reopened = new NarrationSpool(Settings());
        StagedNarrationHandle handle = Assert.Single(reopened.Drain());
        Assert.Equal(4242, handle.Meta.FilesId);
        Assert.True(reopened.TryReadBlob(handle.Key, out byte[] readBack));
        Assert.Equal(clip, readBack);
    }

    [Fact]
    public void StampingAKeyThatNoLongerExistsReturnsFalse()
    {
        var spool = new NarrationSpool(Settings());

        Assert.False(spool.TryStampFilesId("s-0199f0c1-1c00-7a11-b000-000000000001/0000000001.abc", 1));
    }

    /// <summary>Review finding (Copilot round 2): a real Keboola Files id is always positive; this
    /// boundary is enforced at the one place every stamped id enters the spool, not only at
    /// adoption.</summary>
    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void TryStampFilesIdRejectsANonPositiveId(long invalidFilesId)
    {
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));
        string key = Assert.Single(spool.Drain()).Key;

        Assert.Throws<ArgumentOutOfRangeException>(() => spool.TryStampFilesId(key, invalidFilesId));
    }

    /// <summary>
    /// No attempt budget, exactly like <see cref="EventSpool"/> and unlike
    /// <see cref="ScreenshotStagingArea"/>: a narration clip is not a decoration on the record, it
    /// *is* the record, so a retryable failure must retry indefinitely.
    /// </summary>
    [Fact]
    public void ARetryableFailureNeverDropsTheClipRegardlessOfAttemptCount()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(retention: TimeSpan.FromHours(1)), clock.Now);
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));
        string key = Assert.Single(spool.Drain()).Key;

        for (int attempt = 0; attempt < 50; attempt++)
        {
            spool.RecordRetry(key);
        }

        Assert.Equal(1, spool.Status.PendingCount);
        Assert.True(spool.AnyRetrying);
    }

    [Fact]
    public void AClipAloneLargerThanMaximumClipBytesIsRefusedWithoutTouchingDisk()
    {
        var spool = new NarrationSpool(Settings(maximumClipBytes: 100));
        string session = SessionId();
        byte[] tooLarge = NarrationBytes.OfExactSize(200);

        NarrationSpoolAdmission admission = spool.Stage(Pending(session, 1), tooLarge);

        Assert.Equal(NarrationSpoolAdmission.Refused, admission);
        Assert.Equal(0, spool.Status.PendingCount);
        Assert.False(Directory.Exists(Path.Combine(root, session)), "A refusal that fails size validation up front must never touch disk.");
        Assert.NotEmpty(spool.DrainPendingRefusals());
    }

    [Fact]
    public void PastTheSpoolByteCeilingTheOldestClipsAreEvictedAndReported()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(byteCeiling: 280, maximumClipBytes: 200), clock.Now);
        string session = SessionId();

        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.OfExactSize(150)));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 2), NarrationBytes.OfExactSize(150)));

        Assert.Equal(1, spool.Status.PendingCount);
        IReadOnlyList<string> evicted = spool.DrainPendingEvictions();
        Assert.Single(evicted);
        Assert.Contains("0000000001", evicted[0]);
    }

    /// <summary>
    /// Issue #84 review finding (R5): a clip whose sidecar already carries a stamped Files id has
    /// already been successfully uploaded -- evicting it would permanently orphan that Files object
    /// while losing a row that was fully rebuildable from the sidecar at zero further cost. Both
    /// eviction sweeps (byte ceiling and age) must skip a stamped entry; a refusal of the *new*
    /// admission is the accepted trade-off instead.
    /// </summary>
    [Fact]
    public void AStampedClipIsNeverEvictedByTheByteCeilingEvenWhenItIsTheOldest()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(byteCeiling: 280, maximumClipBytes: 200), clock.Now);
        string session = SessionId();

        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.OfExactSize(150)));
        string stampedKey = Assert.Single(spool.Drain()).Key;
        Assert.True(spool.TryStampFilesId(stampedKey, 4242));
        clock.Advance(TimeSpan.FromSeconds(1));

        // The new admission cannot evict the stamped entry to make room, so it is refused instead --
        // not silently admitted by orphaning the already-uploaded Files object.
        NarrationSpoolAdmission admission = spool.Stage(Pending(session, 2), NarrationBytes.OfExactSize(150));

        Assert.Equal(NarrationSpoolAdmission.Refused, admission);
        Assert.Equal(1, spool.Status.PendingCount);
        StagedNarrationHandle survivor = Assert.Single(spool.Drain());
        Assert.Equal(stampedKey, survivor.Key);
        Assert.Equal(4242, survivor.Meta.FilesId);
    }

    /// <summary>Companion: a stamped clip also survives the independent age-based sweep.</summary>
    [Fact]
    public void AStampedClipIsNeverEvictedByAgeEitherEvenWhenItHasExpired()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(retention: TimeSpan.FromHours(1)), clock.Now);
        string session = SessionId();
        Assert.Equal(
            NarrationSpoolAdmission.Staged,
            spool.Stage(Pending(session, 1, stagedAt: clock.Now()), NarrationBytes.TinyClip()));
        string key = Assert.Single(spool.Drain()).Key;
        Assert.True(spool.TryStampFilesId(key, 99));

        clock.Advance(TimeSpan.FromHours(1) + TimeSpan.FromSeconds(1));
        spool.EvictExpired();

        Assert.Equal(1, spool.Status.PendingCount);
        Assert.Empty(spool.DrainPendingEvictions());
    }

    [Fact]
    public void EvictExpiredRemovesEntriesOlderThanRetentionUsingTheInjectedClock()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(retention: TimeSpan.FromHours(1)), clock.Now);
        string session = SessionId();
        Assert.Equal(
            NarrationSpoolAdmission.Staged,
            spool.Stage(Pending(session, 1, stagedAt: clock.Now()), NarrationBytes.TinyClip()));

        clock.Advance(TimeSpan.FromHours(1) + TimeSpan.FromSeconds(1));
        spool.EvictExpired();

        Assert.Equal(0, spool.Status.PendingCount);
        Assert.Single(spool.DrainPendingEvictions());
    }

    /// <summary>
    /// The sidecar is deleted first, then the blob (issue #84, §2.6 step 7): the two deletes are
    /// independent best-effort attempts in that order, so a sidecar that cannot be deleted right now
    /// must not stop the blob from still being removed.
    /// </summary>
    [Fact]
    public void RemoveDeletesTheSidecarBeforeTheBlobAndEachIsIndependentlyBestEffort()
    {
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));
        string key = Assert.Single(spool.Drain()).Key;
        string sidecarPath = Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.json").Single();
        string blobPath = Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.audio").Single();

        using (var lockedSidecar = new FileStream(sidecarPath, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            spool.Remove(key);

            Assert.True(File.Exists(sidecarPath), "Locked open; the delete attempt must fail without throwing.");
            Assert.False(File.Exists(blobPath), "The blob delete is independent and must still succeed.");
        }
    }

    [Fact]
    public void DrainReturnsDueClipsOldestFirst()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(), clock.Now);
        string sessionA = SessionId();
        string sessionB = SessionId();

        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(sessionB, 1), NarrationBytes.TinyClip(1)));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(sessionA, 1), NarrationBytes.TinyClip(2)));

        var due = spool.Drain();

        Assert.Equal(2, due.Count);
        Assert.Equal(sessionB, due[0].SessionId);
        Assert.Equal(sessionA, due[1].SessionId);
    }

    [Fact]
    public void TheSpoolDirectoryAndItsFilesAreCurrentUserOnly()
    {
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        spool.Stage(Pending(session, 1), NarrationBytes.TinyClip());

        AssertCurrentUserOnly(new DirectoryInfo(root).GetAccessControl());
        foreach (string file in Directory.EnumerateFiles(Path.Combine(root, session)))
        {
            AssertCurrentUserOnly(new FileInfo(file).GetAccessControl());
        }
    }

    [Fact]
    public void ARedirectedAncestorIsRejectedBeforeDirectoryCreation()
    {
        string parent = Path.Combine(Path.GetTempPath(), "jazz-narration-junction-parent-" + Guid.NewGuid().ToString("N"));
        string external = Path.Combine(Path.GetTempPath(), "jazz-narration-junction-external-" + Guid.NewGuid().ToString("N"));
        string redirected = Path.Combine(parent, "redirected");
        Directory.CreateDirectory(parent);
        Directory.CreateDirectory(external);
        try
        {
            CreateJunction(redirected, external);

            var settings = Settings() with { SpoolDirectory = Path.Combine(redirected, "narration") };
            Assert.Throws<UnauthorizedAccessException>(() => new NarrationSpool(settings));
            Assert.Empty(Directory.EnumerateFileSystemEntries(external));
        }
        finally
        {
            if (Directory.Exists(redirected)) Directory.Delete(redirected);
            if (Directory.Exists(parent)) Directory.Delete(parent, recursive: true);
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
            Assert.Fail("mklink /J timed out after 10s.");
        }

        Assert.True(process.ExitCode == 0, "mklink /J failed to create a directory junction; this test needs a real reparse point.");
    }

    private string SessionId() => Identifiers.Prefixed("s");

    private static string Sha256Hex(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private PendingNarration Pending(string sessionId, int sequence, long? filesId = null, DateTimeOffset? stagedAt = null) => new(
        SessionId: sessionId,
        ArchiveId: "ar-test",
        CaptureId: "cap-test",
        ArtifactId: "art-test-" + sequence,
        EventId: sessionId + "-" + sequence,
        Sequence: sequence,
        Timestamp: "2026-01-01T00:00:00.000Z",
        LabelId: "lbl-1",
        Label: "Task step",
        MediaType: "audio/wav",
        Sha256: new string('0', 64),
        ByteLength: 0,
        StagedAt: Timestamps.IsoMillisUtc(stagedAt ?? DateTimeOffset.UtcNow),
        TraceId: "trace-1",
        SpanId: "span-1",
        SessionStartedAt: "2026-01-01T00:00:00.000Z",
        User: "user1",
        InstanceName: "machine1",
        ServiceName: "jazz-capture",
        FilesId: filesId);

    private NarrationDeliverySettings Settings(
        long? maximumClipBytes = null,
        long? byteCeiling = null,
        TimeSpan? retention = null) => new()
    {
        SpoolDirectory = root,
        MaximumClipBytes = maximumClipBytes ?? 60L * 1024 * 1024,
        SpoolByteCeiling = byteCeiling ?? 512L * 1024 * 1024,
        SpoolRetention = retention ?? TimeSpan.FromHours(48),
    };

    private sealed class MutableClock
    {
        private DateTimeOffset _now;

        public MutableClock(DateTimeOffset start) => _now = start;

        public DateTimeOffset Now() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
