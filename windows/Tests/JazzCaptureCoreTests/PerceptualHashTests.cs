using JazzCaptureCore.Screen;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the dHash and the grayscale downscale that feeds it.
/// </summary>
/// <remarks>
/// The hash never decides whether a frame is kept, so these tests are not guarding a skip rule —
/// they guard the arithmetic, so two clients looking at the same pixels agree about what they saw.
/// </remarks>
public sealed class PerceptualHashTests
{
    [Fact]
    public void EachBitSaysWhetherThePixelToTheRightIsBrighter()
    {
        // One row: 0 < 9 sets bit 0, 9 > 1 leaves bit 1 clear, 1 < 4 sets bit 2.
        byte[] row = { 0, 9, 1, 4 };

        Assert.Equal(0b101UL, PerceptualHash.DHash(row, 4, 1));
    }

    [Fact]
    public void RowsFillTheBitsInOrder()
    {
        byte[] grid = { 0, 1, 1, 0 };

        // Row 0: 0 < 1 sets bit 0. Row 1: 1 > 0 leaves bit 1 clear.
        Assert.Equal(0b01UL, PerceptualHash.DHash(grid, 2, 2));
    }

    [Fact]
    public void TheCanonicalGridIsExactlySixtyFourBits()
    {
        var alternating = new byte[PerceptualHash.GridWidth * PerceptualHash.GridHeight];
        for (int i = 0; i < alternating.Length; i++)
        {
            alternating[i] = (byte)(i % 2 == 0 ? 0 : 255);
        }

        ulong hash = PerceptualHash.DHash(alternating, PerceptualHash.GridWidth, PerceptualHash.GridHeight);

        Assert.Equal(64, System.Numerics.BitOperations.PopCount(hash) + System.Numerics.BitOperations.PopCount(~hash));
        Assert.NotEqual(0UL, hash);
    }

    [Fact]
    public void AFlatFrameHashesToZeroBecauseNoNeighbourIsBrighter() =>
        Assert.Equal(0UL, PerceptualHash.DHash(new byte[72], 9, 8));

    /// <summary>
    /// Zero is also the answer when the grid cannot be hashed at all. Both meanings are safe,
    /// because zero matches nothing a caller would compare against and the frame is kept either way.
    /// </summary>
    [Theory]
    [InlineData(1, 8)]
    [InlineData(9, 0)]
    [InlineData(20, 8)]
    public void AGridThatCannotBeHashedYieldsNoSignal(int width, int height) =>
        Assert.Equal(0UL, PerceptualHash.DHash(new byte[72], width, height));

    [Fact]
    public void AGridOfTheWrongLengthIsRefused() =>
        Assert.Equal(0UL, PerceptualHash.DHash(new byte[71], 9, 8));

    [Fact]
    public void TheHammingDistanceCountsDifferingBits()
    {
        Assert.Equal(0, PerceptualHash.HammingDistance(0xDEADBEEF, 0xDEADBEEF));
        Assert.Equal(3, PerceptualHash.HammingDistance(0b000, 0b111));
    }

    // --- The downscale --------------------------------------------------------------------------

    [Fact]
    public void TheDownscaleAveragesEachSourceBandIntoOneCell()
    {
        // A 2x1 grid over a 4x2 black-and-white frame: the left half is black, the right white.
        byte[] pixels = Bgra(4, 2, (x, _) => x < 2 ? (byte)0 : (byte)255);

        byte[] grid = ScreenshotThumbnail.Grayscale(pixels, 4, 2, 16, 2, 1)!;

        Assert.Equal(0, grid[0]);
        Assert.InRange(grid[1], 250, 255);
    }

    [Fact]
    public void AFrameSmallerThanTheGridStillProducesEveryCell()
    {
        byte[] pixels = Bgra(2, 2, (_, _) => 128);

        byte[] grid = ScreenshotThumbnail.Grayscale(pixels, 2, 2, 8)!;

        Assert.Equal(PerceptualHash.GridWidth * PerceptualHash.GridHeight, grid.Length);
        Assert.All(grid, sample => Assert.InRange(sample, 125, 131));
    }

    [Fact]
    public void RowPaddingIsRespected()
    {
        // Stride wider than the row: the padding bytes are 255 and must never reach the grid.
        const int width = 2;
        const int height = 2;
        const int stride = 16;
        var pixels = new byte[stride * height];
        Array.Fill(pixels, (byte)255);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width * 4; x++)
            {
                pixels[(y * stride) + x] = 0;
            }
        }

        byte[] grid = ScreenshotThumbnail.Grayscale(pixels, width, height, stride, 1, 1)!;

        Assert.Equal(0, grid[0]);
    }

    [Theory]
    [InlineData(0, 8, 32)]
    [InlineData(8, 0, 32)]
    [InlineData(8, 8, 4)]
    public void ABufferTheDownscaleCannotReadYieldsNoGrid(int width, int height, int stride) =>
        Assert.Null(ScreenshotThumbnail.Grayscale(new byte[256], width, height, stride));

    [Fact]
    public void ATruncatedBufferYieldsNoGrid() =>
        Assert.Null(ScreenshotThumbnail.Grayscale(new byte[16], 8, 8, 32));

    /// <summary>Builds a 32-bit BGRA buffer whose three colour channels all carry the same value.</summary>
    private static byte[] Bgra(int width, int height, Func<int, int, byte> value)
    {
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int offset = ((y * width) + x) * 4;
                byte sample = value(x, y);
                pixels[offset] = sample;
                pixels[offset + 1] = sample;
                pixels[offset + 2] = sample;
                pixels[offset + 3] = 255;
            }
        }

        return pixels;
    }
}
