using JazzCaptureCore;
using JazzCaptureCore.Audio;

namespace JazzCaptureCoreTests;

/// <summary>
/// A microphone that behaves exactly as a test tells it to, and produces real audio when it works.
/// </summary>
/// <remarks>
/// The bytes are a genuine RIFF/WAVE stream rather than a placeholder. The archive only hashes them,
/// so nothing downstream would notice — but the producer refuses a clip whose bytes are not what its
/// media type claims, and a fixture that could not survive its own check would prove nothing about
/// the path a real recorder takes.
/// </remarks>
internal sealed class FakeNarrationSource : INarrationSource
{
    private readonly Queue<NarrationStartResult> _starts = new();
    private readonly Queue<NarrationSealResult> _seals = new();
    private readonly List<string> _startedLabels = new();

    private int _clip;

    /// <summary>Labels a clip was opened for, in order. A refused start still records the attempt.</summary>
    internal IReadOnlyList<string> StartedLabels => _startedLabels;

    /// <summary>How many clips were sealed, however they turned out.</summary>
    internal int SealCount { get; private set; }

    /// <summary>Whether the source believes a clip is open, so a test can catch an unbalanced pair.</summary>
    internal bool IsRecording { get; private set; }

    /// <summary>Queues one start outcome. Unqueued starts succeed.</summary>
    internal FakeNarrationSource ThenStart(NarrationStartResult result)
    {
        _starts.Enqueue(result);
        return this;
    }

    /// <summary>Queues one seal outcome. Unqueued seals produce a fresh clip.</summary>
    internal FakeNarrationSource ThenSeal(NarrationSealResult result)
    {
        _seals.Enqueue(result);
        return this;
    }

    /// <inheritdoc />
    public NarrationStartResult StartClip(string labelId)
    {
        _startedLabels.Add(labelId);
        NarrationStartResult result = _starts.Count > 0 ? _starts.Dequeue() : NarrationStartResult.Started;
        IsRecording = result.Status == NarrationStartStatus.Started;
        return result;
    }

    /// <inheritdoc />
    public NarrationSealResult SealClip()
    {
        SealCount++;
        IsRecording = false;
        return _seals.Count > 0 ? _seals.Dequeue() : NarrationSealResult.Sealed(Clip(++_clip));
    }

    /// <summary>One second of quiet 16 kHz mono audio, timestamped so clips never collide.</summary>
    internal static NarrationClip Clip(int index)
    {
        var start = new DateTimeOffset(2026, 7, 22, 9, index, 0, TimeSpan.Zero);
        return new NarrationClip(
            Timestamps.IsoMillisUtc(start),
            Timestamps.IsoMillisUtc(start.AddSeconds(1)),
            NarrationWave.Wrap(new byte[NarrationWave.BytesPerSecond]),
            NarrationWave.MediaType);
    }
}
