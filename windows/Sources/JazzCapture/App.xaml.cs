using System.Windows;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Net.Http;
using JazzCaptureCore;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Enrollment;
using JazzCaptureCore.Delivery;

namespace JazzCapture;

/// <summary>
/// The application entry point. It has no main window: the whole UI is the tray icon, so the
/// application starts the <see cref="TrayHost"/> and only exits when the host asks it to.
/// </summary>
public partial class App
{
    private TrayHost? _host;
    private MaintenanceShutdownWindow? _maintenanceWindow;
    private Mutex? _instanceMutex;
    private bool _ownsInstanceMutex;
    private UserActivation? _activation;
    private FirstRunStateStore? _startupState;
    private Settings? _settings;
    private OnboardingWindow? _statusWindow;
    private ManualProvisioningWindow? _provisioningWindow;
    private readonly CancellationTokenSource _shutdown = new();
    private readonly DeviceCredentialStore _credentialStore = new();
    private readonly HttpClient _credentialHttpClient = KeboolaDeviceTokenVerifier.CreateProductionClient();
    private MvpStreamDispatcher? _streamDispatcher;
    private MvpDeliveryTarget? _deliveryTarget;
    private readonly CaptureStartupGate _captureStartupGate = new();
    private ArtifactDeliveryQueue? _screenshotQueue;
    private ScreenshotDeliveryScheduler? _screenshotScheduler;
    private volatile bool _screenshotDeliveryAvailable;
    private volatile bool _screenshotReconciliationNeedsAttention;

