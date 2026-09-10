using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using System.IO;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>
/// Current-user-only DPAPI store for the device bundle. Its public state deliberately has no URL
/// or token fields; callers that need a credential receive it only through <see cref="Read"/>.
/// </summary>
public sealed class DeviceCredentialStore
{
    private const string FileName = "device-credentials-v1.bin";
    private static readonly byte[] Entropy = "JazzCapture/device-credentials/v1"u8.ToArray();

    public DeviceCredentialStore(string? securityDirectory = null)
    {
        SecurityDirectory = securityDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jazz", "security");
    }

    public string SecurityDirectory { get; }
    public string FilePath => Path.Combine(SecurityDirectory, FileName);

    public DeviceCredentialState State(DateTimeOffset now)
    {
        try
        {
            DeviceBundle? bundle = Read();
            if (bundle is null) return DeviceCredentialState.NotProvisioned;
            return Timestamps.TryParseRfc3339(bundle.ExpiresAt) is { } expiry && expiry > now
                ? expiry - now <= TimeSpan.FromDays(7) ? DeviceCredentialState.Expiring : DeviceCredentialState.Active
                : DeviceCredentialState.Expired;
        }
        catch (DeviceCredentialStoreException) { return DeviceCredentialState.Invalid; }
    }

    public DeviceBundle? Read()
    {
        if (!File.Exists(FilePath)) return null;
        try
        {
            byte[] protectedBytes = File.ReadAllBytes(FilePath);
            byte[] bytes = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            try
            {
                return DeviceBundleParser.Parse(System.Text.Encoding.UTF8.GetString(bytes), DateTimeOffset.UtcNow);
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        catch (DeviceBundleException ex) { throw new DeviceCredentialStoreException(DeviceCredentialStoreError.Invalid, ex); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException or JsonException)
        { throw new DeviceCredentialStoreException(DeviceCredentialStoreError.Unavailable, ex); }
    }

    public void Write(DeviceBundle bundle)
    {
        ArgumentNullException.ThrowIfNull(bundle);
        string payload = Serialize(bundle);
        byte[] plain = System.Text.Encoding.UTF8.GetBytes(payload);
        try
        {
            Directory.CreateDirectory(SecurityDirectory);
            ApplyCurrentUserAcl(SecurityDirectory, true);
            byte[] cipher = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
            try
            {
                string temporary = FilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllBytes(temporary, cipher);
                ApplyCurrentUserAcl(temporary, false);
                File.Move(temporary, FilePath, true);
            }
            finally { CryptographicOperations.ZeroMemory(cipher); }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException)
        { throw new DeviceCredentialStoreException(DeviceCredentialStoreError.Unavailable, ex); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    /// <summary>Consumes an Intune-written source only after a durable protected write succeeds.</summary>
    public DeviceCredentialState ConsumeProvisioningFile(string provisioningPath, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(provisioningPath)) throw new ArgumentException("A provisioning path is required.", nameof(provisioningPath));
        try
        {
            if (!File.Exists(provisioningPath) || !IsCurrentUserOnly(provisioningPath))
                return DeviceCredentialState.Invalid;
            string text = File.ReadAllText(provisioningPath);
            DeviceBundle bundle = DeviceBundleParser.Parse(text, now);
            Write(bundle);
            File.Delete(provisioningPath); // source is plaintext; retain no recovery copy.
            return State(now);
        }
        catch (DeviceBundleException) { return DeviceCredentialState.Invalid; }
        catch (DeviceCredentialStoreException) { return DeviceCredentialState.Invalid; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return DeviceCredentialState.Invalid; }
    }

    private static string Serialize(DeviceBundle bundle) => JsonSerializer.Serialize(new
    {
        kind = bundle.Kind, deviceId = bundle.DeviceId, stackUrl = bundle.StackUrl, projectId = bundle.ProjectId,
        companyId = bundle.CompanyId, areaId = bundle.AreaId, archiveIngestUrl = bundle.ArchiveIngestUrl,
        streamSourceId = bundle.StreamSourceId, streamEndpoint = bundle.StreamEndpoint, token = bundle.Token,
        tokenId = bundle.TokenId, expiresAt = bundle.ExpiresAt, tokenBucketScope = bundle.TokenBucketScope.ToWire(),
        sinkBucketId = bundle.SinkBucketId, componentAccess = bundle.ComponentAccess,
    });

    private static bool IsCurrentUserOnly(string path)
    {
        FileSecurity security = new FileInfo(path).GetAccessControl();
        if (!security.AreAccessRulesProtected) return false;
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User ?? throw new UnauthorizedAccessException();
        AuthorizationRuleCollection rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier));
        return rules.Cast<FileSystemAccessRule>().All(rule => rule.IdentityReference == current && rule.AccessControlType == AccessControlType.Allow);
    }

    private static void ApplyCurrentUserAcl(string path, bool directory)
    {
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User ?? throw new UnauthorizedAccessException();
        if (directory)
        {
            var directorySecurity = new DirectorySecurity();
            directorySecurity.SetAccessRuleProtection(true, false);
            directorySecurity.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(path).SetAccessControl(directorySecurity);
            return;
        }
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl,
            InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }
}

public enum DeviceCredentialState { NotProvisioned, Active, Expiring, Expired, Invalid }
public enum DeviceCredentialStoreError { Unavailable, Invalid }
public sealed class DeviceCredentialStoreException : Exception
{
    public DeviceCredentialStoreException(DeviceCredentialStoreError reason, Exception inner) : base("The protected credential store is unavailable.", inner) => Reason = reason;
    public DeviceCredentialStoreError Reason { get; }
}
