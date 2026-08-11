using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace JasnostCaptureCore.Journal;

/// <summary>
/// Filesystem barriers used by the capture journal: a file only becomes visible under its final
/// name after its bytes have reached stable storage, and a name is never published over an
/// existing one by accident.
/// </summary>
/// <remarks>
/// <para>
/// The publish pattern is temporary file in the destination directory, write, <c>fsync</c> via
/// <see cref="FileStream.Flush(bool)"/>, then rename. The rename is the atomic publish point:
/// after a crash the destination either does not exist or holds the complete previous or new
/// bytes, never a partial write. Both files stay on the same volume so the rename cannot degrade
/// into a copy.
/// </para>
/// <para>
/// Directory-level flushing (ANNEX-ARCHIVE section 8.23) is best effort. Windows exposes it
/// through <c>FlushFileBuffers</c> on a handle opened with <c>FILE_FLAG_BACKUP_SEMANTICS</c>; the
/// .NET base class library has no portable equivalent, so on other platforms the barrier degrades
/// to the file-level <c>fsync</c> above and <see cref="TryFlushDirectory"/> reports
/// <see langword="false"/>. Callers must treat a rename as durable only after the next successful
/// checkpoint, which is exactly how the journal's write-ahead log is replayed.
/// </para>
/// </remarks>
public static class Durability
{
    /// <summary>Suffix of the short-lived file that receives the bytes before the rename.</summary>
    public const string TemporaryFileSuffix = ".tmp";

    private const uint GenericWrite = 0x4000_0000;
    private const uint FileShareAll = 0x0000_0007;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x0200_0000;

    /// <summary>
    /// Publishes <paramref name="bytes"/> at <paramref name="path"/>, which must not exist yet.
    /// Used for write-ahead log segments and first claims, where reusing a name would silently
    /// discard evidence.
    /// </summary>
    /// <exception cref="IOException">The destination already exists.</exception>
    public static void WriteAtomic(string path, byte[] bytes) => Publish(path, bytes, overwrite: false);

    /// <summary>
    /// Publishes <paramref name="bytes"/> at <paramref name="path"/>, replacing an existing file.
    /// Used for the journal checkpoint, whose whole purpose is to supersede the previous snapshot.
    /// </summary>
    public static void ReplaceAtomic(string path, byte[] bytes) => Publish(path, bytes, overwrite: true);

    /// <summary>
    /// Requests a directory metadata barrier. Returns <see langword="true"/> only when the platform
    /// actually issued one; see the remarks on <see cref="Durability"/> for the fallback.
    /// </summary>
    public static bool TryFlushDirectory(string directory)
    {
        ArgumentException.ThrowIfNullOrEmpty(directory);

        if (!OperatingSystem.IsWindows() || !Directory.Exists(directory))
        {
            return false;
        }

        return FlushWindowsDirectory(directory);
    }

    /// <summary>
    /// Flushes <paramref name="leafDirectory"/> and every ancestor up to and including
    /// <paramref name="stopAtDirectory"/>, nearest first, as required by the file-then-parents
    /// ordering of ANNEX-ARCHIVE section 8.23.
    /// </summary>
    /// <returns>The number of directories for which a barrier was issued.</returns>
    public static int TryFlushDirectoryChain(string leafDirectory, string stopAtDirectory)
    {
        ArgumentException.ThrowIfNullOrEmpty(leafDirectory);
        ArgumentException.ThrowIfNullOrEmpty(stopAtDirectory);

        string stop = Path.TrimEndingDirectorySeparator(Path.GetFullPath(stopAtDirectory));
        string? current = Path.TrimEndingDirectorySeparator(Path.GetFullPath(leafDirectory));
        int flushed = 0;

        while (current is not null)
        {
            if (TryFlushDirectory(current))
            {
                flushed++;
            }

            if (string.Equals(current, stop, StringComparison.Ordinal))
            {
                break;
            }

            string? parent = Path.GetDirectoryName(current);
            current = parent is null ? null : Path.TrimEndingDirectorySeparator(parent);
        }

        return flushed;
    }

    private static void Publish(string path, byte[] bytes, bool overwrite)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(bytes);

        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath)
            ?? throw new ArgumentException("Path must contain a directory component.", nameof(path));
        Directory.CreateDirectory(directory);

        string temporaryPath = Path.Combine(
            directory,
            Path.GetFileName(fullPath) + "." + Identifiers.UuidV7() + TemporaryFileSuffix);

        try
        {
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, fullPath, overwrite);
        }
        catch
        {
            TryDelete(temporaryPath);
            throw;
        }

        TryFlushDirectory(directory);
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
            // The temporary file is already gone or held by a scanner; the publish result stands.
        }
        catch (UnauthorizedAccessException)
        {
            // Same reasoning: cleanup failure must not mask the original error.
        }
    }

    [SupportedOSPlatform("windows")]
    private static bool FlushWindowsDirectory(string directory)
    {
        using SafeFileHandle handle = CreateFileW(
            directory,
            GenericWrite,
            FileShareAll,
            IntPtr.Zero,
            OpenExisting,
            FileFlagBackupSemantics,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            return false;
        }

        return FlushFileBuffers(handle);
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FlushFileBuffers(SafeFileHandle handle);
}
