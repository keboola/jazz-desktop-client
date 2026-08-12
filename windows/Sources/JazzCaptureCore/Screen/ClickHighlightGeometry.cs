namespace JazzCaptureCore.Screen;

/// <summary>
/// The coordinate math behind the on-screen click highlight: deciding whether a resolved element is
/// worth outlining at all, and placing that outline inside the overlay window.
/// </summary>
/// <remarks>
/// <para>
/// This is separated from the window that draws it for the same reason the macOS client separates
/// its own highlight geometry: the arithmetic is where the mistakes live — an origin not subtracted,
/// a scale applied twice, a rectangle that runs off the end of a monitor — and none of it needs a
/// screen to be checked.
/// </para>
/// <para>
/// Two coordinate systems meet here. UI Automation reports an element's rectangle in physical screen
/// pixels, with the origin at the top-left of the primary monitor and negative coordinates on
/// monitors placed above or to the left of it. The overlay draws in device-independent units
/// relative to its own top-left corner. The conversion is therefore "subtract the overlay's screen
/// origin, then divide by the display scale", and it is done once, here.
/// </para>
/// </remarks>
public static class ClickHighlightGeometry
{
    /// <summary>
    /// Smallest side, in physical pixels, an element must have before it is outlined.
    /// </summary>
    /// <remarks>
    /// The resolver falls back to a 1×1 rectangle around the pointer whenever it could not find a
    /// real element, and it collapses an anonymous container to the same rectangle. Flashing a
    /// single pixel tells the user nothing about what was captured while still putting a flicker on
    /// their screen, so the fallback rectangle is deliberately below this bound. The macOS overlay
    /// applies the same rule.
    /// </remarks>
    public const double MinimumFlashSide = 1.0;

    /// <summary>Whether a resolved rectangle describes an element worth outlining.</summary>
    /// <param name="elementRect">The element rectangle in physical screen pixels, if any.</param>
    public static bool IsWorthFlashing(BoundingBox? elementRect) =>
        elementRect is { } rect
        && double.IsFinite(rect.Width)
        && double.IsFinite(rect.Height)
        && rect.Width > MinimumFlashSide
        && rect.Height > MinimumFlashSide;

    /// <summary>
    /// Places an element rectangle inside the overlay window, in the overlay's own units.
    /// </summary>
    /// <param name="elementRect">The element rectangle, in physical screen pixels.</param>
    /// <param name="overlayRect">The overlay window's bounds, in physical screen pixels.</param>
    /// <param name="scaleX">Physical pixels per device-independent unit horizontally; must be positive.</param>
    /// <param name="scaleY">Physical pixels per device-independent unit vertically; must be positive.</param>
    /// <returns>
    /// The rectangle to draw, in device-independent units relative to the overlay's top-left corner,
    /// or <see langword="null"/> when there is nothing to draw — a degenerate element, a degenerate
    /// overlay, or an element that lies entirely outside the overlay.
    /// </returns>
    /// <remarks>
    /// The result is clipped to the overlay rather than merely translated. An element can extend past
    /// the edge of the desktop — a window dragged half off-screen, a control inside one — and an
    /// unclipped rectangle would make the overlay window itself grow a scrollable area or silently
    /// mis-scale. Clipping keeps the outline over the part of the element the user can actually see.
    /// </remarks>
    public static BoundingBox? ToOverlayLocal(
        BoundingBox? elementRect,
        BoundingBox overlayRect,
        double scaleX,
        double scaleY)
    {
        ArgumentNullException.ThrowIfNull(overlayRect);

        if (!IsWorthFlashing(elementRect)
            || elementRect is not { } element
            || overlayRect.Width <= 0
            || overlayRect.Height <= 0
            || !(scaleX > 0)
            || !(scaleY > 0)
            || !double.IsFinite(scaleX)
            || !double.IsFinite(scaleY))
        {
            return null;
        }

        double left = Math.Max(element.X, overlayRect.X);
        double top = Math.Max(element.Y, overlayRect.Y);
        double right = Math.Min(element.X + element.Width, overlayRect.X + overlayRect.Width);
        double bottom = Math.Min(element.Y + element.Height, overlayRect.Y + overlayRect.Height);

        if (right <= left || bottom <= top)
        {
            return null;
        }

        return new BoundingBox(
            (left - overlayRect.X) / scaleX,
            (top - overlayRect.Y) / scaleY,
            (right - left) / scaleX,
            (bottom - top) / scaleY);
    }
}
