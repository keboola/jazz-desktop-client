using System.Threading;
using System.Threading.Channels;
using JazzCaptureCore;
using JazzCaptureCore.Input;
using JazzCapture.Interop;
using Timer = System.Threading.Timer;

namespace JazzCapture.Capture;

/// <summary>
/// The single-threaded pipeline that turns raw hook samples into the host events the
/// <see cref="CaptureEngine"/> admits. Every sample the hooks and the foreground tracker publish is
/// funnelled onto one worker so ordering is deterministic and the engine's own lock is never
/// contended (ANNEX-HOST sections 1, 2, 3 and 7).
/// </summary>
/// <remarks>
/// <para>
/// Pointer handling is two-phase: a release is classified into a drag (emitted at once, anchored to
/// the release point) or a click that is deferred for the system double-click window so a
/// double- or triple-click coalesces into one gesture. A right-click, a scroll, any key, an
/// application switch, a click that starts a new sequence, and Stop all flush the pending click
/// first, so nothing the user did is dropped and no later event overtakes an earlier click in the
/// stream.
/// </para>
/// <para>
/// A pointer event over the capture client's own window is not retained, but it is not silent
/// either: it consumes a stream position and resolves to a gap with the
/// <see cref="CaptureGapDetails.DesktopClientUi"/> detail, matching the macOS client.
/// </para>
/// <para>
/// Typed characters accumulate in a per-field buffer and flush to one redacted <c>input</c> event at a
/// boundary; named keys and chords become <c>keydown</c> events; Ctrl+C/X/V are intercepted ahead of
/// classification and become first-class clipboard events. This is the MVP subset: no screenshots, no
/// narration, no click-highlight overlay, and scroll is throttled.
/// </para>
/// </remarks>
public sealed class CaptureCoordinator : IDisposable
{
    private readonly CaptureEngine _engine;
    private readonly Settings _settings;
    private readonly UiaResolver _uia;
    private readonly AppIdentityResolver _identity;
    private readonly Func<DateTimeOffset> _clock;
    private readonly PointerGestureTracker _gesture;
    private readonly TypingBuffer _typing;

    private readonly Channel<object> _channel = Channel.CreateUnbounded<object>(
        new UnboundedChannelOptions { SingleReader = true });

    private readonly Timer _clickTimer;

    private Task? _worker;
    private PendingClick? _pendingClick;
    private DateTimeOffset _lastScrollAt = DateTimeOffset.MinValue;

    private AppIdentity? _typingApplication;
    private string? _typingSystem;
    private DateTimeOffset _typingStartedAt;
    private int _lastDownX;
    private int _lastDownY;

    /// <summary>Creates the coordinator around a started engine and the resolvers it draws on.</summary>
    public CaptureCoordinator(
        CaptureEngine engine,
        Settings settings,
        UiaResolver uia,
        AppIdentityResolver identity,
        Func<DateTimeOffset> clock,
        GestureMetrics metrics)
    {
        _engine = engine ?? throw new ArgumentNullException(nameof(engine));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _uia = uia ?? throw new ArgumentNullException(nameof(uia));
        _identity = identity ?? throw new ArgumentNullException(nameof(identity));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _gesture = new PointerGestureTracker(metrics);
        _typing = new TypingBuffer(settings.MaxClipboardChars);
        _clickTimer = new Timer(_ => _channel.Writer.TryWrite(ClickFlushTick.Instance));
    }

    /// <summary>Starts the pipeline worker.</summary>
    public void Start() => _worker ??= Task.Run(ProcessLoopAsync);

    /// <summary>Enqueues a raw mouse sample. Called from the hook thread; only enqueues.</summary>
    public void SubmitMouse(MouseSample sample)
    {
        if (sample.Message != NativeMethods.WM_MOUSEMOVE)
        {
            _channel.Writer.TryWrite(sample);
        }
    }

    /// <summary>Enqueues a raw keyboard sample. Called from the hook thread; only enqueues.</summary>
    public void SubmitKey(KeySample sample) => _channel.Writer.TryWrite(sample);

