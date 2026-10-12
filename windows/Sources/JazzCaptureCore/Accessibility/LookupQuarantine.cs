namespace JazzCaptureCore.Accessibility;

/// <summary>How one accessibility lookup ended, as far as the quarantine is concerned.</summary>
/// <remarks>
/// A bare <see langword="null"/> could not tell "this page has no document" from "the provider
/// failed to answer", and only the second one is a reason to stop asking. Each outcome therefore says
/// which it was.
/// </remarks>
public enum LookupOutcome
{
    /// <summary>The lookup finished in time and produced a value.</summary>
    Found,

    /// <summary>
    /// The lookup finished in time and there is legitimately nothing to read: no document, no
    /// selection, a password field. The provider answered, so it is healthy.
    /// </summary>
    Absent,

    /// <summary>
    /// The provider answered badly: a failed HRESULT, a property read that failed under
    /// <c>PreserveSig</c>, an exception, or an answer that arrived after the caller's deadline.
    /// </summary>
    Failed,

    /// <summary>
    /// The provider was never asked — a gate, a missing automation object, or a caller that had
    /// already given up — so the attempt proves nothing either way.
    /// </summary>
    Skipped,
}

/// <summary>Tuning for a <see cref="LookupQuarantine{TKey}"/>; the host keeps these in its settings.</summary>
public sealed record LookupQuarantineOptions
{
    private readonly TimeSpan _initialBackoff;
    private readonly TimeSpan _maxBackoff;
    private readonly int _capacity;
    private readonly TimeSpan _idleRetention;

    /// <summary>Creates the options; see each property for its meaning.</summary>
    public LookupQuarantineOptions(
        TimeSpan initialBackoff,
        TimeSpan maxBackoff,
        int capacity,
        TimeSpan idleRetention)
    {
        InitialBackoff = initialBackoff;
        MaxBackoff = maxBackoff;
        Capacity = capacity;
        IdleRetention = idleRetention;
    }

    /// <summary>The pause after the first failure; each further consecutive failure doubles it.</summary>
    public TimeSpan InitialBackoff
    {
        get => _initialBackoff;
        init => _initialBackoff = value > TimeSpan.Zero
            ? value
            : throw new ArgumentOutOfRangeException(nameof(InitialBackoff), value, "Must be positive.");
    }

    /// <summary>The longest pause, however many failures have accumulated.</summary>
    public TimeSpan MaxBackoff
    {
        get => _maxBackoff;
        init => _maxBackoff = value >= _initialBackoff
            ? value
            : throw new ArgumentOutOfRangeException(
                nameof(MaxBackoff), value, "Must not be shorter than the initial backoff.");
    }

    /// <summary>
    /// How many keys are remembered at once. A browser session opens and closes windows all day, so
    /// without a cap the map would grow with every window handle the user ever clicked in.
    /// </summary>
    public int Capacity
    {
        get => _capacity;
        init => _capacity = value >= 1
            ? value
            : throw new ArgumentOutOfRangeException(nameof(Capacity), value, "Must be at least one.");
    }

    /// <summary>
    /// How long a key with no lookups may keep its failure history. A window nobody has clicked in
    /// for this long is most likely gone, and its handle may be reused by an unrelated window.
    /// </summary>
    public TimeSpan IdleRetention
    {
        get => _idleRetention;
        init => _idleRetention = value > TimeSpan.Zero
            ? value
            : throw new ArgumentOutOfRangeException(nameof(IdleRetention), value, "Must be positive.");
    }
}

