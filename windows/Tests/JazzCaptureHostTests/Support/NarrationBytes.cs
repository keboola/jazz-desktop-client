using JazzCaptureCore.Audio;

namespace JazzCaptureHostTests;

/// <summary>
/// A genuine RIFF/WAVE stream for the host tests that need one, produced through
/// <see cref="NarrationWave.Wrap"/> itself -- a fixture that could not survive the producer's own
/// <see cref="NarrationWave.IsWave"/> check would prove nothing about the narration spool's own
/// integrity verification.
/// </summary>
internal static class NarrationBytes
{
    /// <summary>A short, valid <c>audio/wav</c> clip: a handful of silent 16-bit mono frames wrapped
    /// in the canonical 44-byte RIFF/WAVE header. A fresh array each time, so a test can never
    /// mutate a shared fixture.</summary>
    internal static byte[] TinyClip(int frameCount = 8)
    {
        byte[] pcm = new byte[frameCount * 2];
        return NarrationWave.Wrap(pcm);
    }

    /// <summary>A clip of exactly <paramref name="totalBytes"/> bytes (header included), for bound
    /// and ceiling tests that need a precise size rather than a realistic one.</summary>
    internal static byte[] OfExactSize(int totalBytes)
    {
        int pcmLength = Math.Max(0, totalBytes - NarrationWave.HeaderLength);
        byte[] wrapped = NarrationWave.Wrap(new byte[pcmLength]);
        return wrapped.Length == totalBytes
            ? wrapped
            : throw new ArgumentException(
                $"Cannot produce an exact {totalBytes}-byte clip; header alone is {NarrationWave.HeaderLength} bytes.",
                nameof(totalBytes));
    }
}
