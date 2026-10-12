namespace JazzCaptureCore.Screen;

/// <summary>
/// The one physical screenshot slot of this process, shared by every capture session it runs.
/// </summary>
/// <remarks>
/// <see cref="SingleFlightGate"/> promises one physical capture process-wide, but that promise only
/// holds if there is one gate. The host builds a new screenshot path for every session, and a
/// session now ends whenever the user changes an exemption or marks a session end. A physical
/// capture that wedged in the old session keeps running after the rotation — the gate never cancels
/// one — so a per-session gate would let the new session start a second capture beside it. Owning
/// the slot here, for the life of the process, keeps that second capture out until the first has
/// actually returned.
/// </remarks>
public static class PhysicalScreenshotSlot
{
    /// <summary>The process-lifetime slot every screenshot path acquires.</summary>
    public static SingleFlightGate Gate { get; } = new();
}