    /// <inheritdoc />
    /// <remarks>
    /// The user's saved preferences are read here, before anything else exists, because the
    /// exclusion list has to be in force from the first capture of the run. A settings file that
    /// cannot be read never stops startup: the built-in seeds stand in, and the reason travels to
    /// the settings window so it can be shown rather than swallowed.
    /// </remarks>
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        string sid = WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("Current user SID is unavailable.");
        var security = new MutexSecurity();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new MutexAccessRule(
            new SecurityIdentifier(sid),
            MutexRights.FullControl,
            AccessControlType.Allow));
        _instanceMutex = MutexAcl.Create(false, "Global\\JazzCapture." + sid, out _, security);
        try
        {
            _ownsInstanceMutex = _instanceMutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            // Ownership is recovered; a stale process must not permanently prevent local UI access.
            _ownsInstanceMutex = true;
        }
        if (!_ownsInstanceMutex)
        {
            UserActivation.TryActivateExisting();
            Shutdown();
            return;
        }

        _startupState = new FirstRunStateStore(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jazz"));
        (Settings settings, HostSettingsLoad load) = Settings.Load();
        _settings = settings;
        CaptureJournalRecoveryResult recovery = CaptureJournalRecovery.Recover(
            settings.CaptureRoot,
            () => Timestamps.IsoMillisUtc(DateTimeOffset.UtcNow));
        _host = new TrayHost(
            settings,
            load.Origin == HostSettingsOrigin.Unreadable ? load.Detail : null,
            RecoveryStatus(recovery),
            SendCapturedEventAsync,
            AdmitCapturedScreenshot,
            () => _screenshotScheduler?.Nudge());
        try
        {
            string screenshotSpool = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Jazz",
                "spool",
                "screenshots");
            CurrentUserOnlyAcl.ApplyDirectory(screenshotSpool);
            _screenshotQueue = new ArtifactDeliveryQueue(
                screenshotSpool,
                CurrentUserOnlyAcl.ApplyFile);
            ScreenshotDeliveryIntentReconciliationResult reconciliation =
                ScreenshotDeliveryIntentReconciler.Reconcile(settings.CaptureRoot, _screenshotQueue);
            _screenshotScheduler = new ScreenshotDeliveryScheduler(DrainScreenshotsAsync);
            _screenshotDeliveryAvailable = reconciliation.NeedsAttention == 0;
            _screenshotReconciliationNeedsAttention = reconciliation.NeedsAttention > 0;
            _host.SetScreenshotDeliveryStatus(new(
                reconciliation.NeedsAttention > 0
                    ? ScreenshotDeliveryStatus.Quarantined
                    : ScreenshotDeliveryStatus.NotProvisioned,
                _screenshotQueue.PendingFileCount));
        }
        catch
        {
            // Delivery state is auxiliary to local-first capture. Report only a sanitized state;
            // the journal remains the canonical durable copy and startup continues.
            _screenshotDeliveryAvailable = false;
            _host.SetScreenshotDeliveryStatus(new(ScreenshotDeliveryStatus.Quarantined, 0));
        }
        _streamDispatcher = new MvpStreamDispatcher(DeliverCapturedEventAsync, status =>
        {
            if (!Dispatcher.HasShutdownStarted) Dispatcher.BeginInvoke(() => _host?.SetStreamingStatus(status));
        });
        _host.SetProvisioningStatus(_credentialStore.Status(DateTimeOffset.UtcNow));
        RefreshDeliveryTarget();
        _ = ObserveProvisioningAsync(_shutdown.Token);
        _activation = new UserActivation(() => Dispatcher.BeginInvoke(ShowStatus));
        _activation.Start();
        _maintenanceWindow = new MaintenanceShutdownWindow(
            () => _host?.TryPrepareForMaintenance() ?? true,
            () => Dispatcher.BeginInvoke(() => Shutdown()));

        // This is deliberately after both recovery and host construction. Credentials, device
        // bundles and login registration are intentionally absent from the decision: none of them
        // is a capture preference or consent signal. The decision has no retry path, so this is the
        // one and only automatic start attempt in the process.
        TrayHost host = _host;
        _captureStartupGate.TryStart(
                _ownsInstanceMutex,
                true,
                recovery.NeedsAttention == 0,
                settings.CaptureAtLaunchEnabled,
                settings.CaptureAtLaunchPaused,
                host.StartCapture);

        if (_startupState.RequiresOnboarding()) ShowStatus();
        _ = CheckForUpdateAsync(_startupState, _shutdown.Token);
    }

    private async Task ObserveProvisioningAsync(CancellationToken cancellationToken)
    {
        // This is intentionally detached from capture startup: no credential outage may prevent
        // local-first journaling. #60 only needs to place the ACL-protected file at this seam.
        try
        {
            for (int retry = 0; ; retry++)
            {
                ProvisioningIntakeResult result = await _credentialStore.ConsumeProvisioningFileWithDispositionAsync(
                    DeviceCredentialStore.ProvisioningPath,
                    new KeboolaDeviceTokenVerifier(_credentialHttpClient), DateTimeOffset.UtcNow, cancellationToken).ConfigureAwait(false);
                if (!cancellationToken.IsCancellationRequested && !Dispatcher.HasShutdownStarted)
                    await Dispatcher.InvokeAsync(() => _host?.SetProvisioningStatus(result.Status));
                RefreshDeliveryTarget();
                if (result.Disposition != ProvisioningIntakeDisposition.Retryable) return;
                await Task.Delay(ProvisioningRetryDelay(retry), cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch
        {
            if (!Dispatcher.HasShutdownStarted)
                await Dispatcher.InvokeAsync(() => _host?.SetProvisioningStatus(new(DeviceCredentialState.Invalid, "Provisioning could not be checked.")));
        }
    }

    private Task SendCapturedEventAsync(ActivityEvent activityEvent, SessionContext context)
    {
        _streamDispatcher?.Enqueue(activityEvent, context);
        return Task.CompletedTask;
    }

    private bool AdmitCapturedScreenshot(ActivityEvent activityEvent, ArtifactDeliveryDescriptor artifact, SessionContext context)
    {
        try
        {
            if (_screenshotQueue is null)
            {
                throw new InvalidOperationException("Screenshot delivery spool is unavailable.");
            }

            _screenshotQueue.EnqueueScreenshot(artifact, activityEvent, context);
            _screenshotDeliveryAvailable = !_screenshotReconciliationNeedsAttention;
            return true;
        }
        catch
        {
            _screenshotDeliveryAvailable = false;
            if (!Dispatcher.HasShutdownStarted)
            {
                _ = Dispatcher.BeginInvoke(() => _host?.SetScreenshotDeliveryStatus(new(
                    ScreenshotDeliveryStatus.Quarantined,
                    ScreenshotPendingCount())));
            }
            return false;
        }
    }

    private async Task DrainScreenshotsAsync(CancellationToken cancellationToken)
    {
        MvpDeliveryTarget? target = Volatile.Read(ref _deliveryTarget);
        ArtifactDeliveryQueue? queue = _screenshotQueue;
        if (queue is null) return;
        if (target is null || target.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            if (!Dispatcher.HasShutdownStarted)
            {
                _ = Dispatcher.BeginInvoke(() => _host?.SetScreenshotDeliveryStatus(new(
                    _screenshotDeliveryAvailable
                        ? ScreenshotDeliveryStatus.NotProvisioned
                        : ScreenshotDeliveryStatus.Quarantined,
                    ScreenshotPendingCount())));
            }
            return;
        }
        await new ScreenshotDeliveryWorker(
            queue,
            status =>
            {
                if (!Dispatcher.HasShutdownStarted)
                    Dispatcher.BeginInvoke(() => _host?.SetScreenshotDeliveryStatus(
                        _screenshotReconciliationNeedsAttention
                            ? new ScreenshotDeliveryPresentation(ScreenshotDeliveryStatus.Quarantined, status.PendingCount)
                            : status));
            }).DrainOnceAsync(
                new KeboolaFilesClient(target.Bundle, _credentialHttpClient),
                target.Sender,
                cancellationToken).ConfigureAwait(false);
    }

    private async Task<StreamDeliveryStatus> DeliverCapturedEventAsync(ActivityEvent activityEvent, SessionContext context, CancellationToken cancellationToken)
    {
        MvpDeliveryTarget? target = Volatile.Read(ref _deliveryTarget);
        if (target is null || target.ExpiresAt <= DateTimeOffset.UtcNow) return StreamDeliveryStatus.NotProvisioned;
        try { return await target.Sender.SendAsync(activityEvent, context, cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested) { return StreamDeliveryStatus.NotProvisioned; }
        catch { return StreamDeliveryStatus.Unreachable; }
    }

    private void RefreshDeliveryTarget()
    {
        try
        {
            DateTimeOffset now = DateTimeOffset.UtcNow;
            DeviceBundle? bundle = _credentialStore.Read();
            MvpDeliveryTarget? target = bundle?.StreamEndpoint is { } endpoint
                && Timestamps.TryParseRfc3339(bundle.ExpiresAt) is { } expiry
                && expiry > now
                    ? new MvpDeliveryTarget(
                        new MvpStreamSender(endpoint, _credentialHttpClient),
                        expiry,
                        bundle)
                    : null;
            Volatile.Write(ref _deliveryTarget, target);
            _host?.SetStreamingStatus(target is null
                ? StreamDeliveryStatus.NotProvisioned
                : StreamDeliveryStatus.Waiting);
            _host?.SetScreenshotDeliveryStatus(new(
                !_screenshotDeliveryAvailable
                    ? ScreenshotDeliveryStatus.Quarantined
                    : target is null
                        ? ScreenshotDeliveryStatus.NotProvisioned
                        : ScreenshotDeliveryStatus.Waiting,
                ScreenshotPendingCount()));
            _screenshotScheduler?.Nudge();
        }
        catch
        {
            Volatile.Write(ref _deliveryTarget, null);
            _host?.SetStreamingStatus(StreamDeliveryStatus.NotProvisioned);
            _host?.SetScreenshotDeliveryStatus(new(
                _screenshotDeliveryAvailable
                    ? ScreenshotDeliveryStatus.NotProvisioned
                    : ScreenshotDeliveryStatus.Quarantined,
                ScreenshotPendingCount()));
        }
    }

    private int ScreenshotPendingCount()
    {
        try
        {
            return _screenshotQueue?.PendingFileCount ?? 0;
        }
        catch
        {
            _screenshotDeliveryAvailable = false;
            return 0;
        }
    }

    internal static string? RecoveryStatus(CaptureJournalRecoveryResult recovery)
    {
        if (recovery.NeedsAttention > 0)
        {
            return "Some interrupted capture journals need local attention.";
        }

        // A normal recovery is local housekeeping, not a user-visible error. Surface only journals
        // that were deliberately left untouched and need an operator's attention.
        return null;
    }

    internal static TimeSpan ProvisioningRetryDelay(int retry)
        => TimeSpan.FromSeconds(Math.Min(60, 1 << Math.Min(6, Math.Max(0, retry))));

    internal void ShowStatus()
    {
        if (_startupState is null) return;
        if (_statusWindow is null || !_statusWindow.IsLoaded)
        {
            _statusWindow = new OnboardingWindow(_startupState.Acknowledge, _settings ?? new Settings());
            _statusWindow.Closed += (_, _) => _statusWindow = null;
            _statusWindow.Show();
        }
        _statusWindow.Activate();
    }

    internal void ShowProvisioning()
    {
        if (_provisioningWindow is null || !_provisioningWindow.IsLoaded)
        {
            _provisioningWindow = new ManualProvisioningWindow(async (text, cancellationToken) =>
            {
                DeviceCredentialStatus status = await _credentialStore.AuthorizeAndAcceptManualPasteAsync(
                    text, new KeboolaDeviceTokenVerifier(_credentialHttpClient), DateTimeOffset.UtcNow, cancellationToken);
                _host?.SetProvisioningStatus(status);
                RefreshDeliveryTarget();
                return status;
            });
            _provisioningWindow.Closed += (_, _) => _provisioningWindow = null;
            _provisioningWindow.Show();
        }
        _provisioningWindow.Activate();
    }

    private async Task CheckForUpdateAsync(FirstRunStateStore state, CancellationToken cancellationToken)
    {
        using var client = new GitHubUpdateClient(state);
        AvailableRelease? release = await client.CheckAsync(cancellationToken);
        if (release is not null && _host is not null)
        {
            await Dispatcher.InvokeAsync(() => _host?.SetAvailableRelease(release));
        }
    }

    /// <inheritdoc />
    protected override void OnExit(ExitEventArgs e)
    {
        _shutdown.Cancel();
        _screenshotScheduler?.Dispose();
        _screenshotScheduler = null;
        _streamDispatcher?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        _streamDispatcher = null;
        _host?.Dispose();
        _host = null;
        _maintenanceWindow?.Dispose();
        _maintenanceWindow = null;
        _statusWindow?.Close();
        _statusWindow = null;
        _provisioningWindow?.Close();
        _provisioningWindow = null;
        _activation?.Dispose();
        _activation = null;
        if (_ownsInstanceMutex) _instanceMutex?.ReleaseMutex();
        _instanceMutex?.Dispose();
        _instanceMutex = null;
        _shutdown.Dispose();
        _credentialHttpClient.Dispose();
        base.OnExit(e);
    }
}
