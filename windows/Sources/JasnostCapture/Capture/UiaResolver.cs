using System.Collections.Concurrent;
using System.Threading;
using JasnostCaptureCore;
using JasnostCapture.Interop;

namespace JasnostCapture.Capture;

/// <summary>How a click-target resolution ended.</summary>
public enum UiaStatus
{
    /// <summary>A foreign element was resolved.</summary>
    Resolved,

    /// <summary>The point is over this capture client's own window; the event is a desktop-client gap.</summary>
    OwnWindow,

    /// <summary>No foreign window or element was found; the caller falls back to the foreground app.</summary>
    NoTarget,
}

/// <summary>A resolved click target and its owning process.</summary>
/// <param name="Role">The control-type programmatic name, used for both <c>tag</c> and <c>role</c>.</param>
/// <param name="Name">The accessible name.</param>
/// <param name="HelpText">Help text, used when the name is empty.</param>
/// <param name="Value">The element value (from the Value property).</param>
/// <param name="AutomationId">The automation id (focus identity, never emitted).</param>
/// <param name="IsPassword">Whether the element is a password field.</param>
/// <param name="Bounds">The element rectangle, or <see langword="null"/> when unavailable.</param>
/// <param name="ProcessId">The owning process id.</param>
/// <param name="WindowHandle">The owning top-level window.</param>
public sealed record UiaTarget(
    string? Role,
    string? Name,
    string? HelpText,
    string? Value,
    string? AutomationId,
    bool IsPassword,
    BoundingBox? Bounds,
    uint ProcessId,
    IntPtr WindowHandle);

/// <summary>The outcome of a resolution request.</summary>
/// <param name="Status">Which branch produced this result.</param>
/// <param name="Target">The resolved target when <see cref="UiaStatus.Resolved"/>.</param>
public sealed record UiaResolution(UiaStatus Status, UiaTarget? Target = null);

/// <summary>
/// Resolves click targets on a single dedicated STA worker thread, as ANNEX-HOST section 7 requires:
/// all UI Automation lives here, the thread is COM-apartment initialized once, and one
/// <c>ElementFromPointBuildCache</c> plus a shared cache request fetches every property in one round
/// trip.
/// </summary>
/// <remarks>
/// <para>
/// The fallback ladder is the cheap-first one from ANNEX-HOST section 3: a <c>WindowFromPoint</c> hit
/// test finds the topmost foreign window and rejects invisible, transparent and tool windows and —
/// the second own-window exclusion layer — anything owned by this process, before any UIA call is
/// made. Only then is the element resolved and its properties read from the cache.
/// </para>
/// <para>
/// Each request is bounded by the caller-supplied timeout: the work is posted to the STA thread and
/// awaited, and a request that does not complete in time returns <see cref="UiaStatus.NoTarget"/>
/// rather than blocking the pipeline. This is how the MVP approximates the <c>IUIAutomation2</c>
/// connection and transaction timeouts, which are not wired in the hand-written interop.
/// </para>
/// </remarks>
public sealed class UiaResolver : IDisposable
{
    private static readonly int[] CachedProperties =
    {
        UiaConstants.UIA_ControlTypePropertyId,
        UiaConstants.UIA_NamePropertyId,
        UiaConstants.UIA_HelpTextPropertyId,
        UiaConstants.UIA_ValueValuePropertyId,
        UiaConstants.UIA_BoundingRectanglePropertyId,
        UiaConstants.UIA_AutomationIdPropertyId,
        UiaConstants.UIA_IsPasswordPropertyId,
        UiaConstants.UIA_ProcessIdPropertyId,
    };

    private readonly AppIdentityResolver _identity;
    private readonly TimeSpan _timeout;
    private readonly BlockingCollection<WorkItem> _work = new();
    private readonly ManualResetEventSlim _ready = new(false);

    private Thread? _thread;
    private IUIAutomation? _automation;
    private IUIAutomationCacheRequest? _cacheRequest;
    private volatile bool _running;

    /// <summary>Reports the last failure so the pipeline can flip the accessibility capability.</summary>
    public event Action<string>? SourceFailed;

    /// <summary>Creates the resolver.</summary>
    /// <param name="identity">Owner resolver, reused for the own-window exclusion.</param>
    /// <param name="timeout">Per-request budget; a request over budget yields no target.</param>
    public UiaResolver(AppIdentityResolver identity, TimeSpan timeout)
    {
        _identity = identity ?? throw new ArgumentNullException(nameof(identity));
        _timeout = timeout;
    }

