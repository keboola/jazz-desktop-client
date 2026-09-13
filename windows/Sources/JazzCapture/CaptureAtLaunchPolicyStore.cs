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
/// <b>64-bit view only.</b> <see cref="DefaultRead"/> opens both hives with
/// <see cref="RegistryView.Registry64"/> explicitly (not <see cref="RegistryView.Default"/>, which
/// would only happen to read the 64-bit view for as long as this process itself is x64) -- which is
/// where Intune's settings catalog and ADMX ingestion write. A policy written by a 32-bit tool into
/// <c>WOW6432Node</c> is deliberately not read; there is no known deployment path that would write
/// one there.
/// </para>
/// <para>
/// <b>Both <c>REG_DWORD</c> and <c>REG_SZ</c> are accepted, at both locations, and only those two.</b>
/// Intune's settings catalog and ADMX both write DWORDs; the MSI's <c>[JAZZ_CAPTURE_AT_LAUNCH]</c>
/// formatting (slice 2) can only ever produce a string. <see cref="DefaultRead"/> checks
/// <see cref="RegistryKey.GetValueKind(string?)"/> before ever reading the value, rather than
/// inferring the registry type from the CLR type <see cref="RegistryKey.GetValue(string?)"/>
/// returns: <c>GetValue</c> alone cannot tell a <c>REG_SZ</c> apart from a <c>REG_EXPAND_SZ</c>
/// (both surface as <see cref="string"/>) or a <c>REG_QWORD</c> apart from the accepted
/// <c>REG_DWORD</c> case (the former surfaces as <see cref="long"/>, which
/// <see cref="NormalizeRegistryValue"/> also accepts as a pure function) -- so skipping the kind
/// check would silently let an unsupported registry type decide capture whenever its value happened
/// to normalize to <c>"0"</c> or <c>"1"</c> (a Copilot review finding, PR #85).
/// <see cref="NormalizeRegistryValue"/> is the pure projection from an already kind-checked raw
/// registry value to the string <see cref="CaptureAtLaunchPolicy.Parse"/> understands, kept as its
/// own testable step so the DWORD/string equivalence can be pinned without writing to a real
/// registry key (<c>windows/README.md</c> forbids mutating machine state from the local test suite).
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

        return new CaptureAtLaunchPolicyRead(
            new CaptureAtLaunchPolicy(managed.Value, installer.Value), DecidingDetail(managed, installer));
    }

    /// <summary>
    /// Picks the single <see cref="CaptureAtLaunchPolicyRead.Detail"/> this read reports, mirroring
    /// <see cref="EffectiveCaptureAtLaunch.Resolve(HostSettings, bool, CaptureAtLaunchPolicy)"/>'s
    /// own precedence exactly -- not merely "whichever rank happens to have a non-null detail".
    /// </summary>
    /// <remarks>
    /// <b>An earlier version of this method got this wrong (Opus review finding, PR #85): it
    /// returned a rank's detail whenever that rank was individually Malformed, regardless of
    /// whether a <em>higher</em> rank had already decided <c>Enabled</c>.</b> That let a clean,
    /// enforced-on managed policy (<c>1</c>) surface the installer preference's unrelated malformed
    /// detail -- a rank <c>Resolve</c> never even consults once the managed policy has decided --
    /// so <c>SettingsWindow</c> could show "a setting could not be read" on a machine that was, in
    /// fact, actively enforced on by the organisation. A rank that decides <c>Enabled</c> now ends
    /// the search with <see langword="null"/>, exactly as <c>Resolve</c> stops looking further once
    /// it has an answer, regardless of what a lower rank's own value happens to be. Only when
    /// neither rank decides anything at all does a bare read-failure detail -- still worth
    /// surfacing for diagnostics even though nothing is enforced -- fall back to whichever rank has
    /// one.
    /// </remarks>
    private static string? DecidingDetail(
        (CaptureAtLaunchPolicyValue Value, string? Detail) managed,
        (CaptureAtLaunchPolicyValue Value, string? Detail) installer)
    {
        if (managed.Value == CaptureAtLaunchPolicyValue.Enabled)
        {
            return null;
        }

        if (managed.Value == CaptureAtLaunchPolicyValue.Malformed)
        {
            return managed.Detail;
        }

        // Absent and Disabled both express "no opinion" (amendment 3) and fall through identically.
        if (installer.Value == CaptureAtLaunchPolicyValue.Enabled)
        {
            return null;
        }

        if (installer.Value == CaptureAtLaunchPolicyValue.Malformed)
        {
            return installer.Detail;
        }

        return managed.Detail ?? installer.Detail;
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
        // Registry64 explicitly, not Default: Default tracks the calling process's own bitness,
        // which happens to be x64 today only because the payload is win-x64. Pinning the view
        // keeps the "64-bit view only" guarantee this type documents true even if a future build
        // target changed process bitness -- Intune's settings catalog and ADMX ingestion write the
        // native 64-bit view regardless of what builds this client (a low-severity review finding,
        // PR #85).
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

        // The registry *kind* is checked before the value is ever read, not inferred from the CLR
        // type GetValue happens to return (a Copilot review finding, PR #85). RegistryKey.GetValue
        // cannot tell a REG_SZ "1" apart from a REG_EXPAND_SZ "1" -- both surface as System.String
        // -- and a REG_QWORD surfaces as System.Int64, the same CLR type NormalizeRegistryValue
        // already accepts for the DWORD case. Without this check, an unsupported registry type
        // whose value happened to normalize to "0" or "1" would silently decide capture, contrary
        // to the documented REG_DWORD/REG_SZ-only contract -- the opposite of #60 scope 1's "never
        // let an unrecognised value fall through to the more permissive setting", applied one layer
        // lower than the value itself.
        RegistryValueKind kind;
        try
        {
            kind = subKey.GetValueKind(valueName);
        }
        catch (IOException)
        {
            // No value with this name exists under an otherwise-present key.
            return null;
        }

        if (!IsSupportedValueKind(kind))
        {
            // REG_QWORD, REG_EXPAND_SZ, REG_MULTI_SZ, REG_BINARY, REG_NONE, or anything else: never
            // even read the value itself (nothing to echo, per #62 constraint 2) -- the sentinel
            // always parses as Malformed.
            return UnsupportedValueKindSentinel;
        }

        object? raw = kind == RegistryValueKind.String
            ? subKey.GetValue(valueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames)
            : subKey.GetValue(valueName);
        return NormalizeRegistryValue(raw);
    }

    /// <summary>
    /// Whether <paramref name="kind"/> is one of the two registry types this store ever reads --
    /// the gate <see cref="DefaultRead"/> applies before calling <see cref="RegistryKey.GetValue(string?)"/>
    /// at all, kept as its own pure, testable predicate rather than inlined so the gate itself can
    /// be pinned without touching a real registry key.
    /// </summary>
    internal static bool IsSupportedValueKind(RegistryValueKind kind) =>
        kind is RegistryValueKind.DWord or RegistryValueKind.String;

    /// <summary>
    /// Projects one raw <see cref="RegistryKey.GetValue(string?)"/> result -- already kind-checked
    /// by <see cref="DefaultRead"/> to be exactly <see cref="RegistryValueKind.DWord"/> or
    /// <see cref="RegistryValueKind.String"/> -- to the string <see cref="CaptureAtLaunchPolicy.Parse"/>
    /// understands. A pure function, kept separate from <see cref="DefaultRead"/> so the
    /// DWORD/string equivalence is unit-testable without touching a real registry key.
    /// </summary>
    internal static string? NormalizeRegistryValue(object? raw) => raw switch
    {
        null => null,
        int i => i.ToString(CultureInfo.InvariantCulture),
        long l => l.ToString(CultureInfo.InvariantCulture),
        string s => s,
        // Not reachable from DefaultRead any more (RegistryValueKind is checked first), but this
        // pure function is tested and callable directly, so it still fails safe on any other CLR
        // shape rather than assuming one of the cases above: never echo it (#62 constraint 2) --
        // return a sentinel Parse always rejects as Malformed.
        _ => UnsupportedValueKindSentinel,
    };
}
