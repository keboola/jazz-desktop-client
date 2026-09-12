using System.Windows;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Net.Http;
using System.Text;
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
    private MvpDeliveryTarget? _deliveryTarget;
    // Issue #48, §3.5: the stream transport no longer shares _credentialHttpClient. That client's
    // 30-second verify timeout belongs to provisioning; the event stream needs its own transport so
    // EventDeliverySettings.SendCallBudget is the only deadline in force for a /v1/logs POST, and so
    // it structurally cannot follow a redirect (RedirectSafeHttpClient's own remarks).
    private readonly RedirectSafeHttpClient _streamHttpClient = RedirectSafeHttpClient.CreateProduction();
    private readonly CaptureStartupGate _captureStartupGate = new();

    // Prepare-early screenshot delivery (issue #73). The Files client cannot be built over a bare
    // HttpClient (see RedirectSafeHttpClient's remarks on header-leaking redirects), so this is a
    // second, dedicated transport -- never the credential-verification client above. It is shared
    // across every KeboolaFilesClient rebuilt in RefreshScreenshotDelivery: UploadAsync does not
    // depend on which Storage credential is currently active, so one transport instance can safely
    // outlive any number of credential rotations.
    private readonly RedirectSafeHttpClient _screenshotHttpClient = RedirectSafeHttpClient.CreateProduction();
    private readonly ScreenshotDeliveryPresentationTracker _screenshotDeliveryTracker = new();
    // Finding 2 (#74 review, second pass): PrepareScreenshotDelivery pushes through PushIfChanged
    // on a declined prepare, which can happen once per click for an entire unprovisioned session;
    // this publisher is what keeps that from marshalling a redundant tray refresh per click. See
    // its own remarks for why every other call site below keeps pushing unconditionally through
    // the same publisher's Push instead.
    private readonly DeliveryStatusPublisher<ScreenshotDeliveryPresentation> _screenshotStatusPublisher;
    private ScreenshotStagingArea? _screenshotStaging;
    private DeliveryDrainScheduler? _screenshotDeliveryScheduler;
    private ScreenshotDeliveryWorker? _screenshotWorker;
    private ScreenshotDeliveryPreparer? _screenshotPreparer;

    // Durable event spool and OTLP delivery (issue #48). _eventSpool is null only when it could not
    // be constructed (see the narrow try/catch below); a null spool routes SendCapturedEventAsync and
    // ResolveEventDeliveryPresentation to the distinct Unavailable state -- deliberately
    // distinguishable, unlike the screenshot staging area's identical failure mode, because a null
    // event spool means events are produced and discarded, the exact condition this issue exists to
    // make impossible to hide.
    private readonly EventDeliveryPresentationTracker _eventDeliveryTracker = new();
    private readonly DeliveryStatusPublisher<EventDeliveryPresentation> _eventStatusPublisher;
    private EventSpool? _eventSpool;
    private DeliveryDrainScheduler? _eventDeliveryScheduler;
    private EventDeliveryWorker? _eventWorker;

    /// <summary>Constructs <see cref="_screenshotStatusPublisher"/> and
    /// <see cref="_eventStatusPublisher"/>, both of which need to close over <c>this</c> rather than
    /// being independently newable. WPF generates the parameterless <c>App()</c> constructor from
    /// <c>App.xaml</c> (see the generated <c>App.g.cs</c>); this is the one place a hand-written
    /// constructor for this partial class exists, purely to run these two lines before
    /// <see cref="OnStartup"/>.</summary>
    public App()
    {
        _screenshotStatusPublisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(
            presentation => _host?.SetScreenshotDeliveryStatus(presentation));
        _eventStatusPublisher = new DeliveryStatusPublisher<EventDeliveryPresentation>(
            presentation => _host?.SetStreamingStatus(presentation));
    }

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

        // #76: the only read of the command line this client performs. LaunchOptions retains
        // nothing it did not recognise (no secret, and nothing else, can travel through it -- see
        // its own remarks), and unknown arguments are ignored rather than fatal. Note that a
        // process that lost the single-instance race above already returned at line 97, before
        // this point exists -- so a switch on a second launch never reaches this resolution at
        // all; it only sends the single word Activate through the one-verb activation pipe
        // (UserActivation.cs:8) and raises the running instance's window, changing nothing about
        // capture.
        LaunchOptions launch = LaunchOptions.Parse(e.Args);
        EffectiveCaptureAtLaunch captureAtLaunch =
            EffectiveCaptureAtLaunch.Resolve(settings.Persisted, launch.CaptureAtLaunch);

        // Constructing the staging area runs its launch cleanup exactly once, here, before any
        // capture can begin: any bytes left on disk from a previous process are garbage by
        // definition (that process's in-memory federation credentials are gone with it), and this
        // is the only call site for it in the whole process lifetime.
        //
        // Finding 1 (#74 review, third pass): this used to run unguarded, so a filesystem or ACL
        // failure here -- e.g. a reparse-point ancestor CurrentUserOnlyAcl.ApplyDirectory rejects,
        // exactly what ScreenshotStagingAreaTests.RedirectedAncestorIsRejectedBeforeDirectoryCreation
        // pins -- aborted the whole process before _host even existed, turning an unavailable
        // *optional* delivery dependency into a total capture outage. Screenshot delivery staging is
        // not a capture dependency any more than a Storage credential is (#62 constraint 4: capture
        // must never be blocked or stopped by a delivery problem), so this is caught narrowly to
        // IOException/UnauthorizedAccessException -- the same pair CurrentUserOnlyAcl.RejectReparse,
        // Directory.CreateDirectory/SetAccessControl, and this type's own CleanAtLaunch already treat
        // as expected filesystem/ACL failures (PathTooLongException, DirectoryNotFoundException, and
        // friends all derive from IOException) -- rather than blanket-caught: anything else escaping
        // from here is a genuine defect and should still crash loudly.
        //
        // Leaving _screenshotStaging null routes every downstream consumer through the exact same
        // null guards a missing/expired Storage credential already relies on:
        // RefreshScreenshotDelivery returns before ever publishing a worker or preparer (both types
        // require a non-null staging area by construction, so neither can exist without one),
        // PrepareScreenshotDelivery's read of the preparer is null-conditional and never calls
        // PrepareAsync, DrainScreenshotDeliveryAsync sees a null worker and reports "nothing due" so
        // DeliveryDrainScheduler parks rather than spins, and ResolveScreenshotDeliveryPresentation
        // returns null so nothing is ever pushed to the tray -- leaving TrayHost's own default
        // ScreenshotDeliveryPresentation (NotProvisioned) on screen, which already renders "not
        // provisioned". That is the same text an absent or expired credential renders; the two
        // failure modes are deliberately left indistinguishable on the tray -- there is no logging
        // framework to record the distinction anywhere else, and a dedicated presentation state for
        // "staging unavailable" is not worth the extra tray vocabulary for a case this narrow. This
        // comment is that decision, recorded once, rather than an unstated coincidence.
        try
        {
            _screenshotStaging = new ScreenshotStagingArea(settings.ScreenshotDelivery);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _screenshotStaging = null;
        }
        _screenshotDeliveryScheduler = new DeliveryDrainScheduler(
            DrainScreenshotDeliveryAsync,
            attempt => ScreenshotUploadRetryPolicy.Delay(
                attempt, ScreenshotUploadRetryPolicy.DrainLoopBackoffIdentity, settings.ScreenshotDelivery));

        // The durable event spool (issue #48). Unlike the screenshot staging area above -- whose
        // failure is deliberately left indistinguishable from a missing credential, per this
        // method's own remarks a few lines up -- an unconstructible event spool leaves the tray on
        // the distinct Unavailable state (see ResolveEventDeliveryPresentation below), because a
        // null event spool means every captured event is silently discarded, exactly the condition
        // this issue exists to make impossible to hide. The narrow catch mirrors the staging area's
        // own: a filesystem/ACL failure here must never turn an optional delivery dependency into a
        // total capture outage (#62 constraint 4).
        //
        // This sits before CaptureJournalRecovery.Recover and therefore before CaptureStartupGate.TryStart
        // further down, so a switch-started capture (#76) can never produce an event before adoption
        // finished. The spool is independent of journal recovery and is not entangled with
        // recovery.NeedsAttention.
        try
        {
            _eventSpool = new EventSpool(settings.EventDelivery);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _eventSpool = null;
        }
        _eventDeliveryScheduler = new DeliveryDrainScheduler(
            DrainEventDeliveryAsync,
            attempt => EventStreamRetryPolicy.Delay(
                attempt, EventStreamRetryPolicy.DrainLoopBackoffIdentity, settings.EventDelivery));

        CaptureJournalRecoveryResult recovery = CaptureJournalRecovery.Recover(
            settings.CaptureRoot,
            () => Timestamps.IsoMillisUtc(DateTimeOffset.UtcNow));
        _host = new TrayHost(
            settings,
            load.Origin == HostSettingsOrigin.Unreadable ? load.Detail : null,
            RecoveryStatus(recovery),
            SendCapturedEventAsync,
            PrepareScreenshotDelivery,
            captureAtLaunchFromLaunchSwitch: launch.CaptureAtLaunch);
        _host.SetProvisioningStatus(_credentialStore.Status(DateTimeOffset.UtcNow));
        RefreshDeliveryTarget();
        _ = ObserveProvisioningAsync(_shutdown.Token);
        // #75 §3: kept, deliberately. Unlike the removed startup call site, this fires only when a
        // person launches JazzCapture.exe a second time while an instance already owns the mutex --
        // a real user action at the machine, not an unattended provisioning step. The process has no
        // main window or taskbar presence, so showing nothing here would leave that person's
        // double-click with no feedback at all.
        _activation = new UserActivation(() => Dispatcher.BeginInvoke(ShowStatus));
        _activation.Start();
        _maintenanceWindow = new MaintenanceShutdownWindow(
            () => _host?.TryPrepareForMaintenance() ?? true,
            () => Dispatcher.BeginInvoke(() => Shutdown()));

        // This is deliberately after both recovery and host construction. Credentials, device
        // bundles and login registration are intentionally absent from the decision: none of them
        // is a capture preference or consent signal. The decision has no retry path, so this is the
        // one and only automatic start attempt in the process. #76: the launch switch is the
        // second input to captureAtLaunch, resolved above, and reaches the gate only through this
        // one call -- there is no other path from LaunchOptions to CaptureStartupGate.
        TrayHost host = _host;
        _captureStartupGate.TryStart(
                _ownsInstanceMutex,
                true,
                recovery.NeedsAttention == 0,
                captureAtLaunch.Enabled,
                captureAtLaunch.Paused,
                host.StartCapture);

        // #75: this client is deployed through Intune, onto machines nobody is sitting at during
        // provisioning, so no window may appear here. The status window stays one click away on
        // the tray (TrayHost.cs's "Status and onboarding..." item) and on the second-instance
        // activation path above (line 169). Reintroducing a startup call site is a deliberate act,
        // not a default: `FirstRunStateStore.RequiresOnboarding()` -- the API this call site used
        // to gate on -- is gone; see its type summary. `_startupState` is still constructed above
        // because it also carries the update-check throttle the next line reads.
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

    /// <summary>
    /// The capture-path write: spools the event's exact <c>/v1/logs</c> request body durably before
    /// returning, replacing the old in-memory, drop-under-pressure <c>MvpStreamDispatcher.Enqueue</c>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Runs synchronously on the capture engine's own worker thread, inside the engine's lock.</b>
    /// <c>CaptureEngine.Append</c> invokes the delivery observer only after <c>ResolveObservation</c>
    /// has already made the journal record durable, via <c>TrayHost.SendCapturedEvent</c>, which
    /// discards the <see cref="Task"/> this method returns. The journal record is therefore already
    /// durable before this method ever runs, so nothing here can affect archive truth -- and this
    /// method must never throw, matching the engine's own <c>try { } catch { }</c> around the
    /// observer call.
    /// </para>
    /// <para>
    /// <b>One <see cref="Durability.ReplaceAtomic"/> here is the accepted cost, not an oversight
    /// (R1, #48 plan).</b> <c>CaptureCoordinator</c> drains every observation over a single reader on
    /// an <em>unbounded</em> channel, and <c>windows/README.md</c> already records an accepted
    /// aggregate-unbounded cost for screenshot prepares on this same path. A few kilobytes' atomic
    /// write is cheap and is the same order of magnitude <c>CaptureJournal.AppendWal</c> already pays
    /// twice per observation, on this exact thread -- the alternative (handing the body to a
    /// background worker to write later) would reopen the very loss window issue #48 exists to close.
    /// </para>
    /// <para>
    /// <b>No status push on the success path (R12, #48 plan).</b> The spool's pending count changes
    /// on every event, and pushing a tray refresh here would marshal a dispatcher call per click and
    /// keystroke -- the same trap Finding 2 of the #74 review names for the screenshot path. Only a
    /// refusal or an unavailable spool pushes from here; <see cref="DrainEventDeliveryAsync"/>'s own
    /// post-pass push keeps the tray line current for every <see cref="EventDeliveryWorker"/> outcome
    /// otherwise (see <see cref="OnEventDeliveryOutcome"/>'s own remarks on why that push moved there
    /// instead of firing once per outcome).
    /// </para>
    /// </remarks>
    private Task SendCapturedEventAsync(ActivityEvent activityEvent, SessionContext context)
    {
        EventSpool? spool = Volatile.Read(ref _eventSpool);
        if (spool is null)
        {
            PushEventDeliveryStatusIfChanged();
            return Task.CompletedTask;
        }

        // Body construction moves inside the try too (not just the spool call): this method must
        // never throw, on the capture engine's own worker thread inside the engine's lock, and
        // OtlpMapper.LogsRequest/ToJsonString are as capable of throwing as Spool itself is.
        byte[]? body = null;
        try
        {
            body = Encoding.UTF8.GetBytes(
                OtlpMapper.LogsRequest(new[] { activityEvent }, context).ToJsonString());
            if (spool.Spool(context.SessionId, activityEvent.Sequence, body) != EventSpoolAdmission.Spooled)
            {
                PushEventDeliveryStatusIfChanged();
            }

            // Nudge unconditionally, on both outcomes -- not only Spooled. A refusal still leaves
            // EventSpool's own pending-refusal list holding this event, and only the drain worker
            // (via EventDeliveryWorker.DrainOnceAsync, which runs its bookkeeping regardless of
            // whether a usable target exists) ever drains and reports that list; without this nudge,
            // once refusals become the steady state (e.g. persistent deletion debt keeps every new
            // admission refused), nothing would ever wake the worker again and the tray's abandoned
            // tally would stop moving -- the same class of silent loss the ordering fix above closes,
            // just a narrower trigger for it. Deliberately no status push on the success path (R12):
            // the pending count changes on every event, and pushing here would marshal a tray
            // refresh per click and keystroke; the worker's own outcomes keep the line current.
            _eventDeliveryScheduler?.Nudge();
        }
        catch
        {
            // Spool() threw before ever admitting or refusing this event through its own accounting
            // -- an unexpected defect, not a normal refusal -- so nothing in EventSpool's own
            // pending-refusal list will ever report it. Count it directly here instead of letting it
            // vanish: PushEventDeliveryStatusIfChanged alone is not enough, since it coalesces to
            // nothing when the projected presentation has not otherwise changed, and "every loss is
            // visible" is the whole point of this issue. The key is display-safe synthetic text
            // (session id plus sequence), never a real spool key, since none was ever minted.
            _eventDeliveryTracker.OnOutcome(new EventDeliveryOutcomeEvent(
                context.SessionId + "/" + (activityEvent.Sequence?.ToString(CultureInfo.InvariantCulture) ?? "unsequenced"),
                EventDeliveryOutcome.Refused));
            PushEventDeliveryStatus();
        }
        finally
        {
            if (body is not null)
            {
                CryptographicOperations.ZeroMemory(body);
            }
        }

        return Task.CompletedTask;
    }

    /// <summary>
    /// Sends one spooled event body, classifying the outcome. Keeps the same
    /// <see cref="Volatile.Read{T}(ref T)"/> plus live expiry re-check shape the previous
    /// <c>ActivityEvent</c>-based overload used, so a credential that lapses mid-drain stops being
    /// used on the very next call rather than only at the next <see cref="RefreshDeliveryTarget"/>.
    /// Returns <see cref="EventSendOutcome.Retry"/> (not a distinct "not provisioned" value) when
    /// there is no usable target, so the entry stays spooled rather than being misclassified as
    /// dropped.
    /// </summary>
    private async Task<EventSendOutcome> DeliverCapturedEventAsync(ReadOnlyMemory<byte> body, CancellationToken cancellationToken)
    {
        MvpDeliveryTarget? target = Volatile.Read(ref _deliveryTarget);
        if (target is null || target.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return EventSendOutcome.Retry;
        }

        try
        {
            // _settings is frozen once at construction and never replaced (R6, #48 plan) -- unlike
            // Settings.Persisted, which TrayHost replaces in place, EventDelivery is a compiled-in
            // operational bound that cannot change at runtime, so reading it here is safe.
            return await target.Sender.SendBodyAsync(body, _settings!.EventDelivery, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Re-throw rather than reporting a retry (review finding). Swallowing shutdown
            // cancellation here kept EventDeliveryWorker's own cancellation path from running, so a
            // pass already under way would go on calling the sender for every remaining entry and
            // record a retry for each, and DeliveryDrainScheduler.DisposeAsync could only complete
            // once the whole spool had been walked. With the 32 MiB ceiling that is a lot of
            // entries to traverse while the user is waiting for the process to exit. Letting the
            // cancellation propagate aborts the pass at the first entry instead. Nothing is lost by
            // aborting: an entry is only ever removed after a terminal outcome, so everything still
            // spooled is simply picked up by the next launch's adoption.
            throw;
        }
        catch
        {
            return EventSendOutcome.Retry;
        }
    }

    /// <param name="forceRebuild">
    /// Rebuilds the event worker (and so clears any parked <c>_targetKnownRevoked</c> state)
    /// regardless of whether the effective target compares as unchanged. Passed only from
    /// <see cref="ShowProvisioning"/>'s manual-paste callback (review finding): a person pasting a
    /// credential by hand is an explicit, deliberate "try again now" signal, and the effective-target
    /// comparison below only ever looks at the endpoint path and its expiry -- it cannot see a
    /// replacement credential that happens to keep both fields the same (nothing else about a
    /// <see cref="DeviceBundle"/> has any bearing on the event stream's own capability, since the
    /// capability *is* the URL), so a human explicitly asserting "this should work now" must not be
    /// second-guessed by that narrower, automatic-path comparison.
    /// </param>
    private void RefreshDeliveryTarget(bool forceRebuild = false)
    {
        MvpDeliveryTarget? previousTarget = Volatile.Read(ref _deliveryTarget);
        DeviceBundle? bundle = null;
        try { DateTimeOffset now = DateTimeOffset.UtcNow; bundle = _credentialStore.Read(); MvpDeliveryTarget? target = bundle is { StreamEndpoint: { } endpoint } activeBundle && Timestamps.TryParseRfc3339(activeBundle.ExpiresAt) is { } expiry && expiry > now ? new MvpDeliveryTarget(new MvpStreamSender(endpoint, _streamHttpClient), expiry, activeBundle) : null; Volatile.Write(ref _deliveryTarget, target); }
        catch
        {
            // A transient failure to read or parse the credential store (review finding) must not be
            // confused with "no credential": clearing _deliveryTarget here would make the
            // targetUnchanged comparison below see previousTarget as null on this call, and then --
            // on the very next call, once the exact same still-current bundle reads successfully
            // again -- see that as a *change* from null, rebuilding the worker and resetting a parked
            // _targetKnownRevoked even though nothing about the credential actually changed. Leaving
            // the last successfully read target in place is safe: its own expiry is still checked
            // live by IsDeliveryTargetUsable/DeliverCapturedEventAsync on every use regardless of
            // what happened here.
        }

        // Rebuild the event worker only when the *effective* target actually changed -- not
        // unconditionally on every call (review finding). RefreshDeliveryTarget always constructs a
        // brand-new MvpDeliveryTarget instance even when the underlying bundle is unchanged (e.g.
        // ObserveProvisioningAsync's own retry loop can call this repeatedly while a provisioning
        // *file* read keeps being transiently retryable, with the stored device bundle itself never
        // actually changing), and a fresh EventDeliveryWorker starts with a clean
        // _targetKnownRevoked. Rebuilding on every such call would therefore let a persistently
        // revoked (401/403) credential get re-probed on every one of those checks instead of staying
        // parked until an actual replacement credential is provisioned -- reintroducing, through a
        // different trigger, precisely the "retry a revoked endpoint on a timer" behaviour the
        // 401/403 correction exists to stop. Two targets are compared on the fields that decide the
        // event stream's own capability (the endpoint path and its expiry) rather than by reference
        // or by full record equality: MvpStreamSender has no value equality of its own (a new
        // instance is always constructed), and DeviceBundle's ComponentAccess is a plain list with no
        // value equality either, so comparing either whole object would always report "changed" even
        // for a byte-for-byte-identical re-read.
        MvpDeliveryTarget? currentTarget = Volatile.Read(ref _deliveryTarget);
        bool targetUnchanged = previousTarget is not null && currentTarget is not null
            && previousTarget.ExpiresAt == currentTarget.ExpiresAt
            && string.Equals(previousTarget.Bundle.StreamEndpoint, currentTarget.Bundle.StreamEndpoint, StringComparison.Ordinal);

        EventSpool? spool = Volatile.Read(ref _eventSpool);
        if (forceRebuild || !targetUnchanged || Volatile.Read(ref _eventWorker) is null)
        {
            // Its isTargetUsable and deliver delegates both re-read the current target live rather
            // than closing over this moment's snapshot, so _eventWorker is only null when the spool
            // itself is unavailable -- see ResolveEventDeliveryPresentation for why that is the
            // distinct Unavailable state rather than folded into NotProvisioned.
            Volatile.Write(
                ref _eventWorker,
                spool is null
                    ? null
                    : new EventDeliveryWorker(IsDeliveryTargetUsable, DeliverCapturedEventAsync, spool, OnEventDeliveryOutcome));
        }

        PushEventDeliveryStatus();

        // Nudge unconditionally -- not only when a target now exists (review finding: adoption-time
        // evictions were never drained without credentials). EventSpool.AdoptAtLaunch can populate
        // _pendingEvictions before this method ever first runs (the spool is constructed earlier in
        // OnStartup, independent of provisioning), and EventDeliveryWorker.DrainOnceAsync deliberately
        // performs its bookkeeping -- draining both pending lists -- even when IsDeliveryTargetUsable
        // says no target exists (see that type's own remarks): only the networking half is gated on
        // provisioning. Nudging only when a target existed, as this used to, left a relaunch with no
        // credential yet unable to ever drain those startup eviction notifications until an unrelated
        // event was captured or provisioning later succeeded -- hiding the sticky undelivered tally
        // for exactly as long as the machine stayed unprovisioned, the ordinary case #53 scope 4
        // describes. This also still covers the original reason this nudge exists: a credential that
        // becomes usable again, including the very first successful provisioning, must wake the
        // scheduler so anything spooled during an outage or before first provisioning drains promptly.
        // Cheap and coalesced like every other Nudge() call site, so there is no cost to doing this on
        // every refresh regardless of outcome.
        _eventDeliveryScheduler?.Nudge();

        // Wake once more, right around this target's own expiry (review finding): once the spool is
        // caught up and idle, nothing else calls RefreshDeliveryTarget or nudges the scheduler again
        // on its own -- ObserveProvisioningAsync's loop returns after the first successful
        // provisioning read, and DeliveryDrainScheduler goes idle once nothing is due -- so, with no
        // new event ever captured and no new provisioning event ever arriving, the tray could keep
        // showing whatever it last rendered (e.g. "up to date") long after this exact credential's
        // own ExpiresAt has actually passed. This watch's only job is to refresh the presentation at
        // that moment; IsDeliveryTargetUsable already blocks any send once expired regardless.
        if (Volatile.Read(ref _deliveryTarget) is { } scheduledTarget)
        {
            _ = ScheduleExpiryRefreshAsync(scheduledTarget, _shutdown.Token);
        }

        // Screenshot delivery has its own routing (the Storage token and stack URL, not the OTLP
        // stream endpoint), so it is refreshed independently of whether streaming itself is usable
        // -- a bundle with no streamEndpoint at all must still provision screenshot delivery.
        RefreshScreenshotDelivery(bundle);
    }

    /// <summary>
    /// Waits until <paramref name="target"/>'s own <see cref="MvpDeliveryTarget.ExpiresAt"/> passes,
    /// then refreshes the tray presentation -- see <see cref="RefreshDeliveryTarget"/>'s own remarks
    /// for why nothing else would otherwise do this once the spool is caught up and idle. Waits in
    /// bounded increments, never more than an hour at a time, rather than one
    /// <see cref="Task.Delay(TimeSpan, CancellationToken)"/> for the whole span: a device bundle's
    /// lifetime is not bounded by this type, and a single delay longer than roughly 24.8 days would
    /// throw. Exits without pushing anything the moment a *later* <see cref="RefreshDeliveryTarget"/>
    /// call has already replaced <paramref name="target"/> with a different instance -- that call's
    /// own push already covers whatever changed, and this stale watch's job is therefore already
    /// done.
    /// </summary>
    /// <remarks>
    /// <b>Also an hourly bookkeeping heartbeat while parked (review finding).</b> A worker parked by
    /// <see cref="EventDeliveryWorker"/>'s own <c>_targetKnownRevoked</c> (a 401/403) returns "nothing
    /// due" from every subsequent pass, so <see cref="DeliveryDrainScheduler"/> goes idle with no
    /// scheduled wake of its own. If capture then stops producing new events too -- nothing else ever
    /// calls <see cref="EventSpool.EvictExpired"/> again -- entries could in principle sit past
    /// <see cref="EventDeliverySettings.SpoolRetention"/> with their eviction never reported until an
    /// unrelated event is captured or the credential is refreshed. Nudging on every wait iteration
    /// here, not only at the very end, gives the drain loop a bounded (at most hourly) chance to run
    /// its bookkeeping regardless of capture activity, for as long as this exact target remains live.
    /// </remarks>
    private async Task ScheduleExpiryRefreshAsync(MvpDeliveryTarget target, CancellationToken cancellationToken)
    {
        TimeSpan maximumWait = TimeSpan.FromHours(1);
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                // Checked before the delay too, not only after (a review-suggested tightening): a
                // provisioning-file retry loop can start several of these watches in quick
                // succession for what turns out to be the same, unchanged bundle (RefreshDeliveryTarget
                // always mints a new MvpDeliveryTarget instance regardless), and each older one should
                // recognize it is already superseded on its very first chance to run rather than only
                // after its own first hour-long wait.
                if (!ReferenceEquals(Volatile.Read(ref _deliveryTarget), target))
                {
                    return;
                }

                TimeSpan remaining = target.ExpiresAt - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero)
                {
                    break;
                }

                await Task.Delay(remaining < maximumWait ? remaining : maximumWait, cancellationToken)
                    .ConfigureAwait(false);

                // The heartbeat nudge (see this method's own remarks): cheap and coalesced like every
                // other Nudge() call site, so there is no cost to doing this on every wait iteration.
                _eventDeliveryScheduler?.Nudge();
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }

        // Guarded explicitly rather than relying on the loop's own condition to have caught
        // shutdown (a review-found edge case): if the delay above happens to complete at the exact
        // instant _shutdown.Cancel() runs, the while condition could still read false and fall
        // through here during OnExit. Today that would still be harmless (Nudge short-circuits once
        // disposed, and _host is already null by the time this could run), but this makes it
        // intentional rather than merely accidental ordering.
        if (cancellationToken.IsCancellationRequested)
        {
            return;
        }

        if (ReferenceEquals(Volatile.Read(ref _deliveryTarget), target))
        {
            PushEventDeliveryStatus();
            _eventDeliveryScheduler?.Nudge();
        }
    }

    /// <summary>
    /// Rebuilds the Files transport and the capture-path preparer whenever the credential changes.
    /// This is the seam <see cref="RefreshDeliveryTarget"/> already exists for; screenshot delivery
    /// reuses it rather than inventing a second one. On any failure -- an invalid bundle, an
    /// unexpected exception -- this leaves the preparer's client null rather than let the exception
    /// escape: capture must never be blocked or stopped by a delivery credential problem. The
    /// published worker does not follow the preparer's client one-for-one, though: see the Finding 1
    /// remarks below on why a lapsed credential retains the previous worker instead.
    /// </summary>
    private void RefreshScreenshotDelivery(DeviceBundle? bundle)
    {
        ScreenshotStagingArea? staging = _screenshotStaging;
        if (staging is null || _settings is null)
        {
            // Startup ordering guard: never observed on the documented startup path (the staging
            // area and settings are both in place before the first RefreshDeliveryTarget call), but
            // a missing dependency must fail safe -- no client, no preparer -- rather than throw.
            return;
        }

        KeboolaFilesClient? client = null;
        DateTimeOffset expiresAt = DateTimeOffset.MinValue;
        try
        {
            DateTimeOffset now = DateTimeOffset.UtcNow;
            if (bundle is not null && Timestamps.TryParseRfc3339(bundle.ExpiresAt) is { } expiry && expiry > now)
            {
                client = new KeboolaFilesClient(bundle, _screenshotHttpClient, _settings.ScreenshotDelivery);
                expiresAt = expiry;
            }
        }
        catch { client = null; }

        // Finding 1 (#74 review, second pass): a lapsed or absent Storage credential must stop
        // new prepares only, not draining. KeboolaFilesClient.UploadAsync never sends
        // X-StorageApi-Token -- it PUTs to GCS with the short-lived federation bearer captured at
        // prepare time (see KeboolaFilesClient's own remarks) -- so a worker built around an
        // older client, whose Storage token has since expired, can still drain every entry
        // already staged until each entry's own bearer runs out. The only two routes on that
        // client that do send the Storage token, PrepareAsync and DeleteAsync, are reached
        // exclusively through ScreenshotDeliveryPreparer (see the fresh instance published just
        // below), never through the worker published here -- DrainScreenshotDeliveryAsync only
        // ever calls ScreenshotDeliveryWorker.DrainOnceAsync, which only ever calls UploadAsync
        // -- and the preparer re-checks expiresAt itself on every call, so it already stops
        // issuing new prepares the moment the credential lapses. There is therefore no path left
        // for the retained client's now-invalid token to ever reach the wire. Publish null only
        // when there has never been a worker at all: with nothing ever provisioned, nothing could
        // ever have been staged either, so there is nothing left to retain.
        ScreenshotDeliveryWorker? worker = client is not null
            ? new ScreenshotDeliveryWorker(client, staging, OnScreenshotDeliveryOutcome)
            : Volatile.Read(ref _screenshotWorker);
        Volatile.Write(ref _screenshotWorker, worker);
        // ScreenshotDeliveryPreparer.Prepare re-checks expiresAt against its own clock on every
        // call rather than trusting this snapshot indefinitely -- see its remarks -- so there is no
        // periodic refresh to add here even though this is the only place expiresAt is threaded in.
        Volatile.Write(
            ref _screenshotPreparer,
            new ScreenshotDeliveryPreparer(
                client, staging, _settings.ScreenshotDelivery, NudgeScreenshotDelivery, _shutdown.Token, expiresAt));
        PushScreenshotDeliveryStatus();

        // Defect B (#74 review): a credential that becomes usable again -- including the very
        // first successful provisioning -- must wake the scheduler so anything staged before the
        // outage retries promptly, rather than depending on some later screenshot's own nudge or
        // (per Defect A's fix) on a drain-loop backoff that may not even be running. Nudging
        // unconditionally whenever a worker now exists, rather than only on a null-to-non-null
        // transition, is deliberate: Nudge() is cheap, non-blocking, and nudges coalesce, so there
        // is no benefit to tracking the transition just to skip a redundant one. This also covers
        // the retained-worker case above: a credential that just lapsed still has a worker (the
        // retained one), and nudging it promptly drains whatever can still upload on its old
        // federation bearers rather than waiting for the scheduler's own idle backoff.
        if (worker is not null)
        {
            _screenshotDeliveryScheduler?.Nudge();
        }
    }

    /// <summary>Matches <see cref="EngineConfig.ScreenshotDeliveryPreparer"/>'s shape. Always reads
    /// the current preparer rather than closing over one built at capture-start time, so a
    /// credential that arrives (a new preparer published by <see cref="RefreshScreenshotDelivery"/>)
    /// or expires mid-capture (the same preparer's own live clock check in
    /// <see cref="ScreenshotDeliveryPreparer.Prepare"/>) takes effect on the very next
    /// screenshot.</summary>
    /// <remarks>
    /// Finding 2 (#74 review, second pass): a declined prepare -- most commonly a credential that
    /// expired mid-session -- used to leave the tray showing whatever it last rendered, often "up to
    /// date", indefinitely: nothing else calls <see cref="PushScreenshotDeliveryStatus"/> on this
    /// path, only <see cref="NudgeScreenshotDelivery"/> after a *successful* stage. This method now
    /// pushes on every decline too, but through <see cref="DeliveryStatusPublisher{T}.PushIfChanged(T)"/>
    /// rather than an unconditional push, since this runs on the capture path and a screenshot-bearing
    /// observation can occur once per click -- see that type's own remarks. This method runs inside
    /// the capture engine's own lock (<c>CaptureEngine.ObserveWithArtifact</c>), so every failure here
    /// is swallowed exactly like every other delivery side effect on this path: capture must never be
    /// blocked or stopped by a tray refresh.
    /// </remarks>
    private string? PrepareScreenshotDelivery(ArtifactDeliveryDescriptor descriptor)
    {
        string? filesId = Volatile.Read(ref _screenshotPreparer)?.Prepare(descriptor);
        if (filesId is null)
        {
            try { PushScreenshotDeliveryStatusIfChanged(); }
            catch { /* capture must never be blocked or stopped by a delivery status push */ }
        }

        return filesId;
    }

    /// <summary>The scheduler's stable drain delegate. Reads the current worker fresh on every call
    /// -- exactly the same Volatile-read pattern as <see cref="DeliverCapturedEventAsync"/> -- so a
    /// credential that disappears between one drain pass and the next simply pauses draining
    /// (nothing to upload to) rather than throwing. Returns <see langword="null"/> ("nothing due")
    /// when there is no worker, matching <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/>'s own
    /// "nothing staged" result rather than a zero delay that would spin the scheduler.</summary>
    private Task<TimeSpan?> DrainScreenshotDeliveryAsync(CancellationToken cancellationToken)
    {
        ScreenshotDeliveryWorker? worker = Volatile.Read(ref _screenshotWorker);
        return worker is null ? Task.FromResult<TimeSpan?>(null) : worker.DrainOnceAsync(cancellationToken);
    }

    /// <summary>Wakes the background uploader after a successful stage, and refreshes the tray line
    /// so a newly staged screenshot is reflected without waiting for its first drain outcome.</summary>
    private void NudgeScreenshotDelivery()
    {
        _screenshotDeliveryScheduler?.Nudge();
        PushScreenshotDeliveryStatus();
    }

    /// <summary>Folds one drain-pass outcome into the session's running tally and refreshes the tray
    /// line. Runs on the background delivery worker's own task, not the UI thread; <see
    /// cref="TrayHost.SetScreenshotDeliveryStatus"/> marshals onward exactly as
    /// <see cref="TrayHost.SetStreamingStatus"/> already does for arbitrary caller threads.</summary>
    private void OnScreenshotDeliveryOutcome(ScreenshotDeliveryOutcomeEvent outcome)
    {
        _screenshotDeliveryTracker.OnOutcome(outcome);
        PushScreenshotDeliveryStatus();
    }

    /// <summary>Unconditional refresh, used by every call site driven by a real state transition
    /// (a credential refresh, a successful stage, a drain outcome) rather than a per-click hot
    /// path -- see <see cref="DeliveryStatusPublisher{T}"/>'s own remarks for why those do
    /// not need <see cref="PushScreenshotDeliveryStatusIfChanged"/>'s coalescing.</summary>
    private void PushScreenshotDeliveryStatus()
    {
        if (ResolveScreenshotDeliveryPresentation() is { } presentation)
        {
            _screenshotStatusPublisher.Push(presentation);
        }
    }

    /// <summary>Coalescing refresh for <see cref="PrepareScreenshotDelivery"/>'s declined-prepare
    /// path (Finding 2, #74 review, second pass): pushes only when the projected presentation
    /// differs from whatever was last pushed by either this method or <see cref="PushScreenshotDeliveryStatus"/>.
    /// See <see cref="DeliveryStatusPublisher{T}"/> for why that single shared baseline can
    /// never go stale.</summary>
    private void PushScreenshotDeliveryStatusIfChanged()
    {
        if (ResolveScreenshotDeliveryPresentation() is { } presentation)
        {
            _screenshotStatusPublisher.PushIfChanged(presentation);
        }
    }

    private ScreenshotDeliveryPresentation? ResolveScreenshotDeliveryPresentation()
    {
        ScreenshotStagingArea? staging = _screenshotStaging;
        if (staging is null)
        {
            return null;
        }

        // Read live from the preparer rather than a snapshot bool cached at the last
        // RefreshScreenshotDelivery: ScreenshotDeliveryPreparer.IsUsable re-checks the credential's
        // expiry against the current clock, so an expired Storage token stops reading as
        // "provisioned" the next time anything pushes a status update, without a polling timer
        // (Defect C, #74 review).
        bool provisioned = Volatile.Read(ref _screenshotPreparer)?.IsUsable ?? false;
        int pending = staging.Status.PendingCount;
        return _screenshotDeliveryTracker.Resolve(provisioned, pending);
    }

    /// <summary>The scheduler's stable drain delegate for events. Reads the current worker fresh on
    /// every call -- exactly the same Volatile-read pattern as <see cref="DrainScreenshotDeliveryAsync"/>
    /// -- so a spool that disappears (it cannot, once constructed, but the pattern matches) simply
    /// pauses draining rather than throwing. Returns <see langword="null"/> ("nothing due") when
    /// there is no worker, matching <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/>'s own
    /// "nothing staged" result. The worker's own <see cref="IsDeliveryTargetUsable"/> check is what
    /// parks the pass -- without ever touching the spool -- when there is no usable target right
    /// now.</summary>
    /// <remarks>
    /// <b>Refreshes the tray after every pass, not only through a per-key outcome (review findings:
    /// a live target-usability check that flips with nothing to report).</b> A credential expiring
    /// between drain passes, or a pass parking because no usable target exists, can occur with
    /// nothing in <see cref="EventSpool"/>'s two pending lists to drain and no send outcome to
    /// report that pass -- <see cref="OnEventDeliveryOutcome"/> is then never called at all, and
    /// without this the tray could keep showing a stale <c>sending N</c>/<c>retrying N</c>
    /// indefinitely, since <see cref="RefreshDeliveryTarget"/> only runs on an actual provisioning
    /// change, not on a timer. This scheduler tick is exactly the seam <see cref="DeliveryDrainScheduler"/>
    /// already calls on every pass, due or backoff-driven, so pushing here catches that transition
    /// without a new per-item outcome type or a polling timer of its own; <see cref="ResolveEventDeliveryPresentation"/>
    /// re-reads the delivery target and the spool live, so this is always current as of the moment
    /// it runs. This call is now this pass's <em>only</em> tray push -- see
    /// <see cref="OnEventDeliveryOutcome"/>'s own remarks on why an unconditional per-outcome push was
    /// removed from there (a review finding: it could marshal one dispatcher operation per event in
    /// an eviction or refusal burst) -- so this one call also carries that responsibility for a pass
    /// with outcomes, not only for the outcome-free transitions this remark was originally about.
    /// </remarks>
    /// <remarks>
    /// <b><see cref="PushEventDeliveryStatusIfChanged"/>, not an unconditional push (fix for a
    /// regression the fix above introduced, found in review).</b> <see cref="SendCapturedEventAsync"/>
    /// nudges the scheduler unconditionally on every captured event (R12's own comment there), and
    /// while the scheduler is idle -- exactly the unprovisioned case, the ordinary one #53 scope 4
    /// describes -- a nudge starts a brand new pass immediately. An unconditional push here would
    /// therefore marshal a <c>TrayHost.RefreshStatus</c> call, which does its own filesystem I/O, once
    /// per captured event on such a machine: precisely the per-keystroke cost R12 exists to avoid,
    /// reintroduced one level removed. Coalescing through the shared baseline still pushes on every
    /// *actual* transition (an expiry, a park, a resume), which is the only thing this fix needs.
    /// </remarks>
    private async Task<TimeSpan?> DrainEventDeliveryAsync(CancellationToken cancellationToken)
    {
        EventDeliveryWorker? worker = Volatile.Read(ref _eventWorker);
        if (worker is null)
        {
            return null;
        }

        TimeSpan? next = await worker.DrainOnceAsync(cancellationToken).ConfigureAwait(false);
        PushEventDeliveryStatusIfChanged();
        return next;
    }

    /// <summary>Live re-check of the current delivery target's existence and expiry, passed to
    /// <see cref="EventDeliveryWorker"/> as its <c>isTargetUsable</c> delegate. An expired or revoked
    /// credential must stop networking without deleting evidence (#48 plan §2.4, §4): checking this
    /// fresh on every drain pass, rather than only when <see cref="RefreshDeliveryTarget"/> last ran,
    /// is what makes that live.</summary>
    private bool IsDeliveryTargetUsable() =>
        Volatile.Read(ref _deliveryTarget) is { } target && target.ExpiresAt > DateTimeOffset.UtcNow;

    /// <summary>
    /// Folds one drain-pass outcome into the session's running sticky tally. Runs on the background
    /// delivery worker's own task, not the UI thread, once per outcome <c>EventDeliveryWorker.Report</c>
    /// raises -- which, for one <see cref="EventDeliveryWorker.DrainOnceAsync"/> pass, can be every
    /// entry in a large eviction or refusal burst, not just one.
    /// </summary>
    /// <remarks>
    /// <b>Deliberately does not push the tray itself (fix for a review finding, otherwise real).</b>
    /// This used to call <see cref="PushEventDeliveryStatus"/> -- an unconditional push -- after every
    /// single call, and <see cref="TrayHost.SetStreamingStatus"/> marshals onward via
    /// <c>BeginInvoke</c>, which returns to its caller (this method, by way of
    /// <c>EventDeliveryWorker.Report</c>) before the marshaled action has actually run on the UI
    /// thread. Because <see cref="EventDeliveryWorker.DrainOnceAsync"/> calls
    /// <c>EventDeliveryWorker.Report</c> synchronously and sequentially for every evicted, refused, or
    /// terminally-classified entry in one pass, that unconditional push queued one dispatcher
    /// operation per event -- and at the amended 32 MiB / 48 hour bounds, an eviction or refusal burst
    /// on an unprovisioned machine is the *ordinary* case (see
    /// <see cref="EventDeliveryPresentationTracker"/>'s own remarks), not a rare edge case, so this
    /// could grow or starve the dispatcher queue during exactly the condition this issue's bounds are
    /// sized for. Only <see cref="_eventDeliveryTracker"/>'s in-memory tally -- which must count every
    /// one of those outcomes for the sticky <c>N undelivered</c> line to be correct -- is updated here;
    /// <see cref="DrainEventDeliveryAsync"/> already calls <see cref="PushEventDeliveryStatusIfChanged"/>
    /// exactly once after <see cref="EventDeliveryWorker.DrainOnceAsync"/> returns, which reads the
    /// tally *after* every outcome of the pass has already been folded into it here, so the tray still
    /// reflects the pass's final state -- just as one coalesced refresh instead of one per event.
    /// </remarks>
    private void OnEventDeliveryOutcome(EventDeliveryOutcomeEvent outcome) =>
        _eventDeliveryTracker.OnOutcome(outcome);

    /// <summary>Unconditional refresh, used by every call site driven by a real state transition (a
    /// credential refresh, a drain outcome) rather than a per-event hot path -- see
    /// <see cref="PushEventDeliveryStatusIfChanged"/> for the capture-path coalescing counterpart.</summary>
    private void PushEventDeliveryStatus() => _eventStatusPublisher.Push(ResolveEventDeliveryPresentation());

    /// <summary>Coalescing refresh for <see cref="SendCapturedEventAsync"/>'s own failure paths (a
    /// refusal, or an unavailable spool) -- both of which can occur once per captured event, so this
    /// pushes only when the projected presentation differs from whatever was last pushed by either
    /// this method or <see cref="PushEventDeliveryStatus"/>. See <see cref="DeliveryStatusPublisher{T}"/>
    /// for why that single shared baseline can never go stale.</summary>
    private void PushEventDeliveryStatusIfChanged() => _eventStatusPublisher.PushIfChanged(ResolveEventDeliveryPresentation());

    /// <summary>
    /// Resolves the current tray presentation for event delivery. Returns
    /// <see cref="EventDeliveryPresentationState.Unavailable"/> when the spool itself could not be
    /// constructed -- deliberately distinguishable, unlike the identical screenshot staging failure
    /// mode (see <see cref="OnStartup"/>'s own remarks, at both the staging and the spool
    /// construction sites, on why those two are treated differently): a null event spool means
    /// events are produced and discarded, the exact condition issue #48 exists to make impossible to
    /// hide.
    /// </summary>
    private EventDeliveryPresentation ResolveEventDeliveryPresentation()
    {
        EventSpool? spool = Volatile.Read(ref _eventSpool);
        if (spool is null)
        {
            return new EventDeliveryPresentation(EventDeliveryPresentationState.Unavailable, 0);
        }

        // Read the target live, exactly like ResolveScreenshotDeliveryPresentation reads the
        // preparer's IsUsable live, so an expired credential stops reading as provisioned the next
        // time anything pushes a status update, without a polling timer.
        MvpDeliveryTarget? target = Volatile.Read(ref _deliveryTarget);
        bool provisioned = target is not null && target.ExpiresAt > DateTimeOffset.UtcNow;
        return _eventDeliveryTracker.Resolve(provisioned, spool.Status.PendingCount, spool.AnyRetrying);
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

        // TrayHost replaces its own _settings in place on every preference change -- OpenSettings
        // (TrayHost.cs:428), the stop-pause transition (:298), the manual-start resume (:570, both
        // through :583), and the standalone screenshots/narration toggles (:611, :651) -- while
        // this._settings is frozen once at line 103 and never updated again. This window renders
        // both the capture-at-launch preference those first three change and the Modalities line
        // the last two change, so reading the frozen snapshot would make either one lie the moment
        // a user has touched any of them. Every one of those paths and this method run on the WPF
        // UI thread, so there is no race here.
        Settings settings = _host?.CurrentSettings ?? _settings ?? new Settings();
        // #76 (plan R3): this window must see the same effective value CaptureStartupGate saw,
        // not the raw persisted settings pair -- otherwise a switch-started launch renders "does
        // not start by itself" while it is recording, reintroducing exactly the defect #75 closed.
        // TrayHost.CurrentCaptureAtLaunch recomputes from its own live _settings plus the launch
        // switch fixed at construction; falling back to a fresh Resolve with no switch matches
        // this method's own pre-existing "no host yet" fallback above.
        EffectiveCaptureAtLaunch captureAtLaunch = _host?.CurrentCaptureAtLaunch
            ?? EffectiveCaptureAtLaunch.Resolve(settings.Persisted, launchSwitchPresent: false);
        if (_statusWindow is null || !_statusWindow.IsLoaded)
        {
            _statusWindow = new OnboardingWindow(_startupState.Acknowledge, settings, captureAtLaunch);
            _statusWindow.Closed += (_, _) => _statusWindow = null;
            _statusWindow.Show();
        }
        else
        {
            // The window is modeless (Show, not ShowDialog): a user can leave it open and then
            // change the capture-at-launch checkbox in Settings, or stop/start a capture, before
            // opening it again from the tray or via second-instance activation. Without
            // re-resolving here, IsLoaded is already true and this method would fall straight
            // through to Activate(), leaving the window showing whatever was true when it was
            // first constructed. This makes every ShowStatus() call current as of the moment it
            // runs; it deliberately does not push updates into a window that is already the
            // frontmost, visible one and is never reopened -- doing that would mean wiring a
            // settings-changed callback out of TrayHost, which the plan scopes this change away
            // from ("No other TrayHost change" beyond CurrentSettings), and would be the same kind
            // of continuously-live line the plan's own non-goals already declined to add here.
            // That gap is the qualification pass's to catch, not this accessor's.
            _statusWindow.Refresh(settings, captureAtLaunch);
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
                // forceRebuild: a person pasting a credential by hand is an explicit "try again now"
                // signal -- see RefreshDeliveryTarget's own remarks on why the automatic comparison
                // must not be allowed to second-guess it.
                RefreshDeliveryTarget(forceRebuild: true);
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
    /// <remarks>
    /// <b>No event drain at shutdown, deliberately (§48 plan §3.6(h)).</b> Every spooled event's
    /// bytes are already durable by the time <see cref="SendCapturedEventAsync"/> returned, so there
    /// is nothing to flush here -- unlike a confirmed-archive delivery, which has no equivalent
    /// durability guarantee before shutdown. Shutdown is therefore strictly faster than before this
    /// change, and neither <c>OrderlyCaptureCompletion.TryCommit</c> nor
    /// <c>MaintenanceCaptureSession</c> needs to know this spool exists.
    /// </remarks>
    protected override void OnExit(ExitEventArgs e)
    {
        // Cancelled first, and before anything else below: ScreenshotDeliveryPreparer checks this
        // token up front and returns null immediately once it is set, so no new screenshot is
        // prepared or staged once shutdown has begun.
        _shutdown.Cancel();

        // Disposing each scheduler cancels its own drain-loop token and joins whatever drain pass is
        // currently in flight before returning. That must happen, and complete, before either
        // transport is disposed further down -- otherwise a send already in flight could hit a
        // disposed transport instead of observing cancellation cleanly.
        _screenshotDeliveryScheduler?.Dispose();
        _screenshotDeliveryScheduler = null;
        _eventDeliveryScheduler?.Dispose();
        _eventDeliveryScheduler = null;

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
        // Safe now: both schedulers above have already joined any drain pass that was in flight, so
        // nothing can still be calling through either transport.
        _screenshotHttpClient.Dispose();
        _streamHttpClient.Dispose();
        base.OnExit(e);
    }
}
