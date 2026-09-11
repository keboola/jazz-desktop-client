using System.Text;
using System.IO;
using JazzCaptureCore.Journal;

namespace JazzCapture;

/// <summary>Host-local sentinel for detecting a screenshot spool directory that was replaced
/// while this process is alive. Its absence or changed value is a recovery condition, never an
/// invitation to send from the new directory before journal reconciliation.</summary>
internal sealed class ScreenshotSpoolIdentity
{
    private const string SentinelName = ".jazz-screenshot-spool-id";
    private readonly string root;
    private string? expected;

    public ScreenshotSpoolIdentity(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        this.root = Path.GetFullPath(root);
    }

    /// <returns><see langword="true"/> when the spool is new, missing its sentinel, or has been
    /// replaced. The caller must reconcile journal evidence before allowing transport.</returns>
    public bool Ensure()
    {
        CurrentUserOnlyAcl.ApplyDirectory(root);
        string path = Path.Combine(root, SentinelName);
        string? actual = TryRead(path);
        if (actual is not null && expected is not null
            && string.Equals(actual, expected, StringComparison.Ordinal))
        {
            CurrentUserOnlyAcl.ApplyFile(path);
            return false;
        }

        string next = Guid.NewGuid().ToString("N");
        Durability.ReplaceAtomic(path, Encoding.ASCII.GetBytes(next));
        CurrentUserOnlyAcl.ApplyFile(path);
        expected = next;
        return true;
    }

    private static string? TryRead(string path)
    {
        if (!File.Exists(path)) return null;
        CurrentUserOnlyAcl.ApplyFile(path);
        string value = Encoding.ASCII.GetString(File.ReadAllBytes(path));
        return value.Length == 32 && value.All(Uri.IsHexDigit) ? value : null;
    }
}