    /// <summary>Enqueues a foreground switch. Called from the UI thread's pump; only enqueues.</summary>
    public void SubmitForeground(IntPtr hwnd) =>
        _channel.Writer.TryWrite(new ForegroundSample(hwnd, 0));

    /// <summary>
    /// Raised on the worker thread once a label boundary has reached the engine, so the tray can
    /// show what is open. The submission is asynchronous, so the menu cannot simply assume.
    /// </summary>
    public event Action? LabelChanged;

    /// <summary>
    /// Enqueues a label declaration. It travels the same queue as the input samples rather than
    /// going straight to the engine: a click still waiting out its double-click window physically
    /// happened before the user declared anything, so it has to reach the stream first and stay
    /// outside the new segment.
    /// </summary>
    /// <param name="text">The declared task name.</param>
    public void SubmitLabelStart(string text) => _channel.Writer.TryWrite(new LabelBoundary(text));

    /// <summary>Enqueues the close of the open label, ordered against pending gestures like a start.</summary>
    public void SubmitLabelEnd() => _channel.Writer.TryWrite(new LabelBoundary(null));

    /// <summary>Reduces one capability sample through the engine, while it is still recording.</summary>
    public void EmitCapability(CapabilitySample sample)
    {
        if (_engine.State == EngineState.Recording)
        {
            try
            {
                _engine.ObserveCapability(sample);
            }
            catch (InvalidOperationException)
            {
                // The engine left the recording state between the check and the call; drop the poll.
            }
        }
    }

    /// <summary>
    /// Flushes any pending typing and click, stops the worker, and returns once the pipeline is
    /// drained. The caller commits the engine afterwards.
    /// </summary>
    public void DrainAndStop()
    {
        if (_worker is null)
        {
            return;
        }

        _channel.Writer.TryWrite(DrainTick.Instance);
        _channel.Writer.Complete();
        try
        {
            _worker.Wait(TimeSpan.FromSeconds(5));
        }
        catch (AggregateException)
        {
            // A faulted worker still leaves the engine in a committable state.
        }

        _worker = null;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        _clickTimer.Dispose();
    }

    private async Task ProcessLoopAsync()
    {
        try
        {
            await foreach (object message in _channel.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                Dispatch(message);
            }
        }
        catch (ChannelClosedException)
        {
            // Normal shutdown.
        }

        // Drain whatever the user left mid-gesture before the engine commits.
        FlushPendingClick();
        FlushTyping();
    }

    private void Dispatch(object message)
    {
        switch (message)
        {
            case MouseSample mouse:
                HandleMouse(mouse);
                break;
            case KeySample key:
                HandleKey(key);
                break;
            case ForegroundSample foreground:
                HandleForeground(foreground.WindowHandle);
                break;
            case LabelBoundary boundary:
                HandleLabelBoundary(boundary);
                break;
            case ClickFlushTick:
                FlushPendingClick();
                break;
            case DrainTick:
                FlushPendingClick();
                FlushTyping();
                break;
        }
    }

    // --- Labels -------------------------------------------------------------------------------

    /// <summary>
    /// Applies one label boundary to the engine, in the stream position the user declared it at.
    /// </summary>
    /// <remarks>
    /// The flushes come first for the same reason a right-click flushes: a completed click and a
    /// typing run both physically preceded the declaration, so they belong to whatever came before
    /// the boundary rather than being swept into a segment the user had not opened yet.
    /// </remarks>
    private void HandleLabelBoundary(LabelBoundary boundary)
    {
        FlushPendingClick();
        FlushTyping();

        try
        {
            if (boundary.Text is { } text)
            {
                _engine.StartLabel(text);
            }
            else
            {
                _engine.EndLabel();
            }
        }
        catch (InvalidOperationException)
        {
            // The engine stopped recording between the submission and the boundary; drop it.
        }
        catch (ArgumentException)
        {
            // Nothing survives sanitization, so there is no declaration to record.
        }

        LabelChanged?.Invoke();
    }

    // --- Pointer ------------------------------------------------------------------------------

