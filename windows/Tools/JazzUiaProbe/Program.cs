using System.Runtime.InteropServices;
using JazzCapture.Capture;
using JazzCapture.Interop;
using JazzCaptureCore;

// Exercises the hand-written UI Automation COM interop and the application-identity resolver
// against whatever is currently on screen. The interop declares only the vtable slots the host
// uses, so the slot offsets cannot be checked by the compiler: this probe is how a real machine
// proves they are right before anyone trusts a capture.
//
// The document-URL slots are the ones most worth proving here: point the probe at a browser window
// and the raw line shows what the provider published, the sanitized line what the archive would
// keep. A raw value with no sanitized counterpart means the sanitizer rejected the scheme; both
// lines empty over a browser means the lookup found no Document element.
//
// Usage: JazzUiaProbe [x y]

var identity = new AppIdentityResolver();
using var resolver = new UiaResolver(identity, TimeSpan.FromMilliseconds(300));

resolver.SourceFailed += reason => Console.WriteLine($"  source failure: {reason}");
resolver.Start();
Console.WriteLine($"resolver ready: {resolver.IsReady}");

if (!resolver.IsReady)
{
    Console.WriteLine("FAIL: the UI Automation object could not be created.");
    return 1;
}

var foreground = Win32.GetForegroundWindow();
Console.WriteLine($"foreground hwnd: 0x{foreground.ToInt64():x}");
Console.WriteLine($"foreground title: {identity.WindowTitle(foreground) ?? "(none)"}");

var app = identity.Resolve(foreground);
Console.WriteLine(app is null
    ? "foreground identity: (unresolved)"
    : $"foreground identity: {app.Namespace} = {app.Value} | name={app.Name} version={app.Version}");

var probes = new List<(string Label, int X, int Y)>();
if (args.Length >= 2 && int.TryParse(args[0], out var ax) && int.TryParse(args[1], out var ay))
{
    probes.Add(("requested point", ax, ay));
}
else
{
    var width = Win32.GetSystemMetrics(Win32.SM_CXSCREEN);
    var height = Win32.GetSystemMetrics(Win32.SM_CYSCREEN);
    Console.WriteLine($"virtual screen: {width}x{height}");
    probes.Add(("screen centre", width / 2, height / 2));
    probes.Add(("taskbar strip", width / 2, height - 10));
    probes.Add(("top-left corner", 8, 8));
}

var resolved = 0;
IntPtr surveyWindow = foreground;
foreach (var (label, x, y) in probes)
{
    var result = resolver.ResolveAt(x, y);
    Console.WriteLine($"{label} ({x},{y}): status={result.Status}");
    if (result.Target is not { } target)
    {
        continue;
    }

    resolved++;
    surveyWindow = target.WindowHandle;
    Console.WriteLine($"  role={target.Role ?? "(null)"} name={target.Name ?? "(null)"}");
    Console.WriteLine($"  automationId={target.AutomationId ?? "(null)"} isPassword={target.IsPassword}");
    Console.WriteLine($"  bounds={(target.Bounds is null ? "(null)" : $"{target.Bounds.X},{target.Bounds.Y} {target.Bounds.Width}x{target.Bounds.Height}")}");
    Console.WriteLine($"  pid={target.ProcessId} hwnd=0x{target.WindowHandle.ToInt64():x}");

    // The document-URL gate gives up on any window whose class is not a known browser host, so when
    // a URL is missing the first question is always which class it actually saw.
    Console.WriteLine($"  class={Win32.ClassNameOf(target.WindowHandle) ?? "(none)"}"
        + $" rootClass={Win32.ClassNameOf(Win32.GetAncestor(target.WindowHandle, Win32.GA_ROOT)) ?? "(none)"}");
    Console.WriteLine($"  documentUrl raw={target.RawDocumentUrl ?? "(none)"}");
    Console.WriteLine($"  documentUrl kept={ObservedDocumentUrl.Sanitize(target.RawDocumentUrl) ?? "(none)"}");
}

