namespace JazzCaptureCore;

/// <summary>
/// A window's resolved identity together with whether its AUMID could be read.
/// </summary>
/// <remarks>
/// A window with no AUMID resolves to its executable path, which is correct. A window whose AUMID
/// read failed resolves to its executable path too, but that path is only a guess: an application
/// excluded by AUMID alone would look like a non-excluded application. Exclusion checks therefore
/// need to tell the two cases apart, and fail closed on the second one.
/// </remarks>
/// <param name="Identity">The identity the host resolved, or null when none could be attributed.</param>
/// <param name="AumidUnreadable">True when the AUMID read failed, so "no AUMID" is not known.</param>
public readonly record struct ResolvedWindow(AppIdentity? Identity, bool AumidUnreadable);
