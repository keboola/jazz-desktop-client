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
        process.WaitForExit(10_000);
        Assert.True(
            process.HasExited && process.ExitCode == 0,
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
