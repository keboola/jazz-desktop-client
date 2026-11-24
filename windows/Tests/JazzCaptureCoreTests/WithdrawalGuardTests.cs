using JazzCaptureCore;
using JazzCaptureCore.Consent;
using static JazzCaptureCoreTests.ConsentTestSupport;

namespace JazzCaptureCoreTests;

public sealed class WithdrawalGuardTests
{
    private static ConsentVerdict Allowing() =>
        ConsentEvaluator.Evaluate(Active(ConsentPolicyKind.CompanyWide), false, CurrentVersion, PersonConsentState.Empty);

    private static ConsentVerdict NotAllowing() =>
        ConsentEvaluator.Evaluate(Active(ConsentPolicyKind.CompanyWide), false, CurrentVersion, Answered(ConsentDecision.Withdrawn, "0.3"));

    [Fact]
    public void WithoutAWithdrawalEveryVerdictPassesUnchanged()
    {
        var guard = new WithdrawalGuard();

        Assert.Equal(Allowing(), guard.Apply(Allowing()));
        Assert.False(guard.IsPending);
    }

    [Fact]
    public void AVerdictThatStillAllowsRecordingIsStaleAfterTheWithdrawalClick()
    {
        var guard = new WithdrawalGuard();
        guard.Request();

        ConsentVerdict stale = guard.Apply(Allowing());

        Assert.False(stale.MayRecord);
        Assert.False(stale.CanWithdraw);
        Assert.Equal(ConsentStatus.Withdrawn, stale.Status);
        Assert.True(guard.IsPending);
        Assert.False(guard.Apply(Allowing()).MayRecord);
    }

    [Fact]
    public void TheFirstVerdictThatDoesNotAllowRecordingEndsTheWait()
    {
        var guard = new WithdrawalGuard();
        guard.Request();

        ConsentVerdict withdrawn = guard.Apply(NotAllowing());

        Assert.Equal(NotAllowing(), withdrawn);
        Assert.False(guard.IsPending);
        Assert.True(guard.Apply(Allowing()).MayRecord);
    }
}
