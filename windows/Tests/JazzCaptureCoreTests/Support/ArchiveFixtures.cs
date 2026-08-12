using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests.Support;

/// <summary>
/// Copies of the contract archive fixtures that a test may edit, plus the two rewrites needed to
/// tamper with one document without breaking every digest above it.
/// </summary>
/// <remarks>
/// A byte flipped anywhere in an archive normally trips the very first digest that covers it — the
/// inventory. That is worth proving, but it proves only one link. To exercise a deeper link a test
/// must repair the ones above it, which is exactly what a competent attacker would do, so the repair
/// helpers here are part of the threat model rather than a convenience.
/// </remarks>
internal static class ArchiveFixtures
{
    /// <summary>Names of the archive fixtures under <c>contract/archive/fixtures</c>.</summary>
    public static readonly string[] Names =
    {
        "01-minimal-desktop",
        "02-labeled-narration",
        "03-capture-coach",
        "04-meeting-screen-share",
    };

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>Absolute path of one committed fixture directory.</summary>
    public static string Directory(string name) =>
        Path.Combine(ContractPaths.Root(), "contract", "archive", "fixtures", name);

    /// <summary>Copies a fixture into <paramref name="destination"/> and returns that path.</summary>
    public static string CopyTo(string name, string destination)
    {
        string source = Directory(name);
        foreach (string path in System.IO.Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string relative = Path.GetRelativePath(source, path);
            string target = Path.Combine(destination, relative);
            System.IO.Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(path, target, overwrite: true);
        }

        return destination;
    }

    /// <summary>Packages an archive directory into a <c>.jazz-archive</c> at <paramref name="output"/>.</summary>
    public static string Package(string archiveDirectory, string output)
    {
        JazzArchiveContainer.Export(archiveDirectory, output);
        return output;
    }

    /// <summary>Reads one document out of an archive directory.</summary>
    public static JsonObject Read(string archiveDirectory, string relativePath) =>
        (JsonObject)JsonStrictParser.Parse(
            File.ReadAllText(Path.Combine(
                archiveDirectory,
                relativePath.Replace('/', Path.DirectorySeparatorChar))))!;

    /// <summary>Overwrites one document with indented JSON, the shape the writer emits.</summary>
    public static void Write(string archiveDirectory, string relativePath, JsonObject document)
    {
        string path = Path.Combine(archiveDirectory, relativePath.Replace('/', Path.DirectorySeparatorChar));
        string text = document.ToJsonString(new System.Text.Json.JsonSerializerOptions
        {
            WriteIndented = true,
        }).Replace("\r\n", "\n", StringComparison.Ordinal) + "\n";

        File.WriteAllBytes(path, Utf8.GetBytes(text));
    }

    /// <summary>Flips one byte of a file inside an archive directory.</summary>
    public static void FlipByte(string archiveDirectory, string relativePath, int offset)
    {
        string path = Path.Combine(archiveDirectory, relativePath.Replace('/', Path.DirectorySeparatorChar));
        byte[] bytes = File.ReadAllBytes(path);
        bytes[offset] ^= 0x01;
        File.WriteAllBytes(path, bytes);
    }

    /// <summary>
    /// Rewrites the inventory over the files currently on disk and re-seals the manifest around it,
    /// so a tampered document survives the inventory and the content digest and has to be caught by
    /// whatever digest sits above them.
    /// </summary>
    public static void ResealInventoryAndManifest(string archiveDirectory)
    {
        var entries = new List<(string Path, long ByteLength, string Sha256)>();
        foreach (string path in System.IO.Directory.EnumerateFiles(archiveDirectory, "*", SearchOption.AllDirectories))
        {
            string relative = Path.GetRelativePath(archiveDirectory, path).Replace(Path.DirectorySeparatorChar, '/');
            if (relative is "manifest.json" or "inventory.json"
                || relative.StartsWith("sync/", StringComparison.Ordinal))
            {
                continue;
            }

            entries.Add((relative, new FileInfo(path).Length, JazzArchiveContainer.Sha256File(path)));
        }

        entries.Sort((left, right) => string.CompareOrdinal(left.Path, right.Path));

        var rows = new JsonArray();
        foreach ((string path, long byteLength, string sha256) in entries)
        {
            rows.Add(new JsonObject
            {
                ["path"] = path,
                ["byteLength"] = byteLength,
                ["sha256"] = sha256,
            });
        }

        var inventory = new JsonObject
        {
            ["algorithm"] = "sha256",
            ["entries"] = rows,
        };

        Write(archiveDirectory, "inventory.json", inventory);
        ResealManifest(archiveDirectory, manifest =>
            manifest["inventory"]!["digest"] = JsonCanonicalizer.Sha256Hex(inventory));
    }

    /// <summary>Mutates the manifest and recomputes its content digest, leaving it internally valid.</summary>
    public static void ResealManifest(string archiveDirectory, Action<JsonObject> mutate)
    {
        JsonObject manifest = Read(archiveDirectory, "manifest.json");
        mutate(manifest);
        manifest.Remove("contentDigest");
        manifest["contentDigest"] = JsonCanonicalizer.Sha256Hex(manifest);
        Write(archiveDirectory, "manifest.json", manifest);
    }
}
