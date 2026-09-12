using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="EventDeliveryWorker"/> is one bounded drain pass over <see cref="EventSpool"/>. Unlike
/// <see cref="ScreenshotDeliveryWorker"/>, which carries on past every failed entry regardless of
/// order, this type stops attempting further entries of a session as soon as one of that session's
/// entries comes back retrying -- per-session FIFO (#48 plan §2.4) -- and parks the whole pass,
/// without ever touching the spool, when no usable delivery target currently exists (§2.4/§4:
/// revocation or expiry must stop networking without deleting evidence).
/// </summary>
public sealed class EventDeliveryWorkerTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-event-worker-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            try { Directory.Delete(root, recursive: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    [Fact]
    public void TheConstructorRequiresANonNullSpool()
    {
        Assert.Throws<ArgumentNullException>(
            () => new EventDeliveryWorker(() => true, (_, _) => Task.FromResult(EventSendOutcome.Acknowledged), spool: null!));
    }

    [Fact]
    public async Task ARetryableFailureStopsThatSessionsPassWithoutSkippingAhead()
    {
        var spool = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("first")));
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 2, Body("second")));

        int sends = 0;
        var worker = new EventDeliveryWorker(
            isTargetUsable: () => true,
            deliver: (_, _) => { sends++; return Task.FromResult(EventSendOutcome.Retry); },
            spool);

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(1, sends);
        Assert.Equal(2, spool.Status.PendingCount);
    }

    [Fact]
    public async Task AFourHundredDropsThatEventAndThePassContinues()
    {
        var spool = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("dropped")));
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 2, Body("acknowledged")));

        var outcomes = new List<EventDeliveryOutcome>();
        int calls = 0;
        var worker = new EventDeliveryWorker(
            isTargetUsable: () => true,
            deliver: (_, _) =>
            {
                calls++;
                return Task.FromResult(calls == 1 ? EventSendOutcome.Dropped : EventSendOutcome.Acknowledged);
            },
            spool,
            outcome => outcomes.Add(outcome.Outcome));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(2, calls);
        Assert.Equal(0, spool.Status.PendingCount);
        Assert.Contains(EventDeliveryOutcome.Dropped, outcomes);
        Assert.Contains(EventDeliveryOutcome.Acknowledged, outcomes);
    }

    [Fact]
    public async Task NoUsableTargetParksTheDrainWithoutTouchingTheSpool()
    {
        var spool = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("parked")));

        int sends = 0;
        var outcomes = new List<EventDeliveryOutcome>();
        var worker = new EventDeliveryWorker(
            isTargetUsable: () => false,
            deliver: (_, _) => { sends++; return Task.FromResult(EventSendOutcome.Acknowledged); },
            spool,
            outcome => outcomes.Add(outcome.Outcome));

        TimeSpan? due = await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Null(due);
        Assert.Equal(0, sends);
        Assert.Empty(outcomes);
        Assert.Equal(1, spool.Status.PendingCount);
    }

    [Fact]
    public async Task AnAcknowledgedEventIsRemovedFromTheSpool()
    {
        var spool = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("ok")));

        var worker = new EventDeliveryWorker(
            () => true, (_, _) => Task.FromResult(EventSendOutcome.Acknowledged), spool);

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, spool.Status.PendingCount);
    }

    [Fact]
    public async Task EvictionsAndRefusalsAccumulatedSincePreviousPassAreReportedAsOutcomes()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new EventSpool(Settings(retention: TimeSpan.FromMinutes(1)), clock.Now);
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("will-expire")));
        Assert.Equal(EventSpoolAdmission.Refused, spool.Spool(session, 2, new byte[2 * 1024 * 1024]));
        clock.Advance(TimeSpan.FromMinutes(2));

        var outcomes = new List<EventDeliveryOutcome>();
        var worker = new EventDeliveryWorker(
            () => true, (_, _) => Task.FromResult(EventSendOutcome.Acknowledged), spool, outcome => outcomes.Add(outcome.Outcome));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Contains(EventDeliveryOutcome.Evicted, outcomes);
        Assert.Contains(EventDeliveryOutcome.Refused, outcomes);
    }

    /// <summary>
    /// Regression coverage for a defect found in adversarial review: bookkeeping (age-based eviction
    /// and draining the pending eviction/refusal lists) must run even when no usable delivery target
    /// exists, since <see cref="EventSpool.Spool"/> evicts and refuses on the capture path
    /// independent of provisioning -- an unprovisioned machine is the *ordinary* case the spool's
    /// bounds are sized for. Without this, every loss on a never-provisioned machine would
    /// accumulate in the spool's two pending lists forever with nothing ever draining them, and the
    /// tray's abandoned tally would never move.
    /// </summary>
    [Fact]
    public async Task BookkeepingRunsEvenWithNoUsableTarget()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new EventSpool(Settings(retention: TimeSpan.FromMinutes(1)), clock.Now);
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("will-expire")));
        Assert.Equal(EventSpoolAdmission.Refused, spool.Spool(session, 2, new byte[2 * 1024 * 1024]));
        clock.Advance(TimeSpan.FromMinutes(2));

        int sends = 0;
        var outcomes = new List<EventDeliveryOutcome>();
        var worker = new EventDeliveryWorker(
            isTargetUsable: () => false,
            deliver: (_, _) => { sends++; return Task.FromResult(EventSendOutcome.Acknowledged); },
            spool,
            outcome => outcomes.Add(outcome.Outcome));

        TimeSpan? due = await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Null(due);
        Assert.Equal(0, sends);
        Assert.Contains(EventDeliveryOutcome.Evicted, outcomes);
        Assert.Contains(EventDeliveryOutcome.Refused, outcomes);
        Assert.Equal(0, spool.Status.PendingCount);
    }

    /// <summary>
    /// Regression coverage for a defect found in adversarial review: per-session FIFO must hold
    /// across drain passes, not only within one. A session's earlier entry retrying must keep a
    /// later, never-yet-attempted entry of the *same* session from being attempted on a later pass,
    /// even though that later entry's own <c>NextAttemptAt</c> was never set (and so would otherwise
    /// look "due" in isolation).
    /// </summary>
    [Fact]
    public async Task ARetriedEntryStaysAheadOfALaterNeverAttemptedEntryOfTheSameSessionAcrossPasses()
    {
        var spool = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("first")));
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 2, Body("second")));

        var attempted = new List<string>();
        var worker = new EventDeliveryWorker(
            () => true,
            (body, _) =>
            {
                attempted.Add(System.Text.Encoding.UTF8.GetString(body.ToArray()));
                return Task.FromResult(EventSendOutcome.Retry);
            },
            spool);

        // Pass 1: only the session's earliest (never-attempted) entry is due; it retries.
        await worker.DrainOnceAsync(CancellationToken.None);
        Assert.Single(attempted);
        Assert.Contains(attempted, body => body.Contains("first"));

        // Pass 2, immediately after: the retried entry's own backoff has not elapsed. The second
        // entry was never attempted, so its own NextAttemptAt is still unset -- per-session FIFO
        // must still keep it from being attempted ahead of the first.
        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Single(attempted);
        Assert.Equal(2, spool.Status.PendingCount);
    }

    /// <summary>
    /// Companion to <see cref="ARetryableFailureStopsThatSessionsPassWithoutSkippingAhead"/>: a
    /// session halted by a retryable failure must not prevent a *different* session's entries from
    /// being attempted in the same pass.
    /// </summary>
    [Fact]
    public async Task ASecondSessionsEntriesAreStillAttemptedAfterTheFirstSessionHalts()
    {
        var spool = new EventSpool(Settings());
        string haltedSession = SessionId();
        string otherSession = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(haltedSession, 1, Body("halted")));
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(otherSession, 1, Body("other")));

        var attempted = new List<string>();
        var worker = new EventDeliveryWorker(
            () => true,
            (body, _) =>
            {
                attempted.Add(System.Text.Encoding.UTF8.GetString(body.ToArray()));
                return Task.FromResult(
                    System.Text.Encoding.UTF8.GetString(body.ToArray()).Contains("halted")
                        ? EventSendOutcome.Retry
                        : EventSendOutcome.Acknowledged);
            },
            spool);

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(2, attempted.Count);
        Assert.Equal(1, spool.Status.PendingCount);
    }

    /// <summary>
    /// Regression coverage for a deliberate correction to the #48 plan's §2.5 (PR review finding;
    /// see <see cref="EventSendOutcome.Unauthorized"/>'s own remarks): a 401/403 must stop networking
    /// -- not retry it on a timer -- while leaving the spooled entry exactly as untouched as an
    /// ordinary retry would. One entry coming back <see cref="EventSendOutcome.Unauthorized"/> must
    /// both leave every entry (this one and any other, in this session or another) still spooled,
    /// and stop the rest of *this* pass from attempting any further send at all.
    /// </summary>
    [Fact]
    public async Task AnUnauthorizedResponseParksTheRestOfThePassAndLeavesEveryEntrySpooled()
    {
        var spool = new EventSpool(Settings());
        string firstSession = SessionId();
        string secondSession = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(firstSession, 1, Body("first")));
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(secondSession, 1, Body("second")));

        int sends = 0;
        var outcomes = new List<EventDeliveryOutcome>();
        var worker = new EventDeliveryWorker(
            isTargetUsable: () => true,
            deliver: (_, _) => { sends++; return Task.FromResult(EventSendOutcome.Unauthorized); },
            spool,
            outcome => outcomes.Add(outcome.Outcome));

        TimeSpan? due = await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Null(due);
        Assert.Equal(1, sends);
        Assert.Equal(2, spool.Status.PendingCount);
        Assert.Equal(new[] { EventDeliveryOutcome.Retrying }, outcomes);
    }

    /// <summary>
    /// Companion to <see cref="AnUnauthorizedResponseParksTheRestOfThePassAndLeavesEveryEntrySpooled"/>:
    /// once a worker instance has seen an Unauthorized response, it must never call <c>deliver</c>
    /// again for the rest of its own lifetime -- even once the entry's own backoff has elapsed and it
    /// is genuinely due again -- so the clock is advanced well past the default backoff ceiling
    /// between passes to prove this is <c>_targetKnownRevoked</c> parking the worker, not a
    /// coincidence of timing. The only way sending resumes is a *new* <see cref="EventDeliveryWorker"/>
    /// instance -- exactly what <c>App.RefreshDeliveryTarget</c> constructs whenever the effective
    /// delivery target actually changes (not on every call regardless of whether it did -- see that
    /// method's own remarks) -- simulated here by constructing a second worker over the same spool.
    /// </summary>
    [Fact]
    public async Task AWorkerNeverSendsAgainAfterUnauthorizedUntilReplacedByAFreshOne()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new EventSpool(Settings(), clock.Now);
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("revoked")));

        int sends = 0;
        var worker = new EventDeliveryWorker(
            isTargetUsable: () => true,
            deliver: (_, _) => { sends++; return Task.FromResult(EventSendOutcome.Unauthorized); },
            spool);

        Assert.Null(await worker.DrainOnceAsync(CancellationToken.None));
        Assert.Equal(1, sends);

        // Well past the default 5-minute backoff ceiling, so the entry is genuinely due again --
        // proving the next assertion is _targetKnownRevoked parking the worker, not leftover backoff.
        clock.Advance(TimeSpan.FromMinutes(30));

        Assert.Null(await worker.DrainOnceAsync(CancellationToken.None));
        Assert.Equal(1, sends);
        Assert.Equal(1, spool.Status.PendingCount);

        // A fresh worker over the same spool -- what App.RefreshDeliveryTarget constructs on a real
        // provisioning change -- resumes sending.
        var replacement = new EventDeliveryWorker(
            isTargetUsable: () => true,
            deliver: (_, _) => { sends++; return Task.FromResult(EventSendOutcome.Acknowledged); },
            spool);

        await replacement.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(2, sends);
        Assert.Equal(0, spool.Status.PendingCount);
    }

    /// <summary>
    /// Regression coverage for a review finding: an Unauthorized response used to schedule a real
    /// future backoff via RecordRetry, so even a *replacement* (un-parked) worker would see the
    /// entry as "not yet due" and skip it on its own very first pass -- resuming only once that
    /// stale backoff, timed against a failure a clock could never have fixed, happened to elapse.
    /// Deliberately no clock advance at all here (unlike the companion test above): a replacement
    /// worker must attempt a previously-parked entry immediately.
    /// </summary>
    [Fact]
    public async Task AReplacementWorkerResumesAPreviouslyUnauthorizedEntryImmediatelyWithoutWaitingOutABackoff()
    {
        var spool = new EventSpool(Settings());
        string session = SessionId();
        Assert.Equal(EventSpoolAdmission.Spooled, spool.Spool(session, 1, Body("revoked")));

        var worker = new EventDeliveryWorker(
            isTargetUsable: () => true,
            deliver: (_, _) => Task.FromResult(EventSendOutcome.Unauthorized),
            spool);
        Assert.Null(await worker.DrainOnceAsync(CancellationToken.None));

        int sends = 0;
        var replacement = new EventDeliveryWorker(
            isTargetUsable: () => true,
            deliver: (_, _) => { sends++; return Task.FromResult(EventSendOutcome.Acknowledged); },
            spool);

        // No clock advance: this must succeed on the replacement's very first pass.
        await replacement.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(1, sends);
        Assert.Equal(0, spool.Status.PendingCount);
    }

    private string SessionId() => JazzCaptureCore.Identifiers.Prefixed("s");

    private static byte[] Body(string marker) => System.Text.Encoding.UTF8.GetBytes(
        "{\"resourceLogs\":[],\"marker\":\"" + marker + "\"}");

    private EventDeliverySettings Settings(TimeSpan? retention = null) => new()
    {
        SpoolDirectory = root,
        SpoolRetention = retention ?? TimeSpan.FromHours(48),
        MaximumBodyBytes = 1024 * 1024,
    };

    private sealed class MutableClock
    {
        private DateTimeOffset _now;

        public MutableClock(DateTimeOffset start) => _now = start;

        public DateTimeOffset Now() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
