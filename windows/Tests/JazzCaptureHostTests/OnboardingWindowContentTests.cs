using JazzCapture;
using JazzCaptureCore;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="OnboardingWindowContent"/> is the pure projection behind the "Status and
/// onboarding..." window -- the only testable surface of that window, since
/// <c>App.OnStartup</c>, <c>TrayHost</c>, and every WPF <c>Window</c> are untested in this
/// repository (xunit runs MTA; a WPF window would need a hand-rolled STA thread). These tests pin
/// #75's acceptance criteria: the tray item still shows current paths/modalities/version, the
/// text agrees with the effective capture-at-launch configuration, and the two now-false claims
/// the previous copy made can never come back silently.
/// </summary>
public sealed class OnboardingWindowContentTests
{
    // The fixed (false, true) pair here is what every pre-#78 test in this file implicitly assumes
    // -- it is not itself a claim that Delivery is independent of the modality flags. That
    // independence is asserted separately, and only where it is actually varied: see
    // EveryDisclosureStateCarriesTheSameDeliveryLine below, which calls the four-argument overload
    // with every (screenshotsEnabled, narrationEnabled) combination (Copilot review, PR #90: a
    // version of that test that only ever went through this two-argument overload could not have
    // caught a future Delivery projection that branched on either modality flag).
    private static Settings BaseSettings(bool captureAtLaunchEnabled, bool captureAtLaunchPaused) =>
        BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused, screenshotsEnabled: false, narrationEnabled: true);

    private static Settings BaseSettings(
        bool captureAtLaunchEnabled, bool captureAtLaunchPaused, bool screenshotsEnabled, bool narrationEnabled) => new()
    {
        CaptureRoot = @"C:\distinctive\capture-root",
        QueueDirectory = @"C:\distinctive\queue-directory",
        ExcludedApplications = new[] { "distinctive-app-1", "distinctive-app-2" },
        ScreenshotsEnabled = screenshotsEnabled,
        NarrationEnabled = narrationEnabled,
        CaptureAtLaunchEnabled = captureAtLaunchEnabled,
        CaptureAtLaunchPaused = captureAtLaunchPaused,
    };

    [Fact]
    public void PathsModalitiesExclusionsAndVersionComeFromTheSuppliedSettings()
    {
        Settings settings = BaseSettings(captureAtLaunchEnabled: false, captureAtLaunchPaused: false);

        OnboardingWindowContent content = OnboardingWindowContent.Resolve(settings);

        Assert.Equal(settings.CaptureRoot, content.CaptureDirectory);
        Assert.Equal(settings.QueueDirectory, content.QueueDirectory);
        Assert.Equal("distinctive-app-1, distinctive-app-2", content.Exclusions);
        Assert.Contains("Screenshots: off", content.Modalities);
        Assert.Contains("narration: enabled", content.Modalities);
        Assert.Equal(BuildIdentity.ProducerVersion, content.Version);

        // Controls and UpdateStatus are static across every state (unlike Headline/
        // CaptureAtLaunchDetail), and until now nothing asserted their actual content -- only the
        // negative regression tests below happened to include them in a DoesNotContain check.
        // A future edit could blank or reword either string and every existing test would still
        // pass. Pin them exactly, including the update-throttle wording carried over unchanged
        // from the original OnboardingWindow.xaml.
        Assert.Equal(
            "Screenshots, narration, exclusions, and permissions are controlled in Settings.",
            content.Controls);
        Assert.Equal(
            "Update status: checked only in the background; failures never affect capture.",
            content.UpdateStatus);
    }

    [Theory]
    [InlineData(false, false, CaptureAtLaunchDisclosure.NotConfigured,
        "Jazz Capture does not start by itself",
        "This client is not configured to start capturing when it opens. Start a capture from the notification-area menu when you want one. To have it start on its own, turn on \"Start local capture automatically when Jazz opens\" in Settings.")]
    [InlineData(true, false, CaptureAtLaunchDisclosure.StartsAtLaunch,
        "Jazz Capture starts when Jazz opens",
        "This client is configured to start capturing as soon as it opens, including at login, so a capture may be running right now. The notification-area menu shows whether it is, and stops it. Stopping also pauses the automatic start until you start a capture again.")]
    [InlineData(true, true, CaptureAtLaunchDisclosure.Paused,
        "Automatic capture is paused",
        "This client is configured to start capturing when it opens, but you paused that by stopping a capture. It will not start on its own until you choose Start capture from the notification-area menu.")]
    [InlineData(false, true, CaptureAtLaunchDisclosure.NotConfigured,
        "Jazz Capture does not start by itself",
        "This client is not configured to start capturing when it opens. Start a capture from the notification-area menu when you want one. To have it start on its own, turn on \"Start local capture automatically when Jazz opens\" in Settings.")]
    public void DisclosesTheEffectiveCaptureAtLaunchStateForEveryStoredCombination(
        bool captureAtLaunchEnabled,
        bool captureAtLaunchPaused,
        CaptureAtLaunchDisclosure expectedDisclosure,
        string expectedHeadline,
        string expectedDetail)
    {
        Settings settings = BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused);

        OnboardingWindowContent content = OnboardingWindowContent.Resolve(settings);

        Assert.Equal(expectedDisclosure, content.CaptureAtLaunch);
        Assert.Equal(expectedHeadline, content.Headline);
        Assert.Equal(expectedDetail, content.CaptureAtLaunchDetail);
    }

    /// <summary>
    /// Makes the copy structurally unable to drift from #69's runtime policy: for every reachable
    /// <c>(CaptureAtLaunchEnabled, CaptureAtLaunchPaused, launch switch)</c> triple, the window
    /// claims capture starts at launch if and only if
    /// <see cref="CaptureStartupDecision.ShouldStart"/> -- the actual startup-time decision, fed
    /// the same <em>effective</em> value the window itself resolves through -- would say yes,
    /// holding every other input at its most permissive.
    /// </summary>
    /// <remarks>
    /// #76 plan R3, the highest-severity trap in that issue: extended here (rather than left as
    /// the pre-#76 two-input version) precisely because a version of this test that only ever
    /// constructed <see cref="Settings"/> pairs could not have caught
    /// <see cref="OnboardingWindowContent"/> reading the raw persisted pair instead of the
    /// effective value -- the switch-alone case (<c>enabled: false</c>, <c>launchSwitch: true</c>)
    /// is exactly the combination that regression would have missed.
    /// </remarks>
    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, false, true)]
    [InlineData(false, true, false)]
    [InlineData(false, true, true)]
    [InlineData(true, false, false)]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    [InlineData(true, true, true)]
    public void DisclosureAgreesWithTheStartupDecisionThatActuallyRuns(
        bool captureAtLaunchEnabled, bool captureAtLaunchPaused, bool launchSwitch)
    {
        Settings settings = BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused);
        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(settings.Persisted, launchSwitch);

        OnboardingWindowContent content = OnboardingWindowContent.Resolve(settings, effective);

        bool shouldStart = CaptureStartupDecision.ShouldStart(
            true, true, true, effective.Enabled, effective.Paused);
        Assert.Equal(shouldStart, content.CaptureAtLaunch == CaptureAtLaunchDisclosure.StartsAtLaunch);
    }

    private static readonly CaptureAtLaunchPolicyValue[] AllPolicyValues =
    {
        CaptureAtLaunchPolicyValue.Absent,
        CaptureAtLaunchPolicyValue.Enabled,
        CaptureAtLaunchPolicyValue.Disabled,
        CaptureAtLaunchPolicyValue.Malformed,
    };

    public static IEnumerable<object[]> DisclosureCasesIncludingPolicy()
    {
        foreach (CaptureAtLaunchPolicyValue managed in AllPolicyValues)
        foreach (CaptureAtLaunchPolicyValue installer in AllPolicyValues)
        foreach (bool captureAtLaunchEnabled in new[] { false, true })
        foreach (bool captureAtLaunchPaused in new[] { false, true })
        foreach (bool launchSwitch in new[] { false, true })
        {
            yield return new object[]
            {
                managed, installer, captureAtLaunchEnabled, captureAtLaunchPaused, launchSwitch,
            };
        }
    }

    /// <summary>
    /// #60's own extension of the R3 guard directly above, over the same
    /// <c>(CaptureAtLaunchEnabled, CaptureAtLaunchPaused, launch switch)</c> space plus both new
    /// policy ranks (4 x 4 x 2 x 2 x 2 = 256 cases) -- named separately, per the plan's own
    /// instruction to "extend, do not delete" the existing test rather than widen its signature.
    /// A version of this guard limited to the pre-#60 inputs could not catch
    /// <see cref="OnboardingWindowContent"/> reading raw settings/switch instead of the effective
    /// value once a policy rank is in force, for exactly the reason the un-extended version could
    /// not catch the switch-alone case before it (see that test's own remarks).
    /// </summary>
    [Theory]
    [MemberData(nameof(DisclosureCasesIncludingPolicy))]
    public void DisclosureAgreesWithTheStartupDecisionThatActuallyRunsIncludingAManagedPolicy(
        CaptureAtLaunchPolicyValue managed,
        CaptureAtLaunchPolicyValue installer,
        bool captureAtLaunchEnabled,
        bool captureAtLaunchPaused,
        bool launchSwitch)
    {
        Settings settings = BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused);
        var policy = new CaptureAtLaunchPolicy(managed, installer);
        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(settings.Persisted, launchSwitch, policy);

        OnboardingWindowContent content = OnboardingWindowContent.Resolve(settings, effective);

        bool shouldStart = CaptureStartupDecision.ShouldStart(
            true, true, true, effective.Enabled, effective.Paused);
        Assert.Equal(shouldStart, content.CaptureAtLaunch == CaptureAtLaunchDisclosure.StartsAtLaunch);
    }

    /// <summary>
    /// #60 amendment 4's required assertions about the <c>PolicyUnreadable</c> copy, pinned
    /// directly. This state is reached only when a managed policy or installer preference decided
    /// the value and left it off -- which, per amendment 3, can only happen when that rank's value
    /// failed to parse, since neither rank can enforce "off" as a decision. Its copy must therefore
    /// never send the user to a Settings checkbox that is disabled (the #75-class falsehood #3.7
    /// exists to prevent) and never claim the organisation decided anything (nothing was decided; a
    /// value failed to parse).
    /// </summary>
    /// <remarks>
    /// Amendment 4's third requirement -- the copy must never contain the value that failed to
    /// parse -- is <b>not</b> meaningfully testable at this layer (a review finding on PR #85: an
    /// earlier version of this test planted a sentinel and asserted it absent, but
    /// <see cref="OnboardingWindowContent.Resolve(Settings, EffectiveCaptureAtLaunch)"/> never
    /// receives the raw registry value at all -- only <see cref="EffectiveCaptureAtLaunch"/>, whose
    /// <see cref="CaptureAtLaunchSource"/> carries no string -- so there is structurally nowhere for
    /// a value to appear in this copy, and an assertion that can never fail proves nothing). The
    /// real guard for that requirement lives at the one point a value could actually leak:
    /// <c>DeliverySecretSafetyTests.ThePolicyDetailNeverEchoesTheValueItRejected</c>, which plants a
    /// sentinel into <c>CaptureAtLaunchPolicyStore.Read</c>'s injected reader and asserts it absent
    /// from the resulting <c>Detail</c>.
    /// </remarks>
    [Fact]
    public void APolicyUnreadableDisclosureNeverTellsTheUserToTickTheSettingsCheckboxOrClaimsADecision()
    {
        Settings settings = BaseSettings(captureAtLaunchEnabled: false, captureAtLaunchPaused: false);
        var effective = new EffectiveCaptureAtLaunch(
            Enabled: false, Paused: false, Source: CaptureAtLaunchSource.ManagedPolicy);

        OnboardingWindowContent content = OnboardingWindowContent.Resolve(settings, effective);

        Assert.Equal(CaptureAtLaunchDisclosure.PolicyUnreadable, content.CaptureAtLaunch);
        Assert.DoesNotContain("in Settings", content.CaptureAtLaunchDetail, StringComparison.Ordinal);
        Assert.DoesNotContain("organisation", content.CaptureAtLaunchDetail, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("organization", content.CaptureAtLaunchDetail, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Same state, reached through the installer-preference rank instead of the managed
    /// one -- both ranks must render identically, since amendment 4's copy is about the
    /// misconfiguration, not about which rank carried it.</summary>
    [Fact]
    public void APolicyUnreadableDisclosureRendersTheSameWayFromEitherRank()
    {
        Settings settings = BaseSettings(captureAtLaunchEnabled: false, captureAtLaunchPaused: false);
        var fromManaged = new EffectiveCaptureAtLaunch(false, false, CaptureAtLaunchSource.ManagedPolicy);
        var fromInstaller = new EffectiveCaptureAtLaunch(false, false, CaptureAtLaunchSource.InstallerPreference);

        OnboardingWindowContent managedContent = OnboardingWindowContent.Resolve(settings, fromManaged);
        OnboardingWindowContent installerContent = OnboardingWindowContent.Resolve(settings, fromInstaller);

        Assert.Equal(CaptureAtLaunchDisclosure.PolicyUnreadable, managedContent.CaptureAtLaunch);
        Assert.Equal(CaptureAtLaunchDisclosure.PolicyUnreadable, installerContent.CaptureAtLaunch);
        Assert.Equal(managedContent.Headline, installerContent.Headline);
        Assert.Equal(managedContent.CaptureAtLaunchDetail, installerContent.CaptureAtLaunchDetail);
    }

    /// <summary>
    /// Regression guard for the issue's opening complaint: "Jazz does not start recording from
    /// installation, login, or this window" stopped being true the moment #69/#71 gave
    /// capture-at-launch a real "on" state. None of the three disclosure states may ever say this
    /// again, in whole or in the distinctive fragment that made it false.
    /// </summary>
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void NoLineAssertsThatJazzNeverRecordsAutomatically(
        bool captureAtLaunchEnabled, bool captureAtLaunchPaused)
    {
        string rendered = RenderAllText(BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused));

        Assert.DoesNotContain("does not start recording", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("from installation, login, or this window", rendered, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// #75's product-owner amendment (deferred to #78): the deleted sentence "Captures and local
    /// archives stay local until you explicitly confirm an archive" is false on this build --
    /// events stream to Data Stream OTLP, screenshots upload to Keboola Files, and (since #84)
    /// narration audio does too, live, independent of archive confirmation, once a device
    /// credential is provisioned.
    /// </summary>
    /// <remarks>
    /// #78 replaced that sentence rather than merely deleting it, so this guard now has a second
    /// job: the replacement states the real condition (provisioning) and states explicitly that no
    /// confirmation step exists, and none of the banned fragments below may reappear in it or
    /// anywhere else in the window. The confirmation-shaped bans matter more after #78 than before
    /// it, because the window now talks about delivery at all -- which is exactly where a
    /// well-meaning future edit would be tempted to reintroduce "until you confirm".
    /// </remarks>
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void NeverAssertsCapturedDataStaysLocalUntilAnArchiveIsConfirmed(
        bool captureAtLaunchEnabled, bool captureAtLaunchPaused)
    {
        string rendered = RenderAllText(BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused));

        Assert.DoesNotContain("stay local until", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("stays on this machine", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("never leaves", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("confirm an archive", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("archive confirmation", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("until you confirm", rendered, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("when you confirm", rendered, StringComparison.OrdinalIgnoreCase);
    }

    private const string ExpectedDelivery =
        "Once a device bundle has been provisioned for this machine, what Jazz Capture records "
        + "— the event record, plus the screenshots and narration audio you have turned on — "
        + "is sent to Keboola in the background, including after a capture has ended. Provisioning "
        + "is the only condition; there is no separate step you confirm first. Applications you "
        + "exclude are never recorded, credential fields are dropped, and sensitive typed text is "
        + "masked — always before anything is written down, so none of it is ever sent. With no "
        + "bundle, nothing recorded is sent anywhere, and either way capture still writes its "
        + "journal and local archives to this machine.";

    /// <summary>
    /// #78's copy, pinned verbatim. A substring guard is not enough here: the sentence that makes
    /// this copy true is the conditional one ("With no bundle, nothing recorded is sent anywhere"),
    /// and an edit that dropped the "With no bundle" qualifier would leave an unconditional claim
    /// that captured data does not leave the machine -- strictly worse than the #75 defect -- while
    /// passing every substring ban below. An exact pin makes any edit to this copy a deliberate
    /// act, exactly as the <c>Controls</c>/<c>UpdateStatus</c> pins already do.
    /// </summary>
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    [InlineData(false, true)]
    public void TheDeliveryLineSaysWhatLeavesTheMachineAndUnderWhatCondition(
        bool captureAtLaunchEnabled, bool captureAtLaunchPaused)
    {
        OnboardingWindowContent content = OnboardingWindowContent.Resolve(
            BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused));

        Assert.Equal(ExpectedDelivery, content.Delivery);
    }

    /// <summary>
    /// Delivery is gated on a provisioned device bundle, and #60's managed policy decides only
    /// whether capture <em>starts</em> -- <c>App.OnStartup</c> records that credentials and device
    /// bundles are "intentionally absent from the decision". So all four disclosure states, the
    /// <c>PolicyUnreadable</c> one included, must carry byte-identical delivery copy: a variant
    /// would assert a link between organisational policy and data egress that does not exist.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Each row also pins <em>which</em> disclosure state its inputs actually land on -- asserting
    /// only <c>Delivery</c> would let a future narrowing of the <c>PolicyUnreadable</c> arm in
    /// <c>OnboardingWindowContent.Resolve</c> silently collapse the two policy-rank rows below into
    /// <c>NotConfigured</c> while this test stayed green, no longer covering the fourth state its
    /// own summary claims to.
    /// </para>
    /// <para>
    /// Each row also carries its own, distinct pair of modality flags, covering all four
    /// (screenshotsEnabled, narrationEnabled) combinations across the six rows -- not the "both
    /// modality settings" claim in this test's own summary above (Copilot review, PR #90: every row
    /// previously went through the two-argument <c>BaseSettings</c> overload, which fixes
    /// <c>ScreenshotsEnabled: false</c>/<c>NarrationEnabled: true</c> -- so a future
    /// <c>DeliveryText</c> that accidentally branched on either flag would have passed every case
    /// here undetected).
    /// </para>
    /// </remarks>
    [Theory]
    [InlineData(CaptureAtLaunchSource.None, false, false, CaptureAtLaunchDisclosure.NotConfigured, false, false)]
    [InlineData(CaptureAtLaunchSource.UserSetting, true, false, CaptureAtLaunchDisclosure.StartsAtLaunch, true, false)]
    [InlineData(CaptureAtLaunchSource.UserSetting, true, true, CaptureAtLaunchDisclosure.Paused, false, true)]
    [InlineData(CaptureAtLaunchSource.ManagedPolicy, true, false, CaptureAtLaunchDisclosure.StartsAtLaunch, true, true)]
    [InlineData(CaptureAtLaunchSource.ManagedPolicy, false, false, CaptureAtLaunchDisclosure.PolicyUnreadable, false, false)]
    [InlineData(CaptureAtLaunchSource.InstallerPreference, false, false, CaptureAtLaunchDisclosure.PolicyUnreadable, true, true)]
    public void EveryDisclosureStateCarriesTheSameDeliveryLine(
        CaptureAtLaunchSource source,
        bool enabled,
        bool paused,
        CaptureAtLaunchDisclosure expectedDisclosure,
        bool screenshotsEnabled,
        bool narrationEnabled)
    {
        Settings settings = BaseSettings(
            captureAtLaunchEnabled: false, captureAtLaunchPaused: false, screenshotsEnabled, narrationEnabled);

        OnboardingWindowContent content = OnboardingWindowContent.Resolve(
            settings, new EffectiveCaptureAtLaunch(enabled, paused, source));

        Assert.Equal(expectedDisclosure, content.CaptureAtLaunch);
        Assert.Equal(ExpectedDelivery, content.Delivery);
    }

    /// <summary>
    /// #78 point 4, now concrete rather than hypothetical: #48 has landed in full (the durable
    /// event spool, and #84/#87's upload-then-emit narration hold). Events are written to disk on
    /// the capture path and sent later by a drain worker with no attempt budget; a narration event
    /// is withheld entirely until its clip's upload resolves. So no wording here may promise that
    /// anything leaves immediately or as it happens -- and, because all three paths have bounded,
    /// counted loss modes (eviction at 32 MiB or 48 hours, terminal 400/422, verification failure,
    /// admission refusal), none may promise that everything arrives either.
    /// </summary>
    /// <remarks>
    /// Scoped to <see cref="OnboardingWindowContent.Delivery"/> rather than going through
    /// <see cref="RenderAllText"/>, deliberately: the <c>StartsAtLaunch</c> detail legitimately
    /// contains "as soon as it opens", which is a true statement about capture starting and has
    /// nothing to do with delivery latency. A whole-window ban on "as soon as" would be a false
    /// positive against correct copy.
    /// </remarks>
    [Fact]
    public void TheDeliveryLinePromisesNeitherImmediateNorGuaranteedDelivery()
    {
        string delivery = OnboardingWindowContent
            .Resolve(BaseSettings(captureAtLaunchEnabled: false, captureAtLaunchPaused: false))
            .Delivery;

        Assert.DoesNotContain("immediately", delivery, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("as they happen", delivery, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("as soon as", delivery, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("right away", delivery, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("every event", delivery, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("always arrives", delivery, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The notification-area menu's delivery lines are not a fixed set: #84 added <c>Narration:</c>
    /// to <c>Provisioning:</c>/<c>Streaming:</c>/<c>Screenshots:</c>, and that one hides itself when
    /// it has nothing to say (<c>TrayHost.RefreshStatus</c>). #78's own suggested copy enumerated
    /// three of them and was already wrong when it was written. Copy that names any of them is copy
    /// that rots the next time a delivery path is added, so none may be named.
    /// </summary>
    [Fact]
    public void TheDeliveryLineNamesNoNotificationAreaMenuLine()
    {
        string delivery = OnboardingWindowContent
            .Resolve(BaseSettings(captureAtLaunchEnabled: false, captureAtLaunchPaused: false))
            .Delivery;

        Assert.DoesNotContain("Provisioning:", delivery, StringComparison.Ordinal);
        Assert.DoesNotContain("Streaming:", delivery, StringComparison.Ordinal);
        Assert.DoesNotContain("Screenshots:", delivery, StringComparison.Ordinal);
        Assert.DoesNotContain("Narration:", delivery, StringComparison.Ordinal);
    }

    /// <summary>
    /// R4 in the plan's own risks list: if <c>OnboardingWindowContent</c> were <c>internal</c>, or a
    /// property the XAML binds to were ever renamed without updating the markup, WPF's
    /// reflection-based binding would fail *silently* -- a blank label, no exception, no build
    /// error. Nothing else in this suite would catch that, since every other test goes through
    /// <see cref="OnboardingWindowContent"/> directly rather than through the XAML's own
    /// <c>{Binding X}</c> strings. This extracts every binding name the real, shipped XAML uses and
    /// asserts each one names a public instance property on the type WPF actually binds against.
    /// </summary>
    [Fact]
    public void EveryXamlBindingNamesAPublicPropertyOnTheContentType()
    {
        MatchCollection matches = Regex.Matches(ReadOnboardingWindowXamlText(), @"\{Binding\s+(\w+)\}");
        List<string> bindingNames = matches.Select(match => match.Groups[1].Value).Distinct().ToList();

        // A change to the XAML that stops binding anything, or a helper mistake that lets this
        // list go empty, would make every assertion below vacuously true -- so pin that the window
        // still has the number of bindings it is meant to (ten data-bound TextBlocks since #78
        // added Delivery; the "Version" label TextBlock and the Close button are not data-bound).
        Assert.Equal(10, bindingNames.Count);

        // And that the #78 line is actually one of them. The count alone cannot catch a Delivery
        // property added to the record with no matching {Binding} in the markup: the count stays
        // at the old value, every assertion here still passes, and the copy this issue exists to
        // ship never renders. Named explicitly for that reason.
        Assert.Contains("Delivery", bindingNames);

        // Asserted through the property NAMES, not Assert.Contains(properties, predicate): the
        // latter's failure message is just "filter not matched in collection" plus a PropertyInfo
        // dump -- it never names the offending binding. This fails with an actual expected/actual
        // string diff naming exactly which {Binding X} has no matching property.
        IEnumerable<string> publicInstancePropertyNames = typeof(OnboardingWindowContent)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(property => property.Name);
        foreach (string bindingName in bindingNames)
        {
            Assert.Contains(bindingName, publicInstancePropertyNames);
        }
    }

    /// <summary>
    /// The two regression tests above only ever exercised <see cref="OnboardingWindowContent"/>'s
    /// projection -- but both banned sentences originally lived as hardcoded literal
    /// <c>TextBlock</c> text directly in <c>OnboardingWindow.xaml</c>, not behind any binding. A
    /// literal reintroduced straight into the markup would satisfy every assertion above while
    /// still rendering to the user, so <see cref="RenderAllText"/> folds the raw XAML source text
    /// in too. This reads the file as plain text -- it does not construct, load, or otherwise touch
    /// a live WPF <c>Window</c>, so it needs no STA thread and does not conflict with this
    /// repository's WPF-host-untested policy (see the type summary above). Read fresh per call
    /// rather than cached in a static field: a static field's initializer runs once for the whole
    /// class, so a read failure there (an unexpected checkout layout, for instance) would take down
    /// every test in this class -- including the disclosure/path tests that have nothing to do with
    /// the XAML file -- via a <c>TypeInitializationException</c> rather than failing only the
    /// regression tests that actually need this text.
    /// </summary>
    private static string ReadOnboardingWindowXamlText([CallerFilePath] string testFilePath = "")
    {
        // This file lives at windows/Tests/JazzCaptureHostTests/OnboardingWindowContentTests.cs;
        // the window it tests lives at windows/Sources/JazzCapture/OnboardingWindow.xaml.
        // [CallerFilePath] resolves to the source tree at compile time, which is more robust
        // against build configuration/TFM changes than counting bin/obj output directories.
        string windowsRoot = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(testFilePath)!, "..", ".."));
        string xamlPath = Path.Combine(windowsRoot, "Sources", "JazzCapture", "OnboardingWindow.xaml");
        return File.ReadAllText(xamlPath);
    }

    private static string RenderAllText(Settings settings)
    {
        OnboardingWindowContent content = OnboardingWindowContent.Resolve(settings);
        return string.Join(
            " | ",
            content.Headline,
            content.CaptureAtLaunchDetail,
            content.Delivery,
            content.Controls,
            content.Modalities,
            content.Exclusions,
            content.CaptureDirectory,
            content.QueueDirectory,
            content.Version,
            content.UpdateStatus,
            ReadOnboardingWindowXamlText());
    }
}