    private void HandleMouse(MouseSample sample)
    {
        switch (sample.Message)
        {
            case NativeMethods.WM_LBUTTONDOWN:
                _lastDownX = sample.X;
                _lastDownY = sample.Y;
                _gesture.OnDown(sample.X, sample.Y);
                FlushTyping();
                break;

            case NativeMethods.WM_LBUTTONUP:
                HandleLeftUp(sample);
                break;

            case NativeMethods.WM_RBUTTONUP:
                FlushPendingClick();
                FlushTyping();
                EmitContextMenu(sample);
                break;

            case NativeMethods.WM_MOUSEWHEEL:
                HandleScroll(sample);
                break;
        }
    }

    private void HandleLeftUp(MouseSample sample)
    {
        PointerRelease release = _gesture.OnUp(sample.X, sample.Y, sample.TimeMs);
        DateTimeOffset occurredAt = _clock();

        if (release.IsDrag)
        {
            FlushPendingClick();
            FlushTyping();
            EmitDrag(sample, release.ClickCount, occurredAt);
            return;
        }

        // A continued sequence (ClickCount > 1) updates the deferred click in place. A release that
        // starts a fresh sequence displaces it instead, so the click already waiting has to reach
        // the stream first — overwriting it would drop the gesture entirely, and not even leave a
        // gap. The tracker has already recorded this release as the head of the new sequence, so
        // this one flush must not reset it.
        if (_pendingClick is not null && release.ClickCount == 1)
        {
            FlushPendingClick(resetSequence: false);
        }

        if (!TryResolvePoint(_lastDownX, _lastDownY, out TargetFields fields))
        {
            return; // Over our own window; TryResolvePoint recorded the gap.
        }

        _pendingClick = new PendingClick(fields, release.ClickCount, occurredAt);
        _clickTimer.Change((int)_gesture.DoubleClickBudget(), Timeout.Infinite);
    }

    private void EmitContextMenu(MouseSample sample)
    {
        if (!TryResolvePoint(sample.X, sample.Y, out TargetFields fields))
        {
            return;
        }

        Observe(new ContextMenuEvent
        {
            OccurredAt = _clock(),
            Application = fields.Application,
            System = fields.System,
            TargetRole = fields.Role,
            TargetAccessibleName = fields.Name,
            TargetText = fields.Text,
            TargetBoundingBox = fields.Bounds,
            PageTitle = fields.PageTitle,
            DocumentUrl = fields.DocumentUrl,
            IsSensitive = fields.Sensitive,
            ClickCount = 1,
        });
    }

    private void EmitDrag(MouseSample sample, int clickCount, DateTimeOffset occurredAt)
    {
        if (!TryResolvePoint(_lastDownX, _lastDownY, out TargetFields fields))
        {
            return;
        }

        Observe(new DragEvent
        {
            OccurredAt = occurredAt,
            Application = fields.Application,
            System = fields.System,
            TargetRole = fields.Role,
            TargetAccessibleName = fields.Name,
            TargetText = fields.Text,
            TargetBoundingBox = fields.Bounds,
            PageTitle = fields.PageTitle,
            DocumentUrl = fields.DocumentUrl,
            IsSensitive = fields.Sensitive,
            ClickCount = clickCount,
            DragEndX = sample.X,
            DragEndY = sample.Y,
        });
    }

    private void HandleScroll(MouseSample sample)
    {
        DateTimeOffset now = _clock();
        if (now - _lastScrollAt < _settings.ScrollThrottle)
        {
            return;
        }

        FlushPendingClick();
        FlushTyping();
        if (!TryResolvePoint(sample.X, sample.Y, out TargetFields fields))
        {
            return;
        }

        _lastScrollAt = now;
        Observe(new ScrollEvent
        {
            OccurredAt = now,
            Application = fields.Application,
            System = fields.System,
            TargetRole = fields.Role,
            TargetAccessibleName = fields.Name,
            TargetText = fields.Text,
            TargetBoundingBox = fields.Bounds,
            PageTitle = fields.PageTitle,
            DocumentUrl = fields.DocumentUrl,
            IsSensitive = fields.Sensitive,
        });
    }

