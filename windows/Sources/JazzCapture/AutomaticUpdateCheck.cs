using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// One pass of the background update loop. When the device policy turns automatic updates off, the
/// pass asks nothing, downloads nothing and installs nothing. An older server sends no value, which
/// means on.
/// </summary>
internal sealed class AutomaticUpdateCheck
{
    private readonly Func<bool> _autoUpdateAllowed;
    private readonly Func<CancellationToken, Task<AvailableRelease?>> _check;
    private readonly Func<AvailableRelease, Task> _announceAndApply;

    internal AutomaticUpdateCheck(
        Func<bool> autoUpdateAllowed,
        Func<CancellationToken, Task<AvailableRelease?>> check,
        Func<AvailableRelease, Task> announceAndApply)
    {
        _autoUpdateAllowed = autoUpdateAllowed;
        _check = check;
        _announceAndApply = announceAndApply;
    }

    internal async Task RunAsync(CancellationToken cancellationToken)
    {
        if (!_autoUpdateAllowed()) return;
        AvailableRelease? release = await _check(cancellationToken).ConfigureAwait(false);
        if (release is null || !_autoUpdateAllowed()) return;
        await _announceAndApply(release).ConfigureAwait(false);
    }
}
