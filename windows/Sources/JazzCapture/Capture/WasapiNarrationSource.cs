using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using JazzCaptureCore;
using JazzCaptureCore.Audio;
using JazzCapture.Interop;

namespace JazzCapture.Capture;

/// <summary>
/// The microphone, recorded through WASAPI in shared mode, for exactly as long as one label is open.
/// </summary>
/// <remarks>
/// <para>
/// <b>The microphone runs inside a label and nowhere else.</b> There is no session-long recording
/// here and no way to ask for one: the device is opened by <see cref="StartClip"/> when the user says
/// what they are doing, and it is stopped and released by <see cref="SealClip"/> when they say they
/// have stopped doing it. A user who never declares a label never has a microphone opened on their
/// behalf. Everything else in this class is in service of that being true even when things go wrong —
/// which is why a failed start, an abandoned start and a disposal all end with the endpoint released
/// rather than with a thread left holding it.
/// </para>
/// <para>
/// One dedicated thread per clip owns every COM object it creates, from
/// <c>CoInitializeEx</c> to the final release. Apartment-marshalling a capture stream between threads
/// would be both slower and a source of failures that only appear on someone else's machine; a thread
/// that creates, uses and destroys its own objects has none of that. The thread is event-driven —
/// <c>AUDCLNT_STREAMFLAGS_EVENTCALLBACK</c> and a wait on the handle the engine signals — rather than
/// polling on a timer whose period it would have to guess.
/// </para>
/// <para>
/// <b>No judgement is made in this class that could have been made without a device.</b> Which
/// HRESULT means a refusal, which mix formats are readable, how silence is written and where the
/// clip's ceiling falls all live in <see cref="JazzCaptureCore.Audio"/>, where they are unit-tested on
/// a machine with no microphone at all. What is left here is the call sequence and the lifetime, and
/// those are what <c>JazzAudioProbe</c> is for.
/// </para>
/// </remarks>
public sealed class WasapiNarrationSource : INarrationSource, IDisposable
{
    /// <summary>
    /// Longest <see cref="StartClip"/> waits for the device to come up. The engine calls it under
    /// its own lock while the user waits for the label prompt to close, so this is a budget rather
    /// than a formality: a start that has not happened in two seconds is reported as a failure and
    /// the label brackets no audio.
    /// </summary>
    public static readonly TimeSpan DefaultStartBudget = TimeSpan.FromSeconds(2);

    /// <summary>Longest <see cref="SealClip"/> waits for the capture thread to stop and release.</summary>
    public static readonly TimeSpan DefaultSealBudget = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Buffer the engine is asked to allocate for the stream, in milliseconds. Large enough that an
    /// ordinary scheduling hiccup on the capture thread does not lose samples, small enough that the
    /// clip's tail is not made of stale ones.
    /// </summary>
    private const long BufferDurationMillis = 200;

    /// <summary>
    /// How long one wait on the capture event lasts before the loop looks at the stop flag again.
    /// This is the granularity of "the user closed the label", not of the audio: packets arrive on
    /// the event, and an expired slice simply means none did.
    /// </summary>
    private const uint WaitSliceMillis = 100;

    /// <summary>
    /// How long the stream may deliver nothing at all before it is treated as dead. A microphone in
    /// a silent room still delivers packets — flagged silent, but delivered — so a stream that has
    /// produced none for this long is not quiet, it is broken.
    /// </summary>
    private static readonly TimeSpan StallBudget = TimeSpan.FromSeconds(5);

    private readonly int _clipByteCeiling;
    private readonly Func<DateTimeOffset> _clock;
    private readonly TimeSpan _startBudget;
    private readonly TimeSpan _sealBudget;
    private readonly object _gate = new();

    private Recording? _recording;

    /// <summary>Creates the recorder. No device is touched until a label opens.</summary>
    /// <param name="clipByteCeiling">
    /// Largest audio payload one clip may reach, in bytes of the archived 16 kHz mono PCM. Comes
    /// from the host configuration rather than from a literal here.
    /// </param>
    /// <param name="clock">Wall clock, so a host can make a capture deterministic.</param>
    /// <param name="startBudget">How long a start may take; two seconds unless a caller says otherwise.</param>
    /// <param name="sealBudget">How long a stop may take; two seconds unless a caller says otherwise.</param>
    public WasapiNarrationSource(
        int clipByteCeiling,
        Func<DateTimeOffset> clock,
        TimeSpan? startBudget = null,
        TimeSpan? sealBudget = null)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(clipByteCeiling, 0);