    /// <summary>
    /// Publishes the deferred click, if there is one, and forgets the multiplicity sequence so the
    /// next press starts fresh. A no-op when nothing is pending, which is what lets every boundary
    /// call it unconditionally.
    /// </summary>
    private void FlushPendingClick() => FlushPendingClick(resetSequence: true);

    /// <param name="resetSequence">
    /// False only when the flush was triggered by a release the tracker has already accepted as the
    /// head of a new sequence; resetting there would lose the multiplicity of the click after it.
    /// </param>
    private void FlushPendingClick(bool resetSequence)
    {
        if (_pendingClick is not { } pending)
        {
            return;
        }

        _pendingClick = null;
        _clickTimer.Change(Timeout.Infinite, Timeout.Infinite);
        if (resetSequence)
        {
            _gesture.ResetSequence();
        }

        Observe(new ClickEvent
        {
            OccurredAt = pending.OccurredAt,
            Application = pending.Fields.Application,
            System = pending.Fields.System,
            TargetRole = pending.Fields.Role,
            TargetAccessibleName = pending.Fields.Name,
            TargetText = pending.Fields.Text,
            TargetBoundingBox = pending.Fields.Bounds,
            PageTitle = pending.Fields.PageTitle,
            DocumentUrl = pending.Fields.DocumentUrl,
            IsSensitive = pending.Fields.Sensitive,
            ClickCount = pending.ClickCount,
        });
    }

    // --- Keyboard -----------------------------------------------------------------------------

    private void HandleKey(KeySample sample)
    {
        KeyAction action = KeyClassifier.Classify(
            sample.VirtualKey,
            sample.Characters,
            sample.Ctrl,
            sample.Alt,
            sample.Shift,
            sample.Win);

        // A key this build does not model produces no observation, so it must not disturb the
        // deferred click. Flushing here would split a double-click whenever a modifier goes down
        // between its two halves.
        if (action.Kind == KeyActionKind.Ignored)
        {
            return;
        }

        // Any key that does emit ends the deferred click: the click happened first, so it has to
        // occupy the lower stream position. This runs ahead of every branch below, including the
        // ones that only buffer, because the click is already older than the key that displaced it.
        FlushPendingClick();

        // Ctrl+C / Ctrl+X / Ctrl+V are clipboard events, intercepted ahead of the shortcut branch.
        if (sample.Ctrl && !sample.Alt && !sample.Win)
        {
            switch (sample.VirtualKey)
            {
                case NativeMethods.VK_C:
                    EmitClipboard(isPaste: false, cut: false);
                    return;
                case NativeMethods.VK_X:
                    EmitClipboard(isPaste: false, cut: true);
                    return;
                case NativeMethods.VK_V:
                    EmitClipboard(isPaste: true, cut: false);
                    return;
            }
        }

        switch (action.Kind)
        {
            case KeyActionKind.Text:
                AppendText(action.Value!);
                break;
            case KeyActionKind.Backspace:
                if (_typing.IsEmpty)
                {
                    EmitKeydown("Backspace");
                }
                else
                {
                    _typing.Backspace();
                }

                break;
            case KeyActionKind.WordBackspace:
                if (_typing.IsEmpty)
                {
                    EmitKeydown("Alt+Backspace");
                }
                else
                {
                    _typing.WordBackspace();
                }

                break;
            case KeyActionKind.Special:
                FlushTyping();
                EmitKeydown(action.Value!);
                break;
            case KeyActionKind.Shortcut:
                FlushTyping();
                EmitKeydown(action.Value!);
                break;
            case KeyActionKind.Ignored:
            default:
                break;
        }
    }

    private void AppendText(string characters)
    {
        if (_typing.IsEmpty)
        {
            BeginTypingRun();
        }

        // A sensitive field never accumulates content: flush what came before and drop the key.
        if (_typing.IsSensitive)
        {
            FlushTyping();
            return;
        }

        _typing.Append(characters);
    }

