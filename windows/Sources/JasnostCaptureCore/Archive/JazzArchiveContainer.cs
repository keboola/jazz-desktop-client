using System.Buffers.Binary;
using System.IO.Hashing;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace JasnostCaptureCore.Archive;

/// <summary>
/// Writes the ".jazz-archive" container profile v1: a single-disk, stored-only (method 0)
/// ZIP32 with exactly one legal byte layout. The layout is hand-written rather than delegated
/// to <c>System.IO.Compression</c> because the profile pins every header field (zero timestamps,
/// no extra fields, no data descriptors, no ZIP64, no comments) and the resulting package bytes
/// are a conformance vector: the same archive directory must always produce the same bytes on
/// every platform.
/// </summary>
/// <remarks>
/// Byte layout, ordering rules, and forbidden features follow ANNEX-ARCHIVE sections 1.1 and 1.2,
/// which in turn mirror <c>contract/archive/container/generate_fixtures.py</c>. The golden vector is
/// <c>contract/archive/container/fixtures/01-canonical-v1.jazz-archive</c>.
/// </remarks>
public static class JazzArchiveContainer
{
    private const uint LocalHeaderSignature = 0x0403_4B50;
    private const uint CentralHeaderSignature = 0x0201_4B50;
    private const uint EndOfCentralDirectorySignature = 0x0605_4B50;

    /// <summary>ZIP specification version 2.0 — the minimum for stored entries with UTF-8 names.</summary>
    private const ushort VersionNeeded = 20;

    /// <summary>Made by UNIX (0x03) with specification version 2.0 (0x14).</summary>
    private const ushort VersionMadeBy = 0x0314;

    /// <summary>Language-encoding (UTF-8 name) bit only; the data-descriptor bit stays clear.</summary>
    private const ushort GeneralPurposeFlags = 0x0800;

    /// <summary>Stored — the profile forbids DEFLATE.</summary>
    private const ushort CompressionMethodStored = 0;

    private const ushort FixedLastModifiedTime = 0;

    /// <summary>MS-DOS date for 1980-01-01, the fixed timestamp of the profile.</summary>
    private const ushort FixedLastModifiedDate = 0x0021;

    /// <summary>Regular file, mode 0o100644, shifted into the high word.</summary>
    private const uint ExternalFileAttributes = 0x81A4_0000;

    private const ushort ZeroLength = 0;

    private const int LocalHeaderSize = 30;
    private const int CentralHeaderSize = 46;
    private const int EndOfCentralDirectorySize = 22;

    private const uint MaxZip32Value = 0xFFFF_FFFE;
    private const int MaxEntryCount = 0xFFFE;

    /// <summary>Ingest limit from ANNEX-ARCHIVE section 1.4: 1 024 UTF-8 bytes per path.</summary>
    private const int MaxEntryNameByteCount = 1024;

    private const string ManifestEntryName = "manifest.json";
    private const string InventoryEntryName = "inventory.json";
    private const string ExcludedSubtreePrefix = "sync/";

