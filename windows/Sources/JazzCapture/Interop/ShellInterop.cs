using System.Runtime.InteropServices;

namespace JazzCapture.Interop;

/// <summary>
/// The slice of the Shell property system needed to read a packaged application's AUMID from its
/// window, so packaged apps get their stable Application User Model ID rather than a raw executable
/// path (ANNEX-HOST section 1). Any failure here is caught by the caller and falls back to the
/// executable path, so the interop is best-effort and validated live in Task 10.
/// </summary>
internal static class ShellInterop
{
    /// <summary><c>PKEY_AppUserModel_ID</c>: {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, pid 5.</summary>
    internal static readonly PropertyKey PkeyAppUserModelId = new(
        new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
        5);

    internal static readonly Guid IID_IPropertyStore = new("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    [DllImport("shell32.dll")]
    internal static extern int SHGetPropertyStoreForWindow(
        IntPtr hwnd,
        ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore? propertyStore);

    [DllImport("propsys.dll", CharSet = CharSet.Unicode)]
    internal static extern int PropVariantToStringAlloc(ref PropVariant propvar, out IntPtr stringOut);

    [DllImport("ole32.dll")]
    internal static extern int PropVariantClear(ref PropVariant pvar);

    [DllImport("ole32.dll")]
    internal static extern void CoTaskMemFree(IntPtr ptr);
}

/// <summary>The Shell property-key: a format id and a property id.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct PropertyKey
{
    public Guid FormatId;
    public uint PropertyId;

    public PropertyKey(Guid formatId, uint propertyId)
    {
        FormatId = formatId;
        PropertyId = propertyId;
    }
}

/// <summary>
/// A PROPVARIANT wide enough for both bitnesses. Only the header and the first union pointer are read;
/// string extraction goes through <c>PropVariantToStringAlloc</c>, which handles every string-shaped
/// variant type without decoding the union by hand.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct PropVariant
{
    public ushort VarType;
    public ushort Reserved1;
    public ushort Reserved2;
    public ushort Reserved3;
    public IntPtr Value1;
    public IntPtr Value2;
}

/// <summary>The property store, declared to its <c>GetValue</c> slot (3).</summary>
[ComImport]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPropertyStore
{
    [PreserveSig] int GetCount(out uint count); // 1
    [PreserveSig] int GetAt(uint index, out PropertyKey key); // 2
    [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value); // 3
}
