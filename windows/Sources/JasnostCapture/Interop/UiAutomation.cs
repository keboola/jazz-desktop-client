using System.Runtime.InteropServices;

namespace JasnostCapture.Interop;

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
}

/// <summary>The UI Automation coordinate point: two 32-bit ints (Win32 <c>long</c>).</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct UiaPoint
{
    public int X;
    public int Y;
}

/// <summary>
/// The root client object. Slots 1-8 and 11-17 are placeholders; only
/// <see cref="ElementFromPointBuildCache"/> (9), <see cref="GetFocusedElementBuildCache"/> (10) and
/// <see cref="CreateCacheRequest"/> (18) are called.
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
    [PreserveSig] int ElementFromHandleBuildCache_(); // 8

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
/// An automation element. Slots 1-9 are placeholders; every value is read through
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
    [PreserveSig] int FindFirstBuildCache_(); // 5
    [PreserveSig] int FindAllBuildCache_(); // 6
    [PreserveSig] int BuildUpdatedCache_(); // 7
    [PreserveSig] int GetCurrentPropertyValue_(); // 8
    [PreserveSig] int GetCurrentPropertyValueEx_(); // 9

    // 10
    [PreserveSig]
    int GetCachedPropertyValue(int propertyId, [MarshalAs(UnmanagedType.Struct)] out object? retVal);
}
