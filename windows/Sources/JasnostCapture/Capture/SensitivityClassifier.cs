namespace JasnostCapture.Capture;

/// <summary>
/// The label-based half of the secure-field test of ANNEX-HOST section 2. On Windows the UI
/// Automation <c>IsPassword</c> flag is the only OS backstop, so a field whose accessible name hints
/// at a credential is also treated as sensitive; when in doubt the pipeline drops content rather than
/// keep it.
/// </summary>
public static class SensitivityClassifier
{
    private static readonly string[] Hints =
    {
        "password",
        "passcode",
        "secret",
        "token",
        "api key",
        "apikey",
        "card number",
        "cvv",
        "ssn",
        "pin",
        "credential",
    };

    /// <summary>Whether a UI Automation password flag or an accessible-name hint marks the field sensitive.</summary>
    public static bool IsSensitive(bool isPassword, string? accessibleName)
    {
        if (isPassword)
        {
            return true;
        }

        if (string.IsNullOrWhiteSpace(accessibleName))
        {
            return false;
        }

        string lowered = accessibleName.ToLowerInvariant();
        foreach (string hint in Hints)
        {
            if (lowered.Contains(hint, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }
}
