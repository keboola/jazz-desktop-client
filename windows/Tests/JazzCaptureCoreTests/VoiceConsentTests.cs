using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class VoiceConsentTests
{
    [Fact]
    public void PromptsOnlyUntilTheUserRecordsALastingChoice()
    {
        HostSettings fresh = Seed();
        Assert.True(VoiceConsent.ShouldPrompt(fresh));
        Assert.False(VoiceConsent.RecordWithoutPrompt(fresh));

        HostSettings legacyOn = Seed() with { NarrationEnabled = true };
        Assert.True(VoiceConsent.ShouldPrompt(legacyOn));
        Assert.False(VoiceConsent.RecordWithoutPrompt(legacyOn));

        HostSettings always = VoiceConsent.AfterPrompt(fresh, record: true, dontAskAgain: true);
        Assert.False(VoiceConsent.ShouldPrompt(always));
        Assert.True(VoiceConsent.RecordWithoutPrompt(always));

        HostSettings never = VoiceConsent.AfterPrompt(fresh, record: false, dontAskAgain: true);
        Assert.False(VoiceConsent.ShouldPrompt(never));
        Assert.False(VoiceConsent.RecordWithoutPrompt(never));
    }

    [Fact]
    public void EnablingVoiceInSettingsAsksAgainOnTheNextLabel()
    {
        HostSettings off = VoiceConsent.AfterSettingsToggle(Seed(), enabled: false);
        Assert.False(VoiceConsent.ShouldPrompt(off));
        Assert.False(VoiceConsent.RecordWithoutPrompt(off));

        HostSettings on = VoiceConsent.AfterSettingsToggle(off, enabled: true);
        Assert.True(VoiceConsent.ShouldPrompt(on));
        Assert.False(VoiceConsent.RecordWithoutPrompt(on));
    }

    [Fact]
    public void ANewerPolicyEpochStartsAskingAgain()
    {
        HostSettings declined = VoiceConsent.AfterPrompt(Seed(), record: false, dontAskAgain: true);
        HostSettings reset = VoiceConsent.AfterPolicyEpoch(declined, epoch: 2);
        Assert.Equal(2, reset.VoiceConsentEpoch);
        Assert.True(VoiceConsent.ShouldPrompt(reset));
        Assert.Equal(reset, VoiceConsent.AfterPolicyEpoch(reset, epoch: 2));
    }

    private static HostSettings Seed() => new(
        Array.Empty<string>(),
        HighlightClicks: false,
        NarrationEnabled: false,
        ScreenshotsEnabled: true);
}
