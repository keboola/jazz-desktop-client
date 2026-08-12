using JazzCaptureCore;
using JazzCaptureCore.Delivery;

namespace JazzCaptureCoreTests.Support;

/// <summary>A clock the test moves by hand.</summary>
public sealed class MutableClock
{
    private DateTimeOffset _now;

    /// <summary>Starts at a fixed instant so nothing in a test depends on the wall clock.</summary>
    public MutableClock(DateTimeOffset? start = null) =>
        _now = start ?? new DateTimeOffset(2026, 8, 12, 9, 0, 0, TimeSpan.Zero);

    /// <summary>The current instant; assignable.</summary>
    public DateTimeOffset Now
    {
        get => _now;
        set => _now = value;
    }

    /// <summary>Reads the clock without moving it.</summary>
    public DateTimeOffset Read() => _now;

    /// <summary>Reads the clock and moves it on by one second, for a producer that needs distinct stamps.</summary>
    public DateTimeOffset Next()
    {
        DateTimeOffset value = _now;
        _now = _now.AddSeconds(1);
        return value;
    }

    /// <summary>Moves the clock forward.</summary>
    public void Advance(TimeSpan amount) => _now = _now.Add(amount);
}

/// <summary>One confirmed archive and the package the queue owns for it.</summary>
/// <param name="ArchiveId">Archive identity.</param>
/// <param name="CaptureId">The single capture it contains.</param>
/// <param name="OriginId">Producer origin.</param>
/// <param name="ContentDigest">Logical content digest from the manifest.</param>
/// <param name="ArchiveDirectory">Finalized archive directory, including its <c>sync/</c> subtree.</param>
/// <param name="PackagePath">Queue-owned container.</param>
/// <param name="Engine">
/// The engine that produced it, retained so a test can confirm the same archive twice. Only this
/// engine can: a confirmation is a decision about one reviewed capture, not something another
/// process can repeat on its behalf.
/// </param>
public sealed record ConfirmedArchive(
    string ArchiveId,
    string CaptureId,
    string OriginId,
    string ContentDigest,
    string ArchiveDirectory,
    string PackagePath,
    CaptureEngine Engine);

/// <summary>
/// A throwaway capture root plus delivery queue, holding real archives rather than fixtures.
/// </summary>
/// <remarks>
/// The packages these tests deliver are produced by the actual capture engine, archive writer and
/// container writer. That matters: the queue's promise is about the exact bytes a confirmation
/// produces, and a hand-rolled stand-in would let the queue agree with a file the rest of the client
/// would never write.
/// </remarks>
public sealed class DeliveryWorkspace : IDisposable
{
    private readonly MutableClock _captureClock = new();

    /// <summary>Creates the workspace directories.</summary>
    public DeliveryWorkspace()
    {
        Root = Path.Combine(Path.GetTempPath(), "jazz-delivery-" + Guid.NewGuid().ToString("n"));
        QueueDirectory = Path.Combine(Root, "queue");
        Directory.CreateDirectory(Root);
    }

    /// <summary>Capture root of the throwaway profile.</summary>
    public string Root { get; }

    /// <summary>Queue root the confirmations export into.</summary>
    public string QueueDirectory { get; }

    /// <summary>Clock the queues opened by <see cref="OpenQueue"/> read.</summary>
    public MutableClock QueueClock { get; } = new();

    /// <summary>
    /// Opens the queue from disk. Every call is a fresh object holding no state, so calling it again
    /// is exactly what a relaunch does.
    /// </summary>
    public ArchiveDeliveryQueue OpenQueue() => new(QueueDirectory, QueueClock.Read);

    /// <summary>Records a one-click capture, confirms it, and returns what the queue now owns.</summary>
    public ConfirmedArchive Confirm()
    {
        CaptureEngine engine = CaptureEngine.Start(new EngineConfig(
            Root,
            "petr",
            "WIN-DEV-01",
            "1.0.0",
            Array.Empty<string>(),
            ScreenshotsEnabled: false,
            _captureClock.Next));

        engine.Observe(new ClickEvent
        {
            OccurredAt = _captureClock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, "Contoso.Editor", "Contoso Editor", "2.0"),
            System = "Contoso Editor",
            TargetRole = "Button",
            TargetAccessibleName = "Save",
            TargetBoundingBox = new BoundingBox(4, 8, 60, 20),
            ClickCount = 1,
        });
        engine.Stop();

        string packagePath = engine.ConfirmAndExport(QueueDirectory);
        ArchiveDeliveryRecord record = OpenQueue().Require(engine.Identity.ArchiveId);

        return new ConfirmedArchive(
            engine.Identity.ArchiveId,
            engine.Identity.CaptureId,
            engine.Identity.OriginId,
            record.ContentDigest,
            engine.ArchiveDirectory!,
            packagePath,
            engine);
    }

    /// <summary>Records a capture and rejects it, so nothing may be queued for it.</summary>
    public CaptureEngine Reject(string reason)
    {
        CaptureEngine engine = CaptureEngine.Start(new EngineConfig(
            Root,
            "petr",
            "WIN-DEV-01",
            "1.0.0",
            Array.Empty<string>(),
            ScreenshotsEnabled: false,
            _captureClock.Next));

        engine.Observe(new ClickEvent
        {
            OccurredAt = _captureClock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, "Contoso.Vault", "Contoso Vault", "1.0"),
            System = "Contoso Vault",
            TargetRole = "Button",
            TargetAccessibleName = "Reveal",
            TargetBoundingBox = new BoundingBox(1, 2, 3, 4),
            ClickCount = 1,
        });
        engine.Stop();
        engine.Reject(reason);
        return engine;
    }

    /// <summary>Rewrites the queue-owned package with different bytes of the same shape.</summary>
    public static void DamagePackage(string packagePath)
    {
        byte[] bytes = File.ReadAllBytes(packagePath);
        bytes[^1] ^= 0xFF;
        File.WriteAllBytes(packagePath, bytes);
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        if (Directory.Exists(Root))
        {
            Directory.Delete(Root, recursive: true);
        }
    }
}
