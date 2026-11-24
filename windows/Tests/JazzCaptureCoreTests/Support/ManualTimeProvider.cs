namespace JazzCaptureCoreTests;

/// <summary>
/// A time source whose timers fire only inside <see cref="Advance"/>, on the calling thread, so a
/// test decides exactly when the journal's flush timer runs.
/// </summary>
internal sealed class ManualTimeProvider : TimeProvider
{
    private readonly List<ManualTimer> _timers = new();
    private TimeSpan _now;

    public override long TimestampFrequency => TimeSpan.TicksPerSecond;

    public override long GetTimestamp() => _now.Ticks;

    /// <summary>Number of timers that are armed and have not fired yet.</summary>
    public int ArmedTimers => _timers.Count(timer => timer.DueAt is not null);

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state);
        timer.Change(dueTime, period);
        _timers.Add(timer);
        return timer;
    }

    /// <summary>Moves time forward and runs every timer that falls due, in due order.</summary>
    public void Advance(TimeSpan by)
    {
        TimeSpan target = _now + by;
        while (true)
        {
            ManualTimer? next = _timers
                .Where(timer => timer.DueAt is { } due && due <= target)
                .OrderBy(timer => timer.DueAt)
                .FirstOrDefault();
            if (next is null)
            {
                break;
            }

            _now = next.DueAt!.Value;
            next.Fire();
        }

        _now = target;
    }

    private sealed class ManualTimer : ITimer
    {
        private readonly ManualTimeProvider _owner;
        private readonly TimerCallback _callback;
        private readonly object? _state;
        private TimeSpan _period;

        public ManualTimer(ManualTimeProvider owner, TimerCallback callback, object? state)
        {
            _owner = owner;
            _callback = callback;
            _state = state;
        }

        public TimeSpan? DueAt { get; private set; }

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            DueAt = dueTime == Timeout.InfiniteTimeSpan ? null : _owner._now + dueTime;
            _period = period;
            return true;
        }

        public void Fire()
        {
            DueAt = _period == Timeout.InfiniteTimeSpan || _period == TimeSpan.Zero ? null : DueAt + _period;
            _callback(_state);
        }

        public void Dispose() => DueAt = null;

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
