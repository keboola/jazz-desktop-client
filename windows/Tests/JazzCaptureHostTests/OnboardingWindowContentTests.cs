using JazzCapture;
using JazzCaptureCore;
using System.IO;
using System.Runtime.CompilerServices;

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
    private static Settings BaseSettings(bool captureAtLaunchEnabled, bool captureAtLaunchPaused) => new()
    {
        CaptureRoot = @"C:\distinctive\capture-root",
        QueueDirectory = @"C:\distinctive\queue-directory",
        ExcludedApplications = new[] { "distinctive-app-1", "distinctive-app-2" },
        ScreenshotsEnabled = false,
        NarrationEnabled = true,
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
    /// <c>(CaptureAtLaunchEnabled, CaptureAtLaunchPaused)</c> pair, the window claims capture starts
    /// at launch if and only if <see cref="CaptureStartupDecision.ShouldStart"/> -- the actual
    /// startup-time decision -- would say yes, holding every other input at its most permissive.
    /// </summary>
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    [InlineData(false, true)]
    public void DisclosureAgreesWithTheStartupDecisionThatActuallyRuns(
        bool captureAtLaunchEnabled, bool captureAtLaunchPaused)
    {
        Settings settings = BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused);

        OnboardingWindowContent content = OnboardingWindowContent.Resolve(settings);

        bool shouldStart = CaptureStartupDecision.ShouldStart(
            true, true, true, captureAtLaunchEnabled, captureAtLaunchPaused);
        Assert.Equal(shouldStart, content.CaptureAtLaunch == CaptureAtLaunchDisclosure.StartsAtLaunch);
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
    /// events stream to Data Stream OTLP and screenshots upload to Keboola Files live, independent
    /// of archive confirmation, once a device credential is provisioned. It is removed, not
    /// replaced, so this guards the deletion rather than a replacement: the old sentence must never
    /// silently reappear before #78 settles the correct wording.
    /// </summary>
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void NeverAssertsCapturedDataStaysLocalUntilAnArchiveIsConfirmed(
        bool captureAtLaunchEnabled, bool captureAtLaunchPaused)
    {
        string rendered = RenderAllText(BaseSettings(captureAtLaunchEnabled, captureAtLaunchPaused));

        Assert.DoesNotContain("stay local until", rendered, StringComparison.OrdinalIgnoreCase);
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
