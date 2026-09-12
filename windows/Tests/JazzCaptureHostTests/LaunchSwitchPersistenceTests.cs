using System.Reflection;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// The plan's R1 -- "the in-memory fold" -- is the highest-likelihood way to ship #76 wrong:
/// <c>settings with { CaptureAtLaunchEnabled = true }</c> compiles and passes every functional
/// test, yet silently persists a process-scoped launch switch into
/// <c>%LOCALAPPDATA%\Jazz\settings.json</c> the next time any tray action saves preferences.
/// </summary>
/// <remarks>
/// <b>What this class does and does not guard.</b> The fold itself would live in
/// <c>App.OnStartup</c>, which -- like every other WPF-host code path in this repository -- has
/// no unit test (<c>ci.yml:46-47</c>); nothing here can exercise that call site directly, and
/// nothing in this class can catch a fold written there. What these tests actually pin: that
/// <see cref="HostSettings"/> exposes no member shaped like <see cref="LaunchOptions.CaptureAtLaunch"/>
/// for a fold to write into (a reflection guard, below), and that serializing a profile's
/// persisted settings never reflects the switch regardless of its value (in this specific,
/// unmanaged-profile scenario). Neither of these guards against <c>EffectiveCaptureAtLaunch.Resolve</c>
/// itself somehow mutating what it is given -- it is a pure record-returning method with nothing
/// to mutate by construction, so there is no meaningful additional guard to add against it. The
/// remaining defence against R1 is <c>App.xaml.cs</c> code review and the interactive evidence in
/// the plan's §7, not a unit test.
/// </remarks>
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

        // The persisted document -- what actually reaches disk -- must reflect only the user
        // setting, never the switch, whichever way the switch went.
        string serialized = HostSettingsStore.Serialize(settings.Persisted);
        Assert.Contains("\"captureAtLaunchEnabled\":false", serialized, StringComparison.Ordinal);
    }

    [Fact]
    public void HostSettingsExposesNoMemberTheLaunchSwitchCouldOccupy()
    {
        // A reflection pin, not just a naming convention: if a future change ever added a member
        // shaped like LaunchOptions.CaptureAtLaunch to HostSettings, this fails loudly instead of
        // waiting for someone to notice the persisted document grew a new key. Compared as a set,
        // not an ordered sequence -- Type.GetProperties()'s return order is not documented or
        // guaranteed by .NET, so asserting a specific order would be pinning an implementation
        // detail this test has no business caring about.
        HashSet<string> members = typeof(HostSettings)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(property => property.Name)
            .ToHashSet();

        Assert.Equal(
            new HashSet<string>
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
