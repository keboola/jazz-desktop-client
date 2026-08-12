namespace JazzCaptureCore.Audio;

/// <summary>
/// The fields of a <c>WAVEFORMATEX</c> (or the <c>WAVEFORMATEXTENSIBLE</c> that extends it) which
/// decide whether this recorder can read a device's samples.
/// </summary>
/// <remarks>
/// A plain data carrier rather than the interop struct itself, so the decision it feeds can be made
/// and tested without COM. The interop layer copies the six numbers across and nothing else: the
/// channel mask and the valid-bits field describe how the device lays out channels it is about to
/// average away, and the average-bytes field is derivable from the rest.
/// </remarks>
/// <param name="FormatTag">
/// <c>wFormatTag</c>: 1 (PCM), 3 (IEEE float) or 0xFFFE (extensible, in which case
/// <paramref name="SubFormat"/> carries the real answer).
/// </param>
/// <param name="Channels">
/// <c>nChannels</c>. Any count is acceptable — they are averaged to mono — but it must be positive.
/// </param>
/// <param name="SampleRateHz"><c>nSamplesPerSec</c>; resampled to 16 kHz downstream.</param>
/// <param name="BitsPerSample"><c>wBitsPerSample</c>.</param>
/// <param name="BlockAlign">
/// <c>nBlockAlign</c>: the device's own statement of how many bytes one frame occupies. Cross-checked
/// rather than trusted or ignored, because it is the number that decides where every later frame
/// begins.
/// </param>
/// <param name="SubFormat">
/// The <c>WAVEFORMATEXTENSIBLE.SubFormat</c> GUID, or <see cref="Guid.Empty"/> when the header is a
/// plain <c>WAVEFORMATEX</c>.
/// </param>
public readonly record struct NarrationWaveFormatHeader(
    int FormatTag,
    int Channels,
    int SampleRateHz,
    int BitsPerSample,
    int BlockAlign,
    Guid SubFormat);

/// <summary>The format a capture device hands over, in the terms <see cref="NarrationDownmixer"/> reads.</summary>
/// <param name="SampleRateHz">Device sample rate.</param>
/// <param name="Channels">Device channel count.</param>
/// <param name="Format">Device sample encoding.</param>
public sealed record NarrationMixFormat(int SampleRateHz, int Channels, NarrationSampleFormat Format)
{
    /// <summary>Width of one sample of one channel.</summary>
    public int BitsPerSample => Format == NarrationSampleFormat.Float32 ? 32 : 16;

    /// <summary>Bytes one whole frame (all channels) occupies.</summary>
    public int FrameBytes => Channels * (BitsPerSample / 8);

    /// <summary>A converter from this format to the mono 16 kHz PCM the archive stores.</summary>
    public NarrationDownmixer CreateDownmixer() => new(SampleRateHz, Channels, Format);

    /// <summary>How the format reads in a log line or a capability detail.</summary>
    public override string ToString() =>
        SampleRateHz.ToString(System.Globalization.CultureInfo.InvariantCulture)
        + " Hz, "
        + Channels.ToString(System.Globalization.CultureInfo.InvariantCulture)
        + " ch, "
        + (Format == NarrationSampleFormat.Float32 ? "32-bit float" : "16-bit PCM");
}

/// <summary>
/// The outcome of reading a device's mix format: a format this recorder can convert, or why it
/// cannot.
/// </summary>
/// <remarks>
/// A refusal is a first-class result rather than an exception because it is ordinary evidence: the
/// clip does not happen, <c>audio.capture</c> goes unavailable with this sentence as its detail, and
/// the capture carries on. Nothing here is exceptional enough to unwind a call stack over.
/// </remarks>
public sealed record NarrationFormatChoice
{
    private NarrationFormatChoice()
    {
    }

    /// <summary>The usable format, or <see langword="null"/> when the device offered none.</summary>
    public NarrationMixFormat? Format { get; private init; }

    /// <summary>Why the format is unusable; present exactly when <see cref="Format"/> is absent.</summary>
    public string? Refusal { get; private init; }

    /// <summary>The device's format is one this recorder can read.</summary>
    /// <param name="format">The accepted format.</param>
    public static NarrationFormatChoice Accept(NarrationMixFormat format)
    {
        ArgumentNullException.ThrowIfNull(format);
        return new NarrationFormatChoice { Format = format };
    }

