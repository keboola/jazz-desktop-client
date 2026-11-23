namespace JazzCaptureCore.Journal;

/// <summary>
/// Write-ahead log batching of one <see cref="CaptureJournal"/>. Mutations are buffered in memory
/// and written as one file with one flush, so a crash loses at most the mutations buffered since
/// the last flush: at most <see cref="FlushInterval"/> of events.
/// </summary>
public sealed record JournalOptions
{
    /// <summary>Default longest time a mutation stays only in memory: one second.</summary>
    public static TimeSpan DefaultFlushInterval { get; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// Default size at which the buffer is written at once: 1 MiB of segment text. A normal event
    /// is a few kilobytes, so this is reached only by a burst of hundreds of events inside one
    /// interval. It bounds the memory held by the buffer and the events one crash can lose in a
    /// burst.
    /// </summary>
    public const int DefaultMaxBufferedBytes = 1024 * 1024;

    /// <summary>
    /// Time between the first buffered mutation and the write of the buffer. The timer starts when
    /// the buffer becomes non-empty, so two timed writes are at least this far apart.
    /// </summary>
    public TimeSpan FlushInterval { get; init; } = DefaultFlushInterval;

    /// <summary>Buffered segment bytes at which the buffer is written without waiting for the timer.</summary>
    public int MaxBufferedBytes { get; init; } = DefaultMaxBufferedBytes;

    /// <summary>Source of the flush timer; replaced in tests so that time moves only on request.</summary>
    public TimeProvider TimeProvider { get; init; } = TimeProvider.System;

    internal void Validate()
    {
        if (FlushInterval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(FlushInterval), FlushInterval, "The flush interval must be positive.");
        }

        if (MaxBufferedBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(MaxBufferedBytes), MaxBufferedBytes, "The buffer limit must be positive.");
        }

        ArgumentNullException.ThrowIfNull(TimeProvider);
    }
}
