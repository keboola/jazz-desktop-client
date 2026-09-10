namespace JazzCaptureCore.Journal;

/// <summary>Recoverable journal scan result. Details are deliberately non-sensitive codes.</summary>
public sealed record CaptureJournalRecoveryResult(int Recovered, int AlreadyCommitted, int NeedsAttention)
{
    public bool HasAttention => NeedsAttention != 0;
}

/// <summary>
/// Performs the local, idempotent recovery pass used before a host starts a new capture. This class
/// has no archive, review, queue, or transport dependency: recovery only completes an existing
/// journal or leaves its exact bytes alone for later inspection.
/// </summary>
public static class CaptureJournalRecovery
{
    public static CaptureJournalRecoveryResult Recover(string root, Func<string> endedAt)
    {
        ArgumentException.ThrowIfNullOrEmpty(root);
        ArgumentNullException.ThrowIfNull(endedAt);

        string stateRoot = Path.Combine(root, CaptureJournal.StateRootName);
        if (!Directory.Exists(stateRoot) || IsReparsePoint(stateRoot))
        {
            return new CaptureJournalRecoveryResult(0, 0, Directory.Exists(stateRoot) ? 1 : 0);
        }

        int recovered = 0;
        int committed = 0;
        int attention = 0;
        foreach (string path in Directory.EnumerateDirectories(stateRoot, "*", SearchOption.TopDirectoryOnly))
        {
            try
            {
                if (IsReparsePoint(path))
                {
                    attention++;
                    continue;
                }

                string archiveId = Path.GetFileName(path);
                CaptureJournal journal = CaptureJournal.Reopen(root, archiveId);
                if (journal.Lifecycle == JournalLifecycle.Committed)
                {
                    committed++;
                    continue;
                }

                journal.RecoverInterrupted(endedAt());
                recovered++;
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException
                or ArgumentException
                or CaptureJournalException)
            {
                // A malformed or legacy directory is neither rewritten nor allowed to block a
                // healthy sibling. The caller receives only a count, never journal contents.
                attention++;
            }
        }

        return new CaptureJournalRecoveryResult(recovered, committed, attention);
    }

    private static bool IsReparsePoint(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
}
