using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace JazzCapture;

/// <summary>Host-only ACL boundary for captured screenshot delivery data.</summary>
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
        if ((File.Exists(path) || Directory.Exists(path))
            && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UnauthorizedAccessException();
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
    }
}
