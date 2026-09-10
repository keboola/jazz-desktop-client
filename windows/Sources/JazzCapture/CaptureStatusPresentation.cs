namespace JazzCapture;

internal enum CapturePresentationState
{
    Idle,
    Recording,
    SafeStopPending,
    SafeStopFaulted,
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
        bool safeStopFaulted)
    {
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
                "Stop capture",
                true)
            : new CaptureStatusPresentation(
                CapturePresentationState.Idle,
                false,
                "Idle",
                "Start capture",
                true);
    }
}
