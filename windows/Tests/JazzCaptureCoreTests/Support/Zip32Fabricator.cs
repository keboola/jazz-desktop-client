using System.Buffers.Binary;
using System.IO.Hashing;
using System.Text;

namespace JazzCaptureCoreTests.Support;

/// <summary>The pinned field values of the v1 container profile, shared by the fabricator and its entries.</summary>
internal static class Zip32Profile
{
    /// <summary>Local file header signature.</summary>
    public const uint LocalHeaderSignature = 0x0403_4B50;

    /// <summary>Central directory header signature.</summary>
    public const uint CentralHeaderSignature = 0x0201_4B50;

    /// <summary>End-of-central-directory signature.</summary>
    public const uint EndOfCentralDirectorySignature = 0x0605_4B50;

    /// <summary>Digital-signature record signature.</summary>
    public const uint DigitalSignatureSignature = 0x0505_4B50;

    /// <summary>ZIP64 end-of-central-directory locator signature.</summary>
    public const uint Zip64LocatorSignature = 0x0706_4B50;

    /// <summary>ZIP64 end-of-central-directory record signature.</summary>
    public const uint Zip64EndOfCentralDirectorySignature = 0x0606_4B50;

    /// <summary>Data-descriptor signature.</summary>
    public const uint DataDescriptorSignature = 0x0807_4B50;

    /// <summary>Version needed to extract: 2.0.</summary>
    public const ushort VersionNeeded = 20;

    /// <summary>Version made by: UNIX, specification 2.0.</summary>
    public const ushort VersionMadeBy = 0x0314;

    /// <summary>General-purpose flags: the UTF-8 name bit alone.</summary>
    public const ushort Flags = 0x0800;

    /// <summary>Compression method: stored.</summary>
    public const ushort MethodStored = 0;

    /// <summary>Fixed DOS modification time.</summary>
    public const ushort ModifiedTime = 0;

    /// <summary>Fixed DOS modification date: 1980-01-01.</summary>
    public const ushort ModifiedDate = 0x0021;

    /// <summary>Regular file, mode 0o100644, in the high word.</summary>
    public const uint RegularFileAttributes = 0x81A4_0000;

    /// <summary>Directory mode 0o40755 in the high word — a directory entry, which v1 forbids.</summary>
    public const uint DirectoryAttributes = 0x41ED_0000;

    /// <summary>Symlink mode 0o120777 in the high word — a link entry, which v1 forbids.</summary>
    public const uint SymlinkAttributes = 0xA1FF_0000;
}

/// <summary>
/// Builds ".jazz-archive" container bytes field by field, so a test can emit the canonical v1 layout
/// and then break exactly one rule.
/// </summary>
/// <remarks>
/// The reader under test must reject every ZIP feature outside the v1 profile, and the only way to
/// prove it does is to hand it a package that actually carries that feature. A ZIP library cannot
/// produce most of them on demand — no mainstream writer will emit an entry comment next to a
/// canonical header, or a ZIP64 locator on a 300-byte archive — so the bytes are assembled here
/// instead. Every default matches <c>JazzArchiveContainer</c>; a test overrides one field and asserts
/// the refusal.
/// </remarks>
internal sealed class Zip32Fabricator
{
    private readonly List<EntrySpec> _entries = new();

    /// <summary>Bytes written before the first local header.</summary>
    public byte[] Prefix { get; set; } = Array.Empty<byte>();

    /// <summary>Bytes written between the last local entry and the central directory.</summary>
    public byte[] Gap { get; set; } = Array.Empty<byte>();

    /// <summary>Bytes written between the central directory and the EOCD.</summary>
    public byte[] AfterCentralDirectory { get; set; } = Array.Empty<byte>();

    /// <summary>Whether <see cref="AfterCentralDirectory"/> counts inside the declared directory size.</summary>
    public bool CountAfterCentralDirectory { get; set; }

    /// <summary>Bytes written after the EOCD record.</summary>
    public byte[] Trailer { get; set; } = Array.Empty<byte>();

    /// <summary>Archive comment; a non-empty value also sets the EOCD comment length.</summary>
    public byte[] ArchiveComment { get; set; } = Array.Empty<byte>();

