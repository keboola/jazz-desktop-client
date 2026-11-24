namespace JazzCapture.Capture;

/// <summary>
/// Decides whether a pointer gesture may take a screenshot, so a burst of clicks costs one frame
/// instead of one per click. The first gesture after a quiet interval is admitted; later gestures
/// inside <c>interval</c> of the last admitted one are not. The gesture itself is always emitted by
/// the caller, only the picture is skipped.
/// </summary>
/// <remarks>
/// Not thread-safe; <see cref="CaptureCoordinator"/> calls it from its single worker thread only.
/// </remarks>
public sealed class ScreenshotThrottle
{
    private readonly TimeSpan _interval;
    private DateTimeOffset _lastAdmittedAt = DateTimeOffset.MinValue;

    /// <summary>Creates a throttle that admits one screenshot per <paramref name="interval"/>.</summary>
    public ScreenshotThrottle(TimeSpan interval) => _interval = interval;

    /// <summary>
    /// Whether a screenshot may be taken at <paramref name="now"/>. A true result starts a new
    /// interval. A clock that moved backwards admits the screenshot rather than blocking it until
    /// the clock catches up.
    /// </summary>
    public bool TryAdmit(DateTimeOffset now)
    {
        TimeSpan elapsed = now - _lastAdmittedAt;
        if (elapsed >= TimeSpan.Zero && elapsed < _interval)
        {
            return false;
        }

        _lastAdmittedAt = now;
        return true;
    }
}
