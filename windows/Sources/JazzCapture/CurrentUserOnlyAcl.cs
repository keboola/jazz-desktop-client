using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace JazzCapture;

/// <summary>Host-only ACL boundary for captured screenshot delivery data.</summary>
/// <remarks>
/// Ported from the closed <c>codex/68-screenshot-files</c> branch. Per the #72 review
/// (finding D1), callers must apply <see cref="ApplyDirectory"/> exactly once when a directory is
/// created and <see cref="SetFileAcl"/> at most once per file, at write time -- never on every read.
/// <see cref="ApplyDirectory"/> protects the directory with
/// <c>SetAccessRuleProtection(isProtected: true, preserveInheritance: false)</c>, and files created
/// under a protected directory inherit its DACL from creation, so re-asserting the ACL on a read path
/// is pure syscall cost; <see cref="RejectReparse"/> alone walks the whole ancestor chain, so that
/// cost compounds if called repeatedly.
/// </remarks>
/// <remarks>
/// <b>Why the file path exposes the two halves separately (Finding 1, #74 review, eleventh pass).</b>
/// The branch this was ported from had a single <c>ApplyFile</c> that ran <see cref="RejectReparse"/>
/// and then set the ACL, both signalling failure as <see cref="UnauthorizedAccessException"/>. A
/// caller treating the ACL as best-effort -- which it legitimately is, since a file under an already
/// protected directory inherits that protection -- therefore swallowed the reparse rejection along
/// with it, and a redirected path was accepted rather than refused. The two are not
/// interchangeable: a failed ACL leaves data in the right place with weaker-than-intended
/// permissions, while a reparse rejection means the path is not the place the caller thinks it is at
/// all. They are separate methods so a caller must choose a policy for each; see
/// <c>ScreenshotStagingArea.Stage</c>, which refuses on the first and tolerates the second.
/// </remarks>
public static class CurrentUserOnlyAcl
{
    public static void ApplyDirectory(string path)
    {
        RejectReparse(path);
        Directory.CreateDirectory(path);
        RejectReparse(path);
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User
            ?? throw new UnauthorizedAccessException();
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            current,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }

    public static void RejectReparse(string path)
    {
        DirectoryInfo? current = new(Path.GetFullPath(path));
        while (current is not null)
        {
            try
            {
                if ((File.GetAttributes(current.FullName) & FileAttributes.ReparsePoint) != 0)
                {
                    throw new UnauthorizedAccessException();
                }
            }
            catch (Exception exception) when (exception is FileNotFoundException
                or DirectoryNotFoundException)
            {
                // A missing leaf is expected before creation; existing parents are still checked.
            }
            current = current.Parent;
        }
    }

    /// <summary>
    /// Rejects only if <paramref name="path"/> itself is a reparse point -- no ancestor walk. Safe
    /// to use only when every ancestor has already been separately verified by a real
    /// <see cref="RejectReparse"/> call of its own. <c>EventSpool.AdoptFile</c> is exactly that case
    /// (its own root and the file's session directory are both already checked by the time it
    /// reaches a per-file call): repeating the full ancestor walk once per file, over a spool that
    /// can hold thousands of them, made adopting a full spool measurably slow at startup (a review
    /// finding) for no additional guarantee over this cheaper, single-syscall check.
    /// </summary>
    public static void RejectReparseLeaf(string path)
    {
        try
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                throw new UnauthorizedAccessException();
            }
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
        }
    }

    /// <summary>
    /// Sets <paramref name="path"/>'s own protected DACL to current-user-only. Performs no
    /// path-integrity check of its own: the caller is responsible for calling
    /// <see cref="RejectReparse"/> around this, so that a reparse rejection and an ACL failure can
    /// be given the different policies they need (see this type's own remarks).
    /// </summary>
    public static void SetFileAcl(string path)
    {
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User
            ?? throw new UnauthorizedAccessException();
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            current,
            FileSystemRights.FullControl,
            InheritanceFlags.None,
            PropagationFlags.None,
            AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }
}
