using System.Buffers.Binary;
using System.Globalization;
using System.IO.Hashing;
using System.Security.Cryptography;
using System.Text;

namespace JazzCaptureCore.Archive;

/// <summary>
/// Reads the ".jazz-archive" container profile v1 — the exact inverse of
/// <see cref="JazzArchiveContainer"/>, and strict by construction: it accepts only what that writer
/// emits and rejects everything else <em>before</em> any entry body is read.
/// </summary>
/// <remarks>
/// <para>
/// <c>System.IO.Compression</c> is deliberately absent. A general ZIP reader is permissive by design:
/// it tolerates prefixes, extra fields, data descriptors, ZIP64 promotion and trailing bytes, because
/// tolerance is what makes it useful against the ZIPs of the world. Here tolerance is the
/// vulnerability. The package SHA-256 and byte length are durable delivery provenance, so a receiver
/// that silently normalizes a non-canonical package has published bytes nobody agreed to; the profile
/// therefore has exactly one legal layout and this reader enforces it field by field.
/// </para>
/// <para>
/// Order of work matters as much as the checks themselves. The EOCD and the whole central directory
/// are validated first, including every declared size against the ingest envelope, and only then are
/// the local headers walked and the bodies streamed out. A hostile package is refused on its own
/// declarations rather than on the memory it manages to consume.
/// </para>
/// <para>Rules: ANNEX-ARCHIVE sections 1.1, 1.2 and 1.4, and contract/README.md
/// "Canonical desktop ZIP32 profile".</para>
/// </remarks>
public static class JazzArchiveContainerReader
{
    private const uint LocalHeaderSignature = 0x0403_4B50;
    private const uint CentralHeaderSignature = 0x0201_4B50;
    private const uint EndOfCentralDirectorySignature = 0x0605_4B50;

    /// <summary>ZIP64 end-of-central-directory locator; its presence alone puts a package outside v1.</summary>
    private const uint Zip64LocatorSignature = 0x0706_4B50;

    /// <summary>ZIP64 end-of-central-directory record.</summary>
    private const uint Zip64EndOfCentralDirectorySignature = 0x0606_4B50;

    private const ushort VersionNeeded = 20;
    private const ushort VersionMadeBy = 0x0314;
    private const ushort GeneralPurposeFlags = 0x0800;
    private const ushort CompressionMethodStored = 0;
    private const ushort FixedLastModifiedTime = 0;
    private const ushort FixedLastModifiedDate = 0x0021;
    private const uint ExternalFileAttributes = 0x81A4_0000;

    private const int LocalHeaderSize = 30;
    private const int CentralHeaderSize = 46;
    private const int EndOfCentralDirectorySize = 22;

    /// <summary>Any 16-bit field at this value is a ZIP64 sentinel.</summary>
    private const ushort Zip64Sentinel16 = 0xFFFF;

    /// <summary>Any 32-bit field at this value is a ZIP64 sentinel.</summary>
    private const uint Zip64Sentinel32 = 0xFFFF_FFFF;

    private const string ManifestEntryName = "manifest.json";
    private const string InventoryEntryName = "inventory.json";

    /// <summary>Bytes moved per read while streaming an entry body out to disk.</summary>
    private const int ChunkSize = 64 * 1024;

