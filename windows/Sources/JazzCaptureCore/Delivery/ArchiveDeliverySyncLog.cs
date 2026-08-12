using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Delivery;

/// <summary>
/// The <c>sync/delivery.ndjson</c> working state that lives inside an archive directory.
/// </summary>
/// <remarks>
/// <para>
/// This file is the one mutable thing inside an otherwise frozen archive directory, and it is
/// mutable precisely because nothing depends on it: <c>ArchiveWriter</c> leaves the whole
/// <c>sync/</c> subtree out of the inventory, and <c>JazzArchiveContainer</c> leaves it out of the
/// exported container. Delivery state can therefore change any number of times without moving the
/// inventory digest, the manifest content digest, or a single byte of the package.
/// </para>
/// <para>
/// One line per delivery, keyed by delivery identity: a rewrite replaces the line for that delivery
/// and leaves any other alone, so an archive delivered over two transports keeps both states. It is
/// state, not a history — the durable record in the queue is the authority and this is its readable
/// projection.
/// </para>
/// </remarks>
public static class ArchiveDeliverySyncLog
{
    /// <summary>Name of the never-exported working-state subtree.</summary>
    public const string DirectoryName = "sync";

    /// <summary>Name of the delivery state file inside it.</summary>
    public const string FileName = "delivery.ndjson";

    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>Absolute path of the delivery state file for an archive directory.</summary>
    public static string PathFor(string archiveDirectory)
    {
        ArgumentException.ThrowIfNullOrEmpty(archiveDirectory);
        return Path.Combine(archiveDirectory, DirectoryName, FileName);
    }

    /// <summary>
    /// Reads every delivery state in the file, in the order written. An absent file is an empty
    /// list; a damaged line is skipped rather than allowed to hide the states beside it.
    /// </summary>
    public static IReadOnlyList<DeliveryStateDocument> Read(string archiveDirectory)
    {
        string path = PathFor(archiveDirectory);
        if (!File.Exists(path))
        {
            return Array.Empty<DeliveryStateDocument>();
        }

        var documents = new List<DeliveryStateDocument>();
        foreach (string line in Utf8NoBom.GetString(File.ReadAllBytes(path)).Split('\n'))
        {
            if (line.Length == 0)
            {
                continue;
            }

            try
            {
                if (JsonStrictParser.Parse(line) is JsonObject value)
                {
                    documents.Add(DeliveryStateDocument.FromJson(value));
                }
            }
            catch (FormatException)
            {
                // Working state, not evidence: an unreadable line is dropped on the next rewrite.
            }
        }

        return documents;
    }

    /// <summary>
    /// Writes <paramref name="document"/> into the file, replacing the line for the same delivery
    /// and leaving every other line as it was.
    /// </summary>
    /// <remarks>
    /// The whole file is republished atomically rather than appended to. An append can leave a torn
    /// final line after a power loss, and a torn line in a state file is indistinguishable from a
    /// state that was never written; republishing means the file on disk is always the complete
    /// previous or the complete new set.
    /// </remarks>
    public static void Publish(string archiveDirectory, DeliveryStateDocument document)
    {
        ArgumentException.ThrowIfNullOrEmpty(archiveDirectory);
        ArgumentNullException.ThrowIfNull(document);

        List<DeliveryStateDocument> documents = Read(archiveDirectory)
            .Where(existing => !string.Equals(existing.DeliveryId, document.DeliveryId, StringComparison.Ordinal))
            .ToList();
        documents.Add(document);
        documents.Sort(static (left, right) => string.CompareOrdinal(left.DeliveryId, right.DeliveryId));

        var text = new StringBuilder();
        foreach (DeliveryStateDocument value in documents)
        {
            text.Append(value.ToNdjsonLine()).Append('\n');
        }

        string path = PathFor(archiveDirectory);
        Durability.ReplaceAtomic(path, Utf8NoBom.GetBytes(text.ToString()));
        Durability.TryFlushDirectoryChain(Path.GetDirectoryName(path)!, archiveDirectory);
    }
}
