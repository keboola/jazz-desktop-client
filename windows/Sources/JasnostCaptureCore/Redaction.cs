using System.Text.RegularExpressions;

namespace JasnostCaptureCore;

/// <summary>
/// The two typed-text masking rules and the shared free-text sanitizer of ANNEX-HOST section 2.
/// </summary>
/// <remarks>
/// <para>
/// Redaction happens once, at capture time, before the value reaches the journal: the archive is the
/// evidence, so an unmasked secret that is written even briefly is already a leak. The rules are
/// deliberately conservative and structural rather than clever — an e-mail address and a long digit
/// run are the two shapes a keystroke stream leaks most often — and everything else survives,
/// because the high-fidelity capture mode's whole purpose is to retain business values.
/// </para>
/// <para>
/// <see cref="Sanitize"/> is the second, unconditional stage: it also bounds accessible names,
/// element text, selections, page titles and clipboard payloads, so no single field can inflate a
/// record beyond a predictable size.
/// </para>
/// </remarks>
public static class Redaction
{
    /// <summary>Longest free-text value any field keeps before it is truncated.</summary>
    public const int DefaultMaxLength = 200;

    /// <summary>Replacement written in place of a recognized e-mail address.</summary>
    public const string EmailReplacement = "•••@•••";

    /// <summary>Character a masked digit is replaced with, one for one.</summary>
    public const char MaskCharacter = '•';

    /// <summary>Shortest ASCII digit run that is masked; shorter numbers survive.</summary>
    public const int MinimumMaskedDigitRun = 7;

    /// <summary>Marker appended to a value that was cut at the length bound.</summary>
    public const string TruncationSuffix = "…";

    private static readonly Regex EmailPattern = new(
        @"[\w.+-]+@[\w.-]+\.\w+",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    // Explicitly ASCII: \d would also mask Devanagari or fullwidth digits, which are ordinary
    // business content rather than the account and card numbers this rule exists for.
    private static readonly Regex DigitRunPattern = new(
        "[0-9]{" + MinimumMaskedDigitRun + ",}",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// <summary>
    /// Masks a committed typing run and reports whether anything was actually replaced.
    /// </summary>
    /// <param name="raw">The reconciled typed text.</param>
    /// <param name="maxLength">Length bound applied after masking.</param>
    /// <returns>
    /// The value to emit — <see langword="null"/> when nothing is left after trimming, in which case
    /// no event is emitted at all — and the flag that becomes <c>inputMasked</c>. The flag is true
    /// only when masking changed the string: truncation and trimming are not masking.
    /// </returns>
    public static (string? Value, bool WasMasked) RedactTyped(string raw, int maxLength = DefaultMaxLength)
    {
        ArgumentNullException.ThrowIfNull(raw);

        string masked = EmailPattern.Replace(raw, EmailReplacement);
        masked = DigitRunPattern.Replace(masked, static match => new string(MaskCharacter, match.Length));

        return (Sanitize(masked, maxLength), !string.Equals(masked, raw, StringComparison.Ordinal));
    }

    /// <summary>
    /// Trims, drops empties, and bounds the length of one free-text field.
    /// </summary>
    /// <param name="raw">The observed text; may be <see langword="null"/>.</param>
    /// <param name="maxLength">Maximum retained length, in UTF-16 code units.</param>
    /// <returns>The value to emit, or <see langword="null"/> when the key must be omitted.</returns>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="maxLength"/> is not positive.</exception>
    public static string? Sanitize(string? raw, int maxLength = DefaultMaxLength)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxLength);

        if (raw is null)
        {
            return null;
        }

        string trimmed = raw.Trim();
        if (trimmed.Length == 0)
        {
            return null;
        }

        if (trimmed.Length <= maxLength)
        {
            return trimmed;
        }

        // Cutting between the halves of a surrogate pair would leave a lone surrogate, which the
        // canonical JSON writer rejects; dropping the orphaned high surrogate is the only safe cut.
        int cut = maxLength;
        if (char.IsHighSurrogate(trimmed[cut - 1]))
        {
            cut--;
        }

        return cut == 0 ? null : trimmed[..cut] + TruncationSuffix;
    }
}
