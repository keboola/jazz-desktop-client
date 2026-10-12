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
}
