namespace JazzCaptureCore;

/// <summary>
/// Chooses the <see cref="AppIdentity"/> an event is attributed to so that an application excluded
/// under either of its identities is excluded for every gesture (ANNEX-HOST section 2).
/// </summary>
/// <remarks>
/// <para>
/// Windows has two identities for one application: a window's AUMID and its process's executable
/// path. Gestures resolve through different ones — a click or a typed run through the process, a
/// keydown or an application switch through the window — while the settings picker stores whichever
/// identity the running application showed. Checked against one identity only, an application the
/// user excluded by AUMID kept its clicks and keystrokes recorded under its executable path, and the
/// reverse. That is the failure a user cannot see and the one a denylist exists to prevent.
/// </para>
/// <para>
/// The fix leaves the engine's single owner gate alone. When any identity of the same owner is
/// excluded the event is attributed to that excluded identity, and the gate turns it into the usual
/// "application denylist" gap. An event nobody excluded keeps exactly the attribution it had, so the
/// archive and OTLP contracts do not move.
/// </para>
/// <para>
/// Aliases only ever describe the owner the event is already attributed to: the window's own process,
/// or the window a UI Automation element lives in. An unrelated foreground window is never borrowed,
/// because excluding more than the user chose is a recording with unexplained holes.
/// </para>
/// <para>
/// The Win32 lookups arrive as delegates so the choice of which identities belong together is
/// testable without a desktop. Aliases are resolved only when the denylist is not empty and the
/// primary identity is not already excluded, so the common case costs no extra lookup.
/// </para>
/// </remarks>
public sealed class DenylistAttribution
{
    private readonly ApplicationDenylist _denylist;
    private readonly Func<nint, AppIdentity?> _resolveWindow;
    private readonly Func<nint, uint> _windowProcessId;
    private readonly Func<uint, AppIdentity?> _resolveProcess;
    private readonly Func<nint> _foregroundWindow;
    private readonly Func<nint> _focusedWindow;
    private readonly Func<nint, nint> _rootWindow;

    /// <summary>Creates the attribution over the host's resolvers.</summary>
    /// <param name="denylist">The frozen capture policy's denylist.</param>
    /// <param name="resolveWindow">A window's identity: its AUMID, else its process's executable path.</param>
    /// <param name="windowProcessId">The process owning a window, or 0 when unknown.</param>
    /// <param name="resolveProcess">A process's executable-path identity.</param>
    /// <param name="foregroundWindow">The current foreground window.</param>
    /// <param name="focusedWindow">The window holding keyboard focus in the foreground input queue, or 0.</param>
    /// <param name="rootWindow">A window's top-level ancestor.</param>
    public DenylistAttribution(
        ApplicationDenylist denylist,
        Func<nint, AppIdentity?> resolveWindow,
        Func<nint, uint> windowProcessId,
        Func<uint, AppIdentity?> resolveProcess,
        Func<nint> foregroundWindow,
        Func<nint> focusedWindow,
        Func<nint, nint> rootWindow)
    {
        _denylist = denylist ?? throw new ArgumentNullException(nameof(denylist));
        _resolveWindow = resolveWindow ?? throw new ArgumentNullException(nameof(resolveWindow));
        _windowProcessId = windowProcessId ?? throw new ArgumentNullException(nameof(windowProcessId));
        _resolveProcess = resolveProcess ?? throw new ArgumentNullException(nameof(resolveProcess));
        _foregroundWindow = foregroundWindow ?? throw new ArgumentNullException(nameof(foregroundWindow));
        _focusedWindow = focusedWindow ?? throw new ArgumentNullException(nameof(focusedWindow));
        _rootWindow = rootWindow ?? throw new ArgumentNullException(nameof(rootWindow));
    }

    /// <summary>
    /// The identity an event carries: the primary, unless the primary is not excluded and an alias of
    /// the same owner is, in which case the first excluded alias.
    /// </summary>
    /// <param name="primary">The identity the event is attributed to today.</param>
    /// <param name="aliases">Other identities of the same owner.</param>
    /// <param name="denylist">The denylist; unresolved identities never match it.</param>
    public static AppIdentity? Attribute(
        AppIdentity? primary,
        IReadOnlyList<AppIdentity?> aliases,
        ApplicationDenylist denylist)
    {
        ArgumentNullException.ThrowIfNull(aliases);
        ArgumentNullException.ThrowIfNull(denylist);

        if (denylist.IsExcluded(primary))
        {
            return primary;
        }

        foreach (AppIdentity? alias in aliases)
        {
            if (denylist.IsExcluded(alias))
            {
                return alias;
            }
        }

        return primary;
    }

