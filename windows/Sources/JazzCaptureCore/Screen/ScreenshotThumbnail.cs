namespace JazzCaptureCore.Screen;

/// <summary>
/// Downscales a captured frame to the tiny grayscale grid <see cref="PerceptualHash"/> hashes.
/// </summary>
/// <remarks>
/// The OS could do this — every platform ships an image scaler — but then the hash would depend on
/// which platform and which scaler took the frame, and two clients looking at the same screen would
/// disagree about whether it changed. A box average over the source pixels is arithmetic, so it is
/// the same everywhere and can be tested without a screen.
/// </remarks>
public static class ScreenshotThumbnail
{
    /// <summary>Bytes per pixel of the 32-bit BGRA/BGRX buffers the Windows capture path produces.</summary>
    private const int BytesPerPixel = 4;

    /// <summary>
    /// Box-averages a 32-bit BGRA (or BGRX) buffer into a row-major grayscale grid.
    /// </summary>
    /// <param name="pixels">The source buffer; alpha is ignored.</param>
    /// <param name="width">Source width in pixels.</param>
    /// <param name="height">Source height in pixels.</param>
    /// <param name="stride">Bytes per source row; at least <paramref name="width"/> * 4.</param>
    /// <param name="gridWidth">Target width.</param>
    /// <param name="gridHeight">Target height.</param>
    /// <returns>
    /// The grid, or <see langword="null"/> when the arguments do not describe a buffer this can
    /// read. A null grid means no hash, which the caller treats as "keep the frame".
    /// </returns>
    public static byte[]? Grayscale(
        ReadOnlySpan<byte> pixels,
        int width,
        int height,
        int stride,
        int gridWidth = PerceptualHash.GridWidth,
        int gridHeight = PerceptualHash.GridHeight)
    {
        if (width <= 0
            || height <= 0
            || gridWidth <= 0
            || gridHeight <= 0
            || stride < width * BytesPerPixel
            || pixels.Length < ((height - 1) * stride) + (width * BytesPerPixel))
        {
            return null;
        }

        var grid = new byte[gridWidth * gridHeight];
        for (int cellY = 0; cellY < gridHeight; cellY++)
        {
            // Half-open source bands, each at least one pixel tall even when the frame is smaller
            // than the grid: an empty band would divide by zero and a clamped one would double-count
            // deterministically, which is fine for a similarity signal.
            int top = (int)((long)cellY * height / gridHeight);
            int bottom = Math.Max(top + 1, (int)((long)(cellY + 1) * height / gridHeight));
            bottom = Math.Min(bottom, height);

            for (int cellX = 0; cellX < gridWidth; cellX++)
            {
                int left = (int)((long)cellX * width / gridWidth);
                int right = Math.Max(left + 1, (int)((long)(cellX + 1) * width / gridWidth));
                right = Math.Min(right, width);

                long total = 0;
                long samples = 0;
                for (int y = top; y < bottom; y++)
                {
                    int row = y * stride;
                    for (int x = left; x < right; x++)
                    {
                        int offset = row + (x * BytesPerPixel);
                        // BT.601 luma in integers: the fractional weights would make the grid
                        // depend on floating-point rounding for no perceptual benefit.
                        total += ((pixels[offset] * 29) + (pixels[offset + 1] * 150) + (pixels[offset + 2] * 77)) >> 8;
                        samples++;
                    }
                }

                grid[(cellY * gridWidth) + cellX] = samples == 0 ? (byte)0 : (byte)(total / samples);
            }
        }

        return grid;
    }
}