    private void BeginTypingRun()
    {
        UiaTarget? focus = _uia.ResolveFocused();
        AppIdentity? application = focus is not null
            ? _identity.ResolveByProcess(focus.ProcessId) ?? ForegroundIdentity()
            : ForegroundIdentity();

        string? name = focus?.Name ?? focus?.HelpText;
        bool sensitive = focus is not null && SensitivityClassifier.IsSensitive(focus.IsPassword, name);
        _typing.BeginRun(focus?.Role, name, FocusKey(focus), sensitive);
        _typingApplication = application;
        _typingSystem = application?.Name;
        _typingStartedAt = _clock();
    }

    private void FlushTyping()
    {
        if (_typing.IsEmpty)
        {
            return;
        }

        UiaTarget? focus = _uia.ResolveFocused();
        string raw = _typing.Flush(focus?.Value, FocusKey(focus));
        string? role = _typing.TargetRole;
        string? name = _typing.TargetName;
        bool sensitive = _typing.IsSensitive;
        _typing.Reset();

        Observe(new InputEvent
        {
            OccurredAt = _typingStartedAt,
            Application = _typingApplication,
            System = _typingSystem,
            RawText = raw,
            TargetRole = role,
            TargetAccessibleName = name,
            FieldIsSensitive = sensitive,
        });
    }

    private void EmitKeydown(string combo)
    {
        AppIdentity? application = ForegroundIdentity();
        Observe(new KeydownEvent
        {
            OccurredAt = _clock(),
            Application = application,
            System = application?.Name,
            ComboName = combo,
        });
    }

    private void EmitClipboard(bool isPaste, bool cut)
    {
        // The pending click is already flushed: HandleKey, the only caller, does it for every key.
        FlushTyping();

        UiaTarget? focus = _uia.ResolveFocused();
        AppIdentity? application = focus is not null
            ? _identity.ResolveByProcess(focus.ProcessId) ?? ForegroundIdentity()
            : ForegroundIdentity();
        string? name = focus?.Name ?? focus?.HelpText;
        bool sensitive = focus is not null && SensitivityClassifier.IsSensitive(focus.IsPassword, name);
        DateTimeOffset now = _clock();

        if (isPaste)
        {
            Observe(new PasteEvent
            {
                OccurredAt = now,
                Application = application,
                System = application?.Name,
                TargetRole = focus?.Role,
                TargetAccessibleName = name,
                TargetText = focus?.Value,
                TargetBoundingBox = focus?.Bounds,
                IsSensitive = sensitive,
                ClipboardText = sensitive ? null : ReadClipboardText(_settings.MaxClipboardChars),
            });
            return;
        }

        TargetedHostEvent copyOrCut = cut
            ? new CutEvent()
            : new CopyEvent();

        copyOrCut = copyOrCut with
        {
            OccurredAt = now,
            Application = application,
            System = application?.Name,
            TargetRole = focus?.Role,
            TargetAccessibleName = name,
            TargetText = focus?.Value,
            TargetBoundingBox = focus?.Bounds,
            IsSensitive = sensitive,
        };

        Observe(copyOrCut);
    }

    // --- Foreground ---------------------------------------------------------------------------

    private void HandleForeground(IntPtr hwnd)
    {
        if (_identity.IsOwnWindow(hwnd))
        {
            return;
        }

        // An application switch closes both open gestures, in the order they happened.
        FlushPendingClick();
        FlushTyping();
        AppIdentity? application = _identity.Resolve(hwnd);
        if (application is null)
        {
            return;
        }

        Observe(new NavigateEvent
        {
            OccurredAt = _clock(),
            Application = application,
            System = application.Name,
        });
    }

    // --- Shared -------------------------------------------------------------------------------

