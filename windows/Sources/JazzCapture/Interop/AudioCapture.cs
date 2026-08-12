using System.Runtime.InteropServices;

namespace JazzCapture.Interop;

/// <summary>
/// The slice of Windows Core Audio the narration recorder binds to: <c>MMDeviceEnumerator</c> for the
/// default capture endpoint, <c>IAudioClient</c> for a shared-mode event-driven stream, and
/// <c>IAudioCaptureClient</c> for the packets themselves.
/// </summary>
/// <remarks>
/// <para>
/// Hand-written for the same reason the UI Automation interop is: no source generator, no package,
/// and declarations that are pure metadata, so the project still restores and compiles on macOS with
/// <c>EnableWindowsTargeting</c> while the entry points resolve only on Windows.
/// </para>
/// <para>
/// <b>Every declared slot index is a claim the compiler cannot check.</b> A COM interface's method
/// order is its ABI: an index that is off by one does not fail to compile and does not fail cleanly
/// at run time — it calls whatever genuinely occupies that position, with this signature's arguments.
/// The slots are transcribed from <c>mmdeviceapi.h</c> and <c>audioclient.h</c> and numbered here
/// from 1, counting the first method after <c>IUnknown</c>; unused leading slots are declared as
/// placeholders purely to hold their positions, and unused trailing slots are not declared at all
/// because nothing past them is ever dialled. <c>JazzAudioProbe</c> exists to settle them against a
/// real endpoint, and prints each HRESULT separately so a wrong slot is distinguishable from a device
/// that simply had nothing to say.
/// </para>
/// <para>
/// Where a call hands back an interface the native signature types as <c>void**</c> — <c>Activate</c>
/// and <c>GetService</c> — it is marshalled as <c>IUnknown</c> and cast afterwards, rather than
/// declared as a typed out-parameter. Both forms end in a QueryInterface, but the explicit cast puts
/// it where a failure is visible and keeps the declaration the shape the header actually has. That
/// distinction is not academic here: a typed out-parameter forcing an unwanted QueryInterface is
/// exactly how the document-URL lookup was broken against real Chromium windows.
/// </para>
/// </remarks>
internal static class AudioInterop
{
    /// <summary>CLSID of the <c>MMDeviceEnumerator</c> coclass.</summary>
    internal static readonly Guid CLSID_MMDeviceEnumerator =
        new("BCDE0395-E52F-467C-8E3D-C4579291692E");

    /// <summary>IID of <see cref="IAudioClient"/>, for <c>IMMDevice::Activate</c>.</summary>
    internal static readonly Guid IID_IAudioClient = new("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");

