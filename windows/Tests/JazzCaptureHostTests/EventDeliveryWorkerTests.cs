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
