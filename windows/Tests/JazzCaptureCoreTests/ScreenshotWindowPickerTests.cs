using JazzCaptureCore;
using JazzCaptureCore.Screen;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the window pick of ANNEX-HOST section 4: which of an application's windows a click is
/// entitled to a picture of, and when the honest answer is none.
/// </summary>
public sealed class ScreenshotWindowPickerTests
{
    private static ScreenshotWindowCandidate Window(
        long id,
        double x,
        double y,
        double width,
        double height,
        bool visible = true,
        bool tool = false) =>
        new(id, new BoundingBox(x, y, width, height), visible, tool);

    /// <summary>Where the pointer landed, as the host hands it over: a one-point rectangle.</summary>
    private static BoundingBox At(double x, double y) => new(x - 0.5, y - 0.5, 1, 1);

    [Fact]
    public void TheWindowContainingTheTargetWins()
    {
        var candidates = new[]
        {
            Window(1, 0, 0, 800, 600),
            Window(2, 900, 0, 800, 600),
        };

        Assert.Equal(2, ScreenshotWindowPicker.Pick(candidates, At(1000, 100), true)!.WindowId);
    }

    /// <summary>
    /// The one rule that keeps a screenshot honest. Without it a click in a window the enumeration
    /// missed would be illustrated by whichever window happened to be biggest.
    /// </summary>
    [Fact]
    public void NoWindowAtTheTargetMeansNoPictureWhenTheCallerRequiresOne()
    {
        var candidates = new[] { Window(1, 0, 0, 800, 600) };

        Assert.Null(ScreenshotWindowPicker.Pick(candidates, At(5_000, 5_000), true));
    }

    [Fact]
    public void WithoutThatRequirementTheLargestWindowIsTheDocumentWindow()
    {
        var candidates = new[]
        {
            Window(1, 0, 0, 200, 200),
            Window(2, 0, 0, 800, 600),
        };

        Assert.Equal(2, ScreenshotWindowPicker.Pick(candidates, At(5_000, 5_000), false)!.WindowId);
    }

    [Fact]
    public void WithNoTargetHintAtAllTheLargestWindowIsUsed()
    {
        var candidates = new[]
        {
            Window(9, 0, 0, 800, 600),
            Window(3, 0, 0, 200, 200),
        };

        Assert.Equal(9, ScreenshotWindowPicker.Pick(candidates, null, true)!.WindowId);
    }

    /// <summary>
    /// Enumeration order decides an overlap, and the host enumerates top-down, so the window the
    /// user can actually see wins over the one hidden behind it.
    /// </summary>
    [Fact]
    public void TheTopmostOfTwoOverlappingWindowsWins()
    {
        var candidates = new[]
        {
            Window(7, 0, 0, 400, 400),
            Window(8, 0, 0, 800, 600),
        };

        Assert.Equal(7, ScreenshotWindowPicker.Pick(candidates, At(100, 100), true)!.WindowId);
    }

    [Fact]
    public void AnEqualAreaTieBreaksOnTheSmallerWindowIdentity()
    {
        var candidates = new[]
        {
            Window(42, 0, 0, 800, 600),
            Window(7, 900, 0, 800, 600),
        };

        // Order the two the other way round: the answer must not depend on enumeration order once
        // the geometry is a tie, or the same desktop would produce two different archives.
        Assert.Equal(7, ScreenshotWindowPicker.Pick(candidates, null, false)!.WindowId);
        Assert.Equal(7, ScreenshotWindowPicker.Pick(candidates.Reverse().ToArray(), null, false)!.WindowId);
    }

    [Fact]
    public void HiddenMinimizedAndToolWindowsAreNotCandidates()
    {
        var candidates = new[]
        {
            Window(1, 0, 0, 800, 600, visible: false),
            Window(2, 0, 0, 800, 600, tool: true),
        };

        Assert.Null(ScreenshotWindowPicker.Pick(candidates, At(100, 100), true));
        Assert.Null(ScreenshotWindowPicker.Pick(candidates, null, false));
    }

    /// <summary>
    /// A 1x1 window is a message-only or placeholder window. Capturing one produces a frame that
    /// shows nothing at all, which is worse than admitting there was nothing to capture.
    /// </summary>
    [Theory]
    [InlineData(1, 1)]
    [InlineData(1, 600)]
    [InlineData(800, 1)]
    public void AWindowNoLargerThanOnePixelInEitherDirectionIsNotACandidate(double width, double height)
    {
        var candidates = new[] { Window(1, 0, 0, width, height) };

        Assert.Null(ScreenshotWindowPicker.Pick(candidates, null, false));
    }

    [Fact]
    public void AnApplicationWithNoWindowsAtAllYieldsNothing() =>
        Assert.Null(ScreenshotWindowPicker.Pick(Array.Empty<ScreenshotWindowCandidate>(), At(1, 1), true));

    /// <summary>
    /// Containment is half-open, matching the platform rectangle hit tests: a point on the right or
    /// bottom edge belongs to the neighbour, so two adjacent windows never both claim it.
    /// </summary>
    [Fact]
    public void TheRightAndBottomEdgesBelongToTheNextWindow()
    {
        var candidates = new[]
        {
            Window(1, 0, 0, 100, 100),
            Window(2, 100, 0, 100, 100),
        };

        Assert.Equal(1, ScreenshotWindowPicker.Pick(candidates, At(50.5, 50.5), true)!.WindowId);
        Assert.Equal(2, ScreenshotWindowPicker.Pick(candidates, At(100.5, 50.5), true)!.WindowId);
    }

    [Fact]
    public void ADegenerateTargetRectangleIsTreatedAsNoHintRatherThanAMiss()
    {
        var candidates = new[] { Window(1, 0, 0, 800, 600) };
        var empty = new BoundingBox(10, 10, 0, 0);

        Assert.Equal(1, ScreenshotWindowPicker.Pick(candidates, empty, true)!.WindowId);
    }
}
