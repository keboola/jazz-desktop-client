import Foundation

/// What the app should do at launch about the Keboola connection, decided purely from what
/// we know before touching anything: whether the user opted in and whether a token was
/// stored on a previous run. There are no local services to start anymore — the spool
/// sender drains unconditionally — so the only launch-time action left is re-verifying the
/// stored token (refreshing the detected stack/project/identity and surfacing expiry).
///
/// Kept as a pure function (no Keychain, no network) so it is fully unit-tested in CI
/// without any TCC permissions. ``AppDelegate`` reads the world, calls
/// ``autoStartPlan(enabled:hasStoredToken:)``, and executes the returned plan.
public enum AutoStartPlan: Equatable, Sendable {
    /// The user opted out of launch-time reconnect (Settings) — do nothing.
    case disabled
    /// No Keboola token was ever stored — the user has not connected yet, so there is
    /// nothing to resume. Leave it to the manual Connect flow.
    case noToken
    /// Re-verify the stored token in the background (soft-fail: an expired token surfaces
    /// in the menu, never as a blocking dialog).
    case reconnect
}

/// Decide the launch-time plan. Precedence: an explicit opt-out wins, then "nothing to
/// resume" (no token), else reconnect.
public func autoStartPlan(enabled: Bool, hasStoredToken: Bool) -> AutoStartPlan {
    guard enabled else { return .disabled }
    guard hasStoredToken else { return .noToken }
    return .reconnect
}

/// Whether to auto-start capture at launch (and right after a successful connect) for the
/// continuous-capture model: only when the user has opted in (``continuousCapture``), a token
/// is stored so events can actually ship, AND Accessibility is granted (capture's hard
/// precondition — without it ``CaptureController/start()`` no-ops with a prompt). Pure so it's
/// unit-tested without TCC; ``AppDelegate`` supplies the live permission state.
public func shouldAutoStartCapture(
    continuousCapture: Bool, hasStoredToken: Bool, accessibilityGranted: Bool
) -> Bool {
    continuousCapture && hasStoredToken && accessibilityGranted
}
