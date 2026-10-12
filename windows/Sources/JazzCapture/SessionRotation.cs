using System.IO;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>What one attempt to end the running session and start the next one produced.</summary>
internal enum SessionRotationResult
{
    /// <summary>Nothing was capturing, so there was no session to end.</summary>
    NotCapturing,

    /// <summary>The old session committed and exactly one new session started.</summary>
    Restarted,

    /// <summary>
    /// The old session did not commit: its journal is preserved, every producer is stopped, and no
    /// new session was started. Recording never resumes under the old session's policy.
    /// </summary>
    Suspended,

    /// <summary>The old session committed, but the new one could not start.</summary>
    RestartFailed,
}

/// <summary>
/// The one complete-then-start path shared by "Mark session end" and an exemption change.
/// </summary>
/// <remarks>
/// <para>
/// The steps are injected so the decision is testable without hooks, a journal or a microphone.
/// Completion is the host's ordinary local completion path: it stops admission, drains, and commits.
/// A start is attempted only after a commit, and only once, because a second session started over an
/// uncommitted one would leave two journals claiming the same stretch of the user's work.
/// </para>
/// <para>
/// A completion that does not commit is not retried here. The caller decides whether to offer a
/// retry; this method only guarantees that nothing is still recording when it returns
/// <see cref="SessionRotationResult.Suspended"/>. Admission is already closed by the completion
/// attempt, so the remaining producer is the microphone, which <paramref name="stopRemainingProducers"/>
/// seals.
/// </para>
/// </remarks>
internal static class SessionRotation
{
    internal static SessionRotationResult Rotate(
        Func<CaptureCompletionOutcome> complete,
        Func<bool> start,
        Action stopRemainingProducers)
    {
        ArgumentNullException.ThrowIfNull(complete);
        ArgumentNullException.ThrowIfNull(start);
        ArgumentNullException.ThrowIfNull(stopRemainingProducers);

        switch (complete())
        {
            case CaptureCompletionOutcome.NoActiveCapture:
                return SessionRotationResult.NotCapturing;

            case CaptureCompletionOutcome.PreservedForRecovery:
                stopRemainingProducers();
                return SessionRotationResult.Suspended;

            default:
                return start() ? SessionRotationResult.Restarted : SessionRotationResult.RestartFailed;
        }
    }
}

/// <summary>How an exemption edit ended, for the tray to report.</summary>
internal enum ExemptionChangeResult
{
    /// <summary>The edit normalized to the list already in force; nothing was saved or rotated.</summary>
    Unchanged,

    /// <summary>A rotation is pending or running; the edit was refused without touching anything.</summary>
    Busy,

    /// <summary>The settings file could not be written; the previous list stays in force.</summary>
    SaveFailed,

    /// <summary>Saved while nothing was capturing; the next capture starts under it.</summary>
    SavedWhileIdle,

    /// <summary>Saved, the old session committed, and a new session runs under the new list.</summary>
    Applied,

    /// <summary>Saved, but the old session did not commit; capture is suspended.</summary>
    Suspended,

    /// <summary>Saved and the old session committed, but no new session could start.</summary>
    RestartFailed,
}

/// <summary>Whether capture is held back by an exemption change that has not finished applying.</summary>
internal enum ExemptionSuspension
{
    /// <summary>Nothing is pending.</summary>
    None,

    /// <summary>The old session's completion timed out; retrying it may still commit.</summary>
    Retryable,

    /// <summary>
    /// The old session's pipeline faulted. A fault never authorizes a commit, so retrying in this
    /// process cannot help; the journal is recovered when Jazz next starts.
    /// </summary>
    Faulted,
}