    /// <summary>IID of <see cref="IAudioCaptureClient"/>, for <c>IAudioClient::GetService</c>.</summary>
    internal static readonly Guid IID_IAudioCaptureClient =
        new("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

    /// <summary><c>EDataFlow::eCapture</c>: endpoints the machine records from.</summary>
    internal const int eCapture = 1;

    /// <summary>
    /// <c>ERole::eConsole</c>: the endpoint the user thinks of as "the microphone". Deliberately not
    /// <c>eCommunications</c>, which is the device a voice-call application would take and is often a
    /// headset the user is not wearing.
    /// </summary>
    internal const int eConsole = 0;

    /// <summary><c>CLSCTX_ALL</c>.</summary>
    internal const uint CLSCTX_ALL = 0x17;

    /// <summary><c>AUDCLNT_SHAREMODE_SHARED</c>: never exclusive; the user's other audio keeps working.</summary>
    internal const int AUDCLNT_SHAREMODE_SHARED = 0;

    /// <summary>
    /// <c>AUDCLNT_STREAMFLAGS_EVENTCALLBACK</c>: the engine signals an event when a buffer is ready,
    /// instead of the client polling on a timer it has to guess the period of.
    /// </summary>
    internal const uint AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000;

    /// <summary><c>AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY</c>: samples were dropped before this packet.</summary>
    internal const uint AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY = 0x1;

    /// <summary>
    /// <c>AUDCLNT_BUFFERFLAGS_SILENT</c>: the packet's contents are undefined and are to be treated
    /// as silence. The frame count is still real, and still has to be written.
    /// </summary>
    internal const uint AUDCLNT_BUFFERFLAGS_SILENT = 0x2;

    /// <summary>Units of <c>REFERENCE_TIME</c> in one millisecond (it counts 100-nanosecond ticks).</summary>
    internal const long ReferenceTimesPerMillisecond = 10_000;

    /// <summary><c>WAIT_OBJECT_0</c>: the capture event was signalled.</summary>
    internal const uint WAIT_OBJECT_0 = 0x00000000;

    /// <summary><c>WAIT_TIMEOUT</c>: no buffer became ready inside the wait.</summary>
    internal const uint WAIT_TIMEOUT = 0x00000102;

    /// <summary><c>WAIT_FAILED</c>.</summary>
    internal const uint WAIT_FAILED = 0xFFFFFFFF;

    /// <summary>Creates the auto-reset event the audio engine signals when a packet is ready.</summary>
    /// <remarks>
    /// Auto-reset (<paramref name="manualReset"/> false) is required rather than preferred: a
    /// manual-reset event stays signalled, so the capture loop would spin at the speed of the CPU
    /// instead of the speed of the device.
    /// </remarks>
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr CreateEventW(
        IntPtr eventAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool manualReset,
        [MarshalAs(UnmanagedType.Bool)] bool initialState,
        string? name);

    /// <summary>Waits for the capture event, or for the wait to expire.</summary>
    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    /// <summary>Closes the capture event handle.</summary>
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseHandle(IntPtr handle);
}

/// <summary>
/// <c>WAVEFORMATEX</c>: the eighteen bytes every audio format description starts with.
/// </summary>
/// <remarks>
/// <c>Pack = 1</c> is load-bearing, not tidiness. The Windows headers pack these structures to one
/// byte, so <c>cbSize</c> sits at offset 16 and the extensible tail begins at 18. Left to the
/// default alignment the runtime would place the tail at 20, and every field of
/// <see cref="WaveFormatExtensible"/> would be read from the wrong offset — including the subformat
/// GUID that decides whether the samples are floats or integers.
/// </remarks>
[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal struct WaveFormatEx
{
    public ushort FormatTag;
    public ushort Channels;
    public uint SamplesPerSec;
    public uint AvgBytesPerSec;
    public ushort BlockAlign;
    public ushort BitsPerSample;

    /// <summary>Bytes of format-specific data following this header; 22 for the extensible form.</summary>
    public ushort Size;
}

/// <summary>
/// <c>WAVEFORMATEXTENSIBLE</c>: the header plus the channel mask and the subformat GUID that says
/// what the samples really are when <c>wFormatTag</c> is <c>WAVE_FORMAT_EXTENSIBLE</c>.
/// </summary>
[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal struct WaveFormatExtensible
{
    public WaveFormatEx Format;

    /// <summary>Union of <c>wValidBitsPerSample</c>, <c>wSamplesPerBlock</c> and <c>wReserved</c>.</summary>
    public ushort Samples;

    public uint ChannelMask;
    public Guid SubFormat;
}

/// <summary>
/// The device enumerator. Slot 1 is a placeholder; only
/// <see cref="GetDefaultAudioEndpoint"/> (2) is called, and slots 3-5 (<c>GetDevice</c> and the two
/// notification-callback registrations) are not declared because nothing past slot 2 is dialled.
/// </summary>
[ComImport]
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator
{
    [PreserveSig] int EnumAudioEndpoints_(); // 1

    // 2. Returns E_NOTFOUND when the machine has no capture endpoint at all, which is a fact about
    // the machine rather than a failure of this call, and is reported as such.
    [PreserveSig]
    int GetDefaultAudioEndpoint(
        int dataFlow,
        int role,
        [MarshalAs(UnmanagedType.Interface)] out IMMDevice? endpoint);
}

/// <summary>
/// One endpoint. Only <see cref="Activate"/> (slot 1) is called; <c>OpenPropertyStore</c> (2),
/// <c>GetId</c> (3) and <c>GetState</c> (4) are not declared.
/// </summary>
/// <remarks>
/// The endpoint's friendly name is deliberately not read. It would be the obvious thing to put in a
/// capability detail, and it is also the name the user gave their hardware — "Anna's AirPods" — which
/// is personal information the archive has no reason to carry to say that a microphone worked.
/// </remarks>
[ComImport]
[Guid("D666063F-1587-4E43-81F1-B948E807363F")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice
{
    // 1. The native signature is `void **ppInterface`, so the result is marshalled as IUnknown and
    // cast by the caller: the interface actually returned is chosen by `iid`, not by this
    // declaration. `activationParams` is a PROPVARIANT* and is always null for IAudioClient.
    [PreserveSig]
    int Activate(
        ref Guid iid,
        uint clsCtx,
        IntPtr activationParams,
        [MarshalAs(UnmanagedType.IUnknown)] out object? instance);
}

/// <summary>
/// The audio client. Slots 3-5 and 10 are placeholders; the recorder calls
/// <see cref="Initialize"/> (1), <see cref="GetBufferSize"/> (2), <see cref="GetMixFormat"/> (6),
/// <see cref="GetDevicePeriod"/> (7), <see cref="Start"/> (8), <see cref="Stop"/> (9),
/// <see cref="SetEventHandle"/> (11) and <see cref="GetService"/> (12).
/// </summary>
[ComImport]
[Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioClient
{
    // 1. `format` is the WAVEFORMATEX* the mix-format call handed back, passed through unchanged:
    // in shared mode the engine's own format is the only one guaranteed to be accepted, and
    // rebuilding it here would only introduce a way for the two to disagree. `sessionGuid` is null,
    // which puts the stream in the process's default audio session.
    //
    // This is the call the microphone privacy setting refuses at, with E_ACCESSDENIED.
    [PreserveSig]
    int Initialize(
        int shareMode,
        uint streamFlags,
        long bufferDuration,
        long periodicity,
        IntPtr format,
        IntPtr sessionGuid);

    // 2. Frames in the engine's buffer for this stream; read only to report it from the probe.
    [PreserveSig]
    int GetBufferSize(out uint bufferFrames);

    [PreserveSig] int GetStreamLatency_(); // 3
    [PreserveSig] int GetCurrentPadding_(); // 4
    [PreserveSig] int IsFormatSupported_(); // 5

    // 6. Hands back a CoTaskMemAlloc'd WAVEFORMATEX the caller must free. Whatever the endpoint is
    // already running at: this recorder adopts it and converts, rather than asking the engine to
    // convert for it.
    [PreserveSig]
    int GetMixFormat(out IntPtr format);

    // 7. Both in REFERENCE_TIME units. Read to size the buffer request against the device's own
    // period rather than a number chosen out of the air.
    [PreserveSig]
    int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);

    // 8
    [PreserveSig]
    int Start();

    // 9
    [PreserveSig]
    int Stop();

    [PreserveSig] int Reset_(); // 10

    // 11. Must be called after Initialize and before Start for an event-driven stream; omitting it
    // makes Start fail with AUDCLNT_E_EVENTHANDLE_NOT_SET.
    [PreserveSig]
    int SetEventHandle(IntPtr eventHandle);

    // 12. `void **ppv` again, so IUnknown plus a cast, for the same reason as IMMDevice::Activate.
    [PreserveSig]
    int GetService(
        ref Guid iid,
        [MarshalAs(UnmanagedType.IUnknown)] out object? service);
}

/// <summary>
/// The capture stream. All three slots are called: <see cref="GetBuffer"/> (1),
/// <see cref="ReleaseBuffer"/> (2) and <see cref="GetNextPacketSize"/> (3).
/// </summary>
[ComImport]
[Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioCaptureClient
{
    // 1. `data` points into the engine's own buffer and is valid only until ReleaseBuffer. It may
    // return the success code AUDCLNT_S_BUFFER_EMPTY, in which case no packet was acquired and
    // ReleaseBuffer must NOT be called: pairing a release with an empty get corrupts the engine's
    // idea of how much of its buffer is still in use.
    [PreserveSig]
    int GetBuffer(
        out IntPtr data,
        out uint frames,
        out uint flags,
        out ulong devicePosition,
        out ulong qpcPosition);

    // 2. Releases exactly the frame count the matching GetBuffer reported.
    [PreserveSig]
    int ReleaseBuffer(uint frames);

    // 3. Frames in the next packet, or zero when there is none waiting.
    [PreserveSig]
    int GetNextPacketSize(out uint frames);
}