    private static readonly Regex PortableNamePattern = new(
        "^[A-Za-z0-9._/-]+$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// <summary>
    /// Packages <paramref name="archiveDir"/> into the container at <paramref name="outputZipPath"/>.
    /// The <c>sync/</c> subtree is never exported; every other regular file becomes one stored entry,
    /// ordered by entry name with <see cref="StringComparer.Ordinal"/> (equivalent to UTF-8 byte order
    /// for the portable name subset).
    /// </summary>
    /// <exception cref="DirectoryNotFoundException">The archive directory does not exist.</exception>
    /// <exception cref="InvalidOperationException">
    /// The directory holds a non-portable entry name, is missing <c>manifest.json</c> or
    /// <c>inventory.json</c>, is empty, or exceeds the ZIP32 field ranges.
    /// </exception>
    public static void Export(string archiveDir, string outputZipPath)
    {
        ArgumentException.ThrowIfNullOrEmpty(archiveDir);
        ArgumentException.ThrowIfNullOrEmpty(outputZipPath);

        if (!Directory.Exists(archiveDir))
        {
            throw new DirectoryNotFoundException($"archive directory not found: {archiveDir}");
        }

        IReadOnlyList<string> names = CollectEntryNames(archiveDir);

        string? outputDirectory = Path.GetDirectoryName(Path.GetFullPath(outputZipPath));
        if (!string.IsNullOrEmpty(outputDirectory))
        {
            Directory.CreateDirectory(outputDirectory);
        }

        using FileStream stream = new(
            outputZipPath,
            FileMode.Create,
            FileAccess.Write,
            FileShare.None);
        WriteContainer(archiveDir, names, stream);
    }

    /// <summary>Returns the lowercase hexadecimal SHA-256 of the file at <paramref name="path"/>.</summary>
    public static string Sha256File(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);

        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        byte[] digest = SHA256.HashData(stream);
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    /// <summary>
    /// Reports whether <paramref name="name"/> is a legal container entry name: a relative,
    /// "/"-separated path over <c>[A-Za-z0-9._/-]</c> with no leading or trailing separator and
    /// no empty, "." or ".." segment. Backslashes, spaces, NUL and non-ASCII are rejected by the
    /// character class.
    /// </summary>
    public static bool IsPortableEntryName(string? name)
    {
        if (string.IsNullOrEmpty(name) || !PortableNamePattern.IsMatch(name))
        {
            return false;
        }

        if (name[0] == '/' || name[^1] == '/')
        {
            return false;
        }

        foreach (string segment in name.Split('/'))
        {
            if (segment.Length == 0 || segment == "." || segment == "..")
            {
                return false;
            }
        }

        return true;
    }

    private static IReadOnlyList<string> CollectEntryNames(string archiveDir)
    {
        List<string> names = new();
        foreach (string path in Directory.EnumerateFiles(archiveDir, "*", SearchOption.AllDirectories))
        {
            string name = ToEntryName(archiveDir, path);
            if (name.StartsWith(ExcludedSubtreePrefix, StringComparison.Ordinal))
            {
                continue;
            }

            if (!IsPortableEntryName(name))
            {
                throw new InvalidOperationException($"non-portable archive entry name: {name}");
            }

            if (Encoding.UTF8.GetByteCount(name) > MaxEntryNameByteCount)
            {
                throw new InvalidOperationException($"archive entry name exceeds {MaxEntryNameByteCount} bytes: {name}");
            }

            names.Add(name);
        }

        names.Sort(StringComparer.Ordinal);

        for (int index = 1; index < names.Count; index++)
        {
            if (StringComparer.OrdinalIgnoreCase.Equals(names[index - 1], names[index]))
            {
                throw new InvalidOperationException(
                    $"duplicate or case-colliding archive entry names: {names[index - 1]} and {names[index]}");
            }
        }

        if (names.Count == 0)
        {
            throw new InvalidOperationException($"archive directory holds no exportable files: {archiveDir}");
        }

        if (names.Count > MaxEntryCount)
        {
            throw new InvalidOperationException($"archive entry count is outside ZIP32: {names.Count}");
        }

        if (!names.Contains(ManifestEntryName, StringComparer.Ordinal)
            || !names.Contains(InventoryEntryName, StringComparer.Ordinal))
        {
            throw new InvalidOperationException(
                $"archive is missing {ManifestEntryName} and/or {InventoryEntryName} at its root: {archiveDir}");
        }

        return names;
    }

    /// <summary>
    /// Converts an absolute file path into its "/"-separated entry name. Only the platform
    /// separator is rewritten, so a literal backslash inside a file name on POSIX survives and
    /// is rejected by <see cref="IsPortableEntryName"/> rather than silently becoming a separator.
    /// </summary>
    private static string ToEntryName(string archiveDir, string path)
    {
        string relative = Path.GetRelativePath(archiveDir, path);
        return Path.DirectorySeparatorChar == '/'
            ? relative
            : relative.Replace(Path.DirectorySeparatorChar, '/');
    }

    private static void WriteContainer(string archiveDir, IReadOnlyList<string> names, Stream stream)
    {
        List<ContainerEntry> entries = new(names.Count);
        long offset = 0;

        foreach (string name in names)
        {
            byte[] nameBytes = Encoding.UTF8.GetBytes(name);
            byte[] data = File.ReadAllBytes(Path.Combine(archiveDir, name.Replace('/', Path.DirectorySeparatorChar)));
            RequireZip32(offset, name);
            RequireZip32(data.LongLength, name);

            uint crc32 = Crc32Of(data);
            WriteLocalHeader(stream, nameBytes, data, crc32);
            entries.Add(new ContainerEntry(nameBytes, (uint)data.Length, crc32, (uint)offset));
            offset += LocalHeaderSize + nameBytes.Length + data.LongLength;
        }

        long centralOffset = offset;
        foreach (ContainerEntry entry in entries)
        {
            WriteCentralHeader(stream, entry);
            offset += CentralHeaderSize + entry.Name.Length;
        }

        long centralSize = offset - centralOffset;
        RequireZip32(centralOffset, "central directory offset");
        RequireZip32(centralSize, "central directory size");
        WriteEndOfCentralDirectory(stream, entries.Count, (uint)centralSize, (uint)centralOffset);
    }

    private static void WriteLocalHeader(Stream stream, byte[] nameBytes, byte[] data, uint crc32)
    {
        Span<byte> header = stackalloc byte[LocalHeaderSize];
        BinaryPrimitives.WriteUInt32LittleEndian(header[..4], LocalHeaderSignature);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(4, 2), VersionNeeded);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(6, 2), GeneralPurposeFlags);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(8, 2), CompressionMethodStored);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(10, 2), FixedLastModifiedTime);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(12, 2), FixedLastModifiedDate);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(14, 4), crc32);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(18, 4), (uint)data.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(22, 4), (uint)data.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(26, 2), (ushort)nameBytes.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(28, 2), ZeroLength);

        stream.Write(header);
        stream.Write(nameBytes);
        stream.Write(data);
    }

    private static void WriteCentralHeader(Stream stream, ContainerEntry entry)
    {
        Span<byte> header = stackalloc byte[CentralHeaderSize];
        BinaryPrimitives.WriteUInt32LittleEndian(header[..4], CentralHeaderSignature);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(4, 2), VersionMadeBy);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(6, 2), VersionNeeded);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(8, 2), GeneralPurposeFlags);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(10, 2), CompressionMethodStored);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(12, 2), FixedLastModifiedTime);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(14, 2), FixedLastModifiedDate);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(16, 4), entry.Crc32);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(20, 4), entry.Size);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(24, 4), entry.Size);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(28, 2), (ushort)entry.Name.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(30, 2), ZeroLength);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(32, 2), ZeroLength);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(34, 2), ZeroLength);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(36, 2), ZeroLength);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(38, 4), ExternalFileAttributes);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(42, 4), entry.LocalOffset);

        stream.Write(header);
        stream.Write(entry.Name);
    }

    private static void WriteEndOfCentralDirectory(
        Stream stream,
        int entryCount,
        uint centralSize,
        uint centralOffset)
    {
        Span<byte> record = stackalloc byte[EndOfCentralDirectorySize];
        BinaryPrimitives.WriteUInt32LittleEndian(record[..4], EndOfCentralDirectorySignature);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(4, 2), ZeroLength);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(6, 2), ZeroLength);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(8, 2), (ushort)entryCount);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(10, 2), (ushort)entryCount);
        BinaryPrimitives.WriteUInt32LittleEndian(record.Slice(12, 4), centralSize);
        BinaryPrimitives.WriteUInt32LittleEndian(record.Slice(16, 4), centralOffset);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(20, 2), ZeroLength);

        stream.Write(record);
    }

    /// <summary>
    /// CRC-32 (IEEE, reflected polynomial 0xEDB88320) of <paramref name="data"/>.
    /// <see cref="Crc32.Hash(byte[])"/> emits the value in little-endian byte order, which is
    /// re-read here as a number so the header writer stays explicit about endianness.
    /// </summary>
    private static uint Crc32Of(byte[] data) =>
        BinaryPrimitives.ReadUInt32LittleEndian(Crc32.Hash(data));

    private static void RequireZip32(long value, string subject)
    {
        if (value > MaxZip32Value)
        {
            throw new InvalidOperationException($"archive exceeds ZIP32 fields ({value} bytes): {subject}");
        }
    }

    private readonly record struct ContainerEntry(byte[] Name, uint Size, uint Crc32, uint LocalOffset);
}