    /// <summary>Overrides the EOCD entry counts.</summary>
    public ushort? EntryCountOverride { get; set; }

    /// <summary>Overrides the EOCD "entries on this disk" count alone.</summary>
    public ushort? EntriesOnDiskOverride { get; set; }

    /// <summary>Overrides the EOCD disk number.</summary>
    public ushort? DiskNumberOverride { get; set; }

    /// <summary>Overrides the declared central directory size.</summary>
    public uint? CentralSizeOverride { get; set; }

    /// <summary>Overrides the declared central directory offset.</summary>
    public uint? CentralOffsetOverride { get; set; }

    /// <summary>Emits the entries in the order added rather than sorted by name.</summary>
    public bool PreserveOrder { get; set; }

    /// <summary>Adds one entry, optionally overriding its header fields.</summary>
    public Zip32Fabricator Add(string name, string content, Action<EntrySpec>? configure = null)
    {
        var spec = new EntrySpec(name, Encoding.UTF8.GetBytes(content));
        configure?.Invoke(spec);
        _entries.Add(spec);
        return this;
    }

    /// <summary>A fabricator holding the two entries every package must carry.</summary>
    public static Zip32Fabricator Minimal()
    {
        var fabricator = new Zip32Fabricator();
        fabricator.Add("inventory.json", "{\"algorithm\":\"sha256\",\"entries\":[]}");
        fabricator.Add("manifest.json", "{\"format\":\"dev.jazz.archive\"}");
        return fabricator;
    }

    /// <summary>Serializes the container.</summary>
    public byte[] Build()
    {
        List<EntrySpec> ordered = PreserveOrder
            ? _entries
            : _entries.OrderBy(entry => entry.Name, StringComparer.Ordinal).ToList();

        using var stream = new MemoryStream();
        stream.Write(Prefix);

        var offsets = new List<long>(ordered.Count);
        foreach (EntrySpec entry in ordered)
        {
            offsets.Add(stream.Position);
            WriteLocalHeader(stream, entry);
            stream.Write(entry.LocalNameBytes ?? Encoding.UTF8.GetBytes(entry.Name));
            stream.Write(entry.Data);
            stream.Write(entry.DataDescriptor);
        }

        stream.Write(Gap);

        long centralOffset = stream.Position;
        for (int index = 0; index < ordered.Count; index++)
        {
            WriteCentralHeader(stream, ordered[index], (uint)offsets[index]);
            stream.Write(Encoding.UTF8.GetBytes(ordered[index].Name));
            stream.Write(ordered[index].CentralExtraField);
            stream.Write(ordered[index].CentralComment);
        }

        long centralSize = stream.Position - centralOffset;
        stream.Write(AfterCentralDirectory);
        if (CountAfterCentralDirectory)
        {
            centralSize += AfterCentralDirectory.Length;
        }

        WriteEndOfCentralDirectory(
            stream,
            (ushort)ordered.Count,
            CentralSizeOverride ?? (uint)centralSize,
            CentralOffsetOverride ?? (uint)centralOffset);

        stream.Write(Trailer);
        return stream.ToArray();
    }

    /// <summary>A 20-byte ZIP64 end-of-central-directory locator.</summary>
    public static byte[] Zip64Locator()
    {
        byte[] locator = new byte[20];
        BinaryPrimitives.WriteUInt32LittleEndian(locator, Zip32Profile.Zip64LocatorSignature);
        return locator;
    }

    /// <summary>A 56-byte ZIP64 end-of-central-directory record.</summary>
    public static byte[] Zip64EndOfCentralDirectory()
    {
        byte[] record = new byte[56];
        BinaryPrimitives.WriteUInt32LittleEndian(record, Zip32Profile.Zip64EndOfCentralDirectorySignature);
        return record;
    }

    /// <summary>A 46-byte digital-signature record, sized to look like a central header.</summary>
    public static byte[] DigitalSignatureRecord()
    {
        byte[] record = new byte[46];
        BinaryPrimitives.WriteUInt32LittleEndian(record, Zip32Profile.DigitalSignatureSignature);
        return record;
    }

