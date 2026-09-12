using System.Reflection;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// The plan's R1 -- "the in-memory fold" -- is the highest-likelihood way to ship #76 wrong:
/// <c>settings with { CaptureAtLaunchEnabled = true }</c> compiles, passes every functional test,
/// and silently persists a process-scoped launch switch into <c>%LOCALAPPDATA%\Jazz\settings.json</c>
/// the next time any tray action saves preferences. These tests pin, structurally, that the
/// switch can never enter the persisted document: <see cref="HostSettings"/> exposes no member it
/// could occupy, and serializing a profile's persisted settings never reflects
/// <see cref="LaunchOptions.CaptureAtLaunch"/>, regardless of its value.
/// </summary>
public sealed class LaunchSwitchPersistenceTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void TheLaunchSwitchNeverEntersThePersistedDocument(bool launchSwitchPresent)
    {
        LaunchOptions launch = LaunchOptions.Parse(
            launchSwitchPresent ? new[] { LaunchOptions.CaptureAtLaunchSwitch } : Array.Empty<string>());
        var settings = new Settings(); // CaptureAtLaunchEnabled defaults off, as an unmanaged profile

        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(settings.Persisted, launch.CaptureAtLaunch);

        // Sanity: the switch really did take effect on the *effective* decision, so a passing
        // assertion below is not vacuous because the switch never turned anything on.
        Assert.Equal(launchSwitchPresent, effective.Enabled);

        // But the persisted document -- what actually reaches disk -- must reflect only the user
        // setting, never the switch, whichever way the switch went.
        string serialized = HostSettingsStore.Serialize(settings.Persisted);
        Assert.Contains("\"captureAtLaunchEnabled\":false", serialized, StringComparison.Ordinal);
    }

    [Fact]
    public void HostSettingsExposesNoMemberTheLaunchSwitchCouldOccupy()
    {
        // A reflection pin, not just a naming convention: if a future change ever added a member
        // shaped like LaunchOptions.CaptureAtLaunch to HostSettings, this fails loudly instead of
        // waiting for someone to notice the persisted document grew a new key.
        string[] members = typeof(HostSettings)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(property => property.Name)
            .ToArray();

        Assert.Equal(
            new[]
            {
                nameof(HostSettings.ExcludedApplications),
                nameof(HostSettings.HighlightClicks),
                nameof(HostSettings.NarrationEnabled),
                nameof(HostSettings.ScreenshotsEnabled),
                nameof(HostSettings.CaptureAtLaunchEnabled),
                nameof(HostSettings.CaptureAtLaunchPaused),
            },
            members);
    }
}