        _clipByteCeiling = clipByteCeiling;
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _startBudget = startBudget ?? DefaultStartBudget;
        _sealBudget = sealBudget ?? DefaultSealBudget;
    }

    /// <summary>Whether a clip is open, and therefore whether the microphone is live.</summary>
    public bool IsRecording
    {
        get
        {
            lock (_gate)
            {
                return _recording is not null;
            }
        }
    }

    /// <inheritdoc />
    public NarrationStartResult StartClip(string labelId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(labelId);

        lock (_gate)
        {
            if (_recording is not null)
            {
                // The engine opens one clip per label and closes it before the next, so this is a
                // defence rather than a case: what it must never do is open a second microphone and
                // lose track of the first.
                return NarrationStartResult.Failed("a narration clip is already recording");
            }

            var recording = new Recording(labelId, _clipByteCeiling, _clock);
            NarrationStartResult result = recording.Begin(_startBudget);
            if (result.Status != NarrationStartStatus.Started)
            {
                // Nothing is kept: the thread has already released the endpoint, or is being told
                // to, and the engine will not call SealClip for a clip that never started.
                recording.Abandon(_sealBudget);
                return result;
            }

            _recording = recording;
            return result;
        }
    }

    /// <inheritdoc />
    public NarrationSealResult SealClip()
    {
        lock (_gate)
        {
            if (_recording is not { } recording)
            {
                return NarrationSealResult.Failed("no narration clip was recording");
            }

            _recording = null;
            return recording.Seal(_sealBudget);
        }
    }

    /// <summary>
    /// Releases the microphone. A clip still open at disposal is stopped and its audio dropped: the
    /// capture is being torn down, there is no longer an archive for the bytes to reach, and the one
    /// thing that must not survive this call is an open microphone.
    /// </summary>
    public void Dispose()
    {
        lock (_gate)
        {
            _recording?.Abandon(_sealBudget);
            _recording = null;
        }
    }

    /// <summary>What one pass over the waiting packets produced.</summary>
    private enum DrainOutcome
    {
        /// <summary>At least one packet was captured.</summary>
        Captured,

        /// <summary>The stream had nothing waiting.</summary>
        Empty,

        /// <summary>The stream failed; the recording carries the detail.</summary>
        Faulted,
    }

    /// <summary>
    /// One clip: the capture thread, the COM objects it owns, and the handshake by which the two
    /// callers on the engine's thread learn what happened.
    /// </summary>
    private sealed class Recording
    {
        private readonly int _byteCeiling;
        private readonly Func<DateTimeOffset> _clock;
        private readonly ManualResetEventSlim _ready = new(false);
        private readonly Thread _thread;

        private volatile bool _stopRequested;

        /// <summary>The start outcome, published to the caller by <see cref="_ready"/>.</summary>
        private NarrationStartResult _start = NarrationStartResult.Failed("the capture thread did not report");

        private NarrationClipBuffer? _buffer;
        private IAudioClient? _client;
        private IAudioCaptureClient? _capture;
        private IntPtr _event;
        private string? _startedAt;
        private string? _endedAt;
        private string? _failure;

        internal Recording(string labelId, int byteCeiling, Func<DateTimeOffset> clock)
        {
            _byteCeiling = byteCeiling;
            _clock = clock;

            // The label travels no further than the thread's name. That is the whole of what a
            // recorder needs it for -- a debugger or a hang dump showing which declaration a
            // microphone belongs to -- and a clip that spooled to disk under a label-derived
            // filename would be an unencrypted recording of somebody's voice sitting in a temp
            // directory, which this recorder deliberately never creates.
            _thread = new Thread(Run)
            {
                IsBackground = true,
                Name = "JazzNarrationCapture " + labelId,
            };
        }

        /// <summary>Starts the capture thread and waits for it to report how the device answered.</summary>
        internal NarrationStartResult Begin(TimeSpan budget)
        {
            _thread.Start();
            if (_ready.Wait(budget))
            {
                return _start;
            }

            // A start this slow is a start that did not happen, as far as the label is concerned.
            // The thread is told to unwind whatever it has reached; the caller abandons it.
            _stopRequested = true;
            return NarrationStartResult.Failed(
                "the microphone did not start within "
                + budget.TotalMilliseconds.ToString("F0", System.Globalization.CultureInfo.InvariantCulture)
                + " ms");
        }

        /// <summary>Stops the microphone and returns the clip, or why there is none.</summary>
        internal NarrationSealResult Seal(TimeSpan budget)
        {
            _stopRequested = true;
            if (!_thread.Join(budget))
            {
                // The thread owns every COM object it created and will still release them; what it
                // cannot do is hand over a clip nobody is waiting for any more.
                return NarrationSealResult.Failed("the microphone did not stop within its budget");
            }

            // Only once the thread is provably gone: it is the other user of this handle.
            _ready.Dispose();

            if (_failure is { } failure)
            {
                // A device that died mid-clip is reported as a failure rather than as a short clip.
                // The seal result is one or the other, and audio that stops early for a reason the
                // archive never hears about is exactly the unexplained silence gaps exist to prevent.
                return NarrationSealResult.Failed(NarrationDeviceStatus.Bounded(failure));
            }

            if (_startedAt is not { } startedAt || _endedAt is not { } endedAt || _buffer is null)
            {
                return NarrationSealResult.Failed("the narration clip has no interval");
            }

            return NarrationSealResult.Sealed(new NarrationClip(
                startedAt,
                endedAt,
                _buffer.Seal(),
                NarrationWave.MediaType));
        }

        /// <summary>Stops the microphone and throws the audio away.</summary>
        internal void Abandon(TimeSpan budget)
        {
            _stopRequested = true;
            if (_thread.Join(budget))
            {
                _ready.Dispose();
            }
        }

        /// <summary>The capture thread: one apartment, one endpoint, one clip.</summary>
        private void Run()
        {
            int hr = NativeMethods.CoInitializeEx(IntPtr.Zero, NativeMethods.COINIT_MULTITHREADED);
            bool apartment = !NarrationDeviceStatus.Failed(hr);
            try
            {
                if (!apartment)
                {
                    Report(NarrationDeviceStatus.StartFailure("CoInitializeEx", hr));
                    return;
                }

                Capture();
            }
            catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
            {
                // A COM cast or a marshalling failure is still only a device problem. It is reported
                // as one to whichever side is waiting, and never allowed to reach the capture.
                string detail = NarrationDeviceStatus.Bounded(
                    "the narration capture thread failed: " + ex.Message);
                _failure ??= detail;
                Report(NarrationStartResult.Failed(detail));
            }
            finally
            {
                Release();
                if (apartment)
                {
                    NativeMethods.CoUninitialize();
                }

                // Nothing may be left waiting on a thread that has finished, whatever route it took.
                Report(_start);
            }
        }

        /// <summary>Opens the endpoint, reports the outcome, and pumps until the label closes.</summary>
        private void Capture()
        {
            if (!Open())
            {
                return;
            }

            Report(NarrationStartResult.Started);
            Pump();

            // One last pass before the device is stopped. Everything the engine is still holding was
            // captured before the label closed and belongs to this clip; without this the last two
            // hundred milliseconds of every clip -- the end of the user's last sentence -- would be
            // discarded, while the declared interval went on claiming to cover it.
            if (_failure is null && _buffer is { IsFull: false })
            {
                Drain();
            }

            // The clip ends when the microphone does, not when the seal is collected: the interval
            // the artifact declares has to be the interval the samples cover.
            _client?.Stop();
            _endedAt = Timestamps.IsoMillisUtc(_clock());
        }

        /// <summary>
        /// The whole device-opening sequence. Every step reports its own HRESULT, because "the
        /// microphone did not work" is not a usable thing to tell somebody.
        /// </summary>
        /// <returns>Whether the stream is running.</returns>
        private bool Open()
        {
            if (!Activate())
            {
                return false;
            }

            if (_client is not { } client || !Initialize(client))
            {
                return false;
            }

            _event = AudioInterop.CreateEventW(IntPtr.Zero, manualReset: false, initialState: false, null);
            if (_event == IntPtr.Zero)
            {
                return Refuse(NarrationStartResult.Failed(
                    "the narration capture event could not be created (Win32 error "
                    + Win32Error()
                    + ")"));
            }

            int hr = client.SetEventHandle(_event);
            if (NarrationDeviceStatus.Failed(hr))
            {
                return Refuse(NarrationDeviceStatus.StartFailure("IAudioClient.SetEventHandle", hr));
            }

            Guid captureIid = AudioInterop.IID_IAudioCaptureClient;
            hr = client.GetService(ref captureIid, out object? captureObject);
            if (NarrationDeviceStatus.Failed(hr) || captureObject is null)
            {
                return Refuse(NarrationDeviceStatus.StartFailure("IAudioClient.GetService", hr));
            }

            // The cast is the QueryInterface: GetService types its result as void**, and the
            // interface it actually returned is the one `captureIid` asked for.
            _capture = (IAudioCaptureClient)captureObject;

            hr = client.Start();
            if (NarrationDeviceStatus.Failed(hr))
            {
                return Refuse(NarrationDeviceStatus.StartFailure("IAudioClient.Start", hr));
            }

            // Sampled after the device is running, so the clip's interval starts where its first
            // sample could have.
            _startedAt = Timestamps.IsoMillisUtc(_clock());
            return true;
        }

        /// <summary>
        /// Finds the default capture endpoint and activates an audio client on it.
        /// </summary>
        /// <remarks>
        /// The enumerator and the endpoint are released as soon as the client exists. They are not
        /// needed for the length of a clip, and an endpoint object left to a finalizer is an object
        /// released on another thread, in another apartment, at a time nobody chose.
        /// </remarks>
        private bool Activate()
        {
            object? enumeratorObject = null;
            IMMDevice? endpoint = null;
            try
            {
                Type? enumeratorType = Type.GetTypeFromCLSID(AudioInterop.CLSID_MMDeviceEnumerator);
                enumeratorObject = enumeratorType is null
                    ? null
                    : Activator.CreateInstance(enumeratorType);
                if (enumeratorObject is not IMMDeviceEnumerator enumerator)
                {
                    return Refuse(NarrationStartResult.Failed(
                        "the Windows Core Audio device enumerator could not be created"));
                }

                int hr = enumerator.GetDefaultAudioEndpoint(
                    AudioInterop.eCapture,
                    AudioInterop.eConsole,
                    out endpoint);
                if (NarrationDeviceStatus.Failed(hr) || endpoint is null)
                {
                    // A machine with no microphone answers E_NOTFOUND here. That is a fact about
                    // the machine, and it reads differently from a device that failed.
                    return Refuse(NarrationDeviceStatus.StartFailure(
                        "IMMDeviceEnumerator.GetDefaultAudioEndpoint",
                        NarrationDeviceStatus.Failed(hr) ? hr : NarrationDeviceStatus.NotFound));
                }

                Guid clientIid = AudioInterop.IID_IAudioClient;
                hr = endpoint.Activate(
                    ref clientIid,
                    AudioInterop.CLSCTX_ALL,
                    IntPtr.Zero,
                    out object? clientObject);
                if (NarrationDeviceStatus.Failed(hr) || clientObject is null)
                {
                    return Refuse(NarrationDeviceStatus.StartFailure("IMMDevice.Activate", hr));
                }

                _client = (IAudioClient)clientObject;
                return true;
            }
            finally
            {
                ReleaseCom(endpoint);
                ReleaseCom(enumeratorObject);
            }
        }

        /// <summary>The last Win32 error, for the handful of failures that carry no HRESULT.</summary>
        private static string Win32Error() => Marshal.GetLastWin32Error()
            .ToString(System.Globalization.CultureInfo.InvariantCulture);

        /// <summary>Releases one runtime callable wrapper, on the thread that created it.</summary>
        private static void ReleaseCom(object? instance)
        {
            if (instance is not null && Marshal.IsComObject(instance))
            {
                Marshal.FinalReleaseComObject(instance);
            }
        }

        /// <summary>
        /// Reads the endpoint's mix format, builds the spool for it, and initializes the stream.
        /// </summary>
        /// <remarks>
        /// The format pointer the engine allocates is passed straight back to <c>Initialize</c>
        /// rather than rebuilt from the fields that were read out of it: in shared mode the engine's
        /// own format is the only one certain to be accepted, and a reconstruction is one more thing
        /// that can silently differ.
        /// </remarks>
        private bool Initialize(IAudioClient client)
        {
            int hr = client.GetMixFormat(out IntPtr format);
            if (NarrationDeviceStatus.Failed(hr) || format == IntPtr.Zero)
            {
                return Refuse(NarrationDeviceStatus.StartFailure("IAudioClient.GetMixFormat", hr));
            }

            try
            {
                NarrationFormatChoice choice = NarrationMixFormats.Negotiate(ReadFormat(format));
                if (choice.Format is not { } mix)
                {
                    return Refuse(NarrationStartResult.Failed(choice.Refusal!));
                }

                _buffer = new NarrationClipBuffer(mix, _byteCeiling);

                // Periodicity is zero: in shared mode the engine owns the period, and passing
                // anything else is how a stream ends up rejected with AUDCLNT_E_INVALID_DEVICE_PERIOD
                // on hardware that was working a moment ago.
                hr = client.Initialize(
                    AudioInterop.AUDCLNT_SHAREMODE_SHARED,
                    AudioInterop.AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                    BufferDurationMillis * AudioInterop.ReferenceTimesPerMillisecond,
                    0,
                    format,
                    IntPtr.Zero);

                // The one HRESULT that must not be reported as a broken microphone: on Windows 10
                // and 11 this is where the privacy setting refuses, and the user's next move
                // depends entirely on knowing which of the two happened.
                return !NarrationDeviceStatus.Failed(hr)
                    || Refuse(NarrationDeviceStatus.StartFailure("IAudioClient.Initialize", hr));
            }
            finally
            {
                // Initialize copies the format, so it is safe to free here either way, and it must
                // be freed on every path: the engine allocated it with CoTaskMemAlloc.
                Marshal.FreeCoTaskMem(format);
            }
        }

        /// <summary>Copies the fields of a <c>WAVEFORMATEX</c> that decide whether it can be read.</summary>
        private static NarrationWaveFormatHeader ReadFormat(IntPtr format)
        {
            WaveFormatEx header = Marshal.PtrToStructure<WaveFormatEx>(format);

            // The subformat GUID exists only when the header says it does. Reading it from a plain
            // WAVEFORMATEX would read whatever the engine happened to allocate after those 18 bytes.
            Guid subFormat = Guid.Empty;
            if (header.FormatTag == NarrationMixFormats.WaveFormatExtensible
                && header.Size >= 22)
            {
                subFormat = Marshal.PtrToStructure<WaveFormatExtensible>(format).SubFormat;
            }

            return new NarrationWaveFormatHeader(
                header.FormatTag,
                header.Channels,
                checked((int)header.SamplesPerSec),
                header.BitsPerSample,
                header.BlockAlign,
                subFormat);
        }

        /// <summary>
        /// The capture loop: wait for the engine's event, drain whatever it delivered, and stop when
        /// the label closes, the ceiling is reached, or the stream dies.
        /// </summary>
        private void Pump()
        {
            long lastPacket = Stopwatch.GetTimestamp();

            while (!_stopRequested)
            {
                uint wait = AudioInterop.WaitForSingleObject(_event, WaitSliceMillis);
                if (wait == AudioInterop.WAIT_FAILED)
                {
                    _failure = "the narration capture wait failed (Win32 error " + Win32Error() + ")";
                    return;
                }

                if (_stopRequested)
                {
                    return;
                }

                switch (Drain())
                {
                    case DrainOutcome.Faulted:
                        return;

                    case DrainOutcome.Captured:
                        lastPacket = Stopwatch.GetTimestamp();
                        break;

                    default:
                        // Silence still arrives as packets. Nothing at all arriving means the stream
                        // has stopped, and a clip that quietly records nothing for the rest of a
                        // label is worse than one that says the device failed.
                        if (Stopwatch.GetElapsedTime(lastPacket) > StallBudget)
                        {
                            _failure = "the capture device stopped delivering audio for "
                                + StallBudget.TotalSeconds.ToString("F0", System.Globalization.CultureInfo.InvariantCulture)
                                + " s";
                            return;
                        }

                        break;
                }

                if (_buffer is { IsFull: true })
                {
                    // The ceiling is not a failure: the clip is sealed with what it has, and its
                    // interval ends here, where the audio does.
                    return;
                }
            }
        }

        /// <summary>Reads every packet currently waiting on the stream.</summary>
        private unsafe DrainOutcome Drain()
        {
            if (_capture is not { } capture || _buffer is not { } buffer)
            {
                return DrainOutcome.Empty;
            }

            // Deliberately not conditioned on the stop flag: the last call to this method happens
            // after the stop has been requested, and its whole purpose is to collect the packets
            // that were captured before it. The loop ends when the stream has nothing left.
            var captured = false;
            while (true)
            {
                int hr = capture.GetNextPacketSize(out uint waiting);
                if (NarrationDeviceStatus.Failed(hr))
                {
                    _failure = NarrationDeviceStatus.Detail("IAudioCaptureClient.GetNextPacketSize", hr);
                    return DrainOutcome.Faulted;
                }

                if (waiting == 0)
                {
                    break;
                }

                hr = capture.GetBuffer(
                    out IntPtr data,
                    out uint frames,
                    out uint flags,
                    out _,
                    out _);

                // A success code, and the one case where ReleaseBuffer must not be called: pairing a
                // release with an empty acquire corrupts the engine's own accounting.
                if (NarrationDeviceStatus.IsBufferEmpty(hr))
                {
                    break;
                }

                if (NarrationDeviceStatus.Failed(hr))
                {
                    _failure = NarrationDeviceStatus.Detail("IAudioCaptureClient.GetBuffer", hr);
                    return DrainOutcome.Faulted;
                }

                int release;
                try
                {
                    if (frames > 0)
                    {
                        // AUDCLNT_BUFFERFLAGS_SILENT means the bytes are undefined, not that the
                        // time did not pass: the frames are written as zeroes so the clip stays the
                        // length of the interval it claims to cover. A null pointer is treated the
                        // same way rather than dereferenced.
                        //
                        // AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY, on the same flags word, is
                        // deliberately not acted on. It says samples were lost before this packet,
                        // and there is nothing honest to do about it here: the interval still
                        // brackets exactly when the microphone was open, and failing a whole clip
                        // over one glitch would destroy far more evidence than the glitch did.
                        if ((flags & AudioInterop.AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == IntPtr.Zero)
                        {
                            buffer.AppendSilence(checked((int)frames));
                        }
                        else
                        {
                            buffer.Append(new ReadOnlySpan<byte>(
                                (void*)data,
                                checked((int)frames * buffer.SourceFrameBytes)));
                        }
                    }
                }
                finally
                {
                    // Released even if the conversion threw: the engine's buffer is not ours to
                    // hold, and a packet never released stops the stream for good.
                    release = capture.ReleaseBuffer(frames);
                }

                if (NarrationDeviceStatus.Failed(release))
                {
                    _failure = NarrationDeviceStatus.Detail("IAudioCaptureClient.ReleaseBuffer", release);
                    return DrainOutcome.Faulted;
                }

                captured = true;

                // The ceiling ends the drain as well as the pump: once the spool is full every
                // further packet would be acquired and thrown away, which is a microphone held open
                // for no purpose.
                if (buffer.IsFull)
                {
                    break;
                }
            }

            return captured ? DrainOutcome.Captured : DrainOutcome.Empty;
        }

        /// <summary>Records a start failure and reports it to the waiting caller.</summary>
        /// <returns>Always false, so a caller can <c>return Refuse(...)</c>.</returns>
        private bool Refuse(NarrationStartResult result)
        {
            Report(result);
            return false;
        }

        /// <summary>Publishes the start outcome exactly once.</summary>
        private void Report(NarrationStartResult result)
        {
            if (_ready.IsSet)
            {
                return;
            }

            _start = result;
            _ready.Set();
        }

        /// <summary>
        /// Releases everything this thread created, on this thread. Called on every path out,
        /// including the one where the start was abandoned before the caller ever saw it.
        /// </summary>
        private void Release()
        {
            if (_client is not null)
            {
                // Stopping twice is harmless; not stopping leaves a microphone running inside a
                // process that has already forgotten about it.
                _client.Stop();
            }

            ReleaseCom(_capture);
            _capture = null;
            ReleaseCom(_client);
            _client = null;

            if (_event != IntPtr.Zero)
            {
                AudioInterop.CloseHandle(_event);
                _event = IntPtr.Zero;
            }
        }
    }
}
