namespace JazzCapture;

internal enum CapturePresentationState
{
    Idle,
    Recording,
    SafeStopPending,
    SafeStopFaulted,

    /// <summary>
    /// An exemption change could not commit the previous session. Not a pause the user chose, and
    /// not a recording: every producer is stopped and the journal waits for a retry or recovery.
    /// </summary>
    ExemptionSuspended,
}

internal readonly record struct CaptureStatusPresentation(
    CapturePresentationState State,
    bool ShowsRecording,
    string Status,
    string ActionText,
    bool ActionEnabled)
{
    internal static CaptureStatusPresentation Resolve(
        bool ownsActiveCapture,
        bool safeStopPending,
        bool safeStopFaulted,
        ExemptionSuspension exemptionSuspension = ExemptionSuspension.None)
    {
        // First: an exemption suspension is a safe stop too (the completion attempt left
        // _captureStopping set), but its retry is the exemption retry, which restarts capture once
        // the old session commits, rather than a plain stop that leaves capture off.
        if (exemptionSuspension != ExemptionSuspension.None)
        {
            bool retryable = exemptionSuspension == ExemptionSuspension.Retryable;
            return new CaptureStatusPresentation(
                CapturePresentationState.ExemptionSuspended,
                false,
                ExemptionChange.SuspendedNotice,
                // A fault cannot be retried in this process, and this build has no Quit. Signing out
                // ends the process; Jazz starts again at the next sign-in and its startup recovery
                // commits the preserved journal, after which capture starts under the saved list.
                retryable ? "Retry applying exemptions" : "Sign out of Windows to recover capture",
                retryable);
        }

        if (safeStopFaulted)
        {
            return new CaptureStatusPresentation(
                CapturePresentationState.SafeStopFaulted,
                false,
                "Capture stopped — journal preserved",
                "Capture journal preserved — quit Jazz",
                false);
        }

        if (safeStopPending)
        {
            return new CaptureStatusPresentation(
                CapturePresentationState.SafeStopPending,
                false,
                "Capture stopped — safe commit pending",
                "Retry safe stop",
                true);
        }

        return ownsActiveCapture
            ? new CaptureStatusPresentation(
                CapturePresentationState.Recording,
                true,
                "Recording",
                "Pause capture",
                true)
            : new CaptureStatusPresentation(
                CapturePresentationState.Idle,
                false,
                "Idle",
                "Resume capture",
                true);
    }
}
