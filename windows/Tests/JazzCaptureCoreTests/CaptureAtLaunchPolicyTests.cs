using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// <see cref="CaptureAtLaunchPolicy.Parse"/> is the single place a raw registry string becomes one
/// of the four <see cref="CaptureAtLaunchPolicyValue"/> members #60 adds. These tests pin its exact
/// spelling discipline (one spelling each, matching <see cref="LaunchOptions"/>'s own), that an
/// unrecognised value is <see cref="CaptureAtLaunchPolicyValue.Malformed"/> and never anything more
/// permissive (#60 scope 1), and -- the amendment 3 consequence -- that a malformed value at the
/// managed-policy rank is the only thing that can ever force capture off, outranking every lower
/// layer even when both are on.
/// </summary>
public sealed class CaptureAtLaunchPolicyTests
{
    private static HostSettings Settings(bool enabled, bool paused) =>
        new(Array.Empty<string>(), false, false, true, CaptureAtLaunchEnabled: enabled, CaptureAtLaunchPaused: paused);

    [Fact]
    public void ParseMapsAnAbsentValueToAbsent()
    {
        Assert.Equal(CaptureAtLaunchPolicyValue.Absent, CaptureAtLaunchPolicy.Parse(null));
    }

    [Theory]
    [InlineData("1")]
    [InlineData(" 1")]
    [InlineData("1 ")]
    [InlineData(" 1 ")]
    public void ParseMapsOneToEnabledAfterTrimming(string raw)
    {
        Assert.Equal(CaptureAtLaunchPolicyValue.Enabled, CaptureAtLaunchPolicy.Parse(raw));
    }

    [Theory]
    [InlineData("0")]
    [InlineData(" 0")]
    [InlineData("0 ")]
    [InlineData(" 0 ")]
    public void ParseMapsZeroToDisabledAfterTrimming(string raw)
    {
        Assert.Equal(CaptureAtLaunchPolicyValue.Disabled, CaptureAtLaunchPolicy.Parse(raw));
    }

    /// <summary>
    /// A Copilot review finding on PR #85, reverting an earlier (incorrect) fix attempt: a string
    /// containing an embedded or trailing NUL character must be <see cref="CaptureAtLaunchPolicyValue.Malformed"/>,
    /// not silently accepted by cutting the string at the NUL and comparing whatever precedes it.
    /// <c>"1\0anything"</c> parsing as <see cref="CaptureAtLaunchPolicyValue.Enabled"/> would let a
    /// non-canonical, partially-unexpected registry string enable capture instead of producing the
    /// visible <c>PolicyUnreadable</c> state -- exactly the permissive direction #60 scope 1 forbids.
    /// </summary>
    [Theory]
    [InlineData("1\0")]
    [InlineData("0\0")]
    [InlineData("1\0trailing garbage after the NUL")]
    [InlineData("\01")]
    public void ParseTreatsAnEmbeddedOrTrailingNulAsMalformed(string raw)
    {
        Assert.Equal(CaptureAtLaunchPolicyValue.Malformed, CaptureAtLaunchPolicy.Parse(raw));
    }

    /// <summary>#60 acceptance box 3: an invalid value fails visibly and never resolves to the
    /// permissive option. Every one of these must parse as Malformed -- not "true"/"yes" (no case
    /// folding of words, matching LaunchOptions' single-spelling discipline), not "2"/"-1"/"01"
    /// (only the exact single-character spellings "0"/"1" are accepted), and not the empty or
    /// whitespace-only string.</summary>
    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("true")]
    [InlineData("yes")]
    [InlineData("2")]
    [InlineData("-1")]
    [InlineData("01")]
    [InlineData("Enabled")]
    public void AnUnrecognisedValueIsMalformedAndNeverEnabled(string raw)
    {
        Assert.Equal(CaptureAtLaunchPolicyValue.Malformed, CaptureAtLaunchPolicy.Parse(raw));
    }

    [Fact]
    public void NoneHasBothRanksAbsent()
    {
        Assert.Equal(CaptureAtLaunchPolicyValue.Absent, CaptureAtLaunchPolicy.None.ManagedPolicy);
        Assert.Equal(CaptureAtLaunchPolicyValue.Absent, CaptureAtLaunchPolicy.None.InstallerPreference);
    }

    /// <summary>
    /// The amendment 3 consequence, pinned end to end through <see cref="EffectiveCaptureAtLaunch.Resolve(HostSettings, bool, CaptureAtLaunchPolicy)"/>:
    /// a malformed managed policy forces capture off even when the launch switch and the user's own
    /// setting are both on -- the only path that can ever force an "off" outcome once a lower layer
    /// has turned capture on, since neither policy rank can enforce "off" as a decision (a deployed
    /// <c>0</c> is "no opinion", not an override).
    /// </summary>
    [Fact]
    public void AMalformedPolicyEnforcesOffAndOutranksEveryLowerLayer()
    {
        var policy = new CaptureAtLaunchPolicy(CaptureAtLaunchPolicyValue.Malformed, CaptureAtLaunchPolicyValue.Absent);
        HostSettings settings = Settings(enabled: true, paused: false);

        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(settings, launchSwitchPresent: true, policy);

        Assert.False(effective.Enabled);
        Assert.Equal(CaptureAtLaunchSource.ManagedPolicy, effective.Source);
        Assert.False(CaptureStartupDecision.ShouldStart(true, true, true, effective.Enabled, effective.Paused));
    }

    /// <summary>
    /// Same as above, but the malformed value is at the installer-preference rank with the managed
    /// policy absent -- confirming the second rank enforces off on its own terms too, not only when
    /// the higher rank happens to be involved.
    /// </summary>
    [Fact]
    public void AMalformedInstallerPreferenceEnforcesOffAndOutranksTheLaunchSwitch()
    {
        var policy = new CaptureAtLaunchPolicy(CaptureAtLaunchPolicyValue.Absent, CaptureAtLaunchPolicyValue.Malformed);
        HostSettings settings = Settings(enabled: true, paused: false);

        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(settings, launchSwitchPresent: true, policy);

        Assert.False(effective.Enabled);
        Assert.Equal(CaptureAtLaunchSource.InstallerPreference, effective.Source);
    }

    /// <summary>
    /// The other half of amendment 3: a deployed <c>0</c> (<see cref="CaptureAtLaunchPolicyValue.Disabled"/>)
    /// is "no opinion", not an enforced-off decision -- it falls through exactly like
    /// <see cref="CaptureAtLaunchPolicyValue.Absent"/>, so a lower layer that is on still wins.
    /// </summary>
    [Fact]
    public void ADisabledManagedPolicyFallsThroughToALowerLayerThatIsOn()
    {
        var policy = new CaptureAtLaunchPolicy(CaptureAtLaunchPolicyValue.Disabled, CaptureAtLaunchPolicyValue.Absent);
        HostSettings settings = Settings(enabled: true, paused: false);

        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(settings, launchSwitchPresent: false, policy);

        Assert.True(effective.Enabled);
        Assert.Equal(CaptureAtLaunchSource.UserSetting, effective.Source);
    }
}
