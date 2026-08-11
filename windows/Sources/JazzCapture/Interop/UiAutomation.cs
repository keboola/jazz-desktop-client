using System.Runtime.InteropServices;

namespace JazzCapture.Interop;

/// <summary>
/// A minimal hand-written interop for the UI Automation client, exactly as ANNEX-HOST section 7 asks:
/// <c>CUIAutomation8</c> via <c>IUIAutomation</c>, resolving click targets with
/// <c>ElementFromPointBuildCache</c> and a <see cref="IUIAutomationCacheRequest"/> so one cross-process
/// round trip fetches every property.
/// </summary>
/// <remarks>
/// <para>
/// Only the vtable slots the resolver actually calls are named; the earlier slots are declared as
/// placeholders purely to hold their positions, because a COM interface's method order <em>is</em> its
/// ABI. Every property is read through <see cref="IUIAutomationElement.GetCachedPropertyValue"/>
/// (slot 10) rather than a typed accessor, which keeps the element interface to ten slots instead of
/// the full eighty-plus.
/// </para>
/// <para>
/// The COM types resolve at run time on Windows only; the declarations are pure metadata, so the
/// project still compiles on macOS. The <c>ConnectionTimeout</c>/<c>TransactionTimeout</c> of
/// <c>IUIAutomation2</c> are not set here — that would require transcribing the entire
/// <c>IUIAutomation</c> vtable ahead of the two tail properties — so the resolver bounds every call on
/// its worker thread instead (see <c>UiaResolver</c>). Wiring the native timeouts is a Task 10 follow-up.
/// </para>
/// </remarks>
internal static class UiaConstants
{
    /// <summary>CLSID of the <c>CUIAutomation8</c> coclass.</summary>
    internal static readonly Guid CLSID_CUIAutomation8 = new("E22AD333-B25F-460C-83D0-0581107395C9");

    // Tree scopes (UIAutomationClient.h TreeScope enum).
    internal const int TreeScope_Descendants = 4;

    /// <summary>Control type of a browser page or a viewer's document (<c>UIA_DocumentControlTypeId</c>).</summary>
    internal const int UIA_DocumentControlTypeId = 50030;

    // Property identifiers fetched into the cache (UIAutomationClient.h).
    internal const int UIA_BoundingRectanglePropertyId = 30001;
    internal const int UIA_ProcessIdPropertyId = 30002;
    internal const int UIA_ControlTypePropertyId = 30003;
    internal const int UIA_NamePropertyId = 30005;
    internal const int UIA_AutomationIdPropertyId = 30011;
    internal const int UIA_HelpTextPropertyId = 30013;
    internal const int UIA_IsPasswordPropertyId = 30019;
    internal const int UIA_ValueValuePropertyId = 30045;

    /// <summary>Maps a UI Automation control-type id onto its programmatic name (e.g. <c>Button</c>).</summary>
    internal static string? ControlTypeName(int controlTypeId) => controlTypeId switch
    {
        50000 => "Button",
        50001 => "Calendar",
        50002 => "CheckBox",
        50003 => "ComboBox",
        50004 => "Edit",
        50005 => "Hyperlink",
        50006 => "Image",
        50007 => "ListItem",
        50008 => "List",
        50009 => "Menu",
        50010 => "MenuBar",
        50011 => "MenuItem",
        50012 => "ProgressBar",
        50013 => "RadioButton",
        50014 => "ScrollBar",
        50015 => "Slider",
        50016 => "Spinner",
        50017 => "StatusBar",
        50018 => "Tab",
        50019 => "TabItem",
        50020 => "Text",
        50021 => "ToolBar",
        50022 => "ToolTip",
        50023 => "Tree",
        50024 => "TreeItem",
        50025 => "Custom",
        50026 => "Group",
        50027 => "Thumb",
        50028 => "DataGrid",
        50029 => "DataItem",
        50030 => "Document",
        50031 => "SplitButton",
        50032 => "Window",
        50033 => "Pane",
        50034 => "Header",
        50035 => "HeaderItem",
        50036 => "Table",
        50037 => "TitleBar",
        50038 => "Separator",
        50039 => "SemanticZoom",
        50040 => "AppBar",
        _ => null,
    };

    /// <summary>Anonymous container roles that carry no semantic target on their own.</summary>
    internal static bool IsAnonymousContainer(string? role) =>
        role is "Group" or "Pane" or "Document" or null;

    /// <summary>
    /// Top-level window classes that plausibly host a web document, and therefore the only windows
    /// that pay for a document-URL lookup.
    /// </summary>
    /// <remarks>
    /// <para>
    /// This is the cost gate. <c>GetClassNameW</c> is an in-process Win32 read of a few bytes, so a
    /// text editor or a spreadsheet is rejected before a single cross-process UI Automation call is
    /// made, and the whole feature costs a non-browser application nothing. The alternative gates are
    /// all more expensive: the owning executable needs <c>OpenProcess</c> plus a path query, and
    /// asking UI Automation whether a document exists is the very work being gated.
    /// </para>
    /// <para>
    /// These are window classes, not brands, so one entry covers a whole engine: every Chromium
    /// browser — Chrome, Edge, Brave, Opera, Vivaldi — registers <c>Chrome_WidgetWin_1</c>. The known
    /// blind spot is a web view embedded in another application's window, which advertises the host
    /// application's class and is therefore skipped; the known false positive is an Electron
    /// application, which pays for a lookup whose result is almost always a non-web scheme the
    /// sanitizer discards.
    /// </para>
    /// </remarks>
    internal static bool IsWebDocumentHostClass(string? className) => className switch
    {
        "Chrome_WidgetWin_1" => true, // Chromium: Chrome, Edge, Brave, Opera, Vivaldi, Electron
        "Chrome_WidgetWin_0" => true, // older Chromium builds and some embedders
        "MozillaWindowClass" => true, // Gecko: Firefox
        "IEFrame" => true, // Internet Explorer and the Edge IE mode frame
        _ => false,
    };
}

