using System.Windows;
using System.Windows.Threading;
using JazzCaptureCore.Consent;

namespace JazzCapture;

/// <summary>
/// Connects the consent controller to the tray: it applies each verdict, shows the served texts,
/// and polls the policy. All decisions are made in <see cref="ConsentController"/>. This class only
/// opens windows and forwards what the person clicked.
/// </summary>
internal sealed class ConsentCoordinator
{
    /// <summary>While no policy has arrived yet there is nothing to follow, so the first policy is asked for sooner.</summary>
    private static readonly TimeSpan FirstPolicyRetry = TimeSpan.FromSeconds(30);

    private readonly TrayHost _host;
    private readonly ConsentController _controller;
    private readonly Dispatcher _dispatcher;
    private readonly CancellationToken _shutdown;
    private bool _dialogOpen;
    private string? _promptShownFor;
    private string? _noticeShownFor;

    internal ConsentCoordinator(
        TrayHost host,
        IConsentTransport transport,
        IConsentStorage storage,
        string clientVersion,
        Dispatcher dispatcher,
        CancellationToken shutdown)
    {
        _host = host;
        _dispatcher = dispatcher;
        _shutdown = shutdown;
        _controller = new ConsentController(transport, storage, clientVersion, () => DateTimeOffset.UtcNow, OnVerdict);
        host.WithdrawConsentRequested = () => _ = RunAsync(WithdrawAsync);
        host.GiveConsentRequested = () => _ = RunAsync(AnswerAsync);
        host.AnswerConsentRequested = () => _ = RunAsync(AnswerAsync);
    }

    /// <summary>
    /// Loads the stored answer and the cached policy, applies them at once so the one-time startup
    /// decision sees them, and starts polling.
    /// </summary>
    internal void Start()
    {
        _controller.Load();
        _host.ApplyConsentVerdict(_controller.Current);
        _ = RunLoopAsync();
    }

    /// <summary>Asks the server now, for example after the person signed in with the work account.</summary>
    internal void RefreshSoon() => _ = Task.Run(async () =>
    {
        try { await _controller.RefreshAsync(_shutdown).ConfigureAwait(false); }
        catch (Exception) { }
    });

    private void OnVerdict(ConsentVerdict verdict)
    {
        if (_dispatcher.HasShutdownStarted) return;
        _ = _dispatcher.InvokeAsync(() => Apply(verdict));
    }

    private void Apply(ConsentVerdict verdict)
    {
        _host.ApplyConsentVerdict(verdict);
        if (verdict.Prompt == ConsentPrompt.None) _promptShownFor = null;
        if (verdict.Notice == ConsentNotice.None) _noticeShownFor = null;
        if (_dialogOpen) return;

        string promptKey = verdict.Prompt + "/" + verdict.OfferedText?.Version;
        string noticeKey = verdict.Notice + "/" + verdict.NoticeText?.Version + "/" + verdict.Mode;
        if (verdict.Prompt != ConsentPrompt.None && promptKey != _promptShownFor)
        {
            _promptShownFor = promptKey;
            _ = RunAsync(AnswerAsync);
        }
        else if (verdict.Notice != ConsentNotice.None && noticeKey != _noticeShownFor)
        {
            _noticeShownFor = noticeKey;
            _ = RunAsync(NoticeAsync);
        }
    }

    private async Task RunLoopAsync()
    {
        while (!_shutdown.IsCancellationRequested)
        {
            TimeSpan wait;
            try
            {
                await _controller.RefreshAsync(_shutdown).ConfigureAwait(false);
                wait = _controller.Current.Status == ConsentStatus.NotSetUp
                    ? TimeSpan.FromTicks(Math.Min(_controller.RefreshInterval.Ticks, FirstPolicyRetry.Ticks))
                    : _controller.RefreshInterval;
            }
            catch (OperationCanceledException) when (_shutdown.IsCancellationRequested)
            {
                return;
            }
            catch (Exception)
            {
                wait = FirstPolicyRetry;
            }

            try { await Task.Delay(wait, _shutdown).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task RunAsync(Func<Task> action)
    {
        try { await action().ConfigureAwait(true); }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested) { }
    }

    private async Task WithdrawAsync()
    {
        if (_dialogOpen) return;
        await _controller.WithdrawAsync(_shutdown).ConfigureAwait(true);
    }

    private async Task AnswerAsync()
    {
        if (_dialogOpen || _controller.Current.OfferedText is not { } text) return;
        _dialogOpen = true;
        try
        {
            ConsentChoice choice = ConsentWindow.AskForAnswer(text);
            if (choice == ConsentChoice.Agree)
            {
                ConsentActionOutcome outcome = await _controller.AgreeAsync(_shutdown).ConfigureAwait(true);
                if (outcome != ConsentActionOutcome.Done) ReportAgreeFailure(outcome);
            }
            else if (choice == ConsentChoice.Decline)
            {
                await _controller.DeclineAsync(_shutdown).ConfigureAwait(true);
            }
        }
        finally
        {
            _dialogOpen = false;
        }
    }

    private async Task NoticeAsync()
    {
        ConsentVerdict verdict = _controller.Current;
        if (_dialogOpen || verdict.NoticeText is not { } text) return;
        _dialogOpen = true;
        try
        {
            ConsentChoice choice = ConsentWindow.ShowNotice(text, offerWithdraw: verdict.Notice == ConsentNotice.CompanyWide);
            if (choice == ConsentChoice.Withdraw)
            {
                _host.SuspendRecordingForWithdrawal();
                await _controller.WithdrawAsync(_shutdown).ConfigureAwait(true);
            }
            else
                await _controller.AcknowledgeNoticeAsync(verdict.Notice, _shutdown).ConfigureAwait(true);
        }
        finally
        {
            _dialogOpen = false;
        }
    }

    private static void ReportAgreeFailure(ConsentActionOutcome outcome)
    {
        string message = outcome switch
        {
            ConsentActionOutcome.Refused =>
                "The Jazz server did not accept your agreement. Nothing is recorded.",
            ConsentActionOutcome.Unavailable =>
                "Jazz could not reach its server. Nothing is recorded. Choose \"Answer consent question...\" in the Jazz menu to try again.",
            _ => "The consent text could not be verified. Nothing is recorded.",
        };
        System.Windows.MessageBox.Show(message, "Jazz consent", MessageBoxButton.OK, MessageBoxImage.Warning);
    }
}