    /// <summary>Whether the automation client came up on the worker thread.</summary>
    public bool IsReady => _automation is not null;

    /// <summary>Starts the STA worker and waits until it has initialized (or failed to).</summary>
    public void Start()
    {
        if (_thread is not null)
        {
            return;
        }

        _running = true;
        _thread = new Thread(Run)
        {
            IsBackground = true,
            Name = "JasnostUiaWorker",
        };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        _ready.Wait();
    }

    /// <summary>Resolves the element under a screen point.</summary>
    public UiaResolution ResolveAt(int x, int y) =>
        Dispatch(() => ResolveAtCore(x, y)) ?? new UiaResolution(UiaStatus.NoTarget);

    /// <summary>Resolves the currently focused element (for clipboard and typing targets).</summary>
    public UiaTarget? ResolveFocused() => Dispatch(ResolveFocusedCore)?.Target;

    /// <summary>Stops the worker and releases the automation client.</summary>
    public void Stop()
    {
        if (!_running)
        {
            return;
        }

        _running = false;
        _work.CompleteAdding();
        _thread?.Join(TimeSpan.FromSeconds(2));
        _thread = null;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        Stop();
        _work.Dispose();
        _ready.Dispose();
    }

    private UiaResolution? Dispatch(Func<UiaResolution> work)
    {
        if (!_running || _work.IsAddingCompleted)
        {
            return null;
        }

        var item = new WorkItem(work);
        try
        {
            _work.Add(item);
        }
        catch (InvalidOperationException)
        {
            return null;
        }

        return item.Completion.Wait(_timeout) ? item.Result : null;
    }

    private void Run()
    {
        NativeMethods.CoInitializeEx(IntPtr.Zero, NativeMethods.COINIT_APARTMENTTHREADED);
        try
        {
            Initialize();
        }
        catch (Exception ex)
        {
            SourceFailed?.Invoke(ex.Message);
        }
        finally
        {
            _ready.Set();
        }

        try
        {
            foreach (WorkItem item in _work.GetConsumingEnumerable())
            {
                try
                {
                    item.Result = item.Work();
                }
                catch (Exception ex)
                {
                    item.Result = new UiaResolution(UiaStatus.NoTarget);
                    SourceFailed?.Invoke(ex.Message);
                }
                finally
                {
                    item.Completion.Set();
                }
            }
        }
        catch (InvalidOperationException)
        {
            // CompleteAdding raced with the consumer; treat as a clean shutdown.
        }

        NativeMethods.CoUninitialize();
    }

    private void Initialize()
    {
        Type type = Type.GetTypeFromCLSID(UiaConstants.CLSID_CUIAutomation8)
            ?? throw new InvalidOperationException("CUIAutomation8 CLSID is not registered.");
        _automation = (IUIAutomation)(Activator.CreateInstance(type)
            ?? throw new InvalidOperationException("Failed to create the UI Automation client."));

        if (_automation.CreateCacheRequest(out IUIAutomationCacheRequest? request) < 0 || request is null)
        {
            throw new InvalidOperationException("Failed to create a UI Automation cache request.");
        }

        foreach (int propertyId in CachedProperties)
        {
            request.AddProperty(propertyId);
        }

        _cacheRequest = request;
    }

    private UiaResolution ResolveAtCore(int x, int y)
    {
        if (_automation is null || _cacheRequest is null)
        {
            return new UiaResolution(UiaStatus.NoTarget);
        }

        var point = new NativeMethods.POINT { X = x, Y = y };
        IntPtr root = TopmostForeignWindow(point);
        if (root == OwnWindowSentinel)
        {
            return new UiaResolution(UiaStatus.OwnWindow);
        }

        int hr = _automation.ElementFromPointBuildCache(
            new UiaPoint { X = x, Y = y },
            _cacheRequest,
            out IUIAutomationElement? element);
        if (hr < 0 || element is null)
        {
            return new UiaResolution(UiaStatus.NoTarget);
        }

        try
        {
            UiaTarget target = ReadTarget(element, root);

            // Third exclusion layer: reject an element whose resolved owner is our own process.
            return target.ProcessId == (uint)Environment.ProcessId
                ? new UiaResolution(UiaStatus.OwnWindow)
                : new UiaResolution(UiaStatus.Resolved, target);
        }
        finally
        {
            System.Runtime.InteropServices.Marshal.ReleaseComObject(element);
        }
    }

