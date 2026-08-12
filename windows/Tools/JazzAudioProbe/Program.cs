using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using JazzCapture.Capture;
using JazzCapture.Interop;
using JazzCaptureCore.Audio;

// Settles the hand-written Core Audio interop against a real microphone. The vtable slot indices in
// AudioCapture.cs cannot be checked by the compiler, and a wrong one does not fail cleanly: it calls
// whatever method genuinely occupies that position. This probe walks the same four interfaces the
// recorder uses, one call at a time, and prints every HRESULT separately, so a bad slot is
// distinguishable from a device that simply refused.
//
// It then records a real clip through WasapiNarrationSource and checks the one property no HRESULT
// can prove: that the audio is as long as the wall-clock interval it claims to cover. A recorder
// that drops silent packets passes every call in phase one and fails that comparison.
//
// Usage: JazzAudioProbe [seconds] [outputDirectory]

int seconds = args.Length > 0 && int.TryParse(args[0], out int requested) ? Math.Clamp(requested, 1, 60) : 5;
string outputDirectory = args.Length > 1 ? args[1] : AppContext.BaseDirectory;

NativeMethods.CoInitializeEx(IntPtr.Zero, NativeMethods.COINIT_MULTITHREADED);

Console.WriteLine("=== phase 1: vtable survey ===");
int surveyed = Survey();

Console.WriteLine();
Console.WriteLine("=== phase 2: one clip through the recorder ===");
int recorded = Record(seconds, outputDirectory);

NativeMethods.CoUninitialize();
return surveyed != 0 ? surveyed : recorded;

// Walks the interop by hand. Every step prints its own HRESULT: an 0x8889xxxx code is the audio
// stack answering the call that was actually made, while E_NOTIMPL, E_POINTER, an access violation
// or a plainly absurd out-parameter is what a wrong slot index looks like.
static int Survey()
{
    Type? type = Type.GetTypeFromCLSID(AudioInterop.CLSID_MMDeviceEnumerator);
    if (type is null || Activator.CreateInstance(type) is not IMMDeviceEnumerator enumerator)
    {
        Console.WriteLine("FAIL: MMDeviceEnumerator could not be created");
        return 1;
    }

    Console.WriteLine("MMDeviceEnumerator            : created");

    int hr = enumerator.GetDefaultAudioEndpoint(
        AudioInterop.eCapture,
        AudioInterop.eConsole,
        out IMMDevice? endpoint);
    Report("IMMDeviceEnumerator slot 2    ", hr);
    if (Failed(hr) || endpoint is null)
    {
        return 1;
    }

    Guid clientIid = AudioInterop.IID_IAudioClient;
    hr = endpoint.Activate(ref clientIid, AudioInterop.CLSCTX_ALL, IntPtr.Zero, out object? clientObject);
    Report("IMMDevice slot 1 (Activate)   ", hr);
    if (Failed(hr) || clientObject is not IAudioClient client)
    {
        return 1;
    }

    hr = client.GetMixFormat(out IntPtr format);
    Report("IAudioClient slot 6 (MixFmt)  ", hr);
    if (Failed(hr) || format == IntPtr.Zero)
    {
        return 1;
    }

    // A wrong slot here is unusually easy to see: the fields come back as noise. A real endpoint
    // reports a plausible rate (44100, 48000, 96000), 1-8 channels, and 16 or 32 bits.
    WaveFormatEx header = Marshal.PtrToStructure<WaveFormatEx>(format);
    Console.WriteLine(
        $"  mix format                  : tag={header.FormatTag} ch={header.Channels} "
        + $"rate={header.SamplesPerSec} bits={header.BitsPerSample} align={header.BlockAlign} "
        + $"cbSize={header.Size}");

    Guid subFormat = Guid.Empty;
    if (header.FormatTag == NarrationMixFormats.WaveFormatExtensible && header.Size >= 22)
    {
        subFormat = Marshal.PtrToStructure<WaveFormatExtensible>(format).SubFormat;
        Console.WriteLine($"  subformat                   : {subFormat:D}");
    }

    NarrationFormatChoice choice = NarrationMixFormats.Negotiate(new NarrationWaveFormatHeader(
        header.FormatTag,
        header.Channels,
        (int)header.SamplesPerSec,
        header.BitsPerSample,
        header.BlockAlign,
        subFormat));
    Console.WriteLine(choice.Format is { } mix
        ? $"  negotiated                  : {mix}"
        : $"  REFUSED                     : {choice.Refusal}");

    hr = client.GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
    Report("IAudioClient slot 7 (Period)  ", hr);

    // Device periods are 100-nanosecond ticks and land in the low milliseconds. A number outside
    // that range is the clearest single sign that the slot indices have slipped.
    Console.WriteLine(
        $"  device period               : default={defaultPeriod / 10_000.0:F2} ms "
        + $"minimum={minimumPeriod / 10_000.0:F2} ms");

    hr = client.Initialize(
        AudioInterop.AUDCLNT_SHAREMODE_SHARED,
        AudioInterop.AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        200 * AudioInterop.ReferenceTimesPerMillisecond,
        0,
        format,
        IntPtr.Zero);
    Marshal.FreeCoTaskMem(format);
    Report("IAudioClient slot 1 (Init)    ", hr);
    if (Failed(hr))
    {
        // The one failure that is not a bug: 0x80070005 here is the microphone privacy setting.
        return 1;
    }

    hr = client.GetBufferSize(out uint bufferFrames);
    Report("IAudioClient slot 2 (BufSize) ", hr);
    Console.WriteLine($"  engine buffer               : {bufferFrames} frames");

    IntPtr captureEvent = AudioInterop.CreateEventW(IntPtr.Zero, false, false, null);
    hr = client.SetEventHandle(captureEvent);
    Report("IAudioClient slot 11 (SetEvt) ", hr);

    Guid captureIid = AudioInterop.IID_IAudioCaptureClient;
    hr = client.GetService(ref captureIid, out object? captureObject);
    Report("IAudioClient slot 12 (Service)", hr);
    if (Failed(hr) || captureObject is not IAudioCaptureClient capture)
    {
        AudioInterop.CloseHandle(captureEvent);
        return 1;
    }

    hr = client.Start();
    Report("IAudioClient slot 8 (Start)   ", hr);

    // One wait and one packet: enough to prove the capture-client slots without recording anybody.
    AudioInterop.WaitForSingleObject(captureEvent, 1_000);
    hr = capture.GetNextPacketSize(out uint waiting);
    Report("IAudioCaptureClient slot 3    ", hr);
    Console.WriteLine($"  next packet                 : {waiting} frames");

    if (waiting > 0)
    {
        hr = capture.GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong position, out _);
        Report("IAudioCaptureClient slot 1    ", hr);
        Console.WriteLine(
            $"  packet                      : {frames} frames flags=0x{flags:x} "
            + $"devicePosition={position} silent={(flags & AudioInterop.AUDCLNT_BUFFERFLAGS_SILENT) != 0} "
            + $"data={(data == IntPtr.Zero ? "null" : "present")}");

        if (!NarrationDeviceStatus.IsBufferEmpty(hr) && !Failed(hr))
        {
            Report("IAudioCaptureClient slot 2    ", capture.ReleaseBuffer(frames));
        }
    }

    client.Stop();
    AudioInterop.CloseHandle(captureEvent);
    Console.WriteLine("survey                        : every slot answered");
    return 0;
}

