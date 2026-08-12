namespace JazzCaptureCore.Screen;

/// <summary>
/// Difference hash (dHash) over a tiny grayscale grid: one bit per horizontal neighbour comparison,
/// 64 bits for the canonical 9x8 grid.
/// </summary>
/// <remarks>
/// <para>
/// The hash exists so a consumer can tell two frames apart cheaply. It is deliberately <b>not</b>
/// used to skip frames on the capture path. Whole-frame perceptual dedup was removed upstream after
/// it erased small but process-critical changes — one selected spreadsheet cell, one edited word —
/// which is exactly the evidence a process recording is for. Archive fidelity wins; the bandwidth
/// argument belongs to delivery, which is archive-level and user-confirmed anyway.
/// </para>
/// <para>
/// Pure arithmetic over a byte buffer, so it is unit-tested on any platform rather than only on the
/// machine that can actually take a screenshot.
/// </para>
/// </remarks>
public static class PerceptualHash
{
    /// <summary>Grid width the capture path downscales to; 9 columns give 8 comparisons per row.</summary>
    public const int GridWidth = 9;

    /// <summary>Grid height the capture path downscales to; 8 rows of 8 bits is exactly 64.</summary>
    public const int GridHeight = 8;

    /// <summary>
    /// Hashes a row-major grayscale grid: each pixel is compared with its right neighbour, emitting
    /// <c>(width - 1) * height</c> bits, least significant bit first.
    /// </summary>
    /// <param name="grayscale">Exactly <paramref name="width"/> * <paramref name="height"/> bytes.</param>
    /// <param name="width">Grid width; at least 2, since a comparison needs a neighbour.</param>
    /// <param name="height">Grid height; at least 1.</param>
    /// <returns>
    /// The hash, or 0 when the grid cannot be hashed. Zero is the "no signal" answer: a caller that
    /// compares hashes must treat it as matching nothing, so a frame is kept rather than discarded on
    /// the strength of a hash that was never computed.
    /// </returns>
    public static ulong DHash(ReadOnlySpan<byte> grayscale, int width, int height)
    {
        if (width < 2 || height < 1 || grayscale.Length != width * height || (width - 1) * height > 64)
        {
            return 0;
        }

        ulong hash = 0;
        int bit = 0;
        for (int row = 0; row < height; row++)
        {
            int start = row * width;
            for (int column = 0; column < width - 1; column++)
            {
                if (grayscale[start + column] < grayscale[start + column + 1])
                {
                    hash |= 1UL << bit;
                }

                bit++;
            }
        }

        return hash;
    }

    /// <summary>Number of differing bits between two hashes; small means visually similar.</summary>
    public static int HammingDistance(ulong left, ulong right) =>
        System.Numerics.BitOperations.PopCount(left ^ right);
}
