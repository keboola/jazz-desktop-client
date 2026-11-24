namespace JazzCaptureCore.Consent;

public enum PolicyFetchOutcome
{
    Fetched,

    /// <summary>The server answered 304: the policy this client holds is current.</summary>
    NotModified,

    /// <summary>The server answered 426. This client is older than <c>minClientVersion</c>.</summary>
    TooOld,

    Unavailable,
}

public sealed record PolicyFetchResult(PolicyFetchOutcome Outcome, string? Json = null, string? ETag = null);

public enum PostOutcome
{
    Accepted,

    /// <summary>The server refused the decision, for example <c>agreed</c> from a bulk-enrolled device.</summary>
    Refused,

    TooOld,
    Unavailable,
}

public sealed record PostResult(PostOutcome Outcome);

/// <summary>What one <c>POST /device/consent</c> carries besides the key.</summary>
public sealed record DecisionPost(ConsentDecision Decision, string? TextVersion, string? TextHash, string? CaptureMode);

/// <summary>The two server calls. The host implements them over HTTP.</summary>
public interface IConsentTransport
{
    /// <returns>The person, or null when none can be named now (for example no work account token).</returns>
    Task<ConsentIdentity?> ResolveIdentityAsync(CancellationToken cancellationToken);

    /// <param name="ifNoneMatch">The ETag of the policy this client holds, or null.</param>
    Task<PolicyFetchResult> FetchPolicyAsync(ConsentIdentity identity, string? ifNoneMatch, CancellationToken cancellationToken);

    Task<PostResult> PostDecisionAsync(ConsentIdentity identity, DecisionPost post, CancellationToken cancellationToken);
}

/// <summary>Two small files in the profile of the Windows user: the consent ledger and the cached policy.</summary>
public interface IConsentStorage
{
    string? ReadLedger();

    void WriteLedger(string json);

    string? ReadPolicy();

    void WritePolicy(string json);
}

public enum ConsentActionOutcome
{
    Done,

    /// <summary>Nothing is offered now, or the offered text fails its hash check. Nothing was recorded.</summary>
    NotAvailable,

    /// <summary>The server refused <c>agreed</c>. Nothing was recorded.</summary>
    Refused,

    /// <summary>The text or the mode changed after the person saw it. Nothing was recorded. Ask again with the current offer.</summary>
    OfferChanged,

    /// <summary>The server could not be reached. Nothing was recorded for <c>agreed</c>.</summary>
    Unavailable,
}

/// <summary>
/// Runs the consent flow: fetch the policy, apply the answers of the person, post each decision.
/// It never posts <c>agreed</c> by itself. <see cref="AgreeAsync"/> is the only path, and the host
/// calls it only from the click of the person.
/// </summary>
public sealed class ConsentController
{
    private readonly IConsentTransport _transport;
    private readonly IConsentStorage _storage;
    private readonly string _clientVersion;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Action<ConsentVerdict> _publish;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private ConsentLedger _ledger = ConsentLedger.Empty();
    private DevicePolicy? _policy;
    private bool _refusedAsTooOld;
    private ConsentIdentity? _identity;
    private ConsentVerdict _verdict = ConsentVerdict.NoRecording(ConsentStatus.NotSetUp);

    public ConsentController(
        IConsentTransport transport,
        IConsentStorage storage,
        string clientVersion,
        Func<DateTimeOffset> clock,
        Action<ConsentVerdict> publish)
    {
        _transport = transport;
        _storage = storage;
        _clientVersion = clientVersion;
        _clock = clock;
        _publish = publish;
    }

    public ConsentVerdict Current => _verdict;

    /// <summary>How long to wait before the next <see cref="RefreshAsync"/>: the served <c>consentRefreshSeconds</c>.</summary>
    public TimeSpan RefreshInterval => TimeSpan.FromSeconds(_policy?.RefreshSeconds ?? DevicePolicy.DefaultRefreshSeconds);