// Records one clip exactly as a label would, and checks it against the clock.
static int Record(int seconds, string outputDirectory)
{
    var source = new WasapiNarrationSource(
        NarrationWave.BytesPerSecond * 60 * 30,
        () => DateTimeOffset.UtcNow);

    Console.WriteLine($"speak now: recording {seconds}s ...");
    long startedTicks = Stopwatch.GetTimestamp();
    NarrationStartResult start = source.StartClip("lbl_probe");
    Console.WriteLine($"start                         : {start.Status} {start.Detail}");
    if (start.Status != NarrationStartStatus.Started)
    {
        return 1;
    }

    Thread.Sleep(TimeSpan.FromSeconds(seconds));

    NarrationSealResult seal = source.SealClip();
    TimeSpan elapsed = Stopwatch.GetElapsedTime(startedTicks);
    source.Dispose();

    if (seal.Clip is not { } clip)
    {
        Console.WriteLine($"seal                          : FAILED {seal.FailureDetail}");
        return 1;
    }

    int audioBytes = clip.Bytes.Length - NarrationWave.HeaderLength;
    double heldSeconds = audioBytes / (double)NarrationWave.BytesPerSecond;
    Console.WriteLine($"clip                          : {clip.StartedAt} .. {clip.EndedAt}");
    Console.WriteLine($"media type                    : {clip.MediaType} (wave={NarrationWave.IsWave(clip.Bytes.Span)})");
    Console.WriteLine(
        $"audio                         : {audioBytes} bytes = {heldSeconds:F2} s "
        + $"against {elapsed.TotalSeconds:F2} s on the clock");

    // The check no HRESULT can make. A recorder that skipped silent packets is short here, and the
    // shortfall is exactly the length of the pauses -- so run this once talking and once in
    // silence, and the two must produce the same number of bytes.
    double drift = Math.Abs(heldSeconds - elapsed.TotalSeconds);
    Console.WriteLine(drift <= 0.5
        ? $"alignment                     : OK ({drift:F2} s drift)"
        : $"alignment                     : SUSPECT ({drift:F2} s drift; silent packets dropped?)");

    // Fully qualified: WPF's Shapes.Path is in scope in a UseWPF project.
    string path = System.IO.Path.Combine(
        outputDirectory,
        "jazz-narration-probe-"
        + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture)
        + ".wav");
    System.IO.File.WriteAllBytes(path, clip.Bytes.ToArray());
    Console.WriteLine($"written                       : {path}");
    Console.WriteLine("listen to it: the samples being audible speech is the last thing no HRESULT proves.");

    return drift <= 0.5 ? 0 : 1;
}

static bool Failed(int hr) => NarrationDeviceStatus.Failed(hr);

static void Report(string label, int hr)
{
    string verdict = Failed(hr)
        ? "FAIL " + NarrationDeviceStatus.Reason(NarrationDeviceStatus.Classify(hr))
        : "ok";
    Console.WriteLine($"{label}: 0x{hr:X8} {verdict}");
}
