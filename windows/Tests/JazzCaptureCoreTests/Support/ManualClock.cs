namespace JazzCaptureCoreTests;

/// <summary>
/// A monotonic clock that moves only when a test says so, so that backoff and deadline boundaries
/// are asserted to the tick rather than raced against the wall clock.
/// </summary>
internal sealed class ManualClock : TimeProvider
{
    private long _ticks;

    public override long TimestampFrequency => TimeSpan.TicksPerSecond;

    public override long GetTimestamp() => Interlocked.Read(ref _ticks);

    public void Advance(TimeSpan by) => Interlocked.Add(ref _ticks, by.Ticks);
}
