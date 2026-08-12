using System.Buffers.Binary;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Audio;

namespace JazzCaptureCoreTests;

/// <summary>
/// The narration container and the conversion into it: the parts a host can get wrong without any
/// device being involved.
/// </summary>
public sealed class NarrationAudioTests
{
    private static readonly FrozenCapturePolicy Narrating = new(
        "consent-v1",
        new[] { "accessibility", "keyboard", "narration", "pointer" },
        Array.Empty<string>());

    [Fact]
    public void TheHeaderDescribesTheFormatTheClientActuallyWrites()
    {
        byte[] pcm = { 0x01, 0x00, 0xff, 0x7f };
        byte[] wave = NarrationWave.Wrap(pcm);

        Assert.Equal(NarrationWave.HeaderLength + pcm.Length, wave.Length);
        Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(wave, 0, 4));
        Assert.Equal("WAVE", System.Text.Encoding.ASCII.GetString(wave, 8, 4));
        Assert.Equal("fmt ", System.Text.Encoding.ASCII.GetString(wave, 12, 4));
        Assert.Equal("data", System.Text.Encoding.ASCII.GetString(wave, 36, 4));

        Assert.Equal(16u, BinaryPrimitives.ReadUInt32LittleEndian(wave.AsSpan(16)));
        Assert.Equal(1, BinaryPrimitives.ReadUInt16LittleEndian(wave.AsSpan(20)));
        Assert.Equal(NarrationWave.Channels, BinaryPrimitives.ReadUInt16LittleEndian(wave.AsSpan(22)));
        Assert.Equal((uint)NarrationWave.SampleRateHz, BinaryPrimitives.ReadUInt32LittleEndian(wave.AsSpan(24)));
        Assert.Equal((uint)NarrationWave.BytesPerSecond, BinaryPrimitives.ReadUInt32LittleEndian(wave.AsSpan(28)));
        Assert.Equal(2, BinaryPrimitives.ReadUInt16LittleEndian(wave.AsSpan(32)));
        Assert.Equal(NarrationWave.BitsPerSample, BinaryPrimitives.ReadUInt16LittleEndian(wave.AsSpan(34)));

