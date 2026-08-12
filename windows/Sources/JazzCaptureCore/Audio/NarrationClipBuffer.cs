namespace JazzCaptureCore.Audio;

/// <summary>
/// The spool one narration clip accumulates in: device frames in, bounded mono 16 kHz PCM out, and a
/// RIFF/WAVE stream at the end.
/// </summary>
/// <remarks>
/// <para>
/// This is where the two rules a capture loop keeps getting wrong live, in a class that can be
/// tested without a microphone.
/// </para>
/// <para>
/// <b>Silence is written, not skipped.</b> A capture device sets
/// <c>AUDCLNT_BUFFERFLAGS_SILENT</c> on a packet whose contents are undefined and are to be treated
/// as zeroes. Dropping such a packet — the obvious reading of "there is nothing here" — shortens the
/// clip by exactly the length of every pause in it, so a fifteen-minute label yields nine minutes of
/// audio and every word in it lands earlier than it was spoken. The clip has to be a recording of an
/// interval, not a concatenation of the parts of it that were loud, or nothing downstream can align
/// it to the events it brackets. <see cref="AppendSilence"/> therefore feeds real zeroes through the
/// same converter, so the resampler's phase advances identically either way.
/// </para>
/// <para>
/// <b>A clip is bounded.</b> A label is a task step, but nothing stops a user from opening one and
/// going home, and 16 kHz mono PCM accumulates at
/// <see cref="NarrationWave.BytesPerSecond"/> bytes a second whether anyone is speaking or not. The
/// ceiling is the point at which the recorder stops rather than the point at which the disk does.
/// Reaching it is not an error: the clip is sealed with what it has and its declared interval ends
/// where the audio does, so it still describes itself truthfully.
/// </para>
/// </remarks>
public sealed class NarrationClipBuffer
{
    /// <summary>
    /// Frames of silence synthesized per pass. Bounds the scratch buffer for a device that reports
    /// an implausibly long silent packet; the loop simply runs more than once.
    /// </summary>
    private const int SilenceChunkFrames = 1024;

    private readonly NarrationDownmixer _downmixer;
    private readonly MemoryStream _pcm = new();
    private readonly byte[] _silence;
    private readonly int _byteCeiling;

    /// <summary>Creates a spool for one clip.</summary>
    /// <param name="format">The device format every appended packet is in.</param>
    /// <param name="byteCeiling">
    /// Largest output payload this clip may reach, in bytes. Rounded down to a whole 16-bit sample,
    /// because half a sample is not audio.
    /// </param>
    /// <exception cref="ArgumentOutOfRangeException">The ceiling is smaller than one sample.</exception>
    public NarrationClipBuffer(NarrationMixFormat format, int byteCeiling)
    {
        ArgumentNullException.ThrowIfNull(format);
        ArgumentOutOfRangeException.ThrowIfLessThan(byteCeiling, SampleBytes);

        _downmixer = format.CreateDownmixer();
        _byteCeiling = byteCeiling - (byteCeiling % SampleBytes);
        _silence = new byte[SilenceChunkFrames * _downmixer.SourceFrameBytes];
    }

    /// <summary>Width of one output sample.</summary>
    private static int SampleBytes => NarrationWave.BitsPerSample / 8;

    /// <summary>Bytes one whole device frame occupies; the unit every append is measured in.</summary>
    public int SourceFrameBytes => _downmixer.SourceFrameBytes;

    /// <summary>The ceiling actually in force, after rounding to a whole sample.</summary>
    public int ByteCeiling => _byteCeiling;

    /// <summary>Output bytes accumulated so far, excluding the header a seal adds.</summary>
    public int Length => (int)_pcm.Length;

    /// <summary>
    /// Whether the ceiling has been reached. The recorder stops the device on this rather than
    /// keeping a microphone open whose samples it is throwing away.
    /// </summary>
    public bool IsFull => _pcm.Length >= _byteCeiling;

    /// <summary>Converts one captured packet and appends it.</summary>
    /// <param name="frames">Interleaved device frames, exactly as the endpoint delivered them.</param>
    public void Append(ReadOnlySpan<byte> frames)
    {
        if (IsFull || frames.IsEmpty)
        {
            return;
        }

        _downmixer.Append(frames, _pcm);
        Enforce();
    }

    /// <summary>
    /// Appends <paramref name="frameCount"/> frames of silence: what a packet flagged
    /// <c>AUDCLNT_BUFFERFLAGS_SILENT</c> means, spelled out in samples.
    /// </summary>
    /// <param name="frameCount">Frames the device reported; zero is a no-op.</param>
    public void AppendSilence(int frameCount)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(frameCount);

        int remaining = frameCount;
        while (remaining > 0 && !IsFull)
        {
            int chunk = Math.Min(remaining, SilenceChunkFrames);
            _downmixer.Append(_silence.AsSpan(0, chunk * SourceFrameBytes), _pcm);
            remaining -= chunk;
            Enforce();
        }
    }

    /// <summary>The clip as a complete <c>audio/wav</c> stream.</summary>
    /// <remarks>
    /// Reading the spool leaves it intact, so a caller that seals and then discovers it cannot use
    /// the bytes has not destroyed them.
    /// </remarks>
    public byte[] Seal() => NarrationWave.Wrap(_pcm.GetBuffer().AsSpan(0, Length));

    /// <summary>
    /// Trims anything the last packet pushed past the ceiling, so the bound is exact rather than
    /// exact-to-within-a-packet.
    /// </summary>
    private void Enforce()
    {
        if (_pcm.Length > _byteCeiling)
        {
            _pcm.SetLength(_byteCeiling);
        }
    }
}
