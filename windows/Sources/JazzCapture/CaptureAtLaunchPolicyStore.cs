using System.Globalization;
using System.IO;
using System.Security;
using Microsoft.Win32;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// The outcome of one <see cref="CaptureAtLaunchPolicyStore.Read"/>: the parsed policy, and --
/// separately -- why a read was incomplete or a value could not be understood, for diagnostics.
/// </summary>
/// <param name="Policy">The parsed managed policy and installer preference.</param>
/// <param name="Detail">
/// Non-null only when a rank's value was <see cref="CaptureAtLaunchPolicyValue.Malformed"/> or a
/// registry read failed outright. Names the key path and the reason -- <b>never the value</b>, on
/// the same principle as <c>MvpDeliveryTarget.ToString()</c> (#62 constraint 2).
/// </param>
public sealed record CaptureAtLaunchPolicyRead(CaptureAtLaunchPolicy Policy, string? Detail);

/// <summary>
/// Reads #60's two managed-configuration ranks from the registry. Host-side
/// (<c>JazzCapture</c>), not Core: it calls <see cref="Microsoft.Win32.Registry"/>, and
/// <c>AGENTS.md</c> keeps OS APIs out of <c>JazzCaptureCore</c>.
/// </summary>
/// <remarks>
/// <para>
/// <b>A registry read failure must never be a capture outage.</b> Every exception a registry open
/// or read can throw for reasons outside this process's control --
/// <see cref="SecurityException"/>, <see cref="UnauthorizedAccessException"/>,
/// <see cref="IOException"/>, <see cref="ObjectDisposedException"/> -- is caught and folded into
/// <see cref="CaptureAtLaunchPolicyValue.Absent"/> plus a <see cref="CaptureAtLaunchPolicyRead.Detail"/>,
/// exactly like <c>App.xaml.cs</c>'s own narrow catches around the screenshot staging area and the
/// event spool. A machine where this read fails must still start up and journal locally.
/// </para>
/// <para>
/// <b>64-bit view only.</b> The payload is <c>win-x64</c>, so <see cref="RegistryKey.OpenBaseKey(RegistryHive, RegistryView)"/>
/// with <see cref="RegistryView.Default"/> already reads the 64-bit view -- which is where Intune's
/// settings catalog and ADMX ingestion write. A policy written by a 32-bit tool into
/// <c>WOW6432Node</c> is deliberately not read; there is no known deployment path that would write
/// one there.
/// </para>
/// <para>
/// <b>Both <c>REG_DWORD</c> and <c>REG_SZ</c> are accepted, at both locations.</b> Intune's settings
/// catalog and ADMX both write DWORDs; the MSI's <c>[JAZZ_CAPTURE_AT_LAUNCH]</c> formatting (slice
/// 2) can only ever produce a string. <see cref="NormalizeRegistryValue"/> is the pure projection
/// from either raw registry shape to the string <see cref="CaptureAtLaunchPolicy.Parse"/>
/// understands, kept as its own testable step so the DWORD/string equivalence can be pinned without
/// writing to a real registry key (<c>windows/README.md</c> forbids mutating machine state from the
/// local test suite).
/// </para>
/// <para>
/// <b>Injecting a delegate, rather than writing HKLM or HKCU in a test, is required</b> for exactly
/// that reason. <see cref="Read"/> asks the injected (or default) reader for each rank in turn,
/// using the same two labels (<see cref="ManagedHive"/>, <see cref="InstallerHive"/>) either way, so
/// a test can simulate every combination of present/absent/malformed/throwing without touching a
/// real key.
/// </para>
/// </remarks>
public sealed class CaptureAtLaunchPolicyStore
{
    /// <summary>The managed-policy key, under <c>HKEY_LOCAL_MACHINE</c>. Never written by this client.</summary>
    public const string ManagedPolicyKey = @"Software\Policies\Keboola\Jazz";

    /// <summary>The installer-preference key, under <c>HKEY_CURRENT_USER</c>. Never written by this client.</summary>
    public const string InstallerPreferenceKey = @"Software\Keboola\Jazz\Policy";

    /// <summary>The value name read at both keys.</summary>
    public const string ValueName = "CaptureAtLaunch";

    /// <summary>The hive label <see cref="Read"/> passes for the managed-policy rank.</summary>
    public const string ManagedHive = "HKEY_LOCAL_MACHINE";

    /// <summary>The hive label <see cref="Read"/> passes for the installer-preference rank.</summary>
    public const string InstallerHive = "HKEY_CURRENT_USER";

    /// <summary>
    /// Sentinel returned by <see cref="NormalizeRegistryValue"/> for a value kind this store does
    /// not understand (not <see cref="int"/>, <see cref="long"/>, or <see cref="string"/>). A fixed,
    /// human-readable marker that can never equal the trimmed <c>"0"</c> or <c>"1"</c>
    /// <see cref="CaptureAtLaunchPolicy.Parse"/> accepts -- it always parses as
    /// <see cref="CaptureAtLaunchPolicyValue.Malformed"/> -- and so it never echoes whatever the
    /// unsupported value actually was.
    /// </summary>
    internal const string UnsupportedValueKindSentinel = "unsupported-registry-value-kind";