    /// <summary>
    /// A window-based event (keydown, application switch, a click with no element): the window's
    /// identity, checked against its process's identity as well.
    /// </summary>
    public AppIdentity? ForWindow(nint window)
    {
        AppIdentity? primary = _resolveWindow(window);
        if (IsSettled(primary))
        {
            return primary;
        }

        // A window without an AUMID already resolved to its process's path; asking again adds nothing.
        AppIdentity? process = primary?.Namespace == AppIdentity.ExecutablePathNamespace
            ? null
            : _resolveProcess(_windowProcessId(window));
        return Attribute(primary, new[] { process }, _denylist);
    }

    /// <summary>
    /// The current foreground window, as <see cref="ForWindow"/>; the fallback for every gesture whose
    /// own process could not be resolved.
    /// </summary>
    public AppIdentity? ForForeground() => ForWindow(_foregroundWindow());

    /// <summary>
    /// A pointer gesture on a UI Automation element: the element's process, checked against the
    /// top-level window the element was found in.
    /// </summary>
    /// <remarks>
    /// The window is the root the hit test landed on, so excluding an application also excludes a
    /// control another process hosts inside its window. That is intended: the user excluded what
    /// they see on screen.
    /// </remarks>
    /// <param name="processId">The element's owning process.</param>
    /// <param name="rootWindow">The top-level window the element was hit-tested in.</param>
    public AppIdentity? ForTarget(uint processId, nint rootWindow)
    {
        AppIdentity? primary = _resolveProcess(processId);
        if (primary is null)
        {
            return ForForeground();
        }

        if (IsSettled(primary))
        {
            return primary;
        }

        AppIdentity? window = _resolveWindow(rootWindow);
        if (_denylist.IsExcluded(window))
        {
            return window;
        }

        uint windowProcess = _windowProcessId(rootWindow);
        AppIdentity? process = windowProcess == processId ? null : _resolveProcess(windowProcess);
        return Attribute(primary, new[] { window, process }, _denylist);
    }

    /// <summary>
    /// A typed run or a clipboard gesture: the focused element's process, checked against the
    /// foreground window when the focus provably lives in it.
    /// </summary>
    /// <remarks>
    /// UI Automation's focus carries no window, so the foreground window is the only candidate. It
    /// counts as the same owner when its process is the focused element's process, or when the
    /// window holding keyboard focus belongs to the focused process and sits inside the foreground
    /// window — a control another process hosts in the excluded application's window, which the
    /// pointer path already treats as part of that application. Otherwise nothing ties the two
    /// together and no alias is added.
    /// </remarks>
    /// <param name="focusProcessId">The focused element's process, or null when nothing has focus.</param>
    public AppIdentity? ForFocus(uint? focusProcessId)
    {
        if (focusProcessId is not { } pid)
        {
            return ForForeground();
        }

        AppIdentity? primary = _resolveProcess(pid);
        if (primary is null)
        {
            return ForForeground();
        }

        if (IsSettled(primary))
        {
            return primary;
        }

        nint foreground = _foregroundWindow();
        uint foregroundProcess = _windowProcessId(foreground);
        if (foregroundProcess == pid)
        {
            return Attribute(primary, new[] { _resolveWindow(foreground) }, _denylist);
        }

        nint focused = _focusedWindow();
        bool hostedInForeground = focused != 0
            && foreground != 0
            && _windowProcessId(focused) == pid
            && _rootWindow(focused) == foreground;
        return hostedInForeground
            ? Attribute(primary, new[] { _resolveWindow(foreground), _resolveProcess(foregroundProcess) }, _denylist)
            : primary;
    }

    /// <summary>Whether no alias could change the outcome, so none needs resolving.</summary>
    private bool IsSettled(AppIdentity? primary) => _denylist.IsEmpty || _denylist.IsExcluded(primary);
}
