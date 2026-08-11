using System.IO;

namespace JazzCapture;

/// <summary>
/// The frozen host configuration: everything the tray host and the capture pipeline need that is not
/// a compile-time constant of the wire contract. Values live here rather than being scattered as
/// literals through the capture code, so a later settings UI (out of MVP scope) can populate the same
/// record.
/// </summary>
/// <remarks>
/// The denylist seeds the applications a passive whole-desktop capture must never record — password
/// managers and the OS credential surfaces. It is expressed as case-insensitive substrings matched
/// against the resolved application identity (AUMID or executable path).
/// </remarks>
public sealed record Settings
{
    /// <summary>Directory that receives exported <c>.jazz-archive</c> containers for delivery.</summary>
    public string QueueDirectory { get; init; } =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Jazz",
            "queue");

    /// <summary>Directory that holds the capture root: journal claim, archives, review decisions.</summary>
    public string CaptureRoot { get; init; } =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Jazz",
            "captures");

    /// <summary>The captured user, projected as <c>enduser.id</c>.</summary>
    public string User { get; init; } = Environment.UserName;

    /// <summary>The recording machine, projected as <c>host.name</c>.</summary>
    public string InstanceName { get; init; } = Environment.MachineName;

    /// <summary>Version of this capture client, written to the archive manifest.</summary>
    public string ProducerVersion { get; init; } = "0.1.0-mvp";

    /// <summary>
    /// Applications the policy never records. Seeds cover the common Windows credential surfaces;
    /// matched case-insensitively as substrings of the resolved application identity.
    /// </summary>
    public IReadOnlyList<string> ExcludedApplications { get; init; } = new[]
    {
        "1password",
        "bitwarden",
        "keepass",
        "lastpass",
        "dashlane",
        "credentialuibroker", // the Windows credential prompt host
        "consent.exe", // UAC consent UI
        "logonui.exe",
    };

    /// <summary>Shortest interval between two emitted scroll samples.</summary>
    public TimeSpan ScrollThrottle { get; init; } = TimeSpan.FromMilliseconds(800);

    /// <summary>How long the resolver waits for one UI Automation round trip before giving up.</summary>
    public TimeSpan UiaTimeout { get; init; } = TimeSpan.FromMilliseconds(300);

    /// <summary>
    /// Interval of the capability re-poll and hook watchdog. A hook that has not reported liveness
    /// within this window while input is known to be occurring is re-armed.
    /// </summary>
    public TimeSpan HeartbeatInterval { get; init; } = TimeSpan.FromSeconds(3);

    /// <summary>Longest clipboard payload read for a paste, before sanitization to 200 characters.</summary>
    public int MaxClipboardChars { get; init; } = 4000;

    /// <summary>The MVP records neither screenshots nor narration.</summary>
    public bool ScreenshotsEnabled { get; init; }
}
