using JazzCaptureCore;
using JazzCaptureCore.Consent;
using static JazzCaptureCoreTests.ConsentTestSupport;

namespace JazzCaptureCoreTests;

public sealed class ConsentControllerTests
{
    private readonly FakeStorage _storage = new();
    private readonly FakeTransport _transport = new();
    private readonly List<ConsentVerdict> _verdicts = new();
    private DateTimeOffset _now = new(2026, 11, 23, 10, 0, 0, TimeSpan.Zero);

    private ConsentController Create()
    {
        var controller = new ConsentController(_transport, _storage, CurrentVersion, () => _now, _verdicts.Add);
        controller.Load();
        return controller;
    }

    private void ServePolicy(ConsentPolicyKind kind, ServedText? text = null, ServedText? notice = null, ServedText? modeNotice = null, string mode = "continuous")
    {
        var consent = new Dictionary<string, object>
        {
            ["policy"] = kind == ConsentPolicyKind.PerPerson ? "per_person" : "company_wide",
            ["key"] = "entra_tid_oid",
            ["text"] = ServedObject(text ?? Text("0.3")),
            ["reask"] = new { onTextVersion = "agreed_only" },
        };
        if (notice is not null) consent["notice"] = ServedObject(notice);
        if (modeNotice is not null) consent["modeNotice"] = ServedObject(modeNotice);
        _transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.Fetched, PolicyJson(consent, mode: mode));
    }

    [Fact]
    public async Task NothingIsRecordedBeforeThePolicyArrives()
    {
        ConsentController controller = Create();
        Assert.Equal(ConsentStatus.NotSetUp, controller.Current.Status);

        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentStatus.NotSetUp, controller.Current.Status);
        Assert.False(controller.Current.MayRecord);
    }

    [Fact]
    public async Task PerPersonStaysOffUntilThePersonAgreesAndNothingIsPostedBefore()
    {
        ServePolicy(ConsentPolicyKind.PerPerson);
        ConsentController controller = Create();

        await controller.RefreshAsync(CancellationToken.None);
        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentPrompt.Ask, controller.Current.Prompt);
        Assert.False(controller.Current.MayRecord);
        Assert.Empty(_transport.Posts);
    }

    [Fact]
    public async Task AgreeingPostsTheVersionTheHashAndTheModeThenRecords()
    {
        ServedText text = Text("0.3");
        ServePolicy(ConsentPolicyKind.PerPerson, text);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);

        ConsentActionOutcome outcome = await controller.AgreeAsync(CancellationToken.None);

        Assert.Equal(ConsentActionOutcome.Done, outcome);
        DecisionPost post = Assert.Single(_transport.Posts);
        Assert.Equal(new DecisionPost(ConsentDecision.Agreed, "0.3", text.Sha256, "continuous"), post);
        Assert.True(controller.Current.MayRecord);
    }

    [Fact]
    public async Task ARefusedOrUnreachableServerLeavesTheAgreeingPersonNotRecording()
    {
        ServePolicy(ConsentPolicyKind.PerPerson);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);

        _transport.NextPost = PostOutcome.Refused;
        Assert.Equal(ConsentActionOutcome.Refused, await controller.AgreeAsync(CancellationToken.None));
        _transport.NextPost = PostOutcome.Unavailable;
        Assert.Equal(ConsentActionOutcome.Unavailable, await controller.AgreeAsync(CancellationToken.None));

        Assert.False(controller.Current.MayRecord);
        Assert.Equal(ConsentPrompt.Ask, controller.Current.Prompt);
    }

    [Fact]
    public async Task AgreeIsNotAvailableWhenNothingIsOffered()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentActionOutcome.NotAvailable, await controller.AgreeAsync(CancellationToken.None));

        Assert.Empty(_transport.Posts);
    }

    [Fact]
    public async Task CompanyWideNeverPostsAgreedOnItsOwn()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide, notice: Text("1", "# Jazz records your work"));
        ConsentController controller = Create();

        await controller.RefreshAsync(CancellationToken.None);
        await controller.AcknowledgeNoticeAsync(ConsentNotice.CompanyWide, CancellationToken.None);
        await controller.RefreshAsync(CancellationToken.None);

        Assert.True(controller.Current.MayRecord);
        Assert.Empty(_transport.Posts);
    }

    [Fact]
    public async Task TheCompanyWideNoticeIsShownOnceAndSurvivesARestart()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide, notice: Text("1", "# Jazz records your work"));
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);
        Assert.Equal(ConsentNotice.CompanyWide, controller.Current.Notice);

        await controller.AcknowledgeNoticeAsync(ConsentNotice.CompanyWide, CancellationToken.None);
        ConsentController restarted = Create();

        Assert.Equal(ConsentNotice.None, controller.Current.Notice);
        Assert.Equal(ConsentNotice.None, restarted.Current.Notice);
        Assert.True(restarted.Current.MayRecord);
    }

    [Fact]
    public async Task WithdrawingStopsRecordingBeforeTheServerAnswersAndPostsWithdrawn()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);

        _transport.NextPost = PostOutcome.Unavailable;
        await controller.WithdrawAsync(CancellationToken.None);

        Assert.False(controller.Current.MayRecord);
        Assert.Equal(ConsentStatus.Withdrawn, controller.Current.Status);
        Assert.Equal(ConsentDecision.Withdrawn, Assert.Single(_transport.Posts).Decision);
    }

    [Fact]
    public async Task AWithdrawalThatCouldNotBePostedIsPostedAgainOnTheNextRefresh()
    {
        ServePolicy(ConsentPolicyKind.PerPerson);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);
        await controller.AgreeAsync(CancellationToken.None);
        _transport.NextPost = PostOutcome.Unavailable;
        await controller.WithdrawAsync(CancellationToken.None);
        _transport.Posts.Clear();

        _transport.NextPost = PostOutcome.Accepted;
        await controller.RefreshAsync(CancellationToken.None);
        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentDecision.Withdrawn, Assert.Single(_transport.Posts).Decision);
        Assert.False(controller.Current.MayRecord);
    }

    [Fact]
    public async Task AWithdrawnPersonIsNotAskedAgainAfterANewTextVersionAndCanGiveConsentAgain()
    {
        ServePolicy(ConsentPolicyKind.PerPerson, Text("0.3"));
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);
        await controller.AgreeAsync(CancellationToken.None);
        await controller.WithdrawAsync(CancellationToken.None);

        ServePolicy(ConsentPolicyKind.PerPerson, Text("0.4"));
        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentPrompt.None, controller.Current.Prompt);
        Assert.True(controller.Current.CanGiveConsent);
        Assert.False(controller.Current.MayRecord);

        _transport.Posts.Clear();
        Assert.Equal(ConsentActionOutcome.Done, await controller.AgreeAsync(CancellationToken.None));
        Assert.Equal("0.4", Assert.Single(_transport.Posts).TextVersion);
        Assert.True(controller.Current.MayRecord);
    }

    [Fact]
    public async Task AgreedPersonIsAskedAgainAfterANewTextVersion()
    {
        ServePolicy(ConsentPolicyKind.PerPerson, Text("0.3"));
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);
        await controller.AgreeAsync(CancellationToken.None);

        ServePolicy(ConsentPolicyKind.PerPerson, Text("0.4"));
        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentPrompt.Reask, controller.Current.Prompt);
        Assert.False(controller.Current.MayRecord);
    }

    [Fact]
    public async Task ADeclineSurvivesARestartAndIsNotAskedAgain()
    {
        ServePolicy(ConsentPolicyKind.PerPerson);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);
        await controller.DeclineAsync(CancellationToken.None);
        _transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.Unavailable);

        ConsentController restarted = Create();
        await restarted.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentStatus.Declined, restarted.Current.Status);
        Assert.Equal(ConsentPrompt.None, restarted.Current.Prompt);
        Assert.Equal(ConsentDecision.Declined, Assert.Single(_transport.Posts).Decision);
    }

    [Fact]
    public async Task AnAgreementSurvivesARestartAndAnOfflineStartUsesTheCachedPolicy()
    {
        ServePolicy(ConsentPolicyKind.PerPerson);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);
        await controller.AgreeAsync(CancellationToken.None);
        _transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.Unavailable);
        _transport.Identity = null;

        ConsentController restarted = Create();

        Assert.True(restarted.Current.MayRecord);
        Assert.Equal(ConsentStatus.Agreed, restarted.Current.Status);
    }

    [Fact]
    public async Task OfflineWithNoCachedPolicyRecordsNothing()
    {
        _transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.Unavailable);
        ConsentController controller = Create();

        await controller.RefreshAsync(CancellationToken.None);

        Assert.False(controller.Current.MayRecord);
    }

    [Fact]
    public async Task AnInvalidPolicyDoesNotReplaceTheCachedOne()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);
        _transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.Fetched, "<html>proxy error</html>");

        await controller.RefreshAsync(CancellationToken.None);

        Assert.True(controller.Current.MayRecord);
    }

    [Fact]
    public async Task ASecondPersonOnTheSameComputerGetsTheirOwnPrompt()
    {
        ServePolicy(ConsentPolicyKind.PerPerson);
        ConsentController first = Create();
        await first.RefreshAsync(CancellationToken.None);
        await first.AgreeAsync(CancellationToken.None);

        _transport.Identity = ConsentIdentity.ForWindows(@"ACME\PDvorak", "S-1-5-21-1-2-3-1002");
        ConsentController second = Create();
        await second.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentPrompt.Ask, second.Current.Prompt);
        Assert.False(second.Current.MayRecord);
    }

    [Fact]
    public async Task ServerAnswer426StopsRecordingAndAFetchedPolicyClearsIt()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide);
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);

        _transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.TooOld);
        await controller.RefreshAsync(CancellationToken.None);
        Assert.Equal(ConsentStatus.UpdateRequired, controller.Current.Status);
        Assert.False(controller.Current.MayRecord);

        ServePolicy(ConsentPolicyKind.CompanyWide);
        await controller.RefreshAsync(CancellationToken.None);
        Assert.True(controller.Current.MayRecord);
    }

    [Fact]
    public async Task APolicyThatAwaitsTheAdminSaysSetupNotFinished()
    {
        _transport.Fetch = new PolicyFetchResult(
            PolicyFetchOutcome.Fetched,
            PolicyJson(new { }, status: "awaiting_admin_first_run", mode: string.Empty));
        ConsentController controller = Create();

        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal("Setup not finished", controller.Current.StatusText);
        Assert.False(controller.Current.MayRecord);
    }

    [Fact]
    public async Task AHashMismatchPostsNothingAndOffersNothing()
    {
        ServedText broken = BrokenHash("0.3");
        _transport.Fetch = new PolicyFetchResult(
            PolicyFetchOutcome.Fetched,
            PolicyJson(new { policy = "per_person", key = "entra_tid_oid", text = ServedObject(broken) }));
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);

        ConsentActionOutcome outcome = await controller.AgreeAsync(CancellationToken.None);

        Assert.Equal(ConsentStatus.TextError, controller.Current.Status);
        Assert.Equal(ConsentActionOutcome.NotAvailable, outcome);
        Assert.Empty(_transport.Posts);
    }

    [Fact]
    public async Task TheRefreshIntervalFollowsTheServedValue()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide);
        ConsentController controller = Create();
        Assert.Equal(TimeSpan.FromSeconds(300), controller.RefreshInterval);

        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(TimeSpan.FromSeconds(120), controller.RefreshInterval);
    }

    [Fact]
    public async Task AModeChangeDoesNotAskAndShowsTheModeNoticeOnce()
    {
        ServedText modeNotice = Text("1", "The mode changed.");
        ServePolicy(ConsentPolicyKind.PerPerson, modeNotice: modeNotice, mode: "continuous");
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);
        await controller.AgreeAsync(CancellationToken.None);
        Assert.Equal(ConsentNotice.None, controller.Current.Notice);

        ServePolicy(ConsentPolicyKind.PerPerson, modeNotice: modeNotice, mode: "session");
        _transport.Posts.Clear();
        await controller.RefreshAsync(CancellationToken.None);

        Assert.True(controller.Current.MayRecord);
        Assert.Equal(ConsentPrompt.None, controller.Current.Prompt);
        Assert.Equal(ConsentNotice.ModeChange, controller.Current.Notice);

        await controller.AcknowledgeNoticeAsync(ConsentNotice.ModeChange, CancellationToken.None);
        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(ConsentNotice.None, controller.Current.Notice);
        Assert.Empty(_transport.Posts);
    }

    [Fact]
    public async Task TheEtagIsSentAfterAFetchAndANotModifiedAnswerKeepsThePolicy()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide);
        _transport.Fetch = _transport.Fetch with { ETag = "\"4-abc\"" };
        ConsentController controller = Create();
        await controller.RefreshAsync(CancellationToken.None);

        _transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.NotModified);
        await controller.RefreshAsync(CancellationToken.None);

        Assert.Equal(new string?[] { null, "\"4-abc\"" }, _transport.IfNoneMatch.ToArray());
        Assert.True(controller.Current.MayRecord);
        Assert.Equal("\"4-abc\"", ConsentLedger.Parse(_storage.Ledger).PolicyETag);
    }

    [Fact]
    public async Task TheCachedPolicyHoldsNoFilesTokenOrStreamUrl()
    {
        ServePolicy(ConsentPolicyKind.CompanyWide);
        string json = _transport.Fetch.Json![..^1]
            + ",\"streamUrl\":\"https://stream.example/secret\",\"filesToken\":{\"tokenId\":\"t\",\"token\":\"secret\",\"expiresAt\":\"2026-11-23T11:00:00Z\"}}";
        _transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.Fetched, json);
        ConsentController controller = Create();

        await controller.RefreshAsync(CancellationToken.None);

        Assert.True(controller.Current.MayRecord);
        Assert.DoesNotContain("secret", _storage.Policy, StringComparison.Ordinal);
    }
}