    private bool TryResolvePoint(int x, int y, out TargetFields fields)
    {
        UiaResolution resolution = _uia.ResolveAt(x, y);
        if (resolution.Status == UiaStatus.OwnWindow)
        {
            // Our own UI is never captured, but the interaction still happened: it becomes an
            // explicit gap so the stream says "omitted on purpose" instead of saying nothing.
            ObserveOwnWindowInteraction();
            fields = default;
            return false;
        }

        if (resolution is { Status: UiaStatus.Resolved, Target: { } target })
        {
            AppIdentity? application = _identity.ResolveByProcess(target.ProcessId) ?? ForegroundIdentity();
            string? name = target.Name ?? target.HelpText;
            bool sensitive = SensitivityClassifier.IsSensitive(target.IsPassword, name);
            BoundingBox? bounds = CanonicalizeBounds(target, x, y);
            // The window title is the context that tells a reader which page or document the
            // click landed on. Without it a recorded button name floats free of where it was.
            string? pageTitle = _identity.WindowTitle(target.WindowHandle);
            // The title says what the page called itself; the URL says where it actually was. The
            // resolver observes it raw and this is the one place that decides what may be kept.
            string? documentUrl = ObservedDocumentUrl.Sanitize(target.RawDocumentUrl);
            fields = new TargetFields(
                target.Role,
                name,
                target.Value,
                bounds,
                sensitive,
                application,
                application?.Name,
                pageTitle,
                documentUrl);
            return true;
        }

        // No foreign element: still emit against the foreground app with a 1x1 pointer rect.
        AppIdentity? foreground = ForegroundIdentity();
        fields = new TargetFields(
            null, null, null, PointerRect(x, y), false, foreground, foreground?.Name,
            _identity.WindowTitle(NativeMethods.GetForegroundWindow()), null);
        return true;
    }

    private static BoundingBox? CanonicalizeBounds(UiaTarget target, int x, int y)
    {
        // An anonymous container with no label, value or identifier collapses to the pointer rect.
        bool anonymous = target.Name is null
            && target.HelpText is null
            && target.Value is null
            && target.AutomationId is null
            && UiaConstants.IsAnonymousContainer(target.Role);
        return anonymous || target.Bounds is null ? PointerRect(x, y) : target.Bounds;
    }

    private static BoundingBox PointerRect(int x, int y) => new(x - 0.5, y - 0.5, 1, 1);

    private AppIdentity? ForegroundIdentity() => _identity.Resolve(NativeMethods.GetForegroundWindow());

    private static string? FocusKey(UiaTarget? focus) =>
        focus is null ? null : $"{focus.AutomationId}|{focus.Role}|{focus.Name}";

    private void Observe(HostEvent hostEvent)
    {
        try
        {
            _engine.Observe(hostEvent);
        }
        catch (InvalidOperationException)
        {
            // The engine stopped recording between the check and the call; drop the event.
        }
    }

    private void ObserveOwnWindowInteraction()
    {
        try
        {
            _engine.ObserveOwnWindowInteraction();
        }
        catch (InvalidOperationException)
        {
            // The engine stopped recording between the check and the call; drop the gap.
        }
    }

    private static string? ReadClipboardText(int maxChars)
    {
        if (!NativeMethods.OpenClipboard(IntPtr.Zero))
        {
            return null;
        }

        try
        {
            IntPtr handle = NativeMethods.GetClipboardData(NativeMethods.CF_UNICODETEXT);
            if (handle == IntPtr.Zero)
            {
                return null;
            }

            IntPtr locked = NativeMethods.GlobalLock(handle);
            if (locked == IntPtr.Zero)
            {
                return null;
            }

            try
            {
                string? text = System.Runtime.InteropServices.Marshal.PtrToStringUni(locked);
                if (text is null)
                {
                    return null;
                }

                return text.Length > maxChars ? text[..maxChars] : text;
            }
            finally
            {
                NativeMethods.GlobalUnlock(handle);
            }
        }
        finally
        {
            NativeMethods.CloseClipboard();
        }
    }

    private readonly record struct TargetFields(
        string? Role,
        string? Name,
        string? Text,
        BoundingBox? Bounds,
        bool Sensitive,
        AppIdentity? Application,
        string? System,
        string? PageTitle,
        string? DocumentUrl);

    private sealed record PendingClick(TargetFields Fields, int ClickCount, DateTimeOffset OccurredAt);

    /// <summary>A label declaration to apply; a null text closes the open segment.</summary>
    private sealed record LabelBoundary(string? Text);

    private sealed class ClickFlushTick
    {
        public static readonly ClickFlushTick Instance = new();
    }

    private sealed class DrainTick
    {
        public static readonly DrainTick Instance = new();
    }
}
