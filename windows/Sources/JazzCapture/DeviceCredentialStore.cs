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
    private readonly IProvisioningFileOperations provisioningFiles;
    private readonly Func<string, bool> provisioningAcl;

    public DeviceCredentialStore(string? securityDirectory = null, IProvisioningFileOperations? provisioningFiles = null, Func<string, bool>? provisioningAcl = null)
    {
        SecurityDirectory = securityDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jazz", "security");
        this.provisioningFiles = provisioningFiles ?? new ProvisioningFileOperations();
        this.provisioningAcl = provisioningAcl ?? HasProvisioningAcl;
    }

    public string SecurityDirectory { get; }
    public string FilePath => Path.Combine(SecurityDirectory, FileName);
    /// <summary>Canonical non-secret Intune intake location; #60 only places a protected bundle here.</summary>
    public static string ProvisioningPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jazz", "provisioning", "device-bundle.json");

    public DeviceCredentialState State(DateTimeOffset now)
        => Status(now).State;

    /// <summary>Non-secret status suitable for tray presentation.</summary>
    public DeviceCredentialStatus Status(DateTimeOffset now)
    {
        try
        {
            DeviceBundle? bundle = Read();
            if (bundle is null) return new(DeviceCredentialState.NotProvisioned, "No device bundle has been provisioned.");
            return Timestamps.TryParseRfc3339(bundle.ExpiresAt) is { } expiry && expiry > now
                ? expiry - now <= TimeSpan.FromDays(7) ? new(DeviceCredentialState.Expiring, "The device credential expires soon.") : new(DeviceCredentialState.Active, "Device credential is active.")
                : new(DeviceCredentialState.Expired, "The device credential has expired.");
        }
        catch (DeviceCredentialStoreException) { return new(DeviceCredentialState.Invalid, "The protected credential store could not be read."); }
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
                // Stored expired credentials remain structurally readable so the tray can say
                // "expired" rather than disguising rotation as damaged state.
                return DeviceBundleParser.Parse(System.Text.Encoding.UTF8.GetString(bytes), DateTimeOffset.UtcNow, requireUnexpired: false);
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
                try
                {
                    using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        stream.Write(cipher);
                        stream.Flush(flushToDisk: true);
                    }
                    ApplyCurrentUserAcl(temporary, false);
                    File.Move(temporary, FilePath, true);
                }
                finally
                {
                    // Only a uniquely-owned sibling is ever removed; an older good store survives
                    // every failure before the atomic replacement.
                    if (File.Exists(temporary)) File.Delete(temporary);
                }
            }
            finally { CryptographicOperations.ZeroMemory(cipher); }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException)
        { throw new DeviceCredentialStoreException(DeviceCredentialStoreError.Unavailable, ex); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    /// <summary>Manual and managed intake both verify the scoped token before any protected write.</summary>
    public async Task<DeviceCredentialStatus> AuthorizeAndAcceptManualPasteAsync(
        string text, IDeviceTokenVerifier verifier, DateTimeOffset now, CancellationToken cancellationToken)
    {
        try
        {
            Write(await DeviceCredentialAuthorizer.AuthorizeAsync(text, verifier, now, cancellationToken).ConfigureAwait(false));
            return Status(now);
        }
        catch (DeviceBundleException ex) { return new(DeviceCredentialState.Invalid, DeviceBundleException.Describe(ex.Reason)); }
        catch (DeviceCredentialStoreException) { return new(DeviceCredentialState.Invalid, "The protected credential store could not be written."); }
    }

    public async Task<DeviceCredentialStatus> ConsumeProvisioningFileAsync(
        string provisioningPath, IDeviceTokenVerifier verifier, DateTimeOffset now, CancellationToken cancellationToken)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(provisioningPath) || !provisioningFiles.Exists(provisioningPath))
                return Status(now);
            if (provisioningFiles is ProvisioningFileOperations
                && (File.GetAttributes(provisioningPath) & FileAttributes.ReparsePoint) != 0)
                return new(DeviceCredentialState.Invalid, "The provisioning bundle path is not a regular file.");
            if (!provisioningAcl(provisioningPath))
                return new(DeviceCredentialState.Invalid, "The provisioning bundle is not protected for this user.");
            string text = provisioningFiles.ReadAllText(provisioningPath);
            DeviceBundle bundle;
            try { bundle = DeviceBundleParser.Parse(text, now); }
            catch (DeviceBundleException ex)
            {
                return RefusedSource(provisioningPath, ex);
            }
            try { await DeviceCredentialAuthorizer.AuthorizeAsync(text, verifier, now, cancellationToken).ConfigureAwait(false); }
            catch (DeviceBundleException ex) when (ex.Reason != DeviceBundleError.VerificationUnavailable)
            {
                return RefusedSource(provisioningPath, ex);
            }
            Write(bundle);
            if (!Neutralize(provisioningPath))
                return new(DeviceCredentialState.Invalid, "The accepted provisioning bundle could not be neutralized.");
            return Status(now);
        }
        catch (DeviceBundleException ex) { return new(DeviceCredentialState.Invalid, DeviceBundleException.Describe(ex.Reason)); }
        catch (DeviceCredentialStoreException) { return new(DeviceCredentialState.Invalid, "The protected credential store could not be written."); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return new(DeviceCredentialState.Invalid, "The provisioning bundle could not be consumed."); }
    }

    private static string Serialize(DeviceBundle bundle) => JsonSerializer.Serialize(new
    {
        kind = bundle.Kind, deviceId = bundle.DeviceId, stackUrl = bundle.StackUrl, projectId = bundle.ProjectId,
        companyId = bundle.CompanyId, areaId = bundle.AreaId, archiveIngestUrl = bundle.ArchiveIngestUrl,
        streamSourceId = bundle.StreamSourceId, streamEndpoint = bundle.StreamEndpoint, token = bundle.Token,
        tokenId = bundle.TokenId, expiresAt = bundle.ExpiresAt, tokenBucketScope = bundle.TokenBucketScope.ToWire(),
        sinkBucketId = bundle.SinkBucketId, componentAccess = bundle.ComponentAccess,
    });

    private DeviceCredentialStatus RefusedSource(string path, DeviceBundleException error) => Neutralize(path)
        ? new(DeviceCredentialState.Invalid, DeviceBundleException.Describe(error.Reason))
        : new(DeviceCredentialState.Invalid, "The provisioning bundle could not be neutralized.");

    private static bool HasProvisioningAcl(string path)
    {
        FileSecurity security = new FileInfo(path).GetAccessControl();
        if (!security.AreAccessRulesProtected) return false;
        SecurityIdentifier current = WindowsIdentity.GetCurrent().User ?? throw new UnauthorizedAccessException();
        AuthorizationRuleCollection rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier));
        // Intune may write as LocalSystem, but no other principal may read the plaintext bundle.
        SecurityIdentifier localSystem = new(WellKnownSidType.LocalSystemSid, null);
        FileSystemAccessRule[] acl = rules.Cast<FileSystemAccessRule>().ToArray();
        return acl.Length > 0
            && acl.Any(rule => rule.IdentityReference == current
                && (rule.FileSystemRights & (FileSystemRights.ReadData | FileSystemRights.WriteData))
                    == (FileSystemRights.ReadData | FileSystemRights.WriteData))
            && acl.All(rule =>
            rule.AccessControlType == AccessControlType.Allow
            && (rule.IdentityReference == current || rule.IdentityReference == localSystem));
    }

    private bool Neutralize(string path)
    {
        try
        {
            provisioningFiles.TruncateAndFlush(path);
            try { provisioningFiles.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            return true;
        }
        catch (IOException) { return false; } catch (UnauthorizedAccessException) { return false; }
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

public interface IProvisioningFileOperations
{
    bool Exists(string path); string ReadAllText(string path); void TruncateAndFlush(string path); void Delete(string path);
}
public sealed class ProvisioningFileOperations : IProvisioningFileOperations
{
    public bool Exists(string path) => File.Exists(path);
    public string ReadAllText(string path) => File.ReadAllText(path);
    public void TruncateAndFlush(string path) { using var stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None); stream.SetLength(0); stream.Flush(true); }
    public void Delete(string path) => File.Delete(path);
}

public enum DeviceCredentialState { NotProvisioned, Active, Expiring, Expired, Invalid }
public sealed record DeviceCredentialStatus(DeviceCredentialState State, string Reason);
public enum DeviceCredentialStoreError { Unavailable, Invalid }
public sealed class DeviceCredentialStoreException : Exception
{
    public DeviceCredentialStoreException(DeviceCredentialStoreError reason, Exception inner) : base("The protected credential store is unavailable.", inner) => Reason = reason;
    public DeviceCredentialStoreError Reason { get; }
}