/// <summary>
/// Applies a tray exemption edit: saves it, adopts it, and makes it take effect in the running
/// capture by rotating the session.
/// </summary>
/// <remarks>
/// <para>
/// <b>Transactional.</b> The candidate list is saved before it is adopted. When the save fails the
/// in-memory list is left exactly as it was and nothing rotates: a list that exists only in memory
/// would be silently lost on the next launch, and the tray would claim an exemption that a restart
/// quietly undoes.
/// </para>
/// <para>
/// <b>Immediate.</b> Before the old session is completed, its pipeline is told about every newly
/// added entry (<see cref="LateApplicationExclusions"/>). That is the moment the exemption takes
/// effect. Work of the exempted application still queued in the old pipeline becomes an explicit
/// gap instead of a record, and the new session starts with the entry in its frozen policy. A
/// removed entry needs no such step: the old session continuing to exclude it is the safe direction.
/// </para>
/// <para>
/// <b>One rotation per effective change.</b> An edit that normalizes to the list already in force
/// does nothing. While a rotation runs or a suspended one awaits its retry, further edits are
/// refused, and the tray disables the submenu so they cannot be offered. There is no debounce: each
/// click the user makes is applied, in order, or visibly refused.
/// </para>
/// <para>
/// <b>Suspended, not paused.</b> When the old session does not commit, capture stays suspended until
/// a retry commits it, and that retry starts the new session exactly once. The state is the host's,
/// not the user's: it is never presented as "Paused by you" and never arms the pause reminder.
/// </para>
/// </remarks>
internal sealed class ExemptionChange
{
    /// <summary>Tray notice after a successful rotation.</summary>
    internal const string AppliedNotice = "Exempt-app change applied. A new session has started.";

    /// <summary>Tray status while the previous session awaits a retry or recovery.</summary>
    internal const string SuspendedNotice =
        "Exemption saved. Capture is suspended while the previous session is recovered.";

    /// <summary>Tray notice when the old session committed but the new one did not start.</summary>
    internal const string RestartFailedNotice = "Exemption saved. Capture could not restart.";

    private readonly Func<IReadOnlyList<string>> _current;
    private readonly Action<IReadOnlyList<string>> _save;
    private readonly Action<IReadOnlyList<string>> _adopt;
    private readonly Func<bool> _isRecording;
    private readonly Func<bool> _ownsCapture;
    private readonly Action<IReadOnlyList<string>> _excludeLate;
    private readonly Func<SessionRotationResult> _rotate;
    private readonly Func<bool> _completionFaulted;

    private bool _rotating;

    /// <param name="current">The exemption list in force.</param>
    /// <param name="save">
    /// Persists a candidate list. Throws <see cref="IOException"/> or
    /// <see cref="UnauthorizedAccessException"/> when the file cannot be written.
    /// </param>
    /// <param name="adopt">Makes a saved list the one in force.</param>
    /// <param name="isRecording">
    /// Whether a capture is recording right now. A capture whose completion is already pending —
    /// the user paused it and the drain timed out — is not: an edit then only saves, and never
    /// restarts what the user stopped.
    /// </param>
    /// <param name="ownsCapture">
    /// Whether the host still owns the capture's engine, recording or not. After a completion that
    /// did not commit, this tells a preserved capture (retryable) from one the completion already
    /// tore down, whose journal waits for startup recovery.
    /// </param>
    /// <param name="excludeLate">Tells a capture still holding unadmitted work about newly added entries.</param>
    /// <param name="rotate">Ends the running session and starts the next one.</param>
    /// <param name="completionFaulted">Whether the last failed completion was a pipeline fault.</param>
    internal ExemptionChange(
        Func<IReadOnlyList<string>> current,
        Action<IReadOnlyList<string>> save,
        Action<IReadOnlyList<string>> adopt,
        Func<bool> isRecording,
        Func<bool> ownsCapture,
        Action<IReadOnlyList<string>> excludeLate,
        Func<SessionRotationResult> rotate,
        Func<bool> completionFaulted)
    {
        _current = current ?? throw new ArgumentNullException(nameof(current));
        _save = save ?? throw new ArgumentNullException(nameof(save));
        _adopt = adopt ?? throw new ArgumentNullException(nameof(adopt));
        _isRecording = isRecording ?? throw new ArgumentNullException(nameof(isRecording));
        _ownsCapture = ownsCapture ?? throw new ArgumentNullException(nameof(ownsCapture));
        _excludeLate = excludeLate ?? throw new ArgumentNullException(nameof(excludeLate));
        _rotate = rotate ?? throw new ArgumentNullException(nameof(rotate));
        _completionFaulted = completionFaulted ?? throw new ArgumentNullException(nameof(completionFaulted));
    }

