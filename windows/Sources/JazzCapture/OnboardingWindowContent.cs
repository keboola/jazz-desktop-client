namespace JazzCapture;

/// <summary>
/// Which of the three real capture-at-launch states this profile is in, mirroring
/// <see cref="Settings.CaptureAtLaunchEnabled"/> and <see cref="Settings.CaptureAtLaunchPaused"/>.
/// </summary>
public enum CaptureAtLaunchDisclosure
{
    /// <summary>Not configured to start automatically: <c>CaptureAtLaunchEnabled == false</c>,
    /// whatever <c>CaptureAtLaunchPaused</c> holds.</summary>
    NotConfigured,

    /// <summary><c>CaptureAtLaunchEnabled &amp;&amp; !CaptureAtLaunchPaused</c>.</summary>
    StartsAtLaunch,

    /// <summary><c>CaptureAtLaunchEnabled &amp;&amp; CaptureAtLaunchPaused</c> -- configured to start,
    /// but paused by a user stopping a prior automatically-started capture.</summary>
    Paused,
}

/// <summary>
/// A pure projection of <see cref="Settings"/> to the "Status and onboarding..." window's text.
/// Modelled on <see cref="CaptureStatusPresentation.Resolve"/> and
/// <c>ScreenshotDeliveryPresentation</c>: a plain data-in, data-out mapping with no I/O, so it is
/// unit-testable without a WPF host.
/// </summary>
/// <remarks>
/// <para>
/// This type is host-side (<c>JazzCapture</c>), not <c>JazzCaptureCore</c>, on purpose --
/// AGENTS.md requires Core to stay portable and OS-free, and this is Windows tray copy, not
/// contract material.
/// </para>
/// <para>
/// <see cref="CaptureAtLaunch"/> is pinned by test to agree with
/// <see cref="CaptureStartupDecision.ShouldStart"/> for every reachable combination of
/// <c>(CaptureAtLaunchEnabled, CaptureAtLaunchPaused)</c>, so this copy cannot silently drift from
/// the runtime policy that actually decides whether capture starts.
/// </para>
/// <para>
/// It must be <c>public</c>, not <c>internal</c>: WPF's reflection-based data binding cannot see
/// properties on a non-public type, and the failure is silent -- the window would render blank
/// labels with no exception and no build error.
/// </para>
/// <para>
/// As a positional record its compiler-generated <c>ToString()</c> prints every member, so no
/// credential, token, endpoint, or delivery-bundle detail may ever be added here. This type carries
/// only local paths, modality flags, and version/update text -- nothing that identifies a device,
/// a project, or a transport. <c>CaptureDirectory</c> and <c>QueueDirectory</c> are local
/// <c>%LOCALAPPDATA%</c> paths that do embed the signed-in Windows username, exactly like every
/// other on-disk path this codebase already surfaces to the user (e.g. the settings window); never
/// log this record's <c>ToString()</c> without the same path sanitization those other surfaces get.
/// </para>
/// <para>
/// #75's product-owner decision (deferred to #78): this type deliberately says nothing about
/// where captured data goes. It has no <c>Delivery</c> member. See <see cref="Resolve"/>'s remarks
/// for why.
/// </para>
/// </remarks>
public sealed record OnboardingWindowContent(
    CaptureAtLaunchDisclosure CaptureAtLaunch,
    string Headline,
    string CaptureAtLaunchDetail,
    string Controls,
    string Modalities,
    string Exclusions,
    string CaptureDirectory,
    string QueueDirectory,
    string Version,
    string UpdateStatus)
{
    private const string ControlsText =
        "Screenshots, narration, exclusions, and permissions are controlled in Settings.";

    private const string UpdateStatusText =
        "Update status: checked only in the background; failures never affect capture.";

    /// <summary>
    /// Projects <paramref name="settings"/> to the window's text.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Three states, not two: <c>(CaptureAtLaunchEnabled, CaptureAtLaunchPaused)</c> has three
    /// meaningful runtime values, and <see cref="CaptureStartupDecision.ShouldStart"/> returns
    /// <see langword="false"/> for <c>Enabled &amp;&amp; Paused</c> -- exactly the state
    /// <c>TrayHost.StopCapture</c> puts a profile into after every user stop of an
    /// automatically-started capture. Two states would tell such a user "starts when Jazz opens"
    /// when their very next launch will be idle. <c>(false, true)</c> is reachable only by
    /// hand-editing <c>settings.json</c> -- <c>SettingsWindow</c> clears the pause the moment the
    /// checkbox is unchecked -- and maps to <see cref="CaptureAtLaunchDisclosure.NotConfigured"/>,
    /// matching <c>ShouldStart</c>.
    /// </para>
    /// <para>
    /// The sentence this used to carry -- "Captures and local archives stay local until you
    /// explicitly confirm an archive." -- is deleted, not replaced. It was false on this build for
    /// the same reason the old capture-at-launch line was false: <c>MvpStreamDispatcher</c> and
    /// <c>KeboolaFilesClient</c> already stream events and upload screenshots live, independent of
    /// any archive confirmation, the moment a device credential is provisioned. Telling a user
    /// their data stays on the machine while it is being transmitted would be a strictly worse
    /// defect than the one #75 exists to fix. The correct replacement wording is a product decision
    /// deliberately left to #78 rather than settled inside a PR about a startup window; until then
    /// this window says nothing about where captured data goes, which is incomplete but true.
    /// </para>
    /// </remarks>
    public static OnboardingWindowContent Resolve(Settings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        (CaptureAtLaunchDisclosure disclosure, string headline, string detail) =
            (settings.CaptureAtLaunchEnabled, settings.CaptureAtLaunchPaused) switch
            {
                (true, false) => (
                    CaptureAtLaunchDisclosure.StartsAtLaunch,
                    "Jazz Capture starts when Jazz opens",
                    "This client is configured to start capturing as soon as it opens, including at login, so a capture may be running right now. The notification-area menu shows whether it is, and stops it. Stopping also pauses the automatic start until you start a capture again."),
                (true, true) => (
                    CaptureAtLaunchDisclosure.Paused,
                    "Automatic capture is paused",
                    "This client is configured to start capturing when it opens, but you paused that by stopping a capture. It will not start on its own until you choose Start capture from the notification-area menu."),
                _ => (
                    CaptureAtLaunchDisclosure.NotConfigured,
                    "Jazz Capture does not start by itself",
                    "This client is not configured to start capturing when it opens. Start a capture from the notification-area menu when you want one. To have it start on its own, turn on \"Start local capture automatically when Jazz opens\" in Settings."),
            };

        string modalities =
            $"Screenshots: {(settings.ScreenshotsEnabled ? "enabled" : "off")}; narration: {(settings.NarrationEnabled ? "enabled" : "off")}";

        return new OnboardingWindowContent(
            disclosure,
            headline,
            detail,
            ControlsText,
            modalities,
            string.Join(", ", settings.ExcludedApplications),
            settings.CaptureRoot,
            settings.QueueDirectory,
            BuildIdentity.ProducerVersion,
            UpdateStatusText);
    }
}