    /// <summary>A 16-byte data descriptor for <paramref name="data"/>.</summary>
    public static byte[] DataDescriptor(byte[] data)
    {
        byte[] descriptor = new byte[16];
        BinaryPrimitives.WriteUInt32LittleEndian(descriptor.AsSpan(0, 4), Zip32Profile.DataDescriptorSignature);
        BinaryPrimitives.WriteUInt32LittleEndian(descriptor.AsSpan(4, 4), Crc32Of(data));
        BinaryPrimitives.WriteUInt32LittleEndian(descriptor.AsSpan(8, 4), (uint)data.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(descriptor.AsSpan(12, 4), (uint)data.Length);
        return descriptor;
    }

    /// <summary>CRC-32 (IEEE) of <paramref name="data"/> as a number.</summary>
    public static uint Crc32Of(byte[] data) =>
        BinaryPrimitives.ReadUInt32LittleEndian(Crc32.Hash(data));

    private static void WriteLocalHeader(Stream stream, EntrySpec entry)
    {
        Span<byte> header = stackalloc byte[30];
        BinaryPrimitives.WriteUInt32LittleEndian(header[..4], entry.LocalSignature);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(4, 2), entry.LocalVersionNeeded);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(6, 2), entry.LocalFlags);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(8, 2), entry.LocalMethod);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(10, 2), entry.LocalModifiedTime);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(12, 2), entry.LocalModifiedDate);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(14, 4), entry.LocalCrc32 ?? Crc32Of(entry.Data));
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(18, 4), entry.LocalCompressedSize ?? (uint)entry.Data.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(22, 4), entry.LocalExpandedSize ?? (uint)entry.Data.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(
            header.Slice(26, 2),
            (ushort)(entry.LocalNameBytes ?? Encoding.UTF8.GetBytes(entry.Name)).Length);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(28, 2), entry.LocalExtraFieldLength);

        stream.Write(header);
    }

    private static void WriteCentralHeader(Stream stream, EntrySpec entry, uint localOffset)
    {
        Span<byte> header = stackalloc byte[46];
        BinaryPrimitives.WriteUInt32LittleEndian(header[..4], Zip32Profile.CentralHeaderSignature);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(4, 2), entry.VersionMadeBy);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(6, 2), entry.VersionNeeded);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(8, 2), entry.Flags);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(10, 2), entry.Method);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(12, 2), entry.ModifiedTime);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(14, 2), entry.ModifiedDate);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(16, 4), entry.Crc32 ?? Crc32Of(entry.Data));
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(20, 4), entry.CompressedSize ?? (uint)entry.Data.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(24, 4), entry.ExpandedSize ?? (uint)entry.Data.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(
            header.Slice(28, 2),
            (ushort)Encoding.UTF8.GetByteCount(entry.Name));
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(30, 2), (ushort)entry.CentralExtraField.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(32, 2), (ushort)entry.CentralComment.Length);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(34, 2), entry.DiskStart);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(36, 2), entry.InternalAttributes);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(38, 4), entry.ExternalAttributes);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(42, 4), entry.LocalOffsetOverride ?? localOffset);

        stream.Write(header);
    }

    private void WriteEndOfCentralDirectory(Stream stream, ushort entryCount, uint centralSize, uint centralOffset)
    {
        Span<byte> record = stackalloc byte[22];
        BinaryPrimitives.WriteUInt32LittleEndian(record[..4], Zip32Profile.EndOfCentralDirectorySignature);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(4, 2), DiskNumberOverride ?? 0);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(6, 2), 0);
        BinaryPrimitives.WriteUInt16LittleEndian(
            record.Slice(8, 2),
            EntriesOnDiskOverride ?? EntryCountOverride ?? entryCount);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(10, 2), EntryCountOverride ?? entryCount);
        BinaryPrimitives.WriteUInt32LittleEndian(record.Slice(12, 4), centralSize);
        BinaryPrimitives.WriteUInt32LittleEndian(record.Slice(16, 4), centralOffset);
        BinaryPrimitives.WriteUInt16LittleEndian(record.Slice(20, 2), (ushort)ArchiveComment.Length);

        stream.Write(record);
        stream.Write(ArchiveComment);
    }

    /// <summary>One entry, with every header field overridable.</summary>
    internal sealed class EntrySpec
    {
        public EntrySpec(string name, byte[] data)
        {
            Name = name;
            Data = data;
        }

        /// <summary>The entry name written to the central header.</summary>
        public string Name { get; }

        /// <summary>The stored bytes.</summary>
        public byte[] Data { get; set; }

        /// <summary>Local header signature.</summary>
        public uint LocalSignature { get; set; } = Zip32Profile.LocalHeaderSignature;

        /// <summary>Local "version needed to extract".</summary>
        public ushort LocalVersionNeeded { get; set; } = Zip32Profile.VersionNeeded;

        /// <summary>Local general-purpose flags.</summary>
        public ushort LocalFlags { get; set; } = Zip32Profile.Flags;

        /// <summary>Local compression method.</summary>
        public ushort LocalMethod { get; set; } = Zip32Profile.MethodStored;

        /// <summary>Local DOS modification time.</summary>
        public ushort LocalModifiedTime { get; set; } = Zip32Profile.ModifiedTime;

        /// <summary>Local DOS modification date.</summary>
        public ushort LocalModifiedDate { get; set; } = Zip32Profile.ModifiedDate;

        /// <summary>Local CRC-32; the CRC of the data when unset.</summary>
        public uint? LocalCrc32 { get; set; }

        /// <summary>Local compressed size; the data length when unset.</summary>
        public uint? LocalCompressedSize { get; set; }

        /// <summary>Local uncompressed size; the data length when unset.</summary>
        public uint? LocalExpandedSize { get; set; }

        /// <summary>Declared local extra-field length; the field bytes themselves are not written.</summary>
        public ushort LocalExtraFieldLength { get; set; }

        /// <summary>Name bytes written in the local header; <see cref="Name"/> when unset.</summary>
        public byte[]? LocalNameBytes { get; set; }

        /// <summary>Bytes written after the entry data.</summary>
        public byte[] DataDescriptor { get; set; } = Array.Empty<byte>();

        /// <summary>Central "version made by".</summary>
        public ushort VersionMadeBy { get; set; } = Zip32Profile.VersionMadeBy;

        /// <summary>Central "version needed to extract".</summary>
        public ushort VersionNeeded { get; set; } = Zip32Profile.VersionNeeded;

        /// <summary>Central general-purpose flags.</summary>
        public ushort Flags { get; set; } = Zip32Profile.Flags;

        /// <summary>Central compression method.</summary>
        public ushort Method { get; set; } = Zip32Profile.MethodStored;

        /// <summary>Central DOS modification time.</summary>
        public ushort ModifiedTime { get; set; } = Zip32Profile.ModifiedTime;

        /// <summary>Central DOS modification date.</summary>
        public ushort ModifiedDate { get; set; } = Zip32Profile.ModifiedDate;

        /// <summary>Central CRC-32; the CRC of the data when unset.</summary>
        public uint? Crc32 { get; set; }

        /// <summary>Central compressed size; the data length when unset.</summary>
        public uint? CompressedSize { get; set; }

        /// <summary>Central uncompressed size; the data length when unset.</summary>
        public uint? ExpandedSize { get; set; }

        /// <summary>Central extra field.</summary>
        public byte[] CentralExtraField { get; set; } = Array.Empty<byte>();

        /// <summary>Central entry comment.</summary>
        public byte[] CentralComment { get; set; } = Array.Empty<byte>();

        /// <summary>Central disk-start number.</summary>
        public ushort DiskStart { get; set; }

        /// <summary>Central internal attributes.</summary>
        public ushort InternalAttributes { get; set; }

        /// <summary>Central external attributes.</summary>
        public uint ExternalAttributes { get; set; } = Zip32Profile.RegularFileAttributes;

        /// <summary>Central relative offset of the local header; the real offset when unset.</summary>
        public uint? LocalOffsetOverride { get; set; }
    }
}
