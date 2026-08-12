namespace JazzCaptureCore;

/// <summary>
/// The user-configured application denylist, and the single rule that decides whether a resolved
/// application is excluded from capture (ANNEX-HOST section 2).
/// </summary>
/// <remarks>
/// <para>
/// One type owns the rule because the rule is applied in two places for two different reasons: the
/// engine applies it to turn an excluded application's event into an explicit gap, and the
/// coordinator applies it earlier so an excluded application's pixels are never even rendered into
/// memory. Two hand-rolled comparisons would eventually disagree, and the direction they would
/// disagree in is that something the user asked never to be recorded gets recorded.
/// </para>
/// <para>
/// An entry matches when it occurs anywhere inside the resolved
/// <see cref="AppIdentity.Value"/>, compared case-insensitively. Substring rather than equality is
/// what makes a short, portable entry such as <c>1password</c> exclude
/// <c>c:/program files/1password/1password.exe</c> on one machine and a differently installed copy
/// on the next; an equality rule would silently match nothing at all, which is the worst possible
/// failure mode for a control whose entire job is to keep a password manager out of the archive.
/// The picker in the settings window writes whole identity values, and a whole value is trivially a
/// substring of itself, so both kinds of entry work under the same rule.
/// </para>
/// <para>
/// The rule reads <see cref="AppIdentity.Value"/> and never <see cref="AppIdentity.Name"/>. A
/// display name is neither stable nor unique — several unrelated executables ship as "Setup" — and a
/// denylist that quietly excludes more than the user chose is a recording with unexplained holes.
/// Over-matching within a single identity value is the safe direction; over-matching across
/// applications is not.
/// </para>
/// </remarks>
public sealed class ApplicationDenylist
{
    /// <summary>A denylist that excludes nothing.</summary>
    public static readonly ApplicationDenylist Empty = new(Array.Empty<string>());

    private readonly string[] _entries;

    /// <summary>Creates a denylist from raw entries, normalizing them first.</summary>
    /// <param name="entries">Entries as configured; blanks, duplicates and surrounding space are removed.</param>
    public ApplicationDenylist(IEnumerable<string> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        _entries = Normalize(entries);
    }

    /// <summary>The normalized entries, in the stable order they are persisted and displayed in.</summary>
    public IReadOnlyList<string> Entries => _entries;

    /// <summary>Whether this denylist excludes nothing.</summary>
    public bool IsEmpty => _entries.Length == 0;

    /// <summary>
    /// Normalizes raw entries into the canonical form that is stored, displayed and matched:
    /// trimmed, blanks dropped, de-duplicated case-insensitively, and ordered so the same set of
    /// entries always produces the same bytes on disk.
    /// </summary>
    /// <remarks>
    /// Casing is preserved rather than lowered. Matching ignores case anyway, and an AUMID such as
    /// <c>Microsoft.WindowsTerminal_8wekyb3d8bbwe!App</c> is far easier for a user to recognize in
    /// the settings list with its own capitalization intact. De-duplication is case-insensitive, so
    /// no two surviving entries differ only by case and the ordering below is therefore total.
    /// </remarks>
    public static string[] Normalize(IEnumerable<string> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var kept = new List<string>();
        foreach (string? entry in entries)
        {
            if (string.IsNullOrWhiteSpace(entry))
            {
                continue;
            }

            string trimmed = entry.Trim();
            if (seen.Add(trimmed))
            {
                kept.Add(trimmed);
            }
        }

        kept.Sort(static (left, right) => string.Compare(left, right, StringComparison.OrdinalIgnoreCase));
        return kept.ToArray();
    }

    /// <summary>Whether the application this event was attributed to must never be recorded.</summary>
    /// <param name="identity">The resolved owner; an unresolved or absent owner is not a denylist match.</param>
    public bool IsExcluded(AppIdentity? identity) =>
        identity is not null && identity.IsResolved && IsExcluded(identity.Value);

    /// <summary>Whether a resolved identity value matches any entry.</summary>
    /// <param name="identityValue">The value of an <see cref="AppIdentity"/>.</param>
    public bool IsExcluded(string? identityValue)
    {
        if (string.IsNullOrEmpty(identityValue))
        {
            return false;
        }

        foreach (string entry in _entries)
        {
            if (identityValue.Contains(entry, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
