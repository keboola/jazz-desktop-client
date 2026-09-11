using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace JazzCapture;

/// <summary>Host-only ACL boundary for captured screenshot delivery data.</summary>
/// <remarks>
/// Ported unchanged from the closed <c>codex/68-screenshot-files</c> branch. Per the #72 review
/// (finding D1), callers must apply <see cref="ApplyDirectory"/> exactly once when a directory is
/// created and <see cref="ApplyFile"/> at most once per file, at write time -- never on every read.
/// <see cref="ApplyDirectory"/> protects the directory with
/// <c>SetAccessRuleProtection(isProtected: true, preserveInheritance: false)</c>, and files created
/// under a protected directory inherit its DACL from creation, so re-asserting the ACL on a read path
/// is pure syscall cost; <see cref="RejectReparse"/> alone walks the whole ancestor chain, so that
/// cost compounds if called repeatedly.
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

    public static void ApplyFile(string path)
    {
        RejectReparse(path);
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
        RejectReparse(path);
    }
}