    private UiaResolution ResolveFocusedCore()
    {
        if (_automation is null || _cacheRequest is null)
        {
            return new UiaResolution(UiaStatus.NoTarget);
        }

        if (_automation.GetFocusedElementBuildCache(_cacheRequest, out IUIAutomationElement? element) < 0
            || element is null)
        {
            return new UiaResolution(UiaStatus.NoTarget);
        }

        try
        {
            UiaTarget target = ReadTarget(element, IntPtr.Zero);
            return target.ProcessId == (uint)Environment.ProcessId
                ? new UiaResolution(UiaStatus.OwnWindow)
                : new UiaResolution(UiaStatus.Resolved, target);
        }
        finally
        {
            System.Runtime.InteropServices.Marshal.ReleaseComObject(element);
        }
    }

    private static readonly IntPtr OwnWindowSentinel = new(-1);

    private IntPtr TopmostForeignWindow(NativeMethods.POINT point)
    {
        IntPtr window = NativeMethods.WindowFromPoint(point);
        if (window == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        IntPtr root = NativeMethods.GetAncestor(window, NativeMethods.GA_ROOT);
        if (root == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        if (_identity.IsOwnWindow(root))
        {
            return OwnWindowSentinel;
        }

        if (!NativeMethods.IsWindowVisible(root))
        {
            return IntPtr.Zero;
        }

        long exStyle = NativeMethods.GetWindowLongPtrW(root, NativeMethods.GWL_EXSTYLE).ToInt64();
        if ((exStyle & NativeMethods.WS_EX_TRANSPARENT) != 0 || (exStyle & NativeMethods.WS_EX_TOOLWINDOW) != 0)
        {
            return IntPtr.Zero;
        }

        return root;
    }

    private static UiaTarget ReadTarget(IUIAutomationElement element, IntPtr window)
    {
        string? role = UiaConstants.ControlTypeName(ReadInt(element, UiaConstants.UIA_ControlTypePropertyId) ?? 0);
        string? name = ReadString(element, UiaConstants.UIA_NamePropertyId);
        string? helpText = ReadString(element, UiaConstants.UIA_HelpTextPropertyId);
        string? value = ReadString(element, UiaConstants.UIA_ValueValuePropertyId);
        string? automationId = ReadString(element, UiaConstants.UIA_AutomationIdPropertyId);
        bool isPassword = ReadBool(element, UiaConstants.UIA_IsPasswordPropertyId);
        BoundingBox? bounds = ReadRectangle(element);
        uint processId = (uint)(ReadInt(element, UiaConstants.UIA_ProcessIdPropertyId) ?? 0);

        return new UiaTarget(role, name, helpText, value, automationId, isPassword, bounds, processId, window);
    }

    private static string? ReadString(IUIAutomationElement element, int propertyId) =>
        element.GetCachedPropertyValue(propertyId, out object? value) >= 0 && value is string text
            ? text
            : null;

    private static int? ReadInt(IUIAutomationElement element, int propertyId) =>
        element.GetCachedPropertyValue(propertyId, out object? value) >= 0 && value is int number
            ? number
            : null;

    private static bool ReadBool(IUIAutomationElement element, int propertyId) =>
        element.GetCachedPropertyValue(propertyId, out object? value) >= 0 && value is bool flag && flag;

    private static BoundingBox? ReadRectangle(IUIAutomationElement element)
    {
        if (element.GetCachedPropertyValue(UiaConstants.UIA_BoundingRectanglePropertyId, out object? value) < 0)
        {
            return null;
        }

        // The bounding rectangle marshals from a SAFEARRAY of four R8 as double[]: left, top, w, h.
        if (value is double[] { Length: 4 } rect)
        {
            return new BoundingBox(rect[0], rect[1], rect[2], rect[3]);
        }

        return null;
    }

    private sealed class WorkItem
    {
        public WorkItem(Func<UiaResolution> work) => Work = work;

        public Func<UiaResolution> Work { get; }

        public ManualResetEventSlim Completion { get; } = new(false);

        public UiaResolution? Result { get; set; }
    }
}
