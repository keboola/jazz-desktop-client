namespace JazzCaptureCore.Audio;

/// <summary>
/// What one Windows Core Audio HRESULT means for a narration clip, reduced to the distinctions a
/// user or a reader of the archive can act on.
/// </summary>
/// <remarks>
/// The categories exist because the responses differ. "You turned the microphone off" is fixed in
/// the privacy pane in ten seconds; "your microphone was unplugged" is fixed by plugging it back in;
/// "the audio service is not running" is not fixed by the user at all. Collapsing them into one
/// generic failure would leave the archive saying only that audio was unavailable, which is the one
/// thing the reader could already see from the absent clip.
/// </remarks>
public enum NarrationDeviceFault
{
    /// <summary>The call succeeded; there is no fault.</summary>
    None,

    /// <summary>Windows refused the microphone to this application.</summary>
    PermissionDenied,

    /// <summary>The endpoint was removed, disabled, or its format was reconfigured under us.</summary>
    DeviceInvalidated,

    /// <summary>Another application holds the endpoint in exclusive mode.</summary>
    DeviceInUse,

    /// <summary>The endpoint offers a sample format this recorder cannot read.</summary>
    UnsupportedFormat,

    /// <summary>The Windows Audio service is not running.</summary>
    AudioServiceStopped,

    /// <summary>There is no capture endpoint at all.</summary>
    NoDevice,

    /// <summary>Something else in the audio stack failed.</summary>
    DeviceFailure,
}

/// <summary>
/// The Windows Core Audio result codes the narration recorder acts on, and the reduction from one
/// HRESULT to a fault, a sentence, and a <see cref="NarrationStartResult"/>.
/// </summary>
/// <remarks>
/// <para>
/// This lives in the portable half deliberately. It is the part of the recorder most likely to be
/// wrong and the only part that can be proven right without a microphone: a COM call cannot run on a
/// build machine, but the decision "0x80070005 means the user refused, not that the device is
/// broken" is pure arithmetic over an int and is unit-tested as such. The interop layer above it
/// therefore holds no branching of its own — it makes the call and hands the HRESULT here.
/// </para>
/// <para>
/// The constants are transcribed from <c>audioclient.h</c> and <c>winerror.h</c>. Unlike a vtable
/// slot a wrong value here fails safely: an unrecognized code falls through to
/// <see cref="NarrationDeviceFault.DeviceFailure"/> and the raw HRESULT is printed in the detail, so
/// a misclassification is visible in the archive rather than silent.
/// </para>
/// </remarks>
public static class NarrationDeviceStatus
{
    /// <summary>The call succeeded.</summary>
    public const int Ok = 0;

    /// <summary>
    /// <c>AUDCLNT_S_BUFFER_EMPTY</c>: a success code meaning the capture buffer held no data. It is
    /// positive, so the ordinary failure test passes it through — which is the point, because a
    /// caller that treats it as an error will report a dead microphone every time the user pauses.
    /// </summary>
    public const int BufferEmpty = 0x08890001;

    /// <summary>
    /// <c>E_ACCESSDENIED</c>. On Windows 10 and 11 this is what
    /// <c>IAudioClient::Initialize</c> returns when the microphone privacy setting denies the app,
    /// and it is the whole reason this table exists.
    /// </summary>
    public const int AccessDenied = unchecked((int)0x80070005);

    /// <summary><c>HRESULT_FROM_WIN32(ERROR_NOT_FOUND)</c>: no endpoint of the requested kind.</summary>
    public const int NotFound = unchecked((int)0x80070490);

    /// <summary><c>AUDCLNT_E_NOT_INITIALIZED</c>.</summary>
    public const int NotInitialized = unchecked((int)0x88890001);

    /// <summary><c>AUDCLNT_E_DEVICE_INVALIDATED</c>: the endpoint went away mid-stream.</summary>
    public const int DeviceInvalidated = unchecked((int)0x88890004);

    /// <summary><c>AUDCLNT_E_UNSUPPORTED_FORMAT</c>.</summary>
    public const int UnsupportedFormat = unchecked((int)0x88890008);

    /// <summary><c>AUDCLNT_E_DEVICE_IN_USE</c>: held in exclusive mode by someone else.</summary>
    public const int DeviceInUse = unchecked((int)0x8889000A);

    /// <summary><c>AUDCLNT_E_ENDPOINT_CREATE_FAILED</c>.</summary>
    public const int EndpointCreateFailed = unchecked((int)0x8889000F);

    /// <summary><c>AUDCLNT_E_SERVICE_NOT_RUNNING</c>: the Windows Audio service is stopped.</summary>
    public const int ServiceNotRunning = unchecked((int)0x88890010);

