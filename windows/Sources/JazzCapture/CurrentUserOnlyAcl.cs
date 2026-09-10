using System.Security.AccessControl;
using System.Security.Principal;
using System.IO;

namespace JazzCapture;

/// <summary>Host-only ACL boundary shared by protected credential and delivery spools.</summary>
internal static class CurrentUserOnlyAcl
{
    internal static void ApplyDirectory(string path)
    {
        RejectReparse(path); Directory.CreateDirectory(path); SecurityIdentifier current = WindowsIdentity.GetCurrent().User ?? throw new UnauthorizedAccessException();
        var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }
    internal static void RejectReparse(string path) { if (File.Exists(path) || Directory.Exists(path)) if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new UnauthorizedAccessException(); }
    internal static void ApplyFile(string path) { RejectReparse(path); SecurityIdentifier current = WindowsIdentity.GetCurrent().User ?? throw new UnauthorizedAccessException(); var security = new FileSecurity(); security.SetAccessRuleProtection(true, false); security.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl, InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow)); new FileInfo(path).SetAccessControl(security); }
}
