using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// A tray exemption used to be saved and then ignored by the running capture: on a real notebook,
/// Windows Terminal was exempted and its typed commands and screenshots kept being recorded until the
/// user marked a session end. These tests pin the orchestration that replaced that: save first,
/// adopt only what was saved, tell the old pipeline about the new entry, and rotate the session
/// exactly once — or suspend visibly and retry exactly once.
/// </summary>
public sealed class ExemptionChangeTests
{
    private const string Terminal = "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App";

    /// <summary>A fake host: every side effect the orchestration may cause, counted.</summary>
    private sealed class Host
    {
        public List<string> Current { get; set; } = new() { "1password" };

        public bool Capturing { get; set; } = true;

        /// <summary>A completion is already pending: the capture owns an engine but is not recording.</summary>
        public bool Stopping { get; set; }

        public Exception? SaveFailure { get; set; }

        public Queue<CaptureCompletionOutcome> Completions { get; } = new();

        public bool StartSucceeds { get; set; } = true;

        public bool Faulted { get; set; }

        public List<IReadOnlyList<string>> Saved { get; } = new();

        public List<IReadOnlyList<string>> LateExclusions { get; } = new();

        public int CompleteCalls { get; private set; }

        public int StartCalls { get; private set; }

        public int ProducerStops { get; private set; }

        public Action? DuringComplete { get; set; }

        public ExemptionChange Change { get; }

        public Host()
        {
            Change = new ExemptionChange(
                () => Current,
                list =>
                {
                    if (SaveFailure is not null)
                    {
                        throw SaveFailure;
                    }

                    Saved.Add(list);
                },
                list => Current = list.ToList(),
                () => Capturing && !Stopping,
                () => Capturing,
                list => LateExclusions.Add(list),
                () => SessionRotation.Rotate(Complete, Start, () => ProducerStops++),
                () => Faulted);
        }

        private CaptureCompletionOutcome Complete()
        {
            CompleteCalls++;
            DuringComplete?.Invoke();
            CaptureCompletionOutcome outcome = Completions.Count > 0
                ? Completions.Dequeue()
                : CaptureCompletionOutcome.Committed;
            if (outcome == CaptureCompletionOutcome.Committed)
            {
                Capturing = false;
                Stopping = false;
            }
            else if (outcome == CaptureCompletionOutcome.PreservedForRecovery)
            {
                Stopping = true;
            }

            return outcome;
        }

        private bool Start()
        {
            StartCalls++;
            Capturing = StartSucceeds;
            return StartSucceeds;
        }
    }

    [Fact]
    public void ASaveFailureKeepsThePreviousListAndNeverRotates()
    {
        var host = new Host { SaveFailure = new IOException("disk full") };

        ExemptionChangeResult result = host.Change.Apply(host.Current.Append(Terminal));

        Assert.Equal(ExemptionChangeResult.SaveFailed, result);
        Assert.Equal("disk full", host.Change.SaveError);
        Assert.Equal(new[] { "1password" }, host.Current);
        Assert.Empty(host.LateExclusions);
        Assert.Equal(0, host.CompleteCalls);
        Assert.Equal(0, host.StartCalls);
        Assert.True(host.Change.CanEdit(settingsWindowOpen: false));
    }

    [Fact]
    public void AnAccessDeniedSaveIsTheSameRollback()
    {
        var host = new Host { SaveFailure = new UnauthorizedAccessException("denied") };

        Assert.Equal(ExemptionChangeResult.SaveFailed, host.Change.Apply(host.Current.Append(Terminal)));
        Assert.Equal(new[] { "1password" }, host.Current);
        Assert.Equal(0, host.CompleteCalls);
    }

    [Fact]
    public void AnIdleEditIsSavedAndAdoptedWithoutARotation()
    {
        var host = new Host { Capturing = false };

        ExemptionChangeResult result = host.Change.Apply(host.Current.Append(Terminal));

        Assert.Equal(ExemptionChangeResult.SavedWhileIdle, result);
        Assert.Contains(Terminal, host.Current);
        Assert.Single(host.Saved);
        Assert.Equal(0, host.CompleteCalls);
        Assert.Equal(0, host.StartCalls);
    }

    /// <summary>
    /// The user paused, the drain timed out, and the tray shows "Retry safe stop". An exemption edit
    /// now must still reach the stalled pipeline's queued work, but it must not restart a capture the
    /// user chose to stop.
    /// </summary>
    [Fact]
    public void AnEditWhileASafeStopIsPendingExcludesLateButNeverRestarts()
    {
        var host = new Host { Stopping = true };

        ExemptionChangeResult result = host.Change.Apply(host.Current.Append(Terminal));

        Assert.Equal(ExemptionChangeResult.SavedWhileIdle, result);
        Assert.Equal(new[] { Terminal }, Assert.Single(host.LateExclusions));
        Assert.Equal(0, host.CompleteCalls);
        Assert.Equal(0, host.StartCalls);
        Assert.Equal(ExemptionSuspension.None, host.Change.Suspension);
    }