    /// <summary>Reads the stored answer and the cached policy. Call once, before the first refresh.</summary>
    public void Load()
    {
        _gate.Wait();
        try
        {
            _ledger = ConsentLedger.Parse(TryRead(_storage.ReadLedger));
            _identity = _ledger.LastIdentity;
            string? cached = TryRead(_storage.ReadPolicy);
            _policy = cached is not null && DevicePolicy.TryParse(cached, out DevicePolicy? parsed) ? parsed : null;
            Publish();
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Fetches the policy, posts decisions that are still waiting, and applies the result.</summary>
    public async Task RefreshAsync(CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ConsentIdentity? resolved = await _transport.ResolveIdentityAsync(cancellationToken).ConfigureAwait(false);
            if (resolved is not null && resolved != _identity)
            {
                _identity = resolved;
                _ledger = _ledger with { LastIdentity = resolved, PolicyETag = null };
                Save();
            }

            if (_identity is { } identity)
            {
                string? held = _policy is not null ? _ledger.PolicyETag : null;
                PolicyFetchResult fetched = await _transport.FetchPolicyAsync(identity, held, cancellationToken).ConfigureAwait(false);
                ApplyFetch(fetched);
                await PostPendingAsync(identity, cancellationToken).ConfigureAwait(false);
            }

            Publish();
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// The person clicked "I agree". The decision is recorded locally only after the server accepted
    /// it, so a refused or unreachable server leaves the person not recording. The agreement is for
    /// the text and the mode the person was shown. When the offer changed since, nothing is recorded.
    /// </summary>
    public async Task<ConsentActionOutcome> AgreeAsync(ServedText shown, RecordingMode shownMode, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_identity is not { } identity || _verdict.OfferedText is not { } text || !text.HashMatches() || _policy?.Mode is not RecordingMode mode)
                return ConsentActionOutcome.NotAvailable;
            if (text != shown || mode != shownMode)
                return ConsentActionOutcome.OfferChanged;

            ConsentAnswer answer = Answer(ConsentDecision.Agreed, text, mode, posted: true);
            PostResult result = await _transport
                .PostDecisionAsync(identity, ToPost(answer), cancellationToken)
                .ConfigureAwait(false);
            switch (result.Outcome)
            {
                case PostOutcome.Accepted:
                    // The person has just read the text of this mode, so the mode notice is not shown again for it.
                    Store(identity, state => state with
                    {
                        Answer = answer,
                        ModeNoticeMarker = _policy?.Consent?.ModeNotice is { } notice
                            ? ConsentEvaluator.ModeNoticeMarker(notice, mode)
                            : state.ModeNoticeMarker,
                    });
                    Publish();
                    return ConsentActionOutcome.Done;
                case PostOutcome.TooOld:
                    _refusedAsTooOld = true;
                    Publish();
                    return ConsentActionOutcome.Unavailable;
                case PostOutcome.Refused:
                    return ConsentActionOutcome.Refused;
                default:
                    return ConsentActionOutcome.Unavailable;
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>The person clicked "I don't agree". Recording stays off, with or without the server.</summary>
    public Task<ConsentActionOutcome> DeclineAsync(CancellationToken cancellationToken) =>
        RecordOwnDecisionAsync(ConsentDecision.Declined, cancellationToken);

    /// <summary>The person chose "Withdraw consent". Recording stops before the server is asked.</summary>
    public Task<ConsentActionOutcome> WithdrawAsync(CancellationToken cancellationToken) =>
        RecordOwnDecisionAsync(ConsentDecision.Withdrawn, cancellationToken);

    /// <summary>
    /// The person closed the notice. This never records an answer and never posts. Only the notice
    /// the person saw is marked as seen. When the served notice changed since, nothing is marked.
    /// </summary>
    public async Task AcknowledgeNoticeAsync(ConsentNotice shown, ServedText shownText, RecordingMode shownMode, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_identity is not { } identity) return;
            RecordingMode? mode = _policy?.Mode;
            ConsentSettings? consent = _policy?.Consent;
            if (shown == ConsentNotice.None || mode is not RecordingMode current || consent is null) return;
            if (_verdict.Notice != shown || _verdict.NoticeText != shownText || current != shownMode) return;

            Store(identity, state => shown == ConsentNotice.CompanyWide
                ? state with
                {
                    CompanyNoticeVersion = consent.Notice?.Version,
                    // The company-wide notice describes the mode of now.
                    ModeNoticeMarker = consent.ModeNotice is { } first
                        ? ConsentEvaluator.ModeNoticeMarker(first, current)
                        : state.ModeNoticeMarker,
                }
                : state with
                {
                    ModeNoticeMarker = consent.ModeNotice is { } notice
                        ? ConsentEvaluator.ModeNoticeMarker(notice, current)
                        : state.ModeNoticeMarker,
                });
            Publish();
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<ConsentActionOutcome> RecordOwnDecisionAsync(ConsentDecision decision, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_identity is not { } identity || _policy?.Mode is not RecordingMode mode)
            {
                Publish();
                return ConsentActionOutcome.NotAvailable;
            }

            // A withdrawal is never lost: it counts while the person has not declined or withdrawn
            // already, also when a refresh changed the verdict after the person chose it.
            ConsentDecision? current = _ledger.Person(identity.StoreKey).Answer?.Decision;
            bool allowed = decision == ConsentDecision.Withdrawn
                ? current is not (ConsentDecision.Declined or ConsentDecision.Withdrawn)
                : _verdict.Prompt != ConsentPrompt.None || _verdict.CanGiveConsent;
            if (!allowed)
            {
                Publish();
                return ConsentActionOutcome.NotAvailable;
            }

            ServedText? text = _policy?.Consent?.Text;
            ConsentAnswer answer = Answer(decision, text, mode, posted: false);
            Store(identity, state => state with { Answer = answer });
            Publish();

            PostResult result = await _transport
                .PostDecisionAsync(identity, ToPost(answer), cancellationToken)
                .ConfigureAwait(false);
            if (result.Outcome == PostOutcome.Accepted)
            {
                Store(identity, state => state with { Answer = answer with { Posted = true } });
            }
            else if (result.Outcome == PostOutcome.TooOld)
            {
                _refusedAsTooOld = true;
                Publish();
            }

            // A decline or withdrawal applies on this computer at once. An answer the server did not
            // take yet is posted again by RefreshAsync.
            return ConsentActionOutcome.Done;
        }
        finally
        {
            _gate.Release();
        }
    }

    private void ApplyFetch(PolicyFetchResult fetched)
    {
        switch (fetched.Outcome)
        {
            case PolicyFetchOutcome.TooOld:
                _refusedAsTooOld = true;
                break;
            case PolicyFetchOutcome.NotModified when _policy is not null:
                _refusedAsTooOld = false;
                break;
            case PolicyFetchOutcome.Fetched when fetched.Json is not null && DevicePolicy.TryParse(fetched.Json, out DevicePolicy? parsed):
                _refusedAsTooOld = false;
                _policy = parsed;
                _ledger = _ledger with { PolicyETag = fetched.ETag };
                Save();
                // The cache never holds the Files token or the stream URL of a signed policy.
                try { _storage.WritePolicy(DevicePolicyDocument.WithoutSecrets(fetched.Json)); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
                break;
        }
    }

    private async Task PostPendingAsync(ConsentIdentity identity, CancellationToken cancellationToken)
    {
        ConsentAnswer? answer = _ledger.Person(identity.StoreKey).Answer;
        if (answer is not { Posted: false } || answer.Decision == ConsentDecision.Agreed) return;
        PostResult result = await _transport.PostDecisionAsync(identity, ToPost(answer), cancellationToken).ConfigureAwait(false);
        if (result.Outcome == PostOutcome.Accepted)
            Store(identity, state => state with { Answer = answer with { Posted = true } });
        else if (result.Outcome == PostOutcome.TooOld)
            _refusedAsTooOld = true;
    }

    private ConsentAnswer Answer(ConsentDecision decision, ServedText? text, RecordingMode mode, bool posted) =>
        new(
            decision,
            text?.Version,
            text?.Sha256.ToLowerInvariant(),
            mode == RecordingMode.Continuous ? RecordingModeParser.ContinuousValue : RecordingModeParser.SessionValue,
            _clock(),
            posted);

    private static DecisionPost ToPost(ConsentAnswer answer) =>
        new(answer.Decision, answer.TextVersion, answer.TextHash, answer.CaptureMode);

    private void Store(ConsentIdentity identity, Func<PersonConsentState, PersonConsentState> change)
    {
        PersonConsentState next = change(_ledger.Person(identity.StoreKey));
        var people = new Dictionary<string, PersonConsentState>(_ledger.People) { [identity.StoreKey] = next };
        _ledger = _ledger with { People = people };
        Save();
    }

    private void Save()
    {
        try { _storage.WriteLedger(_ledger.ToJson()); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private void Publish()
    {
        _verdict = _identity is { } identity
            ? ConsentEvaluator.Evaluate(_policy, _refusedAsTooOld, _clientVersion, _ledger.Person(identity.StoreKey))
            : ConsentVerdict.NoRecording(_refusedAsTooOld ? ConsentStatus.UpdateRequired : ConsentStatus.NotSetUp);
        _publish(_verdict);
    }

    private static string? TryRead(Func<string?> read)
    {
        try { return read(); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return null; }
    }
}