/// <summary>The UI Automation coordinate point: two 32-bit ints (Win32 <c>long</c>).</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct UiaPoint
{
    public int X;
    public int Y;
}

/// <summary>
/// The root client object. Slots 1-7, 11-17 and 19-20 are placeholders; only
/// <see cref="ElementFromHandleBuildCache"/> (8), <see cref="ElementFromPointBuildCache"/> (9),
/// <see cref="GetFocusedElementBuildCache"/> (10), <see cref="CreateCacheRequest"/> (18) and
/// <see cref="CreatePropertyCondition"/> (21) are called.
/// </summary>
[ComImport]
[Guid("30CBE57D-D9D0-452A-AB13-7AC5AC4825EE")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IUIAutomation
{
    [PreserveSig] int CompareElements_(); // 1
    [PreserveSig] int CompareRuntimeIds_(); // 2
    [PreserveSig] int GetRootElement_(); // 3
    [PreserveSig] int ElementFromHandle_(); // 4
    [PreserveSig] int ElementFromPoint_(); // 5
    [PreserveSig] int GetFocusedElement_(); // 6
    [PreserveSig] int GetRootElementBuildCache_(); // 7

    // 8
    [PreserveSig]
    int ElementFromHandleBuildCache(
        IntPtr hwnd,
        IUIAutomationCacheRequest cacheRequest,
        [MarshalAs(UnmanagedType.Interface)] out IUIAutomationElement? element);

    // 9
    [PreserveSig]
    int ElementFromPointBuildCache(
        UiaPoint pt,
        IUIAutomationCacheRequest cacheRequest,
        [MarshalAs(UnmanagedType.Interface)] out IUIAutomationElement? element);

    // 10
    [PreserveSig]
    int GetFocusedElementBuildCache(
        IUIAutomationCacheRequest cacheRequest,
        [MarshalAs(UnmanagedType.Interface)] out IUIAutomationElement? element);

    [PreserveSig] int CreateTreeWalker_(); // 11
    [PreserveSig] int get_ControlViewWalker_(); // 12
    [PreserveSig] int get_ContentViewWalker_(); // 13
    [PreserveSig] int get_RawViewWalker_(); // 14
    [PreserveSig] int get_RawViewCondition_(); // 15
    [PreserveSig] int get_ControlViewCondition_(); // 16
    [PreserveSig] int get_ContentViewCondition_(); // 17

    // 18
    [PreserveSig]
    int CreateCacheRequest([MarshalAs(UnmanagedType.Interface)] out IUIAutomationCacheRequest? cacheRequest);

    [PreserveSig] int CreateTrueCondition_(); // 19
    [PreserveSig] int CreateFalseCondition_(); // 20

    // 21. The value is a VARIANT; the CLR boxes an int into VT_I4, which is what a control-type
    // condition expects.
    [PreserveSig]
    int CreatePropertyCondition(
        int propertyId,
        [MarshalAs(UnmanagedType.Struct)] object value,
        [MarshalAs(UnmanagedType.IUnknown)] out object? condition);
}

/// <summary>
/// A cache request. Only <see cref="AddProperty"/> (slot 1) is needed to pre-fetch the properties the
/// resolver reads.
/// </summary>
[ComImport]
[Guid("B32A92B5-BC25-4078-9C08-D7EE95C48E03")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IUIAutomationCacheRequest
{
    [PreserveSig] int AddProperty(int propertyId); // 1
}

/// <summary>
/// An automation element. Slots 1-4 and 6-9 are placeholders; the document lookup uses
/// <see cref="FindFirstBuildCache"/> (slot 5) and every value is read through
/// <see cref="GetCachedPropertyValue"/> (slot 10), which returns a VARIANT the CLR marshals to a
/// managed object.
/// </summary>
[ComImport]
[Guid("D22108AA-8AC5-49A5-837B-37BBB3D7591E")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IUIAutomationElement
{
    [PreserveSig] int SetFocus_(); // 1
    [PreserveSig] int GetRuntimeId_(); // 2
    [PreserveSig] int FindFirst_(); // 3
    [PreserveSig] int FindAll_(); // 4

    // 5. Returns S_OK with a null element when nothing matches, so the caller must check both.
    [PreserveSig]
    int FindFirstBuildCache(
        int scope,
        [MarshalAs(UnmanagedType.IUnknown)] object condition,
        IUIAutomationCacheRequest cacheRequest,
        [MarshalAs(UnmanagedType.Interface)] out IUIAutomationElement? found);

    [PreserveSig] int FindAllBuildCache_(); // 6
    [PreserveSig] int BuildUpdatedCache_(); // 7
    [PreserveSig] int GetCurrentPropertyValue_(); // 8
    [PreserveSig] int GetCurrentPropertyValueEx_(); // 9

    // 10
    [PreserveSig]
    int GetCachedPropertyValue(int propertyId, [MarshalAs(UnmanagedType.Struct)] out object? retVal);
}