/// <summary>
/// An expiring, per-key quarantine for best-effort accessibility lookups (the page URL and the text
/// selection), which pauses a slow or failing provider instead of dropping it for the whole session.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why it expires.</b> A browser is one long-lived process that owns every one of its windows. The
/// first Windows client remembered a slow lookup per process for the rest of the session, so one slow
/// page in the morning cost the page address of every later click in that browser for the whole
/// working day (issue #111). Here a failure pauses its key for a backoff that starts at
/// <see cref="LookupQuarantineOptions.InitialBackoff"/> and doubles with each consecutive failure up
/// to <see cref="LookupQuarantineOptions.MaxBackoff"/>; a lookup that then completes in time clears
/// the history.
/// </para>
/// <para>
/// <b>Eligibility is not history.</b> When a pause expires the key becomes eligible for exactly one
/// recovery probe, and its failure count stays. Only a qualifying answer (<see cref="LookupOutcome.Found"/>
/// or <see cref="LookupOutcome.Absent"/> within the deadline) resets it, so a provider that is still
/// slow is paused for longer each time rather than costing one slow click every 30 seconds. History is
/// otherwise forgotten only by capacity eviction or after
/// <see cref="LookupQuarantineOptions.IdleRetention"/> without activity.
/// </para>
/// <para>
/// <b>One verdict per attempt.</b> Each admitted lookup is a <see cref="LookupAttempt{TKey}"/> with an
/// absolute deadline and exactly one terminal outcome, however many paths report it — the caller's
/// expired wait, a worker-side exception and a late completion are one failure, not three. An
/// attempt carries the generation of the entry it was admitted against, so a completion that arrives
/// after the entry was tripped, reset, evicted or recreated cannot rewrite the newer state.
/// </para>
/// <para>
/// <b>At capacity.</b> A new key first evicts an idle entry, then the least recently used healthy
/// one, then the least recently used entry whose pause has expired and which has no probe in flight.
/// A key that is cooling down or probing is never evicted, because forgetting it would immediately
/// re-admit the provider that is being protected against. When every entry is in that state the new
/// key is refused (its lookup is skipped) rather than admitted untracked: that many simultaneously
/// failing windows means accessibility as a whole is struggling, and an unbounded number of untracked
/// slow lookups is the very cost this type exists to cap.
/// </para>
/// <para>
/// Pure: no Win32 and no UI Automation. Time comes from the injected monotonic
/// <see cref="TimeProvider"/>, so every boundary is testable to the tick.
/// </para>
/// </remarks>
/// <typeparam name="TKey">What one quarantine decision covers, such as a process and window.</typeparam>
public sealed class LookupQuarantine<TKey>
    where TKey : notnull
{
    private readonly LookupQuarantineOptions _options;
    private readonly TimeProvider _clock;
    private readonly long _origin;
    private readonly Dictionary<TKey, Entry> _entries = new();
    private readonly object _gate = new();
    private long _nextGeneration;

    /// <summary>Creates an empty quarantine.</summary>
    /// <param name="options">Backoff, capacity and retention.</param>
    /// <param name="clock">A monotonic clock; <see cref="TimeProvider.System"/> in the host.</param>
    public LookupQuarantine(LookupQuarantineOptions options, TimeProvider clock)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));

        // Re-checked here because a `with` expression can lower the initial backoff past the maximum
        // after both were validated.
        if (options.MaxBackoff < options.InitialBackoff)
        {
            throw new ArgumentOutOfRangeException(nameof(options), "MaxBackoff is shorter than InitialBackoff.");
        }

        _origin = clock.GetTimestamp();
    }

    /// <summary>How many keys currently have an entry; a diagnostic bounded by the capacity.</summary>
    public int TrackedKeys
    {
        get
        {
            lock (_gate)
            {
                return _entries.Count;
            }
        }
    }

    /// <summary>Monotonic time since construction.</summary>
    internal TimeSpan Now => _clock.GetElapsedTime(_origin);

    /// <summary>
    /// Asks whether a lookup on <paramref name="key"/> may run now, and if so admits it.
    /// </summary>
    /// <param name="key">The key the lookup belongs to.</param>
    /// <param name="budget">How long the caller will wait; becomes the attempt's absolute deadline.</param>
    /// <returns>
    /// The admitted attempt, which the caller and the worker must drive to a terminal state; or
    /// <see langword="null"/> when the key is cooling down, already has its recovery probe in flight,
    /// the quarantine is full of active keys, or there is no budget left to spend.
    /// </returns>
    public LookupAttempt<TKey>? TryBegin(TKey key, TimeSpan budget)
    {
        if (budget <= TimeSpan.Zero)
        {
            return null;
        }

        lock (_gate)
        {
            TimeSpan now = Now;
            if (_entries.TryGetValue(key, out Entry? entry) && IsIdle(entry, now))
            {
                _entries.Remove(key);
                entry = null;
            }

            if (entry is null)
            {
                if (_entries.Count >= _options.Capacity && !EvictOne(now))
                {
                    return null;
                }

                entry = new Entry(++_nextGeneration);
                _entries.Add(key, entry);
            }

            bool probe = entry.Failures > 0;
            if (probe && (now < entry.RetryAt || entry.Probe is not null))
            {
                return null;
            }

            entry.LastActivity = now;
            var attempt = new LookupAttempt<TKey>(this, key, entry, entry.Generation, probe, now + budget);
            if (probe)
            {
                entry.Probe = attempt;
            }

            return attempt;
        }
    }

    /// <summary>Applies an attempt's one terminal outcome to its entry, unless the entry has moved on.</summary>
    internal void Record(LookupAttempt<TKey> attempt, LookupOutcome outcome)
    {
        if (outcome == LookupOutcome.Skipped)
        {
            return;
        }

        lock (_gate)
        {
            // A stale attempt: its entry was evicted or recreated, or was tripped or reset by another
            // attempt after this one began. Either way the newer state is the truth.
            if (!_entries.TryGetValue(attempt.Key, out Entry? entry)
                || !ReferenceEquals(entry, attempt.Entry)
                || entry.Generation != attempt.Generation)
            {
                return;
            }

            TimeSpan now = Now;
            entry.LastActivity = now;
            if (outcome == LookupOutcome.Failed)
            {
                entry.Failures++;
                entry.RetryAt = now + Backoff(entry.Failures);
                entry.Generation = ++_nextGeneration;
            }
            else if (entry.Failures > 0)
            {
                entry.Failures = 0;
                entry.RetryAt = TimeSpan.Zero;
                entry.Generation = ++_nextGeneration;
            }
        }
    }

    /// <summary>Frees the recovery-probe slot an attempt held, once nothing is running for it any more.</summary>
    internal void Release(LookupAttempt<TKey> attempt)
    {
        if (!attempt.IsProbe)
        {
            return;
        }

        lock (_gate)
        {
            if (ReferenceEquals(attempt.Entry.Probe, attempt))
            {
                attempt.Entry.Probe = null;
            }
        }
    }

    private TimeSpan Backoff(int failures)
    {
        // Capped before shifting so that a long-lived failing key cannot overflow the multiplier.
        int doublings = Math.Min(failures - 1, 30);
        double ticks = _options.InitialBackoff.Ticks * Math.Pow(2, doublings);
        return ticks >= _options.MaxBackoff.Ticks ? _options.MaxBackoff : TimeSpan.FromTicks((long)ticks);
    }

    private bool IsIdle(Entry entry, TimeSpan now) =>
        entry.Probe is null
        && now >= entry.RetryAt
        && now - entry.LastActivity >= _options.IdleRetention;

    /// <summary>Makes room for one key; see the class remarks for the order.</summary>
    private bool EvictOne(TimeSpan now)
    {
        TKey? victim = default;
        int victimRank = int.MaxValue;
        TimeSpan victimActivity = TimeSpan.MaxValue;
        bool found = false;

        foreach ((TKey key, Entry entry) in _entries)
        {
            if (entry.Probe is not null || now < entry.RetryAt)
            {
                continue;
            }

            int rank = IsIdle(entry, now) ? 0 : entry.Failures == 0 ? 1 : 2;
            if (rank < victimRank || (rank == victimRank && entry.LastActivity < victimActivity))
            {
                victim = key;
                victimRank = rank;
                victimActivity = entry.LastActivity;
                found = true;
            }
        }

        if (found)
        {
            _entries.Remove(victim!);
        }

        return found;
    }

    /// <summary>Mutable per-key state; touched only under the quarantine's lock.</summary>
    internal sealed class Entry
    {
        public Entry(long generation) => Generation = generation;

        /// <summary>Changes on every trip and reset, so attempts admitted earlier become stale.</summary>
        public long Generation { get; set; }

        public int Failures { get; set; }

        public TimeSpan RetryAt { get; set; }

        public TimeSpan LastActivity { get; set; }

        public LookupAttempt<TKey>? Probe { get; set; }
    }
}

