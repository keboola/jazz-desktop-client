namespace JazzCaptureCore.Screen;

/// <summary>
/// One top-level window of the owning application, as the host enumerated it.
/// </summary>
/// <param name="WindowId">Platform window identity; on Windows a <c>HWND</c> truncated to 32 bits.</param>
/// <param name="Bounds">Window rectangle in screen coordinates.</param>
/// <param name="IsVisible">Whether the window is on screen and not minimized.</param>
/// <param name="IsToolWindow">
/// Whether the window is a tool window, palette, or other overlay panel rather than a document
/// window. The Windows counterpart of the macOS <c>windowLayer != 0</c> test.
/// </param>
public sealed record ScreenshotWindowCandidate(
    long WindowId,
    BoundingBox Bounds,
    bool IsVisible,
    bool IsToolWindow);

/// <summary>
/// Picks the window the user actually interacted with, out of everything the owning application has
/// on screen (ANNEX-HOST section 4).
/// </summary>
/// <remarks>
/// <para>
/// "The first window of the app" is the wrong answer and was the original bug on macOS: in a
/// multi-window setup it grabs a background window or a transient panel, and the capture API hands
/// back a blank placeholder. So candidates are filtered down to real, visible, larger-than-1x1
/// document windows, and among those the one containing the target midpoint wins.
/// </para>
/// <para>
/// With <c>requireWindowAtTarget</c> — always, for pointer events — nothing is returned when no
/// window contains the target. Guessing at that point would attach a picture of one window to a
/// click that happened in another, which is worse than having no picture at all.
/// </para>
/// <para>
/// Pure, so the pick is unit-tested without a desktop.
/// </para>
/// </remarks>
public static class ScreenshotWindowPicker
{
    /// <summary>
    /// Chooses among <paramref name="candidates"/>, which the caller has already narrowed to one
    /// application and must supply in z-order (topmost first) so an overlap resolves to the window
    /// the user can actually see.
    /// </summary>
    /// <param name="candidates">The owning application's top-level windows, topmost first.</param>
    /// <param name="targetRect">Where the interaction landed; null when the host has no hint.</param>
    /// <param name="requireWindowAtTarget">
    /// Whether a target that hits no window must return nothing rather than fall back to the largest
    /// window. True for every pointer event.
    /// </param>
    /// <returns>The chosen window, or <see langword="null"/> when there is no honest answer.</returns>
    public static ScreenshotWindowCandidate? Pick(
        IReadOnlyList<ScreenshotWindowCandidate> candidates,
        BoundingBox? targetRect,
        bool requireWindowAtTarget)
    {
        ArgumentNullException.ThrowIfNull(candidates);

        var eligible = candidates
            .Where(candidate => candidate.IsVisible
                && !candidate.IsToolWindow
                && candidate.Bounds.Width > 1
                && candidate.Bounds.Height > 1)
            .ToArray();
        if (eligible.Length == 0)
        {
            return null;
        }

        if (targetRect is { Width: > 0, Height: > 0 } target)
        {
            double x = target.X + (target.Width / 2);
            double y = target.Y + (target.Height / 2);
            foreach (ScreenshotWindowCandidate candidate in eligible)
            {
                if (Contains(candidate.Bounds, x, y))
                {
                    return candidate;
                }
            }

            if (requireWindowAtTarget)
            {
                return null;
            }
        }

        // The largest window is the document window. A tie breaks on the smaller window identity so
        // enumeration order can never change which frame an archive ends up carrying.
        return eligible
            .OrderByDescending(candidate => candidate.Bounds.Width * candidate.Bounds.Height)
            .ThenBy(candidate => candidate.WindowId)
            .First();
    }

    /// <summary>Half-open containment, matching the platform rectangle hit tests.</summary>
    private static bool Contains(BoundingBox bounds, double x, double y) =>
        x >= bounds.X
        && x < bounds.X + bounds.Width
        && y >= bounds.Y
        && y < bounds.Y + bounds.Height;
}
