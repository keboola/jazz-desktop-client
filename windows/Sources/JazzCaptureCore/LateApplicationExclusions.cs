namespace JazzCaptureCore;

/// <summary>
/// Applications the user exempted while a capture was already running (ANNEX-HOST section 2).
/// </summary>
/// <remarks>
/// <para>
/// A capture's denylist is frozen into its policy and its journal when it starts, and it never
/// changes under a running capture: the archive, its recovery policy and its screenshot evidence
/// all describe that one frozen list. A tray exemption therefore takes effect by ending the session
/// and starting a new one under the new list. Between the click and the end of the old session,
/// though, the old pipeline still holds work the user did in the application they just exempted —
/// a typed run still buffered, a click still waiting out its double-click window, samples still
/// queued. This set is how the old pipeline learns about the exemption without its policy moving.
/// </para>
/// <para>
/// "Immediately" means the moment <see cref="Add"/> publishes the entry, which the host does on the
/// exemption click, before it begins completing the old session. Anything the old engine admitted
/// before that moment is kept; anything of the exempted application it would admit afterwards is
/// turned into an explicit "application denylist" gap instead, and no fresh enrichment is acquired
/// for it.
/// </para>
/// <para>
/// Matching is <see cref="ApplicationDenylist"/>'s own rule, and <see cref="Effective"/> is what
/// <see cref="DenylistAttribution"/> reads, so an application exempted under its AUMID is also
/// recognized when a gesture resolves through its executable path. Entries only ever accumulate:
/// a removed exemption needs nothing here, because the old session continuing to exclude an
/// application is the safe direction.
/// </para>
/// <para>
/// Written from the UI thread, read from the capture worker. Each published list is immutable and
/// replaced by one reference write, so a reader sees either the set before an addition or the set
/// after it, never a mixture.
/// </para>
/// </remarks>
public sealed class LateApplicationExclusions
{
    private readonly ApplicationDenylist _frozen;
    private readonly object _gate = new();
    private volatile ApplicationDenylist _late = ApplicationDenylist.Empty;
    private volatile ApplicationDenylist _effective;

    /// <summary>Creates an empty set over a capture's frozen denylist.</summary>
    /// <param name="frozen">The denylist frozen into the running capture's policy.</param>
    public LateApplicationExclusions(ApplicationDenylist frozen)
    {
        _frozen = frozen ?? throw new ArgumentNullException(nameof(frozen));
        _effective = frozen;
    }

    /// <summary>Only the entries added after the policy was frozen.</summary>
    public ApplicationDenylist Late => _late;

    /// <summary>The frozen denylist together with every late entry.</summary>
    public ApplicationDenylist Effective => _effective;

    /// <summary>Whether nothing was exempted late, which keeps the common path free of extra lookups.</summary>
    public bool IsEmpty => _late.IsEmpty;

    /// <summary>Publishes entries the user exempted while this capture runs.</summary>
    /// <param name="entries">The newly exempted entries.</param>
    /// <returns>Whether anything not already excluded was added.</returns>
    public bool Add(IEnumerable<string> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);

        lock (_gate)
        {
            ApplicationDenylist effective = _effective;
            string[] added = ApplicationDenylist.Normalize(entries)
                .Where(entry => !effective.IsExcluded(entry))
                .ToArray();
            if (added.Length == 0)
            {
                return false;
            }

            var late = new ApplicationDenylist(_late.Entries.Concat(added));
            var next = new ApplicationDenylist(_frozen.Entries.Concat(late.Entries));

            // Late first: a reader that sees the new effective list must also find the entry late,
            // or an event attributed to the new alias would reach the engine as an ordinary record.
            _late = late;
            _effective = next;
            return true;
        }
    }

    /// <summary>
    /// Whether an event attributed to <paramref name="identity"/> belongs to an application exempted
    /// after the policy was frozen, and so must become a gap the engine would not write on its own.
    /// </summary>
    /// <param name="identity">The attributed owner; unresolved or absent never matches.</param>
    public bool IsLateExcluded(AppIdentity? identity) => _late.IsExcluded(identity);

    /// <summary>
    /// Whether an event's owner was exempted late under any of its identities, read at the moment of
    /// the call. This is the final check before an event is admitted.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The saved attribution alone is not enough. It was decided when the work began — a typed run
    /// when its first key arrived — under whichever identity that gesture resolved through, and the
    /// user may exempt the application by its other identity while an enrichment read is blocked.
    /// So the owner's process and window are attributed again over <paramref name="attribution"/>,
    /// whose denylist is the effective one, with the same alias rule every gesture uses: the
    /// process's own identity, the window's identity, and the window's process.
    /// </para>
    /// <para>
    /// Re-attribution can only widen a gap toward an application the user just exempted, and only
    /// in the session that was running at the click. With nothing exempted late it costs no lookup.
    /// </para>
    /// </remarks>
    /// <param name="owner">What the event was attributed to, and the process and window it came from.</param>
    /// <param name="attribution">The attribution over <see cref="Effective"/>.</param>
    public bool IsLateExcluded(EventOwner owner, DenylistAttribution attribution)
    {
        ArgumentNullException.ThrowIfNull(attribution);

        ApplicationDenylist late = _late;
        if (late.IsEmpty)
        {
            return false;
        }

        if (late.IsExcluded(owner.Attributed))
        {
            return true;
        }

        AppIdentity? again = owner.ProcessId is { } pid && pid != 0 && owner.Window != 0
            ? attribution.ForTarget(pid, owner.Window)
            : owner.Window != 0
                ? attribution.ForWindow(owner.Window)
                : null;
        return late.IsExcluded(again);
    }
}

/// <summary>
/// Who an event belongs to, as the capture pipeline established it: the identity it was attributed
/// to, and the process and top-level window that identity came from.
/// </summary>
/// <param name="Attributed">The identity the event carries.</param>
/// <param name="ProcessId">The owning process, when one was established.</param>
/// <param name="Window">The owning top-level window, or 0 when none was.</param>
public readonly record struct EventOwner(AppIdentity? Attributed, uint? ProcessId, nint Window);
