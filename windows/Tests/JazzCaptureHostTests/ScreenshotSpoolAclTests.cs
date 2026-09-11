using System.Security.AccessControl;
using System.Security.Principal;
using JazzCapture;
using JazzCaptureCore;
using JazzCaptureCore.Delivery;

namespace JazzCaptureHostTests;

public sealed class ScreenshotSpoolAclTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        Guid.NewGuid().ToString("N"));

    [Fact]
    public void QueueFilesAndReopenAreCurrentUserOnly()
    {
        CurrentUserOnlyAcl.ApplyDirectory(root);
        byte[] bytes = [1];
        var queue = new ArtifactDeliveryQueue(root, CurrentUserOnlyAcl.ApplyFile);
        var descriptor = new ArtifactDeliveryDescriptor(
            "a",
            "c",
            "art",
            "art",
            "image/jpeg",
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes))
                .ToLowerInvariant(),
            bytes.Length,
            bytes);
        var activityEvent = new ActivityEvent
        {
            SessionId = "s",
            EventId = "e",
            Timestamp = "2026-01-01T00:00:00Z",
            EventType = "click",
            Url = "x",
            ScreenshotId = "art",
        };
        ArtifactDeliveryRecord record = queue.EnqueueScreenshot(
            descriptor,
            activityEvent,
            new SessionContext(
                "s",
                new string('a', 32),
                new string('b', 16),
                activityEvent.Timestamp,
                null,
                "u",
                "h",
                null,
                null));
        queue.BindRemoteFile(record, 1);

        AssertAcl(new DirectoryInfo(root).GetAccessControl());
        foreach (string path in Directory.GetFiles(root))
        {
            AssertAcl(new FileInfo(path).GetAccessControl());
        }

        var reopened = new ArtifactDeliveryQueue(root, CurrentUserOnlyAcl.ApplyFile);
        Assert.NotEmpty(reopened.ReadOtlpBytes(Assert.Single(reopened.Pending())));
    }

    [Fact]
    public void RedirectedAncestorIsRejectedBeforeDirectoryCreation()
    {
        string parent = Path.Combine(
            Path.GetTempPath(),
            "jazz-acl-parent-" + Guid.NewGuid().ToString("N"));
        string external = Path.Combine(
            Path.GetTempPath(),
            "jazz-acl-external-" + Guid.NewGuid().ToString("N"));
        string redirected = Path.Combine(parent, "redirected");
        Directory.CreateDirectory(parent);
        Directory.CreateDirectory(external);
        try
        {
            try
            {
                Directory.CreateSymbolicLink(redirected, external);
            }
            catch (Exception exception) when (exception is UnauthorizedAccessException
                or PlatformNotSupportedException
                or IOException)
            {
                return;
            }

            Assert.Throws<UnauthorizedAccessException>(() =>
                CurrentUserOnlyAcl.ApplyDirectory(Path.Combine(redirected, "screenshots")));
            Assert.Empty(Directory.EnumerateFileSystemEntries(external));
        }
        finally
        {
            if (Directory.Exists(redirected)) Directory.Delete(redirected);
            if (Directory.Exists(parent)) Directory.Delete(parent, true);
            if (Directory.Exists(external)) Directory.Delete(external, true);
        }
    }

    private static void AssertAcl(FileSystemSecurity security)
    {
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User!;
        Assert.True(security.AreAccessRulesProtected);
        Assert.All(
            security.GetAccessRules(
                    includeExplicit: true,
                    includeInherited: true,
                    typeof(SecurityIdentifier))
                .Cast<FileSystemAccessRule>(),
            rule =>
            {
                Assert.Equal(current, rule.IdentityReference);
                Assert.Equal(AccessControlType.Allow, rule.AccessControlType);
                Assert.Equal(
                    FileSystemRights.FullControl,
                    rule.FileSystemRights & FileSystemRights.FullControl);
            });
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