    /// <summary>The device's format is not one this recorder can read.</summary>
    /// <param name="refusal">Why, naming the format so the report is actionable.</param>
    public static NarrationFormatChoice Refuse(string refusal)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(refusal);
        return new NarrationFormatChoice { Refusal = NarrationDeviceStatus.Bounded(refusal) };
    }
}

/// <summary>
/// Decides what to do with the shared-mode mix format a capture endpoint reports.
/// </summary>
/// <remarks>
/// <para>
/// <b>The device's format is adopted, never demanded.</b> In shared mode the audio engine hands over
/// whatever the endpoint is already running at, and this recorder converts. The alternative — asking
/// the engine to convert to 16 kHz mono for us with <c>AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM</c> — would
/// move the resampling into the OS, where the two desktop clients would no longer make the same
/// rounding decisions, and would still need this path for the devices where the request is refused.
/// Converting here means a Windows clip and a macOS clip are the same artifact produced the same way.
/// </para>
/// <para>
/// Nearly every endpoint reports 32-bit float, and a few report 16-bit PCM; both are read. A device
/// reporting 24-bit packed PCM or 64-bit float is refused with its format named rather than misread,
/// because the failure mode of guessing is not silence — it is a clip full of noise that looks like a
/// recording and destroys the evidence it claims to be.
/// </para>
/// </remarks>
public static class NarrationMixFormats
{
    /// <summary><c>WAVE_FORMAT_PCM</c>.</summary>
    public const int WaveFormatPcm = 0x0001;

    /// <summary><c>WAVE_FORMAT_IEEE_FLOAT</c>.</summary>
    public const int WaveFormatIeeeFloat = 0x0003;

    /// <summary><c>WAVE_FORMAT_EXTENSIBLE</c>: the real tag is in the subformat GUID.</summary>
    public const int WaveFormatExtensible = 0xFFFE;

    /// <summary><c>KSDATAFORMAT_SUBTYPE_PCM</c>.</summary>
    public static readonly Guid SubtypePcm = new("00000001-0000-0010-8000-00AA00389B71");

    /// <summary><c>KSDATAFORMAT_SUBTYPE_IEEE_FLOAT</c>.</summary>
    public static readonly Guid SubtypeIeeeFloat = new("00000003-0000-0010-8000-00AA00389B71");

    /// <summary>Reads one device header and decides whether this recorder can convert it.</summary>
    /// <param name="header">The device's reported mix format.</param>
    public static NarrationFormatChoice Negotiate(NarrationWaveFormatHeader header)
    {
        if (header.Channels <= 0 || header.SampleRateHz <= 0)
        {
            return NarrationFormatChoice.Refuse(
                "the capture device reports " + header.Channels + " channels at "
                + header.SampleRateHz + " Hz, which is not a stream");
        }

        int tag = header.FormatTag;
        if (tag == WaveFormatExtensible)
        {
            if (header.SubFormat == SubtypePcm)
            {
                tag = WaveFormatPcm;
            }
            else if (header.SubFormat == SubtypeIeeeFloat)
            {
                tag = WaveFormatIeeeFloat;
            }
            else
            {
                return NarrationFormatChoice.Refuse(
                    "the capture device's mix format is WAVE_FORMAT_EXTENSIBLE with subtype "
                    + header.SubFormat.ToString("D")
                    + ", which is neither PCM nor IEEE float");
            }
        }

        NarrationSampleFormat? format = (tag, header.BitsPerSample) switch
        {
            (WaveFormatPcm, 16) => NarrationSampleFormat.Pcm16,
            (WaveFormatIeeeFloat, 32) => NarrationSampleFormat.Float32,
            _ => null,
        };

        if (format is not { } sampleFormat)
        {
            return NarrationFormatChoice.Refuse(
                "the capture device's mix format is tag " + tag + " at " + header.BitsPerSample
                + " bits per sample, which this recorder cannot read");
        }

        // The device's own frame stride has to agree with the arithmetic the converter will do, or
        // every frame after the first is read from the wrong offset. A disagreement is refused
        // rather than papered over: there is no reading of the samples that is safe once the two
        // descriptions of the same buffer differ.
        int frameBytes = header.Channels * (header.BitsPerSample / 8);
        if (header.BlockAlign != frameBytes)
        {
            return NarrationFormatChoice.Refuse(
                "the capture device reports nBlockAlign " + header.BlockAlign + " but "
                + header.Channels + " channels of " + header.BitsPerSample + " bits need "
                + frameBytes + " bytes per frame");
        }

        return NarrationFormatChoice.Accept(
            new NarrationMixFormat(header.SampleRateHz, header.Channels, sampleFormat));
    }
}