    [Fact]
    public void AnAddedExemptionReachesTheOldSessionAndRestartsExactlyOnce()
    {
        var host = new Host();
        IReadOnlyList<string>? lateAtCompletion = null;
        bool editableDuringRotation = true;
        ExemptionChangeResult? reentrant = null;
        host.DuringComplete = () =>
        {
            lateAtCompletion = host.LateExclusions.SingleOrDefault();
            editableDuringRotation = host.Change.CanEdit(settingsWindowOpen: false);
            reentrant = host.Change.Apply(new[] { "another" });
        };

        ExemptionChangeResult result = host.Change.Apply(host.Current.Append(Terminal));

        Assert.Equal(ExemptionChangeResult.Applied, result);

        // Saved before adopted, adopted before the rotation, and the old pipeline told before its
        // completion began: that ordering is what "immediately" means.
        Assert.Equal(new[] { "1password", Terminal }, Assert.Single(host.Saved));
        Assert.Equal(new[] { Terminal }, lateAtCompletion);
        Assert.Equal(1, host.CompleteCalls);
        Assert.Equal(1, host.StartCalls);
        Assert.Equal(0, host.ProducerStops);

        // A second edit cannot sneak in while the first is still rotating.
        Assert.False(editableDuringRotation);
        Assert.Equal(ExemptionChangeResult.Busy, reentrant);
        Assert.Single(host.Saved);

        Assert.Equal(ExemptionSuspension.None, host.Change.Suspension);
        Assert.True(host.Change.CanEdit(settingsWindowOpen: false));
    }

    [Fact]
    public void ARemovedExemptionRestartsExactlyOnceAndExcludesNothingLate()
    {
        var host = new Host { Current = new List<string> { "1password", Terminal } };

        ExemptionChangeResult result = host.Change.Apply(new[] { "1password" });

        Assert.Equal(ExemptionChangeResult.Applied, result);
        Assert.Equal(new[] { "1password" }, host.Current);
        Assert.Empty(host.LateExclusions);
        Assert.Equal(1, host.CompleteCalls);
        Assert.Equal(1, host.StartCalls);
    }

    [Fact]
    public void AnEditThatNormalizesToTheCurrentListDoesNothing()
    {
        var host = new Host { Current = new List<string> { "1password", Terminal } };

        // Different case, a duplicate, blank entries, and a longer entry the short one already covers.
        ExemptionChangeResult result = host.Change.Apply(new[]
        {
            Terminal.ToUpperInvariant(), " 1Password ", "", "c:/apps/1password/1password.exe", Terminal,
        });

        Assert.Equal(ExemptionChangeResult.Unchanged, result);
        Assert.Empty(host.Saved);
        Assert.Empty(host.LateExclusions);
        Assert.Equal(0, host.CompleteCalls);
        Assert.Equal(0, host.StartCalls);
    }

    [Fact]
    public void ATimedOutDrainSuspendsThenARetryRestartsExactlyOnce()
    {
        var host = new Host();
        host.Completions.Enqueue(CaptureCompletionOutcome.PreservedForRecovery);
        host.Completions.Enqueue(CaptureCompletionOutcome.PreservedForRecovery);
        host.Completions.Enqueue(CaptureCompletionOutcome.Committed);

        Assert.Equal(ExemptionChangeResult.Suspended, host.Change.Apply(host.Current.Append(Terminal)));
        Assert.Equal(ExemptionSuspension.Retryable, host.Change.Suspension);
        Assert.Equal(0, host.StartCalls);

        // Nothing is recording behind a suspended capture, the microphone included.
        Assert.Equal(1, host.ProducerStops);

        // The exemption is saved and in force for the next session, but nothing else may be edited.
        Assert.Contains(Terminal, host.Current);
        Assert.False(host.Change.CanEdit(settingsWindowOpen: false));
        Assert.Equal(ExemptionChangeResult.Busy, host.Change.Apply(new[] { "another" }));
        Assert.Single(host.Saved);

        // A retry that times out again stays suspended and still starts nothing.
        Assert.Equal(ExemptionChangeResult.Suspended, host.Change.Retry());
        Assert.Equal(0, host.StartCalls);

        Assert.Equal(ExemptionChangeResult.Applied, host.Change.Retry());
        Assert.Equal(3, host.CompleteCalls);
        Assert.Equal(1, host.StartCalls);
        Assert.Equal(ExemptionSuspension.None, host.Change.Suspension);
        Assert.True(host.Change.CanEdit(settingsWindowOpen: false));

        // Nothing left to retry: a stray click cannot start a second session.
        Assert.Equal(ExemptionChangeResult.Busy, host.Change.Retry());
        Assert.Equal(1, host.StartCalls);
    }

    [Fact]
    public void APermanentFaultIsNeverRetriedAndNeverRestarts()
    {
        var host = new Host { Faulted = true };
        host.Completions.Enqueue(CaptureCompletionOutcome.PreservedForRecovery);

        Assert.Equal(ExemptionChangeResult.Suspended, host.Change.Apply(host.Current.Append(Terminal)));
        Assert.Equal(ExemptionSuspension.Faulted, host.Change.Suspension);
        Assert.Equal(1, host.ProducerStops);

        Assert.Equal(ExemptionChangeResult.Busy, host.Change.Retry());
        Assert.Equal(1, host.CompleteCalls);
        Assert.Equal(0, host.StartCalls);
        Assert.False(host.Change.CanEdit(settingsWindowOpen: false));
    }

