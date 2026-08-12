using System.Buffers.Binary;

namespace JazzCaptureCore.Audio;

/// <summary>Sample encoding of the interleaved frames a capture device hands over.</summary>
public enum NarrationSampleFormat
{
    /// <summary>32-bit IEEE float, the shared-mode mix format of nearly every Windows endpoint.</summary>
    Float32,

    /// <summary>16-bit signed little-endian PCM.</summary>
    Pcm16,
}

/// <summary>
/// The narration container: linear PCM in a RIFF/WAVE wrapper, plus the conversion from whatever
/// the capture device hands over into it.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why WAV and not AAC.</b> The macOS client writes AAC in an MPEG-4 container because
/// <c>AVAudioRecorder</c> hands it over for four lines of configuration. Windows has no equivalent:
/// the only in-box AAC encoder is Media Foundation, which means <c>MFStartup</c>, an
/// <c>IMFSinkWriter</c>, media-type negotiation and a second COM apartment to keep alive for the
/// length of a clip — several hundred lines of interop whose failure modes are invisible until a
/// real machine runs them. Linear PCM needs none of it: the bytes WASAPI already produced, a
/// forty-four byte header, and a media type that is exactly true.
/// </para>
/// <para>
/// The cost is size, and it is bounded by the rule that makes narration what it is: the microphone
/// records only inside a label, so a clip is one task step rather than a session. At the
/// speech-standard <see cref="SampleRateHz"/> mono, that is
/// <see cref="BytesPerSecond"/> bytes per second — about two megabytes a minute, and the archive
/// container deflates it further. A clip that is honestly large can be transcoded by any reader; a
/// clip that claims to be <c>audio/mp4</c> and is not cannot be repaired by anyone, because nothing
/// in the archive says which of the two claims to believe. If a smaller container is wanted later it
/// belongs behind <see cref="INarrationSource"/>, whose clips carry their own
/// <see cref="NarrationClip.MediaType"/> — so it is a new encoder, not a format migration.
/// </para>
/// <para>
/// 16 kHz mono is chosen rather than the device's own mix format because narration is speech
/// evidence: every transcriber downsamples to 16 kHz anyway, and keeping 48 kHz stereo would triple
/// the size of the archive to preserve information no consumer of it uses.
/// </para>
/// </remarks>
public static class NarrationWave
{
    /// <summary>Media type of the bytes this container produces. It is the literal truth about them.</summary>
    public const string MediaType = "audio/wav";

    /// <summary>Output sample rate: the speech-recognition standard.</summary>
    public const int SampleRateHz = 16_000;

    /// <summary>Output channel count. Think-aloud narration is one person at one microphone.</summary>
    public const int Channels = 1;

    /// <summary>Output sample width.</summary>
    public const int BitsPerSample = 16;

    /// <summary>Bytes one second of output occupies.</summary>
    public const int BytesPerSecond = SampleRateHz * Channels * (BitsPerSample / 8);

    /// <summary>Size of the canonical 44-byte RIFF/WAVE header this writer emits.</summary>
    public const int HeaderLength = 44;

    private const ushort WaveFormatPcm = 1;
    private const int FormatChunkLength = 16;

    /// <summary>Wraps raw little-endian PCM in a RIFF/WAVE header describing this format.</summary>
    /// <param name="pcm">Mono 16-bit little-endian samples; may be empty.</param>
    /// <returns>A complete <c>audio/wav</c> stream.</returns>
    public static byte[] Wrap(ReadOnlySpan<byte> pcm)
    {
        var bytes = new byte[HeaderLength + pcm.Length];
        Span<byte> header = bytes.AsSpan(0, HeaderLength);

        "RIFF"u8.CopyTo(header);
        BinaryPrimitives.WriteUInt32LittleEndian(header[4..], (uint)(HeaderLength - 8 + pcm.Length));
        "WAVE"u8.CopyTo(header[8..]);
        "fmt "u8.CopyTo(header[12..]);
        BinaryPrimitives.WriteUInt32LittleEndian(header[16..], FormatChunkLength);
        BinaryPrimitives.WriteUInt16LittleEndian(header[20..], WaveFormatPcm);
        BinaryPrimitives.WriteUInt16LittleEndian(header[22..], Channels);
        BinaryPrimitives.WriteUInt32LittleEndian(header[24..], SampleRateHz);
        BinaryPrimitives.WriteUInt32LittleEndian(header[28..], BytesPerSecond);
        BinaryPrimitives.WriteUInt16LittleEndian(header[32..], Channels * (BitsPerSample / 8));
        BinaryPrimitives.WriteUInt16LittleEndian(header[34..], BitsPerSample);
        "data"u8.CopyTo(header[36..]);
        BinaryPrimitives.WriteUInt32LittleEndian(header[40..], (uint)pcm.Length);

        pcm.CopyTo(bytes.AsSpan(HeaderLength));
        return bytes;
    }

