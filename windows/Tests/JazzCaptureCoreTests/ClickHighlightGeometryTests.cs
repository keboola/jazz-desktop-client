using JazzCaptureCore;
using JazzCaptureCore.Screen;

namespace JazzCaptureCoreTests;

/// <summary>
/// The highlight is drawn from an element rectangle in physical screen pixels into a window that
/// measures in device-independent units and may start at a negative screen coordinate. These are the
/// three ways that goes wrong: the origin, the scale, and a rectangle that leaves the desktop.
/// </summary>
public sealed class ClickHighlightGeometryTests
{
    private static readonly BoundingBox SingleDisplay = new(0, 0, 1920, 1080);

    [Fact]
    public void ARectangleOnThePrimaryDisplayIsUnchangedAtUnitScale()
    {
        BoundingBox? local = ClickHighlightGeometry.ToOverlayLocal(
            new BoundingBox(100, 200, 300, 40),
            SingleDisplay,
            scaleX: 1,
            scaleY: 1);

        Assert.Equal(new BoundingBox(100, 200, 300, 40), local);
    }

    [Fact]
    public void TheOverlayOriginIsSubtractedBeforeScaling()
    {
        // A second monitor to the left of the primary puts the virtual screen origin at a negative
        // coordinate; forgetting to subtract it draws the outline a whole monitor away.
        var virtualScreen = new BoundingBox(-1920, -200, 3840, 1280);

        BoundingBox? local = ClickHighlightGeometry.ToOverlayLocal(
            new BoundingBox(-1820, -100, 200, 50),
            virtualScreen,
            scaleX: 1,
            scaleY: 1);

        Assert.Equal(new BoundingBox(100, 100, 200, 50), local);
    }

    [Fact]
    public void PhysicalPixelsAreConvertedToDeviceIndependentUnits()
    {
        BoundingBox? local = ClickHighlightGeometry.ToOverlayLocal(
            new BoundingBox(300, 150, 600, 90),
            SingleDisplay,
            scaleX: 1.5,
            scaleY: 1.5);

        Assert.Equal(new BoundingBox(200, 100, 400, 60), local);
    }

    [Fact]
    public void OriginAndScaleCompose()
    {
        BoundingBox? local = ClickHighlightGeometry.ToOverlayLocal(
            new BoundingBox(-1600, -100, 400, 200),
            new BoundingBox(-1920, -200, 3840, 1280),
            scaleX: 2,
            scaleY: 2);

        Assert.Equal(new BoundingBox(160, 50, 200, 100), local);
    }

    [Fact]
    public void ARectangleRunningOffTheDesktopIsClipped()
    {
        BoundingBox? local = ClickHighlightGeometry.ToOverlayLocal(
            new BoundingBox(1820, 1040, 400, 400),
            SingleDisplay,
            scaleX: 1,
            scaleY: 1);

        Assert.Equal(new BoundingBox(1820, 1040, 100, 40), local);
    }

    [Fact]
    public void ARectangleEntirelyOffTheDesktopDrawsNothing()
    {
        Assert.Null(ClickHighlightGeometry.ToOverlayLocal(
            new BoundingBox(4000, 4000, 100, 100),
            SingleDisplay,
            scaleX: 1,
            scaleY: 1));
    }

    [Fact]
    public void ThePointerFallbackRectangleIsNeverFlashed()
    {
        // The resolver emits a 1x1 rectangle around the pointer when it found no element, and
        // collapses an anonymous container to the same shape. Outlining one pixel would be a
        // flicker that tells the user nothing about what was captured.
        var pointerRect = new BoundingBox(499.5, 299.5, 1, 1);

        Assert.False(ClickHighlightGeometry.IsWorthFlashing(pointerRect));
        Assert.Null(ClickHighlightGeometry.ToOverlayLocal(pointerRect, SingleDisplay, 1, 1));
    }

    [Fact]
    public void AnAbsentOrDegenerateRectangleIsNotFlashed()
    {
        Assert.False(ClickHighlightGeometry.IsWorthFlashing(null));
        Assert.False(ClickHighlightGeometry.IsWorthFlashing(new BoundingBox(0, 0, 0, 0)));
        Assert.False(ClickHighlightGeometry.IsWorthFlashing(new BoundingBox(0, 0, 100, -5)));
        Assert.False(ClickHighlightGeometry.IsWorthFlashing(new BoundingBox(0, 0, double.NaN, 10)));
        Assert.False(ClickHighlightGeometry.IsWorthFlashing(
            new BoundingBox(0, 0, double.PositiveInfinity, 10)));
    }

    [Fact]
    public void AnElementLargerThanOnePixelIsFlashed()
    {
        Assert.True(ClickHighlightGeometry.IsWorthFlashing(new BoundingBox(10, 10, 1.5, 1.5)));
    }

    [Fact]
    public void ANonsensicalScaleOrOverlayDrawsNothing()
    {
        var element = new BoundingBox(10, 10, 100, 100);

        Assert.Null(ClickHighlightGeometry.ToOverlayLocal(element, SingleDisplay, 0, 1));
        Assert.Null(ClickHighlightGeometry.ToOverlayLocal(element, SingleDisplay, 1, -1));
        Assert.Null(ClickHighlightGeometry.ToOverlayLocal(element, SingleDisplay, double.NaN, 1));
        Assert.Null(ClickHighlightGeometry.ToOverlayLocal(element, new BoundingBox(0, 0, 0, 1080), 1, 1));
    }
}