var focused = resolver.ResolveFocused();
Console.WriteLine(focused is null
    ? "focused element: (none)"
    : $"focused element: role={focused.Role} name={focused.Name} isPassword={focused.IsPassword}");

Console.WriteLine();
DocumentSurvey.Run(Win32.GetAncestor(surveyWindow, Win32.GA_ROOT));

resolver.Stop();

// A locked or blank screen legitimately resolves nothing, so an empty result is reported rather
// than treated as a failure. Only a resolver that never came up is a hard failure.
Console.WriteLine($"RESULT: resolver started, {resolved}/{probes.Count} probe points resolved");
return 0;

// The host keeps its own interop internal; the probe declares the two entry points it needs so
// running it never widens the host's public surface.
internal static class Win32
{
    internal const int SM_CXSCREEN = 0;
    internal const int SM_CYSCREEN = 1;
    internal const uint GA_ROOT = 2;

    [DllImport("user32.dll")]
    internal static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hwnd, System.Text.StringBuilder buffer, int capacity);

    internal static string? ClassNameOf(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return null;
        }

        var buffer = new System.Text.StringBuilder(256);
        int copied = GetClassNameW(hwnd, buffer, buffer.Capacity);
        return copied > 0 ? buffer.ToString(0, copied) : null;
    }

    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    internal static extern int GetSystemMetrics(int nIndex);
}

/// <summary>
/// Enumerates how a live provider actually exposes its document, so a failed URL lookup can be told
/// apart from a wrong vtable slot. The control type a browser publishes for its page root is not
/// something the compiler or a macOS test can settle.
/// </summary>
internal static class DocumentSurvey
{
    // Control types worth naming in the output; anything else prints as its raw id.
    private static readonly Dictionary<int, string> Names = new()
    {
        [50030] = "Document", [50033] = "Pane", [50026] = "Group", [50004] = "Edit",
        [50032] = "Window", [50005] = "Hyperlink", [50000] = "Button", [50020] = "Text",
    };

    internal static void Run(IntPtr window)
    {
        var type = Type.GetTypeFromCLSID(new Guid("E22AD333-B25F-460C-83D0-0581107395C9"));
        if (type is null || Activator.CreateInstance(type) is not IUIAutomation automation)
        {
            Console.WriteLine("survey: cannot create the automation client");
            return;
        }

        if (automation.CreateCacheRequest(out IUIAutomationCacheRequest? request) < 0 || request is null)
        {
            Console.WriteLine("survey: cannot create a cache request");
            return;
        }

        foreach (int property in new[] { 30003, 30005, 30045, 30004 })
        {
            request.AddProperty(property);
        }

        if (automation.ElementFromHandleBuildCache(window, request, out IUIAutomationElement? root) < 0
            || root is null)
        {
            Console.WriteLine("survey: ElementFromHandleBuildCache failed for the window");
            return;
        }

        Console.WriteLine("survey: window element bound");
        foreach (int controlType in new[] { 50030, 50033, 50026, 50004 })
        {
            if (automation.CreatePropertyCondition(30003, controlType, out object? condition) < 0
                || condition is null)
            {
                Console.WriteLine($"  condition for {Label(controlType)} could not be created");
                continue;
            }

            int hr = root.FindFirstBuildCache(4, condition, request, out IUIAutomationElement? found);
            if (hr < 0)
            {
                Console.WriteLine($"  {Label(controlType)}: FindFirstBuildCache hr=0x{hr:x8}");
                continue;
            }

            if (found is null)
            {
                Console.WriteLine($"  {Label(controlType)}: no match");
                continue;
            }

            Console.WriteLine($"  {Label(controlType)}: found"
                + $" name={Read(found, 30005)} value={Read(found, 30045)} class={Read(found, 30004)}");
        }
    }

    private static string Label(int controlType) =>
        Names.TryGetValue(controlType, out string? name) ? name : controlType.ToString();

    private static string Read(IUIAutomationElement element, int propertyId) =>
        element.GetCachedPropertyValue(propertyId, out object? value) >= 0 && value is string text
            ? (text.Length == 0 ? "(empty)" : text)
            : "(none)";
}
