using JazzCaptureCore;
using JazzCapture.Interop;

namespace JazzCapture.Capture;

/// <summary>One application the user could choose to exclude, as the capture would attribute it.</summary>
/// <param name="Identity">The identity the archive would record for this application.</param>
/// <param name="DisplayName">What to call it in the picker.</param>
public sealed record RunningApplication(AppIdentity Identity, string DisplayName);

/// <summary>
/// Enumerates the applications that currently have a window on screen, so the settings window can
/// offer them for exclusion by name instead of asking the user to type an identifier.
/// </summary>
/// <remarks>
/// <para>
/// The whole point of the picker is that what the user excludes is exactly what the denylist
/// matches, so this deliberately resolves each window through <see cref="AppIdentityResolver"/> —
/// the same resolver, on the same window handle, that attributes a captured event. A free-text field
/// would let a user type <c>Signal</c>, see it sit in the list looking like a control, and never
/// exclude anything.
/// </para>
/// <para>
/// The filter is the ordinary "would this show in Alt+Tab" one: a visible, titled, non-tool top-level
/// window. Minimized windows are kept — an application the user has parked is still running and is
/// still exactly the kind of thing they want on the list. Windows owned by this process resolve to a
/// null identity and drop out, which is the first of the three own-window exclusion layers doing its
/// usual job.
/// </para>
/// </remarks>
public static class RunningApplications
{
    /// <summary>
    /// Lists the distinct applications with a visible top-level window, ordered by display name.
    /// </summary>
    /// <param name="identity">The attribution resolver the capture pipeline uses.</param>
    public static IReadOnlyList<RunningApplication> Enumerate(AppIdentityResolver identity)
    {
        ArgumentNullException.ThrowIfNull(identity);

        var byValue = new Dictionary<string, RunningApplication>(StringComparer.OrdinalIgnoreCase);

        NativeMethods.EnumWindows(
            (hwnd, _) =>
            {
                if (!IsPickable(hwnd))
                {
                    return true;
                }

                AppIdentity? resolved = identity.Resolve(hwnd);
                if (resolved is null || !resolved.IsResolved || byValue.ContainsKey(resolved.Value))
                {
                    return true;
                }

                byValue[resolved.Value] = new RunningApplication(resolved, DisplayName(identity, resolved, hwnd));
                return true;
            },
            IntPtr.Zero);

        return byValue.Values
            .OrderBy(application => application.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    private static bool IsPickable(IntPtr hwnd)
    {
        if (!NativeMethods.IsWindowVisible(hwnd)
            || NativeMethods.GetAncestor(hwnd, NativeMethods.GA_ROOT) != hwnd
            || NativeMethods.GetWindowTextLengthW(hwnd) <= 0)
        {
            return false;
        }

        long exStyle = NativeMethods.GetWindowLongPtrW(hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        return (exStyle & NativeMethods.WS_EX_TOOLWINDOW) == 0;
    }

    /// <summary>
    /// The friendliest true name available: the executable's product name, else the window title,
    /// else the identity itself. The identity is shown next to this in the picker either way, so a
    /// poor name costs recognition rather than correctness.
    /// </summary>
    private static string DisplayName(AppIdentityResolver identity, AppIdentity resolved, IntPtr hwnd)
    {
        if (!string.IsNullOrWhiteSpace(resolved.Name))
        {
            return resolved.Name!;
        }

        string? title = identity.WindowTitle(hwnd);
        return string.IsNullOrWhiteSpace(title) ? resolved.Value : title!;
    }
}
