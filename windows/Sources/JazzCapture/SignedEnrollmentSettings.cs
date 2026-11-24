using System.IO;
using System.Security;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// Where a device without Entra ID enrolls. <see cref="Code"/> is the per-tenant enrollment code. It
/// is needed only until the device is enrolled.
/// </summary>
public sealed record SignedEnrollmentSettings(string ServerUrl, string? Code);

/// <summary>
/// Reads <c>EnrollmentServerUrl</c> and <c>EnrollmentCode</c> from managed policy (HKLM), then from
/// the HKCU preference. The pair comes from one location, like the Entra settings.
/// </summary>
public sealed class SignedEnrollmentPolicyStore
{
    public const string CodeValueName = "EnrollmentCode";

    private readonly Func<string, string, string, string?> _read;

    public SignedEnrollmentPolicyStore(Func<string, string, string, string?>? read = null)
    {
        _read = read ?? CommandCenterUrlPolicyStore.DefaultRead;
    }

    public SignedEnrollmentSettings? Read() =>
        ReadOne(CaptureAtLaunchPolicyStore.ManagedHive, CaptureAtLaunchPolicyStore.ManagedPolicyKey)
        ?? ReadOne(CaptureAtLaunchPolicyStore.InstallerHive, CaptureAtLaunchPolicyStore.InstallerPreferenceKey);

    private SignedEnrollmentSettings? ReadOne(string hive, string key)
    {
        try
        {
            string? url = EntraEnrollmentPolicyStore.NormalizeServerUrl(_read(hive, key, EntraEnrollmentPolicyStore.ServerUrlValueName));
            if (url is null) return null;
            string? code = _read(hive, key, CodeValueName)?.Trim();
            return new SignedEnrollmentSettings(url, string.IsNullOrEmpty(code) ? null : code);
        }
        catch (Exception exception) when (exception is SecurityException or UnauthorizedAccessException or IOException or ObjectDisposedException)
        {
            return null;
        }
    }
}