    private readonly Func<string, string, string, string?> _read;

    /// <param name="read">
    /// Reads one raw value, given (hive label, subkey path, value name); returns the normalized
    /// string form (see <see cref="NormalizeRegistryValue"/>) or <see langword="null"/> when the key
    /// or the value does not exist. May throw <see cref="SecurityException"/>,
    /// <see cref="UnauthorizedAccessException"/>, <see cref="IOException"/>, or
    /// <see cref="ObjectDisposedException"/>; <see cref="Read"/> catches all four. Defaults to the
    /// real registry; tests inject a delegate instead of writing machine state.
    /// </param>
    public CaptureAtLaunchPolicyStore(Func<string, string, string, string?>? read = null)
    {
        _read = read ?? DefaultRead;
    }

    /// <summary>
    /// Reads both ranks. Never throws: any read failure resolves to
    /// <see cref="CaptureAtLaunchPolicyValue.Absent"/> for that rank, plus a
    /// <see cref="CaptureAtLaunchPolicyRead.Detail"/> describing why.
    /// </summary>
    public CaptureAtLaunchPolicyRead Read()
    {
        (CaptureAtLaunchPolicyValue Value, string? Detail) managed =
            ReadOne(ManagedHive, ManagedPolicyKey);
        (CaptureAtLaunchPolicyValue Value, string? Detail) installer =
            ReadOne(InstallerHive, InstallerPreferenceKey);

        // Detail is a single field on the combined read, so it has to pick one story when both
        // ranks have something to say. This mirrors Resolve's own precedence for exactly the two
        // ranks this store can see: a rank that actually decides (Malformed; Absent/Disabled never
        // do) is asked first, managed before installer, so the detail always names whichever rank
        // Resolve would actually blame -- a read failure at a higher rank that leaves it merely
        // Absent must never eclipse a real Malformed decision one rank down. Only once neither rank
        // decides does a plain read-failure detail (still worth surfacing for diagnostics even
        // though nothing is enforced) fall back to whichever rank has one.
        string? detail = managed.Value == CaptureAtLaunchPolicyValue.Malformed ? managed.Detail
            : installer.Value == CaptureAtLaunchPolicyValue.Malformed ? installer.Detail
            : managed.Detail ?? installer.Detail;

        return new CaptureAtLaunchPolicyRead(new CaptureAtLaunchPolicy(managed.Value, installer.Value), detail);
    }

    private (CaptureAtLaunchPolicyValue Value, string? Detail) ReadOne(string hive, string key)
    {
        string? raw;
        try
        {
            raw = _read(hive, key, ValueName);
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException or ObjectDisposedException)
        {
            return (
                CaptureAtLaunchPolicyValue.Absent,
                FormattableString.Invariant($"{hive}\\{key}\\{ValueName} could not be read ({ex.GetType().Name})."));
        }

        CaptureAtLaunchPolicyValue value = CaptureAtLaunchPolicy.Parse(raw);
        return value == CaptureAtLaunchPolicyValue.Malformed
            ? (value, FormattableString.Invariant($"{hive}\\{key}\\{ValueName} is set but is not a recognised value."))
            : (value, null);
    }

    private static string? DefaultRead(string hive, string key, string valueName)
    {
        using RegistryKey baseKey = hive switch
        {
            ManagedHive => RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Default),
            InstallerHive => RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Default),
            _ => throw new ArgumentOutOfRangeException(nameof(hive), hive, "Unrecognised registry hive label."),
        };

        using RegistryKey? subKey = baseKey.OpenSubKey(key, writable: false);
        return subKey is null ? null : NormalizeRegistryValue(subKey.GetValue(valueName));
    }

    /// <summary>
    /// Projects one raw <see cref="RegistryKey.GetValue(string?)"/> result to the string
    /// <see cref="CaptureAtLaunchPolicy.Parse"/> understands. A pure function, kept separate from
    /// <see cref="DefaultRead"/> so the DWORD/string equivalence is unit-testable without touching a
    /// real registry key.
    /// </summary>
    internal static string? NormalizeRegistryValue(object? raw) => raw switch
    {
        null => null,
        int i => i.ToString(CultureInfo.InvariantCulture),
        long l => l.ToString(CultureInfo.InvariantCulture),
        string s => s,
        // REG_MULTI_SZ, REG_BINARY, REG_EXPAND_SZ, or anything else this store does not expect:
        // never echo it (#62 constraint 2) -- return a sentinel Parse always rejects as Malformed.
        _ => UnsupportedValueKindSentinel,
    };
}