    /// <summary><c>AUDCLNT_E_EVENTHANDLE_NOT_SET</c>: event-driven mode without a handle.</summary>
    public const int EventHandleNotSet = unchecked((int)0x88890014);

    /// <summary><c>AUDCLNT_E_RESOURCES_INVALIDATED</c>: the stream's resources were reclaimed.</summary>
    public const int ResourcesInvalidated = unchecked((int)0x88890026);

    /// <summary>Whether an HRESULT reports failure. Success codes are non-negative.</summary>
    /// <param name="hr">The result code.</param>
    public static bool Failed(int hr) => hr < 0;

    /// <summary>Whether an HRESULT is the "no data this time" success code.</summary>
    /// <param name="hr">The result code.</param>
    public static bool IsBufferEmpty(int hr) => hr == BufferEmpty;

    /// <summary>Reduces one HRESULT to the fault it represents.</summary>
    /// <param name="hr">The result code; any success code classifies as <see cref="NarrationDeviceFault.None"/>.</param>
    public static NarrationDeviceFault Classify(int hr) => !Failed(hr)
        ? NarrationDeviceFault.None
        : hr switch
        {
            AccessDenied => NarrationDeviceFault.PermissionDenied,
            NotFound => NarrationDeviceFault.NoDevice,
            DeviceInvalidated or ResourcesInvalidated => NarrationDeviceFault.DeviceInvalidated,
            DeviceInUse => NarrationDeviceFault.DeviceInUse,
            UnsupportedFormat => NarrationDeviceFault.UnsupportedFormat,
            ServiceNotRunning => NarrationDeviceFault.AudioServiceStopped,
            _ => NarrationDeviceFault.DeviceFailure,
        };

    /// <summary>The sentence a fault is reported as, written for the person who has to fix it.</summary>
    /// <param name="fault">The classified fault.</param>
    public static string Reason(NarrationDeviceFault fault) => fault switch
    {
        NarrationDeviceFault.None => "the audio stack reported success",
        NarrationDeviceFault.PermissionDenied =>
            "Windows denied microphone access to this application "
            + "(Settings > Privacy & security > Microphone)",
        NarrationDeviceFault.DeviceInvalidated =>
            "the capture device was removed, disabled or reconfigured",
        NarrationDeviceFault.DeviceInUse =>
            "another application holds the capture device in exclusive mode",
        NarrationDeviceFault.UnsupportedFormat =>
            "the capture device offers no sample format this recorder can read",
        NarrationDeviceFault.AudioServiceStopped => "the Windows Audio service is not running",
        NarrationDeviceFault.NoDevice => "no capture device is available",
        _ => "the capture device failed",
    };

    /// <summary>
    /// The detail string one failed call becomes: what was being done, why it failed, and the raw
    /// HRESULT.
    /// </summary>
    /// <remarks>
    /// The numeric code is kept alongside the sentence rather than replaced by it. The sentence is a
    /// guess at a category; the code is the fact, and it is the only thing that lets a support
    /// conversation about an unrecognized failure get anywhere.
    /// </remarks>
    /// <param name="operation">The call that failed, for example <c>IAudioClient.Initialize</c>.</param>
    /// <param name="hr">Its result code.</param>
    public static string Detail(string operation, int hr)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(operation);

        return Bounded(
            operation + ": " + Reason(Classify(hr)) + " (HRESULT 0x" + hr.ToString("X8") + ")");
    }

    /// <summary>
    /// The <see cref="NarrationStartResult"/> a failed start call becomes: a refusal is reported as
    /// a refusal and everything else as a device failure.
    /// </summary>
    /// <remarks>
    /// The two are separate archive facts — a denial is authorization state, a failure is
    /// availability state — and this is the single place the distinction is made, so no call site
    /// can quietly report one as the other.
    /// </remarks>
    /// <param name="operation">The call that failed.</param>
    /// <param name="hr">Its result code; must be a failure code.</param>
    public static NarrationStartResult StartFailure(string operation, int hr)
    {
        string detail = Detail(operation, hr);
        return Classify(hr) == NarrationDeviceFault.PermissionDenied
            ? NarrationStartResult.PermissionDenied(detail)
            : NarrationStartResult.Failed(detail);
    }

    /// <summary>
    /// Bounds a detail to what a capability observation accepts, so a long message from the audio
    /// stack degrades to a truncated one rather than throwing inside the capture engine.
    /// </summary>
    /// <param name="detail">The detail to bound; already trimmed by the caller or not.</param>
    public static string Bounded(string detail)
    {
        ArgumentNullException.ThrowIfNull(detail);

        string trimmed = detail.Trim();
        return trimmed.Length <= CapabilityObservation.MaxDetailLength
            ? trimmed
            : trimmed[..CapabilityObservation.MaxDetailLength].TrimEnd();
    }
}
