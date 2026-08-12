using System.IO;
using JazzCaptureCore;
using JazzCaptureCore.Audio;

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
    /// The exclusions a profile starts with, before the user has saved any of their own. They cover
    /// the common Windows credential surfaces and the best-known password managers, and each is a
    /// short fragment that <see cref="ApplicationDenylist"/> matches anywhere inside the resolved
    /// identity — so <c>1password</c> excludes that application wherever it happens to be installed.
    /// </summary>
    /// <remarks>
    /// These apply only to a profile with no settings file. Once the user has saved an exclusion
    /// list, that list is the whole truth and these are never consulted again; see
    /// <see cref="HostSettingsStore"/>.
    /// </remarks>
    public static readonly IReadOnlyList<string> SeedExcludedApplications = new[]
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

    /// <summary>Full path of the document the user's preferences are persisted in.</summary>
    public string SettingsFilePath { get; init; } =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Jazz",
            HostSettingsStore.FileName);

    /// <summary>
    /// Applications the policy never records, as the user has configured them. Matched
    /// case-insensitively as substrings of the resolved application identity.
    /// </summary>
    /// <remarks>
    /// Frozen into the capture policy when a capture starts, and recorded in the archive as
    /// <c>capturePolicy.excludedApplications</c>. Editing this between captures is the point of the
    /// settings window; editing it during one would make that declaration a lie, so the window
    /// refuses.
    /// </remarks>
    public IReadOnlyList<string> ExcludedApplications { get; init; } =
        ApplicationDenylist.Normalize(SeedExcludedApplications);

    /// <summary>
    /// Whether each resolved click is briefly outlined on screen, so the user can see what the
    /// client recorded. Off by default; the settings window turns it on.
    /// </summary>
    public bool HighlightClicks { get; init; } = HostSettingsStore.DefaultHighlightClicks;

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

    /// <summary>
    /// Whether a completed click, drag or context menu captures the focused window.
    /// </summary>
    /// <remarks>
    /// On by default: a process recording without pictures is a list of control names, and the whole
    /// point of the archive is that someone can see what the user saw. The tray menu turns it off for
    /// the next capture, which then declares no <c>screenshots</c> modality and reports
    /// <c>screen.capture</c> as disabled by policy rather than failed.
    /// </remarks>
    public bool ScreenshotsEnabled { get; init; } = true;

    /// <summary>
    /// Whether the microphone records think-aloud narration for the length of each declared label.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Off until the user says otherwise, then remembered.</b> The default is off because a
    /// microphone is a larger consent step than a screenshot — a recording of a room can contain a
    /// colleague or a phone call nobody in it agreed to — and because Windows, unlike macOS, puts up
    /// no per-application microphone prompt for the operating system to ask on the client's behalf.
    /// See <see cref="HostSettingsStore.DefaultNarrationEnabled"/>. But that argument is about the
    /// first answer, not about every answer: once the user has decided, re-asking each launch buys
    /// nothing and costs friction, so the choice is persisted alongside the exclusion list, as the
    /// macOS client persists its own.
    /// </para>
    /// <para>
    /// Like <see cref="ScreenshotsEnabled"/>, this is read once when a capture starts and frozen into
    /// the policy the archive declares; the tray refuses to change it mid-recording.
    /// </para>
    /// </remarks>
    public bool NarrationEnabled { get; init; } = HostSettingsStore.DefaultNarrationEnabled;

    /// <summary>
    /// Largest audio payload one narration clip may reach, in bytes of the archived 16 kHz mono PCM.
    /// </summary>
    /// <remarks>
    /// The bound exists because a label is a task step by intent and an open-ended interval by
    /// mechanism: nothing stops a user from declaring one and going to lunch, and linear PCM
    /// accumulates at <see cref="NarrationWave.BytesPerSecond"/> bytes a second whether or not anyone
    /// is speaking. Half an hour is far longer than any think-aloud step and still an archive
    /// artifact of a size a machine can hold. Reaching it stops the recorder rather than the disk:
    /// the clip is sealed with what it has and its declared interval ends where its audio does.
    /// </remarks>
    public int NarrationClipByteCeiling { get; init; } = NarrationWave.BytesPerSecond * 60 * 30;

    /// <summary>The subset of this configuration that is written to disk and survives a restart.</summary>
    public HostSettings Persisted => new(ExcludedApplications, HighlightClicks, NarrationEnabled);

    /// <summary>Returns a copy with the persisted preferences replaced.</summary>
    /// <param name="persisted">The preferences as loaded from, or about to be written to, disk.</param>
    public Settings With(HostSettings persisted)
    {
        ArgumentNullException.ThrowIfNull(persisted);

        return this with
        {
            ExcludedApplications = persisted.ExcludedApplications,
            HighlightClicks = persisted.HighlightClicks,
            NarrationEnabled = persisted.NarrationEnabled,
        };
    }

    /// <summary>
    /// Builds the host configuration for this run: the compiled-in defaults, with the user's saved
    /// preferences applied over them.
    /// </summary>
    /// <returns>The configuration, and how its preferences were obtained.</returns>
    public static (Settings Settings, HostSettingsLoad Load) Load()
    {
        var defaults = new Settings();
        HostSettingsLoad load = HostSettingsStore.Load(
            defaults.SettingsFilePath,
            SeedExcludedApplications);
        return (defaults.With(load.Settings), load);
    }
}