        // Both length fields count what actually follows them, which is the whole of what makes the
        // stream readable by something that did not write it.
        Assert.Equal((uint)(wave.Length - 8), BinaryPrimitives.ReadUInt32LittleEndian(wave.AsSpan(4)));
        Assert.Equal((uint)pcm.Length, BinaryPrimitives.ReadUInt32LittleEndian(wave.AsSpan(40)));
        Assert.True(NarrationWave.IsWave(wave));
    }

    [Fact]
    public void ATruncatedOrForeignStreamIsNotMistakenForWave()
    {
        byte[] wave = NarrationWave.Wrap(new byte[64]);

        Assert.False(NarrationWave.IsWave(ScreenshotBytes.TinyJpeg));
        Assert.False(NarrationWave.IsWave(Array.Empty<byte>()));

        // A recorder killed mid-write leaves a header promising more than the file holds. That is
        // exactly the clip that must not reach the archive wearing a complete-stream media type.
        Assert.False(NarrationWave.IsWave(wave.AsSpan(0, wave.Length - 8)));
    }

    [Fact]
    public void StereoFloatFromTheDeviceBecomesMono16kHzPcm()
    {
        // 48 kHz stereo float is the shared-mode mix format of nearly every Windows endpoint.
        var downmixer = new NarrationDownmixer(48_000, 2, NarrationSampleFormat.Float32);
        Assert.Equal(8, downmixer.SourceFrameBytes);

        using var output = new MemoryStream();
        // Eight bytes a frame: two channels of 32-bit float, which is what SourceFrameBytes reports.
        downmixer.Append(
            Float32Frames(new[] { (1.0f, -1.0f), (0.5f, 0.5f), (0f, 0f) }, downmixer.SourceFrameBytes),
            output);

        // Three source frames at 48 kHz land on one output sample at 16 kHz.
        byte[] pcm = output.ToArray();
        Assert.Equal(sizeof(short), pcm.Length);

        // The first output sample is the mean of the first frame's two channels: +1 and -1 cancel.
        Assert.Equal(0, BinaryPrimitives.ReadInt16LittleEndian(pcm));
    }

    [Fact]
    public void TheResamplingPhaseSurvivesPacketBoundaries()
    {
        // 44.1 kHz does not divide into 16 kHz, so the fractional position has to carry across
        // packets. A converter that reset per packet would drift against the event stream.
        var streamed = new NarrationDownmixer(44_100, 1, NarrationSampleFormat.Pcm16);
        var whole = new NarrationDownmixer(44_100, 1, NarrationSampleFormat.Pcm16);

        short[] samples = Enumerable.Range(0, 4_410).Select(index => (short)(index % 1_000)).ToArray();
        byte[] bytes = Pcm16Frames(samples);

        using var piecewise = new MemoryStream();
        for (var offset = 0; offset < bytes.Length; offset += 314)
        {
            streamed.Append(bytes.AsSpan(offset, Math.Min(314, bytes.Length - offset)), piecewise);
        }

        using var single = new MemoryStream();
        whole.Append(bytes, single);

        Assert.Equal(single.ToArray(), piecewise.ToArray());

        // A tenth of a second at 44.1 kHz is 1600 output samples, not 1599 or 1601.
        Assert.Equal(1_600 * sizeof(short), single.Length);
    }

    [Fact]
    public void APartialTrailingFrameIsIgnoredRatherThanMisread()
    {
        var downmixer = new NarrationDownmixer(16_000, 2, NarrationSampleFormat.Pcm16);
        using var output = new MemoryStream();

        // Two whole frames plus a stray byte: half a frame is not a sample.
        downmixer.Append(new byte[(2 * 4) + 1], output);

        Assert.Equal(2 * sizeof(short), output.Length);
    }

    [Fact]
    public void LoudSamplesClampInsteadOfWrappingAround()
    {
        var downmixer = new NarrationDownmixer(16_000, 1, NarrationSampleFormat.Float32);
        using var output = new MemoryStream();
        downmixer.Append(Float32Frames(new[] { (2.5f, 0f), (-2.5f, 0f) }, 4), output);

        byte[] pcm = output.ToArray();
        Assert.Equal(short.MaxValue, BinaryPrimitives.ReadInt16LittleEndian(pcm));
        Assert.Equal(-short.MaxValue, BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(2)));
    }

    [Fact]
    public void AClipThatIsNotWhatItsMediaTypeClaimsIsRefused()
    {
        var lying = new NarrationClip(
            "2026-07-22T09:00:00.000Z",
            "2026-07-22T09:00:01.000Z",
            ScreenshotBytes.TinyJpeg,
            NarrationWave.MediaType);

        Assert.Contains(
            "is not a RIFF/WAVE stream",
            Assert.Single(NarrationEvidence.Errors(lying, Narrating)),
            StringComparison.Ordinal);
        Assert.Throws<ArgumentException>(() => NarrationEvidence.Attach(lying, Narrating));
    }

    [Fact]
    public void AnEmptyOrBackwardsClipIsRefused()
    {
        var empty = new NarrationClip(
            "2026-07-22T09:00:00.000Z",
            "2026-07-22T09:00:01.000Z",
            ReadOnlyMemory<byte>.Empty,
            NarrationWave.MediaType);
        Assert.Contains(
            NarrationEvidence.Errors(empty, Narrating),
            error => error.Contains("no audio", StringComparison.Ordinal));

        NarrationClip backwards = FakeNarrationSource.Clip(1) with
        {
            StartedAt = "2026-07-22T09:00:05.000Z",
            EndedAt = "2026-07-22T09:00:01.000Z",
        };
        Assert.Contains(
            NarrationEvidence.Errors(backwards, Narrating),
            error => error.Contains("cannot end before it starts", StringComparison.Ordinal));
    }

    [Fact]
    public void APolicyThatDoesNotAdmitNarrationRefusesTheClip()
    {
        var silent = new FrozenCapturePolicy(
            "consent-v1",
            new[] { "keyboard", "pointer" },
            Array.Empty<string>());

        Assert.False(silent.AllowsNarration);
        Assert.Contains(
            NarrationEvidence.Errors(FakeNarrationSource.Clip(1), silent),
            error => error.Contains("does not admit the narration modality", StringComparison.Ordinal));
    }

    [Fact]
    public void AGoodClipBecomesTheAttachmentTheArchiveExpects()
    {
        NarrationClip clip = FakeNarrationSource.Clip(3);
        ArtifactAttachment attachment = NarrationEvidence.Attach(clip, Narrating);

        Assert.Equal(NarrationAudioV1.Kind, attachment.Kind);
        Assert.Equal(NarrationWave.MediaType, attachment.MediaType);
        Assert.Equal(NarrationAudioV1.Role, attachment.Role);
        Assert.Equal(NarrationAudioV1.SourceRole, attachment.SourceRole);
        Assert.Equal(clip.StartedAt, attachment.CaptureInterval!.StartedAt);
        Assert.Equal(clip.EndedAt, attachment.CaptureInterval!.EndedAt);

        // A clip covers the interval it declares exactly, unlike a frame, so nothing is approximate.
        Assert.Equal(ArtifactQualityStatus.Complete, attachment.Quality.Status);
        Assert.Empty(attachment.Quality.Reasons);
        Assert.Null(attachment.Quality.TimingErrorMillis);

        ArtifactActorRef actor = Assert.Single(attachment.ActorRefs);
        Assert.Equal(NarrationAudioV1.ActorRole, actor.Role);
        Assert.Equal(ArtifactActorRef.DeclaredBasis, actor.Basis);

        // Whether the declaration the engine builds from this is one the archive accepts is settled
        // by the end-to-end gate, which runs the real validator over a real archive; asserting it
        // again here would only restate the shape this test already fixed.
    }

    private static byte[] Float32Frames(IReadOnlyList<(float Left, float Right)> frames, int channelBytes)
    {
        var bytes = new byte[frames.Count * channelBytes];
        for (var index = 0; index < frames.Count; index++)
        {
            Span<byte> frame = bytes.AsSpan(index * channelBytes, channelBytes);
            BinaryPrimitives.WriteInt32LittleEndian(frame, BitConverter.SingleToInt32Bits(frames[index].Left));
            if (channelBytes >= 8)
            {
                BinaryPrimitives.WriteInt32LittleEndian(
                    frame[4..],
                    BitConverter.SingleToInt32Bits(frames[index].Right));
            }
        }

        return bytes;
    }

    private static byte[] Pcm16Frames(IReadOnlyList<short> samples)
    {
        var bytes = new byte[samples.Count * sizeof(short)];
        for (var index = 0; index < samples.Count; index++)
        {
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(index * sizeof(short)), samples[index]);
        }

        return bytes;
    }
}