    /// <summary>
    /// Whether <paramref name="bytes"/> really are a RIFF/WAVE stream, checked structurally rather
    /// than by trusting the caller's media type.
    /// </summary>
    /// <remarks>
    /// This exists because a wrong <c>mediaType</c> is the one artifact defect a reader cannot
    /// detect or repair: the bytes are content-addressed and internally consistent, and nothing else
    /// in the archive says what they are. So the producer proves the claim before the bytes become
    /// durable, rather than asserting it.
    /// </remarks>
    /// <param name="bytes">The candidate container.</param>
    public static bool IsWave(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 12 || !bytes[..4].SequenceEqual("RIFF"u8) || !bytes[8..12].SequenceEqual("WAVE"u8))
        {
            return false;
        }

        // The declared RIFF size must account for everything after it. A truncated clip is a real
        // failure mode of a recorder that was killed mid-write, and it must not reach the archive
        // wearing a media type that promises a complete stream.
        uint declared = BinaryPrimitives.ReadUInt32LittleEndian(bytes[4..]);
        return declared == (uint)(bytes.Length - 8);
    }
}

/// <summary>
/// Converts a device's interleaved capture frames into the mono 16 kHz signed PCM
/// <see cref="NarrationWave"/> stores, keeping the resampling phase across buffer boundaries.
/// </summary>
/// <remarks>
/// <para>
/// The instance is stateful on purpose. A capture device delivers packets whose frame counts do not
/// divide evenly into the output rate, so the fractional position within the output grid has to
/// survive from one packet to the next; a converter that reset per packet would drop or duplicate a
/// sample at every boundary and accumulate drift a transcript could not be aligned against.
/// </para>
/// <para>
/// The resampler is the same zero-order accumulator the macOS client uses for its live PCM path.
/// Both clients therefore make the same rounding decisions, which is what lets a downstream consumer
/// treat their clips as one format rather than two.
/// </para>
/// </remarks>
public sealed class NarrationDownmixer
{
    private readonly int _sourceRateHz;
    private readonly int _sourceChannels;
    private readonly NarrationSampleFormat _format;
    private readonly int _bytesPerSample;
    private double _accumulator;

    /// <summary>Creates a converter for one device format.</summary>
    /// <param name="sourceRateHz">Device sample rate; positive.</param>
    /// <param name="sourceChannels">Device channel count; positive.</param>
    /// <param name="format">Device sample encoding.</param>
    /// <exception cref="ArgumentOutOfRangeException">The format is not one this can read.</exception>
    public NarrationDownmixer(int sourceRateHz, int sourceChannels, NarrationSampleFormat format)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(sourceRateHz, 0);
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(sourceChannels, 0);

        _sourceRateHz = sourceRateHz;
        _sourceChannels = sourceChannels;
        _format = format;
        _bytesPerSample = format switch
        {
            NarrationSampleFormat.Float32 => sizeof(float),
            NarrationSampleFormat.Pcm16 => sizeof(short),
            _ => throw new ArgumentOutOfRangeException(nameof(format), format, "unknown sample format"),
        };
    }

    /// <summary>Bytes one whole device frame (all channels) occupies.</summary>
    public int SourceFrameBytes => _bytesPerSample * _sourceChannels;

    /// <summary>
    /// Converts one packet and appends the result to <paramref name="destination"/>.
    /// </summary>
    /// <param name="frames">
    /// Interleaved device frames. A trailing partial frame is ignored rather than misread: half a
    /// frame is not a sample, and inventing one would put a click in the recording.
    /// </param>
    /// <param name="destination">Receives mono 16-bit little-endian samples.</param>
    public void Append(ReadOnlySpan<byte> frames, Stream destination)
    {
        ArgumentNullException.ThrowIfNull(destination);

        int frameCount = frames.Length / SourceFrameBytes;
        Span<byte> sample = stackalloc byte[sizeof(short)];

        for (var frame = 0; frame < frameCount; frame++)
        {
            ReadOnlySpan<byte> current = frames.Slice(frame * SourceFrameBytes, SourceFrameBytes);
            float mono = 0;
            for (var channel = 0; channel < _sourceChannels; channel++)
            {
                mono += Read(current.Slice(channel * _bytesPerSample, _bytesPerSample));
            }

            mono /= _sourceChannels;

            _accumulator += NarrationWave.SampleRateHz;
            while (_accumulator >= _sourceRateHz)
            {
                _accumulator -= _sourceRateHz;
                BinaryPrimitives.WriteInt16LittleEndian(sample, Quantize(mono));
                destination.Write(sample);
            }
        }
    }

    private float Read(ReadOnlySpan<byte> value) => _format switch
    {
        NarrationSampleFormat.Float32 => BitConverter.Int32BitsToSingle(
            BinaryPrimitives.ReadInt32LittleEndian(value)),
        _ => BinaryPrimitives.ReadInt16LittleEndian(value) / (float)short.MaxValue,
    };

    /// <summary>
    /// Clamps before scaling. A device can hand over a float slightly outside [-1, 1], and letting
    /// that wrap around <see cref="short"/> would turn a loud syllable into a burst of noise.
    /// </summary>
    private static short Quantize(float value)
    {
        float clamped = Math.Clamp(value, -1f, 1f);
        return (short)Math.Round(clamped * short.MaxValue, MidpointRounding.AwayFromZero);
    }
}
