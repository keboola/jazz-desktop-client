namespace JazzCaptureCore.Consent;

/// <summary>
/// Keeps a withdrawal in force on this computer until the controller has applied it. From the click
/// on, a verdict that still allows recording is stale: it was produced before the withdrawal, for
/// example by a refresh that was already running. Such a verdict is turned into "withdrawn". The
/// first verdict that does not allow recording ends the wait.
/// </summary>
public sealed class WithdrawalGuard
{
    private bool _pending;

    public bool IsPending => _pending;

    /// <summary>The person chose "Withdraw consent".</summary>
    public void Request() => _pending = true;

    public ConsentVerdict Apply(ConsentVerdict verdict)
    {
        if (!_pending) return verdict;
        if (!verdict.MayRecord)
        {
            _pending = false;
            return verdict;
        }

        return verdict with
        {
            Status = ConsentStatus.Withdrawn,
            MayRecord = false,
            Prompt = ConsentPrompt.None,
            Notice = ConsentNotice.None,
            CanWithdraw = false,
            CanGiveConsent = false,
            OfferedText = null,
            NoticeText = null,
        };
    }
}