/// <summary>
/// One admitted lookup, shared between the caller that waits for it and the worker that runs it.
/// </summary>
/// <remarks>
/// <para>
/// UI Automation cannot be cancelled, so a caller whose wait expires abandons the attempt and the
/// worker may still be inside the provider. The attempt is therefore a small state machine with one
/// owner per transition: the worker claims it with <see cref="TryStart"/> before asking the provider
/// anything, and the caller gives up with <see cref="Abandon"/>.
/// </para>
/// <list type="bullet">
/// <item>Abandoned before the worker reached it — or reached after its deadline — the provider was
/// never asked: the worker drops it without calling UI Automation, the outcome is
/// <see cref="LookupOutcome.Skipped"/>, and the key is not blamed for time spent queued behind
/// somebody else's slow lookup.</item>
/// <item>Abandoned while running, the provider is genuinely slow: that is the attempt's failure,
/// recorded at once so that later clicks stop queueing behind it. A recovery probe keeps its slot
/// until the worker actually returns, so no second call is stacked onto a wedged provider.</item>
/// <item>Completed by the worker, the outcome is judged against the deadline: an answer after it is a
/// failure, never a success.</item>
/// </list>
/// </remarks>
/// <typeparam name="TKey">The quarantine's key type.</typeparam>
public sealed class LookupAttempt<TKey>
    where TKey : notnull
{
    private const int Queued = 0;
    private const int Running = 1;
    private const int Dropped = 2;
    private const int Finished = 3;

    private readonly LookupQuarantine<TKey> _owner;
    private int _state = Queued;
    private int _recorded;

    internal LookupAttempt(
        LookupQuarantine<TKey> owner,
        TKey key,
        LookupQuarantine<TKey>.Entry entry,
        long generation,
        bool isProbe,
        TimeSpan deadline)
    {
        _owner = owner;
        Key = key;
        Entry = entry;
        Generation = generation;
        IsProbe = isProbe;
        Deadline = deadline;
    }

    /// <summary>The key this attempt was admitted for.</summary>
    public TKey Key { get; }

    /// <summary>Whether this is the single recovery probe of a key with failure history.</summary>
    public bool IsProbe { get; }

    internal LookupQuarantine<TKey>.Entry Entry { get; }

    internal long Generation { get; }

    internal TimeSpan Deadline { get; }

    /// <summary>
    /// Called by the worker before it asks the provider anything. Returns <see langword="false"/>
    /// when the caller has already given up or the deadline has passed; the worker must then skip the
    /// lookup entirely, and need not call <see cref="Complete"/>.
    /// </summary>
    public bool TryStart()
    {
        if (_owner.Now >= Deadline)
        {
            if (Interlocked.CompareExchange(ref _state, Dropped, Queued) == Queued)
            {
                _owner.Release(this);
            }

            return false;
        }

        return Interlocked.CompareExchange(ref _state, Running, Queued) == Queued;
    }

    /// <summary>Called by the caller when its wait expired (or the work could not be posted).</summary>
    public void Abandon()
    {
        int previous = Interlocked.CompareExchange(ref _state, Dropped, Queued);
        if (previous == Queued)
        {
            _owner.Release(this);
        }
        else if (previous == Running)
        {
            // Still inside the provider: the timeout is this attempt's failure. The probe slot stays
            // held until the worker's Complete.
            RecordOnce(LookupOutcome.Failed);
        }
    }

    /// <summary>Called by the worker exactly when it has finished asking the provider.</summary>
    /// <param name="outcome">What the provider answered; a late answer is downgraded to a failure.</param>
    public void Complete(LookupOutcome outcome)
    {
        while (true)
        {
            int state = Volatile.Read(ref _state);
            if (state is Dropped or Finished)
            {
                return;
            }

            if (Interlocked.CompareExchange(ref _state, Finished, state) == state)
            {
                break;
            }
        }

        if (outcome != LookupOutcome.Skipped && _owner.Now > Deadline)
        {
            outcome = LookupOutcome.Failed;
        }

        RecordOnce(outcome);
        _owner.Release(this);
    }

    private void RecordOnce(LookupOutcome outcome)
    {
        if (Interlocked.Exchange(ref _recorded, 1) == 0)
        {
            _owner.Record(this, outcome);
        }
    }
}