    [Fact]
    public void ACommittedSessionThatCannotRestartReportsItAndFreesTheMenu()
    {
        var host = new Host { StartSucceeds = false };

        Assert.Equal(ExemptionChangeResult.RestartFailed, host.Change.Apply(host.Current.Append(Terminal)));
        Assert.Equal(1, host.CompleteCalls);
        Assert.Equal(1, host.StartCalls);
        Assert.Equal(0, host.ProducerStops);
        Assert.Equal(ExemptionSuspension.None, host.Change.Suspension);
        Assert.True(host.Change.CanEdit(settingsWindowOpen: false));

        // Nothing is pending, so there is nothing to retry; Resume is the way back.
        Assert.Equal(ExemptionChangeResult.Busy, host.Change.Retry());
        Assert.Equal(1, host.StartCalls);
    }

    [Fact]
    public void ACompletionThatToreTheCaptureDownLeavesNothingToRetry()
    {
        // The completion threw: the host released the pipeline and left the journal for startup
        // recovery. Nothing old is running, so this is a failed restart, not a suspension.
        var host = new Host();
        host.Completions.Enqueue(CaptureCompletionOutcome.PreservedForRecovery);
        host.DuringComplete = () => host.Capturing = false;

        Assert.Equal(ExemptionChangeResult.RestartFailed, host.Change.Apply(host.Current.Append(Terminal)));
        Assert.Equal(ExemptionSuspension.None, host.Change.Suspension);
        Assert.Equal(0, host.StartCalls);
    }

    [Fact]
    public void TheSettingsWindowDisablesTheSubmenu()
    {
        var host = new Host();

        Assert.True(host.Change.CanEdit(settingsWindowOpen: false));
        Assert.False(host.Change.CanEdit(settingsWindowOpen: true));
    }

    [Fact]
    public void MaintenanceCommittingTheSuspendedSessionClearsItWithoutStarting()
    {
        var host = new Host();
        host.Completions.Enqueue(CaptureCompletionOutcome.PreservedForRecovery);
        host.Change.Apply(host.Current.Append(Terminal));

        host.Change.CompletedElsewhere();

        Assert.Equal(ExemptionSuspension.None, host.Change.Suspension);
        Assert.Equal(ExemptionChangeResult.Busy, host.Change.Retry());
        Assert.Equal(0, host.StartCalls);
    }

    [Fact]
    public void SessionRotationStartsOnlyAfterACommit()
    {
        int starts = 0;
        int stops = 0;

        Assert.Equal(
            SessionRotationResult.NotCapturing,
            SessionRotation.Rotate(() => CaptureCompletionOutcome.NoActiveCapture, () => ++starts > 0, () => stops++));
        Assert.Equal(
            SessionRotationResult.Suspended,
            SessionRotation.Rotate(() => CaptureCompletionOutcome.PreservedForRecovery, () => ++starts > 0, () => stops++));
        Assert.Equal(0, starts);
        Assert.Equal(1, stops);

        Assert.Equal(
            SessionRotationResult.Restarted,
            SessionRotation.Rotate(() => CaptureCompletionOutcome.Committed, () => ++starts > 0, () => stops++));
        Assert.Equal(
            SessionRotationResult.RestartFailed,
            SessionRotation.Rotate(() => CaptureCompletionOutcome.Committed, () => { starts++; return false; }, () => stops++));
        Assert.Equal(2, starts);
        Assert.Equal(1, stops);
    }

    [Fact]
    public void TheSuspendedStateIsItsOwnPresentationNotAPauseOrARecording()
    {
        CaptureStatusPresentation retryable = CaptureStatusPresentation.Resolve(
            ownsActiveCapture: true, safeStopPending: true, safeStopFaulted: false, ExemptionSuspension.Retryable);
        Assert.Equal(CapturePresentationState.ExemptionSuspended, retryable.State);
        Assert.False(retryable.ShowsRecording);
        Assert.Equal(ExemptionChange.SuspendedNotice, retryable.Status);
        Assert.Equal("Retry applying exemptions", retryable.ActionText);
        Assert.True(retryable.ActionEnabled);

        CaptureStatusPresentation faulted = CaptureStatusPresentation.Resolve(
            ownsActiveCapture: true, safeStopPending: true, safeStopFaulted: true, ExemptionSuspension.Faulted);
        Assert.Equal(CapturePresentationState.ExemptionSuspended, faulted.State);
        Assert.False(faulted.ShowsRecording);
        Assert.Equal(ExemptionChange.SuspendedNotice, faulted.Status);
        Assert.DoesNotContain("quit", faulted.ActionText, StringComparison.OrdinalIgnoreCase);
        Assert.False(faulted.ActionEnabled);
    }
}