    /// <summary>Whether capture is held back waiting for the previous session to commit.</summary>
    internal ExemptionSuspension Suspension { get; private set; }

    /// <summary>Why the last save failed, for the tray's error line.</summary>
    internal string? SaveError { get; private set; }

    /// <summary>
    /// Whether the exemption submenu may offer edits. Never while a rotation is running or awaiting
    /// its retry, and never while the settings window is open: that window edits the same list from
    /// a snapshot taken when it opened, and saving it would overwrite a newer tray exemption.
    /// </summary>
    internal bool CanEdit(bool settingsWindowOpen) =>
        !_rotating && Suspension == ExemptionSuspension.None && !settingsWindowOpen;

    /// <summary>Saves and applies one candidate list.</summary>
    internal ExemptionChangeResult Apply(IEnumerable<string> candidate)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        if (_rotating || Suspension != ExemptionSuspension.None)
        {
            return ExemptionChangeResult.Busy;
        }

        IReadOnlyList<string> previous = ApplicationDenylist.DistinctCovering(_current());
        string[] next = ApplicationDenylist.DistinctCovering(candidate);
        if (previous.SequenceEqual(next, StringComparer.OrdinalIgnoreCase))
        {
            return ExemptionChangeResult.Unchanged;
        }

        try
        {
            _save(next);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SaveError = ex.Message;
            return ExemptionChangeResult.SaveFailed;
        }

        SaveError = null;
        _adopt(next);

        // Told before anything else happens, and whether or not a rotation follows: a capture whose
        // safe stop is still pending holds queued work too, and it must not admit the exempted
        // application's share of it either.
        var before = new ApplicationDenylist(previous);
        string[] added = next.Where(entry => !before.IsExcluded(entry)).ToArray();
        if (added.Length > 0)
        {
            _excludeLate(added);
        }

        return _isRecording() ? Rotate() : ExemptionChangeResult.SavedWhileIdle;
    }

    /// <summary>
    /// Retries the suspended completion. Starts the new session exactly once, after the old one
    /// commits; does nothing when nothing retryable is pending.
    /// </summary>
    internal ExemptionChangeResult Retry() =>
        _rotating || Suspension != ExemptionSuspension.Retryable
            ? ExemptionChangeResult.Busy
            : Rotate();

    /// <summary>
    /// Forgets a pending suspension because another path — installer maintenance — has committed the
    /// old session itself. No new session starts: that path is shutting capture down on purpose.
    /// </summary>
    internal void CompletedElsewhere() => Suspension = ExemptionSuspension.None;

    private ExemptionChangeResult Rotate()
    {
        _rotating = true;
        SessionRotationResult result;
        try
        {
            result = _rotate();
        }
        finally
        {
            _rotating = false;
        }

        switch (result)
        {
            case SessionRotationResult.Restarted:
                Suspension = ExemptionSuspension.None;
                return ExemptionChangeResult.Applied;

            case SessionRotationResult.Suspended when _ownsCapture():
                Suspension = _completionFaulted() ? ExemptionSuspension.Faulted : ExemptionSuspension.Retryable;
                return ExemptionChangeResult.Suspended;

            case SessionRotationResult.NotCapturing when Suspension == ExemptionSuspension.None:
                // The capture ended between the save and the rotation; the next one starts under
                // the saved list, which is all an idle edit promises.
                return ExemptionChangeResult.SavedWhileIdle;

            default:
                // Committed but not restarted, or a completion that tore the capture down instead of
                // preserving it (its journal waits for startup recovery). Either way nothing old is
                // running and nothing is left to retry; Resume starts a session under the new list.
                Suspension = ExemptionSuspension.None;
                return ExemptionChangeResult.RestartFailed;
        }
    }
}
