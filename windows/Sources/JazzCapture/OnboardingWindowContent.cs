using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// Which of the four real capture-at-launch states this profile is in, mirroring the
/// <em>effective</em> <see cref="EffectiveCaptureAtLaunch.Enabled"/> and
/// <see cref="EffectiveCaptureAtLaunch.Paused"/> -- the same two values
/// <see cref="CaptureStartupDecision.ShouldStart"/> decides startup with, not the raw persisted
/// <see cref="Settings.CaptureAtLaunchEnabled"/> alone. #76's product-owner decision: a
/// switch-started launch shows exactly the same three-state copy #75 already had, not a fourth
/// state; #60 (amendment 4 on the decisions comment) adds a genuinely new fourth state, described
/// on <see cref="PolicyUnreadable"/> below -- see
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

    /// <summary>
    /// <c>!effective.Enabled &amp;&amp; effective.Source is ManagedPolicy or InstallerPreference</c>.
    /// #60 amendment 4: neither policy rank can ever enforce "off" (a deployed <c>0</c> is "no
    /// opinion", not a decision -- see <see cref="CaptureAtLaunchPolicyValue"/>'s remarks), so the
    /// only way a policy rank ever "decides" <em>and</em> leaves capture off is a value that could
    /// not be parsed. This state is a misconfiguration notice, not an organisational decision --
    /// its copy must never say the organisation chose this, and must never send the user to a
    /// Settings checkbox that is disabled.
    /// </summary>
    PolicyUnreadable,
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
/// only local paths, modality flags, version/update text, and (since #78) fixed delivery prose --
/// nothing that identifies a device, a project, or a transport, though <see cref="Delivery"/> does
/// name Keboola as the recipient, the same non-secret way <c>windows/README.md</c> already names it
/// throughout. <c>CaptureDirectory</c> and
/// <c>QueueDirectory</c> are local <c>%LOCALAPPDATA%</c> paths that do embed the signed-in Windows
/// username, exactly like every other on-disk path this codebase already surfaces to the user (e.g.
/// the settings window); never log this record's <c>ToString()</c> without the same path
/// sanitization those other surfaces get. <see cref="Delivery"/> is a fixed literal that names no
/// endpoint, token, or bundle identifier, and adding one would be caught by
/// <c>DeliverySecretSafetyTests</c>.
/// </para>
/// <para>
/// #78 settles what #75 deferred: this type now says what leaves the machine and under what
/// condition, through <see cref="Delivery"/>. That member is a compile-time constant and no
/// credential, endpoint, or bundle identifier may ever be folded into it -- see
/// <see cref="DeliveryText"/>'s own remarks, and the paragraph above on why this record's
/// generated <c>ToString()</c> makes that a hard rule for every member.
/// </para>
/// </remarks>
public sealed record OnboardingWindowContent(
    CaptureAtLaunchDisclosure CaptureAtLaunch,
    string Headline,
    string CaptureAtLaunchDetail,
    string Delivery,
    string Controls,
    string Modalities,
    string Exclusions,
    string CaptureDirectory,
    string QueueDirectory,
    string Version,
    string UpdateStatus)
{
    /// <summary>
    /// #78. What leaves this machine, under what condition, in the words a person asking "does my
    /// screen leave this machine" would use. This is the replacement #75 deliberately deferred; see
    /// <see cref="Resolve(Settings)"/>'s remarks for what the deleted sentence got wrong.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>One fixed string, identical in every <see cref="CaptureAtLaunchDisclosure"/> state, and
    /// that is deliberate.</b> Delivery is gated on a provisioned, unexpired device bundle
    /// (<c>App.IsDeliveryTargetUsable</c>, <c>ScreenshotDeliveryPreparer.IsUsable</c>,
    /// <c>App.RefreshNarrationDelivery</c>), which has no relationship whatever to whether capture
    /// starts at launch -- <c>App.OnStartup</c>'s own comment states that credentials, device
    /// bundles and login registration are "intentionally absent from the decision". A per-state
    /// variant would imply a link that does not exist, including on a #60 policy-enforced machine.
    /// </para>
    /// <para>
    /// <b>It describes both conditions rather than reporting which one this machine is in, and that
    /// is also deliberate.</b> This window is modeless and is only re-resolved when something calls
    /// <c>App.ShowStatus</c> (see <see cref="OnboardingWindow.Refresh"/>), while provisioning arrives
    /// unattended through <c>App.ObserveProvisioningAsync</c> reading an Intune-dropped file -- with
    /// no user action to trigger a refresh. A live "nothing is being sent" would therefore keep
    /// asserting itself after delivery had already begun: the #75 defect class again, in its most
    /// reassuring and so most damaging direction. The notification-area menu is where the live
    /// per-path state is reported, and it is deliberately not duplicated here.
    /// </para>
    /// <para>
    /// <b>Every phrase here is load-bearing.</b> "in the background, including after a capture has
    /// ended" is true of the durable spools issue #48 shipped and must not become "immediately" or
    /// "as they happen", both of which are false (<c>EventSpool</c>'s own remarks, and narration's
    /// upload-then-emit hold in <c>CaptureEngine</c>). "the screenshots and narration audio you have
    /// turned on" tracks <c>Settings.ScreenshotsEnabled</c>/<c>NarrationEnabled</c> without branching
    /// on them, so it cannot overstate on a profile with either off. "before anything is written
    /// down" is stronger than #78's own "before anything is transmitted", and correct:
    /// <c>ApplicationDenylist</c> stops an excluded application's pixels from ever being rendered
    /// into memory, and typed-text redaction runs before the journal record. <b>No
    /// notification-area line is named</b>, because that set has already grown once (#84 added
    /// <c>Narration:</c>, which itself hides when it has nothing to say) and copy that enumerates it
    /// is copy that rots. <b>No endpoint, token or bundle identifier appears</b>, and none can: this
    /// is a compile-time constant and <see cref="Resolve(Settings, EffectiveCaptureAtLaunch)"/> never
    /// receives a credential of any kind.
    /// </para>
    /// <para>
    /// <b>Accepted, deliberate imprecision:</b> an expired bundle stops delivery, and this says
    /// "provisioned" rather than "provisioned and still valid". The error is in the safe direction
    /// -- the window claims data may be leaving when it is not, never the reverse -- and the tray's
    /// provisioning line already reports expiry in plain words. The same applies to a narration
    /// spool or event spool that could not be constructed: delivery of that modality stops, and
    /// this copy still says it is sent. It also applies to a bundle
    /// <c>DeviceBundleParser.ParseMvp</c> accepts with no <c>StreamEndpoint</c> at all (Storage
    /// credentials but no stream target): <c>App.RefreshDeliveryTargetCore</c> then never builds an
    /// event target, so the event record specifically is not sent even though screenshots/narration
    /// still can be from the same bundle -- one more modality-level exception in the same safe
    /// direction as the two above, and, per <c>windows/README.md</c>'s narration-delivery notes, not
    /// the profile this client is actually provisioned with today.
    /// </para>
    /// </remarks>
    private const string DeliveryText =
        "Once a device bundle has been provisioned for this machine, what Jazz Capture records "
        + "— the event record, plus the screenshots and narration audio you have turned on — "
        + "is sent to Keboola in the background, including after a capture has ended. Provisioning "
        + "is the only condition; there is no separate step you confirm first. Applications you "
        + "exclude are never recorded, credential fields are dropped, and sensitive typed text is "
        + "masked — always before anything is written down, so none of it is ever sent. With no "
        + "bundle, nothing recorded is sent anywhere, and either way capture still writes its "
        + "journal and local archives to this machine.";

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
    /// explicitly confirm an archive." -- was deleted by #75 and is now <em>replaced</em>, by #78,
    /// with <see cref="DeliveryText"/>. It was false for three reasons, not the two #75 recorded:
    /// the durable event spool drains to the Data Stream OTLP sink, <c>KeboolaFilesClient</c>
    /// uploads screenshot bytes, and -- since #84/#87 -- narration audio as well, all live,
    /// independent of any archive confirmation, from the moment a device credential is provisioned.
    /// A confirmed archive, meanwhile, is the one thing on this client that never leaves at all:
    /// nothing in the shipped host drains the delivery queue (see <c>windows/README.md</c>'s
    /// "Delivery architecture"). The replacement therefore states the real condition --
    /// provisioning -- and states explicitly that no confirmation step exists, so the deleted claim
    /// cannot be reconstructed by a reader.
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
    /// <para>
    /// <b>#60 does add a genuinely new, fourth state: <see cref="CaptureAtLaunchDisclosure.PolicyUnreadable"/>.</b>
    /// Unlike the switch-started case above, a managed policy or installer preference that decided
    /// the value <em>and</em> left it off cannot be folded into <c>NotConfigured</c>'s existing
    /// copy: that copy's own closing sentence -- "turn on ... in Settings" -- would be false the
    /// moment the checkbox it names is disabled, exactly the class of falsehood #75 was opened to
    /// fix, arriving through a different door. This is the rename the decisions comment on #60
    /// (amendment 4) directs: the plan's original <c>EnforcedOff</c> assumed a policy could enforce
    /// "off" as a decision; amendment 3 established that neither rank can, so the only way this
    /// state is ever reached is a value that failed to parse -- a misconfiguration, not anyone's
    /// choice, which is why the disclosure and its copy are named <c>PolicyUnreadable</c> instead.
    /// </para>
    /// </remarks>
    public static OnboardingWindowContent Resolve(Settings settings, EffectiveCaptureAtLaunch captureAtLaunch)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(captureAtLaunch);

        (CaptureAtLaunchDisclosure disclosure, string headline, string detail) =
            (captureAtLaunch.Enabled, captureAtLaunch.Paused, captureAtLaunch.Source) switch
            {
                (true, false, _) => (
                    CaptureAtLaunchDisclosure.StartsAtLaunch,
                    "Jazz Capture starts when Jazz opens",
                    "This client is configured to start capturing as soon as it opens, including at login, so a capture may be running right now. The notification-area menu shows whether it is, and stops it. Stopping also pauses the automatic start until you start a capture again."),
                (true, true, _) => (
                    CaptureAtLaunchDisclosure.Paused,
                    "Automatic capture is paused",
                    "This client is configured to start capturing when it opens, but you paused that by stopping a capture. It will not start on its own until you choose Start capture from the notification-area menu."),
                // #60 amendment 4: the only way a managed policy or installer preference ever
                // decides *and* leaves capture off is a value that failed to parse -- neither rank
                // can enforce "off" (see CaptureAtLaunchPolicyValue's remarks). This is a
                // misconfiguration notice, so its copy (verbatim from the decisions comment) must
                // not say "in Settings" (the checkbox is disabled), must not claim the organisation
                // decided anything, and must never contain the value that failed to parse.
                (false, _, CaptureAtLaunchSource.ManagedPolicy or CaptureAtLaunchSource.InstallerPreference) => (
                    CaptureAtLaunchDisclosure.PolicyUnreadable,
                    "Jazz Capture is not starting capture on its own",
                    "A setting deployed to this machine could not be read, so Jazz Capture is not starting capture automatically. You can still start a capture yourself from the notification-area menu. If this is unexpected, ask whoever manages this machine to check it."),
                _ => (
                    CaptureAtLaunchDisclosure.NotConfigured,
                    "Jazz Capture does not start by itself",
                    "This client is not configured to start capturing when it opens. Start a capture from the notification-area menu when you want one. To have it start on its own, turn on \"Start local capture automatically when Jazz opens\" in Settings."),
            };

        if (settings.ContinuousCapture && captureAtLaunch.Enabled)
        {
            detail = settings.CaptureAtLaunchPaused
                ? "A previous persistent stop still blocks automatic capture. Choose Resume capture from the notification-area menu to clear it."
                : captureAtLaunch.Paused
                    ? "Continuous capture is paused for this run. Choose Resume capture, or relaunch Jazz, to record again."
                    : "Continuous capture starts when Jazz opens. Pause capture stops this run; Resume capture or relaunching Jazz starts again. Mark session end commits locally and starts a fresh session without confirming an archive.";
        }

        string modalities =
            $"Screenshots: {(settings.ScreenshotsEnabled ? "enabled" : "off")}; narration: {(settings.NarrationEnabled ? "enabled" : "off")}";

        return new OnboardingWindowContent(
            disclosure,
            headline,
            detail,
            DeliveryText,
            ControlsText,
            modalities,
            string.Join(", ", settings.ExcludedApplications),
            settings.CaptureRoot,
            settings.QueueDirectory,
            BuildIdentity.ProducerVersion,
            UpdateStatusText);
    }
}
