namespace JazzCaptureCore.Screen;

/// <summary>
/// Decides whether a window may be photographed as evidence for an event attributed to an owner.
/// </summary>
/// <remarks>
/// <para>
/// A window has two honest identities on Windows: the AUMID the Shell publishes for the window, and
/// the executable path of the process that owns it. A pointer event is attributed by the process
/// under the pointer, so its owner is usually the executable path; a keyboard or foreground event is
/// attributed by the window, so its owner is the AUMID when there is one. Comparing an owner of one
/// kind with a window identity of the other kind can never match. That was the bug that refused
/// almost every Chromium click: Edge and Chrome publish an AUMID on their main windows, so the
/// exe-path owner of the click never equalled it, while their AUMID-less file dialogs did.
/// </para>
/// <para>
/// So the window is accepted when either of its identities is exactly the owner, namespace and
/// value. A window of a genuinely different application has neither identity in common with the
/// owner and is still refused.
/// </para>
/// <para>
/// Accepting either identity must not let a denylisted application through the other one: a user
/// may exclude Edge by its AUMID while the click owner is its executable path. So the window is
/// refused when either of its identities is on the denylist, whatever the owner matched on.
/// </para>
/// </remarks>
public static class ScreenshotOwnership
{
    /// <summary>Whether the window belongs to the application the event names.</summary>
    /// <param name="owner">The application the event was attributed to.</param>
    /// <param name="windowIdentity">The window's identity as the window lookup resolves it (AUMID first).</param>
    /// <param name="processIdentity">The identity of the window's owning process (executable path).</param>
    /// <param name="denylist">The frozen capture policy's excluded applications.</param>
    public static bool IsOwnedBy(
        AppIdentity owner,
        AppIdentity? windowIdentity,
        AppIdentity? processIdentity,
        ApplicationDenylist denylist)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(denylist);
        return owner.IsResolved
            && !denylist.IsExcluded(windowIdentity)
            && !denylist.IsExcluded(processIdentity)
            && (Same(owner, windowIdentity) || Same(owner, processIdentity));
    }

    private static bool Same(AppIdentity owner, AppIdentity? candidate) =>
        candidate is not null
        && candidate.IsResolved
        && string.Equals(candidate.Namespace, owner.Namespace, StringComparison.Ordinal)
        && string.Equals(candidate.Value, owner.Value, StringComparison.OrdinalIgnoreCase);
}
