using JazzCaptureCore;
using JazzCaptureCore.Consent;
using static JazzCaptureCoreTests.ConsentTestSupport;

namespace JazzCaptureCoreTests;

public sealed class ConsentEvaluatorTests
{
    private static ConsentVerdict Evaluate(DevicePolicy? policy, PersonConsentState? person = null, bool tooOld = false) =>
        ConsentEvaluator.Evaluate(policy, tooOld, CurrentVersion, person ?? PersonConsentState.Empty);

    [Fact]
    public void NoPolicyAndNoCacheMeansNoRecording()
    {
        ConsentVerdict verdict = Evaluate(null);

        Assert.False(verdict.MayRecord);
        Assert.Equal(ConsentStatus.NotSetUp, verdict.Status);
        Assert.Equal("Not set up", verdict.StatusText);
    }

    [Fact]
    public void AwaitingAdminFirstRunSaysSetupNotFinished()
    {
        var policy = new DevicePolicy(DevicePolicy.StatusAwaitingAdminFirstRun, 300, null, null, null);

        ConsentVerdict verdict = Evaluate(policy);

        Assert.False(verdict.MayRecord);
        Assert.Equal("Setup not finished", verdict.StatusText);
    }

    [Fact]
    public void ActivePolicyWithoutModeOrConsentRecordsNothing()
    {
        Assert.False(Evaluate(new DevicePolicy(DevicePolicy.StatusActive, 300, null, null, null)).MayRecord);
        Assert.False(Evaluate(new DevicePolicy(DevicePolicy.StatusActive, 300, null, RecordingMode.Session, null)).MayRecord);
    }

    [Fact]
    public void OlderClientRecordsNothingAndSaysSo()
    {
        ConsentVerdict verdict = Evaluate(
            Active(ConsentPolicyKind.CompanyWide, minClientVersion: "0.28.0"),
            Answered(ConsentDecision.Agreed, "0.3"));

        Assert.False(verdict.MayRecord);
        Assert.Equal("Update required", verdict.StatusText);
    }

    [Fact]
    public void ServerAnswer426RecordsNothingEvenWithoutPolicy()
    {
        Assert.Equal(ConsentStatus.UpdateRequired, Evaluate(null, tooOld: true).Status);
        Assert.False(Evaluate(Active(ConsentPolicyKind.CompanyWide), tooOld: true).MayRecord);
    }

    [Fact]
    public void PerPersonNeverAnsweredAsksAndDoesNotRecord()
    {
        ConsentVerdict verdict = Evaluate(Active(ConsentPolicyKind.PerPerson));

        Assert.False(verdict.MayRecord);
        Assert.Equal(ConsentPrompt.Ask, verdict.Prompt);
        Assert.NotNull(verdict.OfferedText);
    }

    [Fact]
    public void PerPersonAgreedToCurrentVersionRecords()
    {
        ConsentVerdict verdict = Evaluate(Active(ConsentPolicyKind.PerPerson), Answered(ConsentDecision.Agreed, "0.3"));

        Assert.True(verdict.MayRecord);
        Assert.Equal(ConsentPrompt.None, verdict.Prompt);
        Assert.True(verdict.CanWithdraw);
    }

    [Fact]
    public void NewTextVersionAsksAgainOnlyAPersonWhoAgreed()
    {
        DevicePolicy policy = Active(ConsentPolicyKind.PerPerson, Text("0.4"));

        ConsentVerdict agreed = Evaluate(policy, Answered(ConsentDecision.Agreed, "0.3"));
        ConsentVerdict declined = Evaluate(policy, Answered(ConsentDecision.Declined, "0.3"));
        ConsentVerdict withdrawn = Evaluate(policy, Answered(ConsentDecision.Withdrawn, "0.3"));

        Assert.Equal(ConsentPrompt.Reask, agreed.Prompt);
        Assert.False(agreed.MayRecord);
        Assert.Equal(ConsentPrompt.None, declined.Prompt);
        Assert.False(declined.MayRecord);
        Assert.Equal(ConsentPrompt.None, withdrawn.Prompt);
        Assert.False(withdrawn.MayRecord);
    }

    [Fact]
    public void AHashMismatchShowsAnErrorAndRecordsNothing()
    {
        DevicePolicy policy = Active(ConsentPolicyKind.PerPerson, BrokenHash("0.3"));

        ConsentVerdict verdict = Evaluate(policy);

        Assert.Equal(ConsentStatus.TextError, verdict.Status);
        Assert.False(verdict.MayRecord);
        Assert.Equal(ConsentPrompt.None, verdict.Prompt);
        Assert.Null(verdict.OfferedText);
    }

    [Fact]
    public void PerPersonWithoutServedTextRecordsNothing()
    {
        var policy = new DevicePolicy(
            DevicePolicy.StatusActive, 300, null, RecordingMode.Session,
            new ConsentSettings(ConsentPolicyKind.PerPerson, null, null, null));

        Assert.Equal(ConsentStatus.TextError, Evaluate(policy, Answered(ConsentDecision.Agreed, "0.3")).Status);
    }

