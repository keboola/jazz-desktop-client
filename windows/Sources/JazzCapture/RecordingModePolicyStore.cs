using System.IO;
using System.Security;
using Microsoft.Win32;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>Outcome of reading <c>HKLM\Software\Policies\Keboola\Jazz\RecordingMode</c>.</summary>
/// <param name="Mode">Parsed mode, or <see langword="null"/> when absent, unreadable, or malformed.</param>
/// <param name="Detail">Diagnostic detail when the value was present but not recognised. Never contains the raw value.</param>
public sealed record RecordingModePolicyRead(RecordingMode? Mode, string? Detail);

/// <summary>
/// Reads the managed recording-mode fallback from the registry. Host-side only; failures never
/// prevent capture.
/// </summary>
public sealed class RecordingModePolicyStore
{
    public const string ManagedPolicyKey = CaptureAtLaunchPolicyStore.ManagedPolicyKey;
    public const string ValueName = "RecordingMode";

    private readonly Func<string, string, string, string?> _read;

    public RecordingModePolicyStore(Func<string, string, string, string?>? read = null)
    {
        _read = read ?? DefaultRead;
    }

    public RecordingModePolicyRead Read()
    {
        string? raw;
        try
        {
            raw = _read(CaptureAtLaunchPolicyStore.ManagedHive, ManagedPolicyKey, ValueName);
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException or ObjectDisposedException)
        {
            return new RecordingModePolicyRead(
                null,
                FormattableString.Invariant(
                    $"{CaptureAtLaunchPolicyStore.ManagedHive}\\{ManagedPolicyKey}\\{ValueName} could not be read ({ex.GetType().Name})."));
        }

        if (raw is null)
        {
            return new RecordingModePolicyRead(null, null);
        }

        if (RecordingModeParser.TryParse(raw, out RecordingMode mode))
        {
            return new RecordingModePolicyRead(mode, null);
        }

        return new RecordingModePolicyRead(
            null,
            FormattableString.Invariant(
                $"{CaptureAtLaunchPolicyStore.ManagedHive}\\{ManagedPolicyKey}\\{ValueName} is set but is not a recognised value."));
    }

    private static string? DefaultRead(string hive, string key, string valueName)
    {
        using RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using RegistryKey? subKey = baseKey.OpenSubKey(key, writable: false);
        if (subKey is null)
        {
            return null;
        }

        object? value = subKey.GetValue(valueName);
        if (value is null)
        {
            return null;
        }

        RegistryValueKind kind = subKey.GetValueKind(valueName);
        if (kind is RegistryValueKind.String or RegistryValueKind.ExpandString)
        {
            return subKey.GetValue(valueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        }

        if (kind == RegistryValueKind.DWord && value is int dword)
        {
            return dword == 0 ? RecordingModeParser.SessionValue : RecordingModeParser.ContinuousValue;
        }

        return null;
    }
}
