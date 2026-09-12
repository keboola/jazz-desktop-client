using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// Which of the three real capture-at-launch states this profile is in, mirroring the
/// <em>effective</em> <see cref="EffectiveCaptureAtLaunch.Enabled"/> and
/// <see cref="EffectiveCaptureAtLaunch.Paused"/> -- the same two values
/// <see cref="CaptureStartupDecision.ShouldStart"/> decides startup with, not the raw persisted
/// <see cref="Settings.CaptureAtLaunchEnabled"/> alone. #76's product-owner decision: a
/// switch-started launch shows exactly this same three-state copy, not a fourth state -- see
/// <see cref="Resolve(Settings, EffectiveCaptureAtLaunch)"/>'s remarks.
/// </summary>
public enum CaptureAtLaunchDisclosure
{
    /// <summary>Not configured to start automatically: <c>effective.Enabled == false</c>,
    /// whatever <c>effective.Paused</c> holds.</summary>
    NotConfigured,

    /// <summary><c>effective.Enabled &amp;&amp; !effective.Paused</c>.</summary>
    StartsAtLaunch,

    /// <summary><c>effective.Enabled &amp;&amp; effective.Paused</c> -- configured to start,
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
/// <c>(EffectiveCaptureAtLaunch.Enabled, EffectiveCaptureAtLaunch.Paused, launch switch)</c>, so
/// this copy cannot silently drift from the runtime policy that actually decides whether capture
/// starts -- including on a profile the #76 launch switch alone configured.
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
    /// Three states, not two: <c>(effective.Enabled, effective.Paused)</c> has three meaningful
    /// runtime values, and <see cref="CaptureStartupDecision.ShouldStart"/> returns
    /// <see langword="false"/> for <c>Enabled &amp;&amp; Paused</c> -- exactly the state
    /// <c>TrayHost.StopCapture</c> puts a profile into after every user stop of an
    /// automatically-started capture. Two states would tell such a user "starts when Jazz opens"
    /// when their very next launch will be idle. <c>(false, true)</c> maps to
    /// <see cref="CaptureAtLaunchDisclosure.NotConfigured"/>, matching <c>ShouldStart</c>.
    /// </para>
    /// <para>
    /// #76: <c>(effective.Enabled: false, effective.Paused: true)</c> is reachable without
    /// hand-editing <c>settings.json</c> as soon as a switch-only profile's Stop is recorded --
    /// <c>CaptureAtLaunchPreference.AfterSuccessfulUserStop</c> now pauses against the effective
    /// value, not the persisted <c>CaptureAtLaunchEnabled</c> alone -- but the mapping above still
    /// holds: <c>ShouldStart</c> is false for it either way, so it still reads as
    /// <see cref="CaptureAtLaunchDisclosure.NotConfigured"/>, and a downgraded build that has never
    /// heard of the launch switch reads the same document as idle.
    /// </para>
    /// <para>
    /// This delegates to <see cref="Resolve(Settings, EffectiveCaptureAtLaunch)"/> with no launch
    /// switch, so every caller that predates #76 -- including every existing test -- sees exactly
    /// the copy it always saw.
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
    /// <para>
    /// <b>Deliberately <see langword="internal"/>, not <see langword="public"/>.</b> This is the
    /// R3-unsafe form: it can only ever see "no launch switch", so passing raw
    /// <c>Settings</c> through it from a live code path would reintroduce the #75 defect the
    /// two-argument overload exists to prevent. No production caller uses it -- only tests, via
    /// <c>InternalsVisibleTo</c> -- and it stays that way.
    /// </para>
    /// </remarks>
    internal static OnboardingWindowContent Resolve(Settings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return Resolve(settings, EffectiveCaptureAtLaunch.Resolve(settings.Persisted, launchSwitchPresent: false));
    }

    /// <summary>
    /// Projects <paramref name="settings"/> to the window's text, reading the capture-at-launch
    /// disclosure from <paramref name="captureAtLaunch"/> -- the same effective value
    /// <c>CaptureStartupGate</c> evaluated at startup -- rather than the raw persisted
    /// <see cref="Settings.CaptureAtLaunchEnabled"/>/<see cref="Settings.CaptureAtLaunchPaused"/>
    /// pair.
    /// </summary>
    /// <remarks>
    /// This is #76's fix for the plan's R3: a switch-started launch has
    /// <c>settings.CaptureAtLaunchEnabled == false</c> (the switch is process-scoped and never
    /// persisted) but <c>captureAtLaunch.Enabled == true</c>. Reading the raw settings pair here
    /// would render "Jazz Capture does not start by itself" on a machine that is recording --
    /// reintroducing precisely the defect #75 was opened to fix. #76's product-owner decision is
    /// to reuse this existing three-state copy verbatim for a switch-started launch rather than add
    /// a fourth state: the headline and detail strings below are unchanged from #75, and only the
    /// switch expression's inputs move from the persisted pair to the effective one.
    /// </remarks>
    public static OnboardingWindowContent Resolve(Settings settings, EffectiveCaptureAtLaunch captureAtLaunch)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(captureAtLaunch);

        (CaptureAtLaunchDisclosure disclosure, string headline, string detail) =
            (captureAtLaunch.Enabled, captureAtLaunch.Paused) switch
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
