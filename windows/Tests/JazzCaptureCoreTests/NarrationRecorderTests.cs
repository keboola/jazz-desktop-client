using System.Buffers.Binary;
using JazzCaptureCore;
using JazzCaptureCore.Audio;

namespace JazzCaptureCoreTests;

/// <summary>
/// The half of the WASAPI narration recorder that has no COM in it: what an HRESULT means, which
/// device formats are readable, and how a clip is bounded and padded.
/// </summary>
/// <remarks>
/// These are the decisions worth testing precisely because the machine that runs them cannot run a
/// COM call. The interop above this layer makes calls and copies numbers; every judgement it would
/// otherwise have made inline is here, where a build on any operating system can prove it.
/// </remarks>
public sealed class NarrationRecorderTests
{
    /// <summary>The 48 kHz stereo float extensible header nearly every Windows endpoint reports.</summary>
    private static NarrationWaveFormatHeader TypicalHeader => new(
        NarrationMixFormats.WaveFormatExtensible,
        2,
        48_000,
        32,
        8,
        NarrationMixFormats.SubtypeIeeeFloat);

    [Fact]
    public void ARefusedMicrophoneIsNotReportedAsABrokenOne()
    {
        // The distinction the whole HRESULT table exists for: one of these the user fixes in the
        // privacy pane, the other they cannot fix at all.
        NarrationStartResult denied = NarrationDeviceStatus.StartFailure(
            "IAudioClient.Initialize",
            NarrationDeviceStatus.AccessDenied);
        NarrationStartResult broken = NarrationDeviceStatus.StartFailure(
            "IAudioClient.Initialize",
            NarrationDeviceStatus.DeviceInvalidated);

        Assert.Equal(NarrationStartStatus.PermissionDenied, denied.Status);
        Assert.Equal(NarrationStartStatus.SourceFailure, broken.Status);
        Assert.Contains("privacy", denied.Detail!, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("removed, disabled or reconfigured", broken.Detail!, StringComparison.Ordinal);
    }

    [Fact]
    public void EveryCodeTheRecorderActsOnClassifiesToItsOwnFault()
    {
        Assert.Equal(
            NarrationDeviceFault.PermissionDenied,
            NarrationDeviceStatus.Classify(NarrationDeviceStatus.AccessDenied));
        Assert.Equal(
            NarrationDeviceFault.NoDevice,
            NarrationDeviceStatus.Classify(NarrationDeviceStatus.NotFound));
        Assert.Equal(
            NarrationDeviceFault.DeviceInvalidated,
            NarrationDeviceStatus.Classify(NarrationDeviceStatus.DeviceInvalidated));
        Assert.Equal(
            NarrationDeviceFault.DeviceInvalidated,
            NarrationDeviceStatus.Classify(NarrationDeviceStatus.ResourcesInvalidated));
        Assert.Equal(
            NarrationDeviceFault.DeviceInUse,
            NarrationDeviceStatus.Classify(NarrationDeviceStatus.DeviceInUse));
        Assert.Equal(
            NarrationDeviceFault.UnsupportedFormat,
            NarrationDeviceStatus.Classify(NarrationDeviceStatus.UnsupportedFormat));
        Assert.Equal(
            NarrationDeviceFault.AudioServiceStopped,
            NarrationDeviceStatus.Classify(NarrationDeviceStatus.ServiceNotRunning));

        // An unrecognized failure is still a failure, and still says so out loud.
        Assert.Equal(
            NarrationDeviceFault.DeviceFailure,
            NarrationDeviceStatus.Classify(unchecked((int)0x80004005)));
    }

    [Fact]
    public void TheEmptyBufferCodeIsASuccessAndNotADeadMicrophone()
    {
        // AUDCLNT_S_BUFFER_EMPTY is positive. A capture loop that tests it with FAILED() keeps
        // recording; one that tests it for zero reports a device failure every time a user pauses.
        Assert.False(NarrationDeviceStatus.Failed(NarrationDeviceStatus.BufferEmpty));
        Assert.True(NarrationDeviceStatus.IsBufferEmpty(NarrationDeviceStatus.BufferEmpty));
        Assert.Equal(
            NarrationDeviceFault.None,
            NarrationDeviceStatus.Classify(NarrationDeviceStatus.BufferEmpty));

        Assert.False(NarrationDeviceStatus.Failed(NarrationDeviceStatus.Ok));
        Assert.False(NarrationDeviceStatus.IsBufferEmpty(NarrationDeviceStatus.Ok));
        Assert.True(NarrationDeviceStatus.Failed(NarrationDeviceStatus.NotInitialized));
    }

    [Fact]
    public void ADetailNamesTheCallAndKeepsTheRawCode()
    {
        string detail = NarrationDeviceStatus.Detail(
            "IAudioClient.Initialize",
            NarrationDeviceStatus.AccessDenied);

        Assert.StartsWith("IAudioClient.Initialize:", detail, StringComparison.Ordinal);

        // The sentence is a category; the number is the fact, and an unrecognized failure is only
        // ever diagnosable from the number.
        Assert.Contains("0x80070005", detail, StringComparison.Ordinal);
    }

    [Fact]
    public void ADetailIsBoundedToWhatACapabilityObservationAccepts()
    {
        // The engine hands this straight to a capability observation, which throws above 512
        // characters — inside the capture, over one clip.
        string bounded = NarrationDeviceStatus.Bounded(new string('x', 4_000));

        Assert.Equal(CapabilityObservation.MaxDetailLength, bounded.Length);
        Assert.Equal("short enough", NarrationDeviceStatus.Bounded("  short enough  "));
    }

    [Fact]
    public void TheMixFormatsRealDevicesReportAreAccepted()
    {
        NarrationMixFormat extensibleFloat = Accepted(TypicalHeader);
        Assert.Equal(48_000, extensibleFloat.SampleRateHz);
        Assert.Equal(2, extensibleFloat.Channels);
        Assert.Equal(NarrationSampleFormat.Float32, extensibleFloat.Format);
        Assert.Equal(8, extensibleFloat.FrameBytes);

        NarrationMixFormat plainFloat = Accepted(TypicalHeader with
        {
            FormatTag = NarrationMixFormats.WaveFormatIeeeFloat,
            SubFormat = Guid.Empty,
        });
        Assert.Equal(NarrationSampleFormat.Float32, plainFloat.Format);

        NarrationMixFormat pcm = Accepted(new NarrationWaveFormatHeader(
            NarrationMixFormats.WaveFormatPcm,
            1,
            44_100,
            16,
            2,
            Guid.Empty));
        Assert.Equal(NarrationSampleFormat.Pcm16, pcm.Format);
        Assert.Equal(2, pcm.FrameBytes);

        NarrationMixFormat extensiblePcm = Accepted(new NarrationWaveFormatHeader(
            NarrationMixFormats.WaveFormatExtensible,
            2,
            16_000,
            16,
            4,
            NarrationMixFormats.SubtypePcm));
        Assert.Equal(NarrationSampleFormat.Pcm16, extensiblePcm.Format);
    }

    [Fact]
    public void ASampleWidthTheConverterCannotReadIsRefusedRatherThanMisread()
    {
        // Guessing here does not produce silence, it produces noise that looks like a recording.
        Assert.Contains(
            "24 bits per sample",
            Refused(TypicalHeader with { BitsPerSample = 24, BlockAlign = 6, SubFormat = NarrationMixFormats.SubtypePcm }),
            StringComparison.Ordinal);

        Assert.Contains(
            "64 bits per sample",
            Refused(TypicalHeader with { BitsPerSample = 64, BlockAlign = 16 }),
            StringComparison.Ordinal);
    }

    [Fact]
    public void AnUnknownExtensibleSubtypeIsRefusedWithItsGuidNamed()
    {
        var alien = new Guid("00000092-0000-0010-8000-00aa00389b71");
        string refusal = Refused(TypicalHeader with { SubFormat = alien });

        Assert.Contains("WAVE_FORMAT_EXTENSIBLE", refusal, StringComparison.Ordinal);
        Assert.Contains(alien.ToString("D"), refusal, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AFrameStrideThatContradictsTheFormatIsRefused()
    {
        // nBlockAlign is where every later frame begins. If the device's arithmetic and ours differ,
        // there is no offset at which the samples can be read correctly.
        Assert.Contains(
            "nBlockAlign 6",
            Refused(TypicalHeader with { BlockAlign = 6 }),
            StringComparison.Ordinal);
    }

    [Fact]
    public void AHeaderThatDescribesNoStreamIsRefused()
    {
        Assert.Contains(
            "which is not a stream",
            Refused(TypicalHeader with { Channels = 0 }),
            StringComparison.Ordinal);
        Assert.Contains(
            "which is not a stream",
            Refused(TypicalHeader with { SampleRateHz = 0 }),
            StringComparison.Ordinal);
    }

    [Fact]
    public void TheNegotiatedFormatIsTheOneTheConverterIsBuiltFrom()
    {
        NarrationMixFormat format = Accepted(TypicalHeader);

        // The device's frame stride and the converter's have to be the same number, or the capture
        // loop and the downmixer disagree about what a packet contains.
        Assert.Equal(format.FrameBytes, format.CreateDownmixer().SourceFrameBytes);
        Assert.Equal("48000 Hz, 2 ch, 32-bit float", format.ToString());
    }

    [Fact]
    public void SilencePadsTheClipInsteadOfShorteningIt()
    {
        // A silent packet carries undefined bytes and a flag. Skipping it would pull every later
        // word earlier in the clip by the length of the pause before it.
        var padded = new NarrationClipBuffer(Stereo48kFloat, Ceiling);
        var loud = new NarrationClipBuffer(Stereo48kFloat, Ceiling);

        padded.AppendSilence(4_800);
        loud.Append(new byte[4_800 * padded.SourceFrameBytes]);

        Assert.Equal(loud.Length, padded.Length);

        // A tenth of a second of 16 kHz mono is 1600 samples, whether or not anyone spoke.
        Assert.Equal(1_600 * sizeof(short), padded.Length);
    }

    [Fact]
    public void SilenceAdvancesTheResamplerLikeAnyOtherPacket()
    {
        // 44.1 kHz does not divide into 16 kHz, so a pause has to leave the fractional position
        // exactly where a spoken packet of the same length would.
        var mixed = new NarrationClipBuffer(Mono44kPcm, Ceiling);
        var whole = new NarrationClipBuffer(Mono44kPcm, Ceiling);

        for (var packet = 0; packet < 10; packet++)
        {
            mixed.AppendSilence(441);
        }

        whole.Append(new byte[4_410 * whole.SourceFrameBytes]);

        Assert.Equal(whole.Length, mixed.Length);
        Assert.Equal(1_600 * sizeof(short), mixed.Length);
    }

    [Fact]
    public void TheCeilingIsExactAndDeclaresTheClipFull()
    {
        var buffer = new NarrationClipBuffer(Stereo48kFloat, NarrationWave.BytesPerSecond);

        Assert.False(buffer.IsFull);

        // Ten seconds of audio into a one-second ceiling: the bound holds to the byte, not to the
        // packet, and the excess never occupies memory it could not be trimmed from.
        for (var second = 0; second < 10; second++)
        {
            buffer.Append(new byte[48_000 * buffer.SourceFrameBytes]);
        }

        Assert.True(buffer.IsFull);
        Assert.Equal(NarrationWave.BytesPerSecond, buffer.Length);

        // Silence is bounded by the same ceiling; a label left open overnight cannot spool zeroes.
        buffer.AppendSilence(48_000);
        Assert.Equal(NarrationWave.BytesPerSecond, buffer.Length);
    }

    [Fact]
    public void ACeilingIsRoundedDownToAWholeSample()
    {
        // Half a sample is not audio, and a data chunk with an odd byte count is a clip that ends
        // mid-value.
        var buffer = new NarrationClipBuffer(Stereo48kFloat, 1_001);

        Assert.Equal(1_000, buffer.ByteCeiling);

        buffer.Append(new byte[48_000 * buffer.SourceFrameBytes]);
        Assert.Equal(1_000, buffer.Length);
        Assert.Equal(0, buffer.Length % sizeof(short));

        Assert.Throws<ArgumentOutOfRangeException>(
            () => new NarrationClipBuffer(Stereo48kFloat, 1));
    }

    [Fact]
    public void ASealedClipIsAWaveStreamOfExactlyWhatWasCaptured()
    {
        var buffer = new NarrationClipBuffer(Stereo48kFloat, Ceiling);
        buffer.Append(Float32Frames(0.5f, 48));

        byte[] wave = buffer.Seal();

        Assert.True(NarrationWave.IsWave(wave));
        Assert.Equal(NarrationWave.HeaderLength + buffer.Length, wave.Length);
        Assert.Equal(
            (uint)buffer.Length,
            BinaryPrimitives.ReadUInt32LittleEndian(wave.AsSpan(40)));

        // Sealing reads the spool; it does not consume it. A caller that cannot use the bytes has
        // not destroyed them by asking.
        Assert.Equal(wave, buffer.Seal());
    }

    [Fact]
    public void ALabelClosedImmediatelyStillSealsAReadableStream()
    {
        // A user who opens and ends a label in the same second recorded nothing, and the clip says
        // so as a valid empty stream rather than as malformed bytes.
        byte[] wave = new NarrationClipBuffer(Stereo48kFloat, Ceiling).Seal();

        Assert.True(NarrationWave.IsWave(wave));
        Assert.Equal(NarrationWave.HeaderLength, wave.Length);
    }

    private const int Ceiling = 1 << 20;

    private static NarrationMixFormat Stereo48kFloat =>
        new(48_000, 2, NarrationSampleFormat.Float32);

    private static NarrationMixFormat Mono44kPcm => new(44_100, 1, NarrationSampleFormat.Pcm16);

    private static NarrationMixFormat Accepted(NarrationWaveFormatHeader header)
    {
        NarrationFormatChoice choice = NarrationMixFormats.Negotiate(header);
        Assert.Null(choice.Refusal);
        return choice.Format!;
    }

    private static string Refused(NarrationWaveFormatHeader header)
    {
        NarrationFormatChoice choice = NarrationMixFormats.Negotiate(header);
        Assert.Null(choice.Format);
        return choice.Refusal!;
    }

    /// <summary>Interleaved stereo float frames all holding the same value.</summary>
    private static byte[] Float32Frames(float value, int frames)
    {
        var bytes = new byte[frames * 2 * sizeof(float)];
        for (var index = 0; index < frames * 2; index++)
        {
            BinaryPrimitives.WriteInt32LittleEndian(
                bytes.AsSpan(index * sizeof(float)),
                BitConverter.SingleToInt32Bits(value));
        }

        return bytes;
    }
}