    [Fact]
    public void CompanyWideRecordsWithoutPrompt()
    {
        ConsentVerdict verdict = Evaluate(Active(ConsentPolicyKind.CompanyWide));

        Assert.True(verdict.MayRecord);
        Assert.Equal(ConsentPrompt.None, verdict.Prompt);
        Assert.Equal(ConsentNotice.None, verdict.Notice);
        Assert.True(verdict.CanWithdraw);
    }

    [Fact]
    public void CompanyWideShowsTheNoticeOnceAndStillRecords()
    {
        ServedText notice = Text("1", "# Jazz records your work");
        DevicePolicy policy = Active(ConsentPolicyKind.CompanyWide, notice: notice);

        ConsentVerdict first = Evaluate(policy);
        ConsentVerdict later = Evaluate(policy, PersonConsentState.Empty with { CompanyNoticeVersion = "1" });

        Assert.True(first.MayRecord);
        Assert.Equal(ConsentNotice.CompanyWide, first.Notice);
        Assert.Equal(notice, first.NoticeText);
        Assert.Equal(ConsentNotice.None, later.Notice);
    }

    [Fact]
    public void ANoticeThatFailsItsHashStopsRecording()
    {
        ConsentVerdict verdict = Evaluate(Active(ConsentPolicyKind.CompanyWide, notice: BrokenHash("1")));

        Assert.Equal(ConsentStatus.TextError, verdict.Status);
        Assert.False(verdict.MayRecord);
    }

    [Theory]
    [InlineData(ConsentDecision.Declined)]
    [InlineData(ConsentDecision.Withdrawn)]
    public void APersonalDeclineOrWithdrawalBeatsCompanyWideConsent(ConsentDecision decision)
    {
        ConsentVerdict verdict = Evaluate(Active(ConsentPolicyKind.CompanyWide), Answered(decision, "0.3"));

        Assert.False(verdict.MayRecord);
        Assert.False(verdict.CanWithdraw);
        Assert.True(verdict.CanGiveConsent);
        Assert.NotNull(verdict.OfferedText);
    }

    [Fact]
    public void GiveConsentAgainIsNotOfferedWhenTheTextFailsItsHash()
    {
        ConsentVerdict verdict = Evaluate(
            Active(ConsentPolicyKind.PerPerson, BrokenHash("0.3")),
            Answered(ConsentDecision.Withdrawn, "0.3"));

        Assert.False(verdict.CanGiveConsent);
        Assert.Null(verdict.OfferedText);
    }

    [Fact]
    public void ACaptureModeChangeNeverChangesConsentOrAsksAgain()
    {
        PersonConsentState person = Answered(ConsentDecision.Agreed, "0.3");

        ConsentVerdict continuous = Evaluate(Active(ConsentPolicyKind.PerPerson, mode: RecordingMode.Continuous), person);
        ConsentVerdict session = Evaluate(Active(ConsentPolicyKind.PerPerson, Text("0.3", "# Session variant"), mode: RecordingMode.Session), person);

        Assert.True(continuous.MayRecord);
        Assert.True(session.MayRecord);
        Assert.Equal(ConsentPrompt.None, session.Prompt);
        Assert.Equal(RecordingMode.Session, session.Mode);
    }

    [Fact]
    public void TheModeNoticeIsShownOncePerNoticeVersionAndMode()
    {
        ServedText modeNotice = Text("1", "The mode changed.");
        PersonConsentState person = Answered(ConsentDecision.Agreed, "0.3");
        DevicePolicy continuous = Active(ConsentPolicyKind.PerPerson, modeNotice: modeNotice, mode: RecordingMode.Continuous);
        DevicePolicy session = Active(ConsentPolicyKind.PerPerson, modeNotice: modeNotice, mode: RecordingMode.Session);

        ConsentVerdict unseen = Evaluate(continuous, person);
        PersonConsentState seen = person with { ModeNoticeMarker = ConsentEvaluator.ModeNoticeMarker(modeNotice, RecordingMode.Continuous) };

        Assert.Equal(ConsentNotice.ModeChange, unseen.Notice);
        Assert.True(unseen.MayRecord);
        Assert.Equal(ConsentNotice.None, Evaluate(continuous, seen).Notice);
        Assert.Equal(ConsentNotice.ModeChange, Evaluate(session, seen).Notice);
    }

    [Fact]
    public void NoModeNoticeIsShownToAPersonWhoIsNotRecording()
    {
        ServedText modeNotice = Text("1", "The mode changed.");

        ConsentVerdict declined = Evaluate(
            Active(ConsentPolicyKind.PerPerson, modeNotice: modeNotice), Answered(ConsentDecision.Declined, "0.3"));
        ConsentVerdict waiting = Evaluate(Active(ConsentPolicyKind.PerPerson, modeNotice: modeNotice));

        Assert.Equal(ConsentNotice.None, declined.Notice);
        Assert.Equal(ConsentNotice.None, waiting.Notice);
    }
}
