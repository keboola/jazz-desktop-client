using JazzCapture.Capture;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Input;
using JazzCaptureCore.Journal;
using System.Reflection;

namespace JazzCaptureHostTests;

public sealed class MaintenanceShutdownTests
{
    [Fact]
    public void QueryCloseRetriesFailedPreparationAndCachesSuccess()
    {
        int attempts = 0;
        var controller = new JazzCapture.MaintenanceShutdownController(() => ++attempts >= 2, () => { });

        Assert.False(controller.QueryClose());
        Assert.True(controller.QueryClose());
        Assert.True(controller.QueryClose());
        Assert.Equal(2, attempts);
    }

    [Fact]
    public void RequestCloseNeverShutsDownBeforePreparationAndIsIdempotent()
    {
        bool allow = false;
        int shutdowns = 0;
        var controller = new JazzCapture.MaintenanceShutdownController(() => allow, () => shutdowns++);

        Assert.False(controller.RequestClose());
        Assert.Equal(0, shutdowns);
        allow = true;
        Assert.True(controller.RequestClose());
        Assert.True(controller.RequestClose());
        Assert.Equal(1, shutdowns);
    }

    [Fact]
    public void DrainTimeoutCanBeRetriedAfterTheSameWorkerCompletes()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.Equal(DrainAttempt.TimedOut, CaptureDrainWait.Wait(completion.Task, TimeSpan.Zero));
        completion.SetResult();
        Assert.Equal(DrainAttempt.Drained, CaptureDrainWait.Wait(completion.Task, TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public void CaptureCoordinatorDrainRetriesSameWorkerAfterTimeout()
    {
        string root = Path.Combine(Path.GetTempPath(), "jazz-drain-test-" + Guid.NewGuid().ToString("n"));
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            CaptureEngine engine = CaptureEngine.Start(new EngineConfig(
                root,
                "fixture-user",
                "fixture-host",
                "0.0.0-test",
                Array.Empty<string>(),
                false,
                () => DateTimeOffset.UtcNow));
            var settings = new JazzCapture.Settings
            {
                CaptureRoot = root,
                QueueDirectory = Path.Combine(root, "queue"),
                ScreenshotsEnabled = false,
                NarrationEnabled = false,
            };
            var identity = new AppIdentityResolver();
            using var uia = new UiaResolver(identity, TimeSpan.FromMilliseconds(10));
            using var coordinator = new CaptureCoordinator(
                engine,
                settings,
                uia,
                identity,
                () => DateTimeOffset.UtcNow,
                new GestureMetrics(500, 4, 4, 4, 4));
            FieldInfo workerField = typeof(CaptureCoordinator).GetField(
                "_worker",
                BindingFlags.Instance | BindingFlags.NonPublic) ??
                throw new InvalidOperationException("CaptureCoordinator worker field is missing.");
            workerField.SetValue(coordinator, completion.Task);

            Assert.Equal(DrainAttempt.TimedOut, coordinator.DrainAndStop(TimeSpan.Zero));
            completion.SetResult();
            Assert.Equal(DrainAttempt.Drained, coordinator.DrainAndStop(TimeSpan.FromSeconds(1)));

            engine.Stop();
        }
        finally
        {
            completion.TrySetResult();
            if (Directory.Exists(root)) { Directory.Delete(root, true); }
        }
    }

    [Fact]
    public void FaultedDrainNeverReportsSuccess()
    {
        Assert.Equal(
            DrainAttempt.Faulted,
            CaptureDrainWait.Wait(Task.FromException(new InvalidOperationException("fixture")), TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public void EndSessionShutsDownOnlyWhenWindowsConfirmsSessionEnd()
    {
        int shutdowns = 0;
        var controller = new JazzCapture.MaintenanceShutdownController(() => true, () => shutdowns++);
        Assert.False(controller.EndSession(false));
        Assert.True(controller.EndSession(true));
        Assert.True(controller.EndSession(true));
        Assert.Equal(1, shutdowns);
    }

    [Fact]
    public void RestartRegistrationResultIsExplicitWithoutThrowing()
    {
        Assert.True(JazzCapture.RestartRegistration.IsSuccess(0));
        Assert.False(JazzCapture.RestartRegistration.IsSuccess(unchecked((int)0x80004005)));
    }

    [Fact]
    public void RestartRegistrationUsesMaintenanceOnlyFlags()
    {
        Assert.Equal(1, JazzCapture.Interop.NativeMethods.RESTART_NO_CRASH);
        Assert.Equal(2, JazzCapture.Interop.NativeMethods.RESTART_NO_HANG);
        Assert.Equal(8, JazzCapture.Interop.NativeMethods.RESTART_NO_REBOOT);
        Assert.Equal(11, JazzCapture.Interop.NativeMethods.MAINTENANCE_RESTART_FLAGS);
    }

    [Fact]
    public void FailedRestartRegistrationKeepsCloseSinkAliveAndDisposable()
    {
        var window = new JazzCapture.MaintenanceShutdownWindow(
            () => true,
            () => { },
            () => unchecked((int)0x80004005));
        try
        {
            Assert.False(window.RestartRegistered);
            Assert.True(window.HasNativeHandle);
        }
        finally
        {
            window.Dispose();
        }

        Assert.False(window.HasNativeHandle);
    }

    [Fact]
    public void MaintenanceCommitPreservesJournalWithoutReviewFinalizationExportOrQueue()
    {
        string root = Path.Combine(Path.GetTempPath(), "jazz-maintenance-test-" + Guid.NewGuid().ToString("n"));
        string queue = Path.Combine(root, "queue");
        try
        {
            DateTimeOffset clock = DateTimeOffset.Parse("2026-09-09T12:00:00Z");
            CaptureEngine engine = CaptureEngine.Start(new EngineConfig(
                root, "fixture-user", "fixture-host", "0.0.0-test", Array.Empty<string>(), false,
                () => clock = clock.AddMilliseconds(1)));

            Assert.True(JazzCapture.MaintenanceCaptureSession.TryCommit(engine, () => true));
            Assert.Equal(EngineState.Committed, engine.State);
            Assert.Null(engine.ArchiveDirectory);
            Assert.False(Directory.Exists(Path.Combine(root, CaptureEngine.ArchivesDirectoryName)));
            Assert.False(Directory.Exists(queue));

            string draft = Path.Combine(root, CaptureJournal.StateRootName, engine.Identity.ArchiveId);
            Assert.True(Directory.Exists(draft));
            string assertionPath = Path.Combine(draft, ArchiveReviewLog.FileName);
            Assert.False(File.Exists(assertionPath));
            Assert.Contains(Directory.EnumerateFiles(draft, "*", SearchOption.AllDirectories), path =>
                File.ReadAllText(path).Contains("committed", StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            if (Directory.Exists(root)) { Directory.Delete(root, true); }
        }
    }

    [Fact]
    public void FailedMaintenanceDrainLeavesRealEngineRecordingAndUncommitted()
    {
        string root = Path.Combine(Path.GetTempPath(), "jazz-maintenance-test-" + Guid.NewGuid().ToString("n"));
        try
        {
            CaptureEngine engine = CaptureEngine.Start(new EngineConfig(
                root, "fixture-user", "fixture-host", "0.0.0-test", Array.Empty<string>(), false,
                () => DateTimeOffset.UtcNow));
            Assert.False(JazzCapture.MaintenanceCaptureSession.TryCommit(engine, () => false));
            Assert.Equal(EngineState.Recording, engine.State);
            Assert.Null(engine.ArchiveDirectory);
            Assert.False(Directory.Exists(Path.Combine(root, CaptureEngine.ArchivesDirectoryName)));
            Assert.False(Directory.Exists(Path.Combine(root, "queue")));
        }
        finally
        {
            if (Directory.Exists(root)) { Directory.Delete(root, true); }
        }
    }
}