    /// <summary>
    /// Verifies the container at <paramref name="packagePath"/> and expands it into
    /// <paramref name="destinationDirectory"/>, which must already exist and should be empty.
    /// </summary>
    /// <returns>
    /// One fingerprint per extracted entry, keyed by its "/"-separated entry name. The caller
    /// compares this against the archive's own inventory: the container proved the bytes arrived
    /// intact, the inventory proves they are the bytes the archive claims.
    /// </returns>
    /// <exception cref="JazzArchiveImportException">
    /// The package is outside the v1 profile, breaches the ingest envelope, or fails CRC-32.
    /// </exception>
    public static IReadOnlyDictionary<string, JazzArchiveFileFingerprint> Extract(
        string packagePath,
        string destinationDirectory,
        JazzArchiveImportLimits limits)
    {
        ArgumentException.ThrowIfNullOrEmpty(packagePath);
        ArgumentException.ThrowIfNullOrEmpty(destinationDirectory);
        ArgumentNullException.ThrowIfNull(limits);
        limits.Validate();

        using FileStream stream = new(packagePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        long length = stream.Length;
        if (length <= 0 || length > limits.MaxArchiveBytes)
        {
            throw JazzArchiveImportException.ArchiveTooLarge(
                Format("{0} bytes", length));
        }

        (IReadOnlyList<ContainerEntry> entries, long centralOffset) = InspectCentralDirectory(stream, length, limits);
        return ExtractEntries(stream, entries, centralOffset, Path.GetFullPath(destinationDirectory));
    }

    /// <summary>
    /// Validates the EOCD and every central header, and returns the entries plus the offset the
    /// local-entry region must end at. Nothing here reads an entry body.
    /// </summary>
    private static (IReadOnlyList<ContainerEntry> Entries, long CentralOffset) InspectCentralDirectory(
        FileStream stream,
        long length,
        JazzArchiveImportLimits limits)
    {
        if (length < EndOfCentralDirectorySize)
        {
            throw JazzArchiveImportException.MalformedZip("missing EOCD");
        }

        byte[] eocd = ReadExact(stream, length - EndOfCentralDirectorySize, EndOfCentralDirectorySize);
        if (U32(eocd, 0) != EndOfCentralDirectorySignature)
        {
            throw JazzArchiveImportException.MalformedZip("EOCD signature");
        }

        ushort thisDisk = U16(eocd, 4);
        ushort centralDirectoryDisk = U16(eocd, 6);
        ushort entriesOnDisk = U16(eocd, 8);
        ushort totalEntries = U16(eocd, 10);
        uint centralSize = U32(eocd, 12);
        uint centralOffset32 = U32(eocd, 16);
        ushort commentLength = U16(eocd, 20);

        if (thisDisk != 0 || centralDirectoryDisk != 0 || entriesOnDisk != totalEntries)
        {
            throw JazzArchiveImportException.UnsupportedZipFeature("multi-disk EOCD");
        }

        // A non-zero comment length is how an archive comment is declared, and it is also the only
        // way the EOCD could stop being the final 22 bytes while still parsing.
        if (commentLength != 0)
        {
            throw JazzArchiveImportException.UnsupportedZipFeature("archive comment");
        }

        if (totalEntries == Zip64Sentinel16
            || centralSize == Zip64Sentinel32
            || centralOffset32 == Zip64Sentinel32)
        {
            throw JazzArchiveImportException.UnsupportedZipFeature("ZIP64 sentinel in EOCD");
        }

        if (totalEntries == 0)
        {
            throw JazzArchiveImportException.InvalidArchive("package holds no entries");
        }

        if (totalEntries > limits.MaxEntries)
        {
            throw JazzArchiveImportException.EntryLimitExceeded(
                Format("entry count {0}", totalEntries));
        }

        long centralOffset = centralOffset32;
        long centralEnd = Add(centralOffset, centralSize);

        // One equation forbids three separate things at once: a ZIP64 record or locator between the
        // central directory and the EOCD, a gap there, and any trailing byte before it.
        if (centralEnd != length - EndOfCentralDirectorySize)
        {
            RejectZip64Records(stream, length);
            throw JazzArchiveImportException.MalformedZip("central directory boundary");
        }

        var entries = new List<ContainerEntry>(totalEntries);
        var exactNames = new HashSet<string>(StringComparer.Ordinal);
        var collisionKeys = new HashSet<string>(StringComparer.Ordinal);
        string? previousName = null;
        long totalExpanded = 0;
        long totalStructured = 0;
        long cursor = centralOffset;

        for (int index = 0; index < totalEntries; index++)
        {
            if (Add(cursor, CentralHeaderSize) > centralEnd)
            {
                throw JazzArchiveImportException.MalformedZip("truncated central header");
            }

            byte[] header = ReadExact(stream, cursor, CentralHeaderSize);
            if (U32(header, 0) != CentralHeaderSignature)
            {
                // The digital-signature record (0x05054b50) and a ZIP64 record both land here.
                throw JazzArchiveImportException.UnsupportedZipFeature(
                    Format("central header signature 0x{0:x8}", U32(header, 0)));
            }

            if (U16(header, 4) != VersionMadeBy
                || U16(header, 6) != VersionNeeded
                || U16(header, 8) != GeneralPurposeFlags
                || U16(header, 10) != CompressionMethodStored
                || U16(header, 12) != FixedLastModifiedTime
                || U16(header, 14) != FixedLastModifiedDate)
            {
                // The pinned flag word is what rejects encryption (bit 0) and the data-descriptor
                // bit (bit 3) together with any other general-purpose flag; the pinned method word
                // rejects DEFLATE and every other compression method.
                throw JazzArchiveImportException.UnsupportedZipFeature("central header profile");
            }

            uint crc32 = U32(header, 16);
            uint compressedSize = U32(header, 20);
            uint expandedSize = U32(header, 24);
            int nameLength = U16(header, 28);
            ushort extraLength = U16(header, 30);
            ushort entryCommentLength = U16(header, 32);
            ushort diskStart = U16(header, 34);
            ushort internalAttributes = U16(header, 36);
            uint externalAttributes = U32(header, 38);
            uint localOffset = U32(header, 42);

            if (compressedSize == Zip64Sentinel32
                || expandedSize == Zip64Sentinel32
                || localOffset == Zip64Sentinel32)
            {
                throw JazzArchiveImportException.UnsupportedZipFeature("ZIP64 sentinel in central header");
            }

            if (compressedSize != expandedSize)
            {
                throw JazzArchiveImportException.UnsupportedZipFeature("compressed entry");
            }

            if (extraLength != 0)
            {
                throw JazzArchiveImportException.UnsupportedZipFeature("central extra field");
            }

            if (entryCommentLength != 0)
            {
                throw JazzArchiveImportException.UnsupportedZipFeature("entry comment");
            }

            if (diskStart != 0 || internalAttributes != 0)
            {
                throw JazzArchiveImportException.UnsupportedZipFeature("entry disk or internal attributes");
            }

            // 0o100644 is a regular file. A directory entry (0o40000), a symlink (0o120000) and
            // every device, socket and FIFO carry a different type nibble and are refused here.
            if (externalAttributes != ExternalFileAttributes)
            {
                throw JazzArchiveImportException.UnsafeEntry(
                    Format("entry external attributes 0x{0:x8}", externalAttributes));
            }

            if (nameLength <= 0 || nameLength > limits.MaxPathBytes)
            {
                throw JazzArchiveImportException.EntryLimitExceeded(
                    Format("entry name length {0}", nameLength));
            }

            if (expandedSize > limits.MaxEntryBytes)
            {
                throw JazzArchiveImportException.EntryLimitExceeded(
                    Format("entry bytes {0}", expandedSize));
            }

            long nameOffset = Add(cursor, CentralHeaderSize);
            byte[] nameBytes = ReadExact(stream, nameOffset, nameLength);
            string name = DecodeUtf8(nameBytes);
            JazzArchivePortablePath.Validate(name, limits.MaxPathBytes);

            if (!exactNames.Add(name))
            {
                throw JazzArchiveImportException.DuplicateEntry(name);
            }

            if (!collisionKeys.Add(JazzArchivePortablePath.CollisionKey(name)))
            {
                throw JazzArchiveImportException.DuplicateEntry(name);
            }

            // Ordinal comparison is UTF-8 byte order over the portable ASCII subset, which the
            // name has already been restricted to.
            if (previousName is not null && string.CompareOrdinal(previousName, name) >= 0)
            {
                throw JazzArchiveImportException.MalformedZip(
                    Format("entry order: {0} after {1}", name, previousName));
            }

            previousName = name;
            totalExpanded = BoundedAdd(
                totalExpanded,
                expandedSize,
                limits.MaxTotalExpandedBytes,
                "total expanded bytes");

            if (IsStructured(name))
            {
                totalStructured = BoundedAdd(
                    totalStructured,
                    expandedSize,
                    limits.MaxTotalStructuredBytes,
                    "total structured bytes");

                if (name.EndsWith(".json", StringComparison.Ordinal) && expandedSize > limits.MaxJsonEntryBytes)
                {
                    throw JazzArchiveImportException.EntryLimitExceeded(name);
                }
            }

            entries.Add(new ContainerEntry(name, nameBytes.Length, crc32, expandedSize, localOffset));
            cursor = Add(nameOffset, nameLength);
        }

        if (cursor != centralEnd)
        {
            throw JazzArchiveImportException.MalformedZip("central directory size");
        }

        if (!exactNames.Contains(ManifestEntryName) || !exactNames.Contains(InventoryEntryName))
        {
            throw JazzArchiveImportException.InvalidArchive(
                "package is missing manifest.json and/or inventory.json at its root");
        }

        return (entries, centralOffset);
    }

    /// <summary>
    /// Names ZIP64 as the reason a central-directory boundary did not add up, when a ZIP64 locator or
    /// record is what is sitting in the space.
    /// </summary>
    /// <remarks>
    /// This runs only after the boundary equation has already failed, never before it. Probing a
    /// well-formed package for a signature at a fixed offset would risk reading four bytes of some
    /// entry's CRC as if they were a record header and refusing a package that is perfectly valid; a
    /// package that has already failed cannot be made more refused, so the probe is free there and
    /// buys a message that says ZIP64 instead of arithmetic.
    /// </remarks>
    private static void RejectZip64Records(FileStream stream, long length)
    {
        const int LocatorSize = 20;
        if (length < EndOfCentralDirectorySize + LocatorSize)
        {
            return;
        }

        uint signature = U32(
            ReadExact(stream, length - EndOfCentralDirectorySize - LocatorSize, 4),
            0);

        if (signature == Zip64LocatorSignature)
        {
            throw JazzArchiveImportException.UnsupportedZipFeature(
                "ZIP64 end of central directory locator");
        }

        if (signature == Zip64EndOfCentralDirectorySignature)
        {
            throw JazzArchiveImportException.UnsupportedZipFeature(
                "ZIP64 end of central directory record");
        }
    }

    /// <summary>
    /// Walks the local entries in central-directory order, proving each one starts exactly where the
    /// previous one ended, and streams its body out under a CRC-32 and a SHA-256.
    /// </summary>
    private static IReadOnlyDictionary<string, JazzArchiveFileFingerprint> ExtractEntries(
        FileStream stream,
        IReadOnlyList<ContainerEntry> entries,
        long centralOffset,
        string destinationRoot)
    {
        var fingerprints = new Dictionary<string, JazzArchiveFileFingerprint>(entries.Count, StringComparer.Ordinal);

        // Starting the cursor at zero is what forbids a prefix: the first local header must be the
        // first byte of the package, so a self-extracting stub or any other preamble has nowhere to sit.
        long cursor = 0;
        foreach (ContainerEntry entry in entries)
        {
            if (entry.LocalOffset != cursor)
            {
                throw JazzArchiveImportException.MalformedZip(
                    Format("non-contiguous local entries at {0}", entry.Name));
            }

            byte[] header = ReadExact(stream, cursor, LocalHeaderSize);
            if (U32(header, 0) != LocalHeaderSignature)
            {
                throw JazzArchiveImportException.MalformedZip("local header signature");
            }

            if (U16(header, 4) != VersionNeeded
                || U16(header, 6) != GeneralPurposeFlags
                || U16(header, 8) != CompressionMethodStored
                || U16(header, 10) != FixedLastModifiedTime
                || U16(header, 12) != FixedLastModifiedDate)
            {
                throw JazzArchiveImportException.UnsupportedZipFeature(
                    "local header profile " + entry.Name);
            }

            if (U32(header, 14) != entry.Crc32
                || U32(header, 18) != entry.Size
                || U32(header, 22) != entry.Size)
            {
                throw JazzArchiveImportException.MalformedZip(
                    "local and central headers disagree: " + entry.Name);
            }

            if (U16(header, 26) != entry.NameByteCount || U16(header, 28) != 0)
            {
                throw JazzArchiveImportException.UnsupportedZipFeature(
                    "local extra field or filename length: " + entry.Name);
            }

            byte[] nameBytes = ReadExact(stream, Add(cursor, LocalHeaderSize), entry.NameByteCount);
            if (!string.Equals(DecodeUtf8(nameBytes), entry.Name, StringComparison.Ordinal))
            {
                throw JazzArchiveImportException.MalformedZip(
                    "local and central filenames disagree: " + entry.Name);
            }

            long dataOffset = Add(cursor, LocalHeaderSize + entry.NameByteCount);
            long dataEnd = Add(dataOffset, entry.Size);
            if (dataEnd > centralOffset)
            {
                throw JazzArchiveImportException.MalformedZip(
                    "entry overlaps the central directory: " + entry.Name);
            }

            fingerprints[entry.Name] = WriteEntry(stream, entry, dataOffset, destinationRoot);
            cursor = dataEnd;
        }

        // Anything between the last entry body and the central directory is a gap, a data
        // descriptor, or an unlisted entry. All three are forbidden and all three land here.
        if (cursor != centralOffset)
        {
            throw JazzArchiveImportException.MalformedZip("orphan local bytes");
        }

        return fingerprints;
    }

    /// <summary>Streams one entry body to disk, verifying its CRC-32 and fingerprinting its bytes.</summary>
    private static JazzArchiveFileFingerprint WriteEntry(
        FileStream stream,
        ContainerEntry entry,
        long dataOffset,
        string destinationRoot)
    {
        string target = Path.GetFullPath(
            Path.Combine(destinationRoot, entry.Name.Replace('/', Path.DirectorySeparatorChar)));

        // The name has already been proven relative and free of "..", so this cannot fail; it is
        // kept because a path-traversal escape must be impossible by check as well as by argument.
        if (!target.StartsWith(destinationRoot + Path.DirectorySeparatorChar, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.UnsafeEntry(entry.Name);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(target)!);

        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var crc = new Crc32();
        long remaining = entry.Size;

        // CreateNew rather than Create: two entries resolving to one file is a collision the name
        // checks are meant to have caught, and silently overwriting would hide that they did not.
        using (FileStream output = new(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            stream.Seek(dataOffset, SeekOrigin.Begin);
            byte[] buffer = new byte[ChunkSize];
            while (remaining > 0)
            {
                int wanted = (int)Math.Min(ChunkSize, remaining);
                int read = stream.Read(buffer, 0, wanted);
                if (read <= 0)
                {
                    throw JazzArchiveImportException.MalformedZip("truncated entry " + entry.Name);
                }

                output.Write(buffer, 0, read);
                hasher.AppendData(buffer, 0, read);
                crc.Append(buffer.AsSpan(0, read));
                remaining -= read;
            }

            output.Flush(flushToDisk: true);
        }

        uint actualCrc = BinaryPrimitives.ReadUInt32LittleEndian(crc.GetCurrentHash());
        if (actualCrc != entry.Crc32)
        {
            throw JazzArchiveImportException.IntegrityMismatch("CRC-32 " + entry.Name);
        }

        return new JazzArchiveFileFingerprint(
            Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant(),
            entry.Size);
    }

    private static bool IsStructured(string name) =>
        name.EndsWith(".json", StringComparison.Ordinal)
        || name.EndsWith(".ndjson", StringComparison.Ordinal);

    private static string DecodeUtf8(byte[] bytes)
    {
        try
        {
            return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true)
                .GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            throw JazzArchiveImportException.UnsafeEntry("entry name is not valid UTF-8");
        }
    }

    private static byte[] ReadExact(FileStream stream, long offset, int count)
    {
        if (offset < 0 || count < 0 || offset + count > stream.Length)
        {
            throw JazzArchiveImportException.MalformedZip("truncated package");
        }

        stream.Seek(offset, SeekOrigin.Begin);
        byte[] buffer = new byte[count];
        int filled = 0;
        while (filled < count)
        {
            int read = stream.Read(buffer, filled, count - filled);
            if (read <= 0)
            {
                throw JazzArchiveImportException.MalformedZip("truncated package");
            }

            filled += read;
        }

        return buffer;
    }

    private static long Add(long left, long right)
    {
        try
        {
            return checked(left + right);
        }
        catch (OverflowException)
        {
            throw JazzArchiveImportException.MalformedZip("integer overflow");
        }
    }

    private static long BoundedAdd(long left, long right, long limit, string subject)
    {
        long value = Add(left, right);
        if (value > limit)
        {
            throw JazzArchiveImportException.EntryLimitExceeded(
                Format("{0} {1} exceeds {2}", subject, value, limit));
        }

        return value;
    }

    private static ushort U16(byte[] buffer, int offset) =>
        BinaryPrimitives.ReadUInt16LittleEndian(buffer.AsSpan(offset, 2));

    private static uint U32(byte[] buffer, int offset) =>
        BinaryPrimitives.ReadUInt32LittleEndian(buffer.AsSpan(offset, 4));

    private static string Format(string template, params object[] arguments) =>
        string.Format(CultureInfo.InvariantCulture, template, arguments);

    /// <summary>One central-directory entry, as declared before any body was read.</summary>
    private readonly record struct ContainerEntry(
        string Name,
        int NameByteCount,
        uint Crc32,
        uint Size,
        uint LocalOffset);
}
