using System.Globalization;
using System.IO;
using System.Security;
using Microsoft.Win32;
using JazzCaptureCore;

namespace JazzCapture;

public sealed record CommandCenterUrlRead(string? Url, string? Detail);

/// <summary>
/// Reads the command-center URL from managed policy and the MSI installer preference.
/// Precedence: managed policy, then installer preference, then none.
/// </summary>
public sealed class CommandCenterUrlPolicyStore
{
    public const string ManagedPolicyKey = CaptureAtLaunchPolicyStore.ManagedPolicyKey;
    public const string InstallerPreferenceKey = CaptureAtLaunchPolicyStore.InstallerPreferenceKey;
    public const string ValueName = "CommandCenterUrl";
    public const string ManagedHive = CaptureAtLaunchPolicyStore.ManagedHive;
    public const string InstallerHive = CaptureAtLaunchPolicyStore.InstallerHive;

    private readonly Func<string, string, string, string?> _read;

    public CommandCenterUrlPolicyStore(Func<string, string, string, string?>? read = null)
    {
        _read = read ?? DefaultRead;
    }

    public CommandCenterUrlRead Read()
    {
        (string? Url, string? Detail) managed = ReadOne(ManagedHive, ManagedPolicyKey);
        if (managed.Url is not null || managed.Detail is not null)
        {
            return new CommandCenterUrlRead(managed.Url, managed.Detail);
        }

        (string? Url, string? Detail) installer = ReadOne(InstallerHive, InstallerPreferenceKey);
        return new CommandCenterUrlRead(installer.Url, installer.Detail);
    }

    private (string? Url, string? Detail) ReadOne(string hive, string key)
    {
        string? raw;
        try
        {
            raw = _read(hive, key, ValueName);
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException or ObjectDisposedException)
        {
            return (
                null,
                FormattableString.Invariant($"{hive}\\{key}\\{ValueName} could not be read ({ex.GetType().Name})."));
        }

        if (raw is null)
        {
            return (null, null);
        }

        if (string.IsNullOrWhiteSpace(raw))
        {
            return (null, null);
        }

        string? normalized = CommandCenterUrl.TryNormalize(raw);
        return normalized is not null
            ? (normalized, null)
            : (
                null,
                FormattableString.Invariant(
                    $"{hive}\\{key}\\{ValueName} is set but is not a valid https command center URL."));
    }

    private static string? DefaultRead(string hive, string key, string valueName)
    {
        using RegistryKey baseKey = hive switch
        {
            ManagedHive => RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64),
            InstallerHive => RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64),
            _ => throw new ArgumentOutOfRangeException(nameof(hive), hive, "Unrecognised registry hive label."),
        };

        using RegistryKey? subKey = baseKey.OpenSubKey(key, writable: false);
        if (subKey is null)
        {
            return null;
        }

        RegistryValueKind kind;
        try
        {
            kind = subKey.GetValueKind(valueName);
        }
        catch (IOException)
        {
            return null;
        }

        if (kind != RegistryValueKind.String)
        {
            return CaptureAtLaunchPolicyStore.UnsupportedValueKindSentinel;
        }

        return subKey.GetValue(valueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
    }
}
