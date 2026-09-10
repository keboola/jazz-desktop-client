namespace JazzCaptureCore;

/// <summary>
/// Guards the one automatic capture-start evaluation a process is allowed to make.
/// </summary>
/// <remarks>
/// A failed start is still an attempted automatic start. Retrying it later in the same process
/// could silently begin recording after the user has seen an idle client, so the gate closes before
/// invoking the host callback.
/// </remarks>
public sealed class CaptureStartupGate
{
    private bool _evaluated;

    /// <summary>Attempts the supplied start callback once when the pure policy permits it.</summary>
    public bool TryStart(
        bool ownsSingleInstance,
        bool initializationSucceeded,
        bool recoveryCompleted,
        bool captureAtLaunchEnabled,
        bool captureAtLaunchPaused,
        Func<bool> start)
    {
        ArgumentNullException.ThrowIfNull(start);

        if (_evaluated)
        {
            return false;
        }

        _evaluated = true;
        return CaptureStartupDecision.ShouldStart(
                ownsSingleInstance,
                initializationSucceeded,
                recoveryCompleted,
                captureAtLaunchEnabled,
                captureAtLaunchPaused)
            && start();
    }
}
