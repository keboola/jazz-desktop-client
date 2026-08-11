namespace JazzCaptureCore.Input;

/// <summary>The system pointer thresholds a gesture tracker needs.</summary>
/// <param name="DoubleClickMillis">The double-click time window (<c>GetDoubleClickTime</c>).</param>
/// <param name="DoubleClickWidth">Half-width of the double-click rectangle (<c>SM_CXDOUBLECLK</c>).</param>
/// <param name="DoubleClickHeight">Half-height of the double-click rectangle (<c>SM_CYDOUBLECLK</c>).</param>
/// <param name="DragWidth">Drag start threshold in x (<c>SM_CXDRAG</c>).</param>
/// <param name="DragHeight">Drag start threshold in y (<c>SM_CYDRAG</c>).</param>
public readonly record struct GestureMetrics(
    uint DoubleClickMillis,
    int DoubleClickWidth,
    int DoubleClickHeight,
    int DragWidth,
    int DragHeight);

/// <summary>The classified result of one press-release.</summary>
/// <param name="IsDrag">Whether the pointer moved beyond the drag threshold between down and up.</param>
/// <param name="ClickCount">
/// The coalesced multiplicity: 1, 2 or 3. A count of 1 is also the signal that this release did
/// <em>not</em> continue the previous sequence, which is what tells the coordinator its deferred
/// click has been displaced and must be published before this one replaces it.
/// </param>
public readonly record struct PointerRelease(bool IsDrag, int ClickCount);

/// <summary>
/// Derives click multiplicity and the click-versus-drag distinction from raw down/up samples, using
/// the platform's own double-click window and metrics (ANNEX-HOST section 7). It carries no timers:
/// the coordinator owns the deferral that coalesces a sequence into one gesture.
/// </summary>
/// <remarks>
/// The metrics are injected rather than read from Win32, so the arithmetic that decides "same
/// gesture or new one" is unit-tested in the portable core; the host only supplies
/// <c>GetDoubleClickTime</c> and the <c>SM_C*</c> metrics.
/// </remarks>
public sealed class PointerGestureTracker
{
    private const int MaxClickCount = 3;

    private readonly GestureMetrics _metrics;

    private int _downX;
    private int _downY;
    private bool _hasDown;

    private int _lastUpX;
    private int _lastUpY;
    private uint _lastUpTime;
    private int _lastClickCount;
    private bool _hasLastUp;

    /// <summary>Creates a tracker bound to the current system metrics.</summary>
    public PointerGestureTracker(GestureMetrics metrics) => _metrics = metrics;

    /// <summary>The double-click window, in milliseconds, used to arm a deferred-click flush.</summary>
    public uint DoubleClickBudget() => _metrics.DoubleClickMillis;

    /// <summary>Records a press so the next release can measure travel from it.</summary>
    public void OnDown(int x, int y)
    {
        _downX = x;
        _downY = y;
        _hasDown = true;
    }

    /// <summary>Classifies a release into a drag or a click of a given multiplicity.</summary>
    public PointerRelease OnUp(int x, int y, uint timeMs)
    {
        bool isDrag = _hasDown
            && (Math.Abs(x - _downX) > _metrics.DragWidth || Math.Abs(y - _downY) > _metrics.DragHeight);
        _hasDown = false;

        if (isDrag)
        {
            _hasLastUp = false;
            _lastClickCount = 0;
            return new PointerRelease(true, 1);
        }

        int clickCount = ContinuesSequence(x, y, timeMs)
            ? Math.Min(_lastClickCount + 1, MaxClickCount)
            : 1;

        _lastUpX = x;
        _lastUpY = y;
        _lastUpTime = timeMs;
        _lastClickCount = clickCount;
        _hasLastUp = true;
        return new PointerRelease(false, clickCount);
    }

    /// <summary>Forgets any pending multiplicity, so the next click starts a fresh sequence.</summary>
    public void ResetSequence()
    {
        _hasLastUp = false;
        _lastClickCount = 0;
    }

    private bool ContinuesSequence(int x, int y, uint timeMs) =>
        _hasLastUp
        && timeMs - _lastUpTime <= _metrics.DoubleClickMillis
        && Math.Abs(x - _lastUpX) <= _metrics.DoubleClickWidth
        && Math.Abs(y - _lastUpY) <= _metrics.DoubleClickHeight;
}
