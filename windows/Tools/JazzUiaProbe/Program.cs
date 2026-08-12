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
// The TextPattern slots are the other unverifiable ones. Select some text before running this and
// the selection lines should echo it back; the survey at the end walks the same three interfaces by
// hand and prints every HRESULT, which is what separates "nothing was selected" from "the vtable
// slot is wrong".
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
    Console.WriteLine($"  selectedText raw={Describe(target.SelectedText)}");
    Console.WriteLine($"  selectedText kept={Redaction.Sanitize(target.SelectedText) ?? "(none)"}");
}

var focused = resolver.ResolveFocused();
Console.WriteLine(focused is null
    ? "focused element: (none)"
    : $"focused element: role={focused.Role} name={focused.Name} isPassword={focused.IsPassword}"
        + $" selectedText={Describe(focused.SelectedText)}");

Console.WriteLine();
DocumentSurvey.Run(Win32.GetAncestor(surveyWindow, Win32.GA_ROOT));

Console.WriteLine();
SelectionSurvey.Run();

resolver.Stop();

// A locked or blank screen legitimately resolves nothing, so an empty result is reported rather
// than treated as a failure. Only a resolver that never came up is a hard failure.
Console.WriteLine($"RESULT: resolver started, {resolved}/{probes.Count} probe points resolved");
return 0;

// Selections carry user content, so the probe shows the shape and a short prefix rather than
// dumping whatever happens to be highlighted into a terminal someone may be sharing.
static string Describe(string? selection) => selection switch
{
    null => "(none)",
    { Length: 0 } => "(empty)",
    _ => $"{selection.Length} chars: \"{selection[..Math.Min(40, selection.Length)]}\"",
};

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

/// <summary>
/// Walks the TextPattern interfaces by hand against the focused element, printing every HRESULT.
/// </summary>
/// <remarks>
/// The three interfaces this exercises — <c>IUIAutomationElement.GetCurrentPattern</c> (slot 14),
/// <c>IUIAutomationTextPattern.GetSelection</c> (slot 3), and
/// <c>IUIAutomationTextRangeArray.get_Length</c>/<c>GetElement</c> plus
/// <c>IUIAutomationTextRange.GetText</c> (slot 10) — are hand-transcribed vtable offsets that no
/// compiler and no macOS test can check. A wrong offset does not fail cleanly: it calls whatever
/// method actually sits at that index. Printing each HRESULT separately is what tells a bad slot
/// apart from an element that simply has no selection.
/// </remarks>
internal static class SelectionSurvey
{
    private const int UIA_TextPatternId = 10014;

    internal static void Run()
    {
        var type = Type.GetTypeFromCLSID(new Guid("E22AD333-B25F-460C-83D0-0581107395C9"));
        if (type is null || Activator.CreateInstance(type) is not IUIAutomation automation)
        {
            Console.WriteLine("selection survey: cannot create the automation client");
            return;
        }

        if (automation.CreateCacheRequest(out IUIAutomationCacheRequest? request) < 0 || request is null)
        {
            Console.WriteLine("selection survey: cannot create a cache request");
            return;
        }

        request.AddProperty(30003); // control type
        request.AddProperty(30019); // is password

        int hr = automation.GetFocusedElementBuildCache(request, out IUIAutomationElement? element);
        if (hr < 0 || element is null)
        {
            Console.WriteLine($"selection survey: no focused element (hr=0x{hr:x8})");
            return;
        }

        hr = element.GetCurrentPattern(UIA_TextPatternId, out object? pattern);
        Console.WriteLine($"selection survey: GetCurrentPattern hr=0x{hr:x8}"
            + $" object={(pattern is null ? "(null)" : pattern.GetType().Name)}");
        if (hr < 0 || pattern is null)
        {
            Console.WriteLine("  the focused element does not support TextPattern; focus a text field and retry");
            return;
        }

        if (pattern is not IUIAutomationTextPattern text)
        {
            Console.WriteLine("  FAIL: the returned object is not IUIAutomationTextPattern - check slot 14");
            return;
        }

        hr = text.GetSelection(out IUIAutomationTextRangeArray? ranges);
        Console.WriteLine($"  GetSelection hr=0x{hr:x8} ranges={(ranges is null ? "(null)" : "present")}");
        if (hr < 0 || ranges is null)
        {
            return;
        }

        hr = ranges.get_Length(out int length);
        Console.WriteLine($"  get_Length hr=0x{hr:x8} length={length}");
        if (hr < 0 || length <= 0)
        {
            return;
        }

        hr = ranges.GetElement(0, out IUIAutomationTextRange? range);
        Console.WriteLine($"  GetElement(0) hr=0x{hr:x8} range={(range is null ? "(null)" : "present")}");
        if (hr < 0 || range is null)
        {
            return;
        }

        hr = range.GetText(4000, out string? selection);
        Console.WriteLine($"  GetText hr=0x{hr:x8} length={selection?.Length ?? -1}");
        if (selection is { Length: > 0 })
        {
            Console.WriteLine($"  prefix=\"{selection[..Math.Min(40, selection.Length)]}\"");
        }
    }
}
