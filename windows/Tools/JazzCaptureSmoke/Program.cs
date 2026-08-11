using JasnostCaptureCore;

// Drives one synthetic capture session through the engine and confirms it, so a real machine can
// produce a real .jazz-archive without a human at the keyboard. The events mirror what the tray
// host feeds in: an app switch, clicks, a redacted typing run, a copy, a scroll, and one event from
// a denylisted application that must become an explicit gap rather than a silent omission.
//
// Usage: JazzCaptureSmoke <workRoot> [queueDir]

var workRoot = args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "jazz-smoke");
var queueDir = args.Length > 1 ? args[1] : Path.Combine(workRoot, "queue");

Directory.CreateDirectory(workRoot);
Directory.CreateDirectory(queueDir);

// A fixed clock keeps the run reproducible: two identical runs differ only in the minted ids.
var start = new DateTimeOffset(2026, 8, 11, 9, 0, 0, TimeSpan.Zero);
var tick = 0;
DateTimeOffset Clock() => start.AddSeconds(tick);

const string DeniedApplication = @"C:\Program Files\1Password\1Password.exe";

var config = new EngineConfig(
    RootDir: workRoot,
    User: Environment.UserName,
    InstanceName: Environment.MachineName,
    ProducerVersion: "0.1.0-smoke",
    ExcludedApplications: new[] { DeniedApplication },
    ScreenshotsEnabled: false,
    Clock: Clock);

var notepad = new AppIdentity(
    AppIdentity.ExecutablePathNamespace,
    @"C:\Windows\System32\notepad.exe",
    "Notepad",
    "11.2401.26.0");

var engine = CaptureEngine.Start(config);
Console.WriteLine($"started archive {engine.Identity.ArchiveId}");

tick = 1;
engine.Observe(new NavigateEvent
{
    OccurredAt = Clock(),
    Application = notepad,
    System = "Notepad",
});

tick = 2;
engine.Observe(new ClickEvent
{
    OccurredAt = Clock(),
    Application = notepad,
    System = "Notepad",
    TargetRole = "Button",
    TargetAccessibleName = "New tab",
    TargetBoundingBox = new BoundingBox(120.5, 64, 88, 24),
    PageTitle = "Untitled - Notepad",
    ClickCount = 1,
});

tick = 3;
engine.Observe(new InputEvent
{
    OccurredAt = Clock(),
    Application = notepad,
    System = "Notepad",
    RawText = "invoice for john@doe.com card 4111111111111111",
    TargetRole = "Edit",
    TargetAccessibleName = "Text editor",
});

tick = 4;
engine.Observe(new ClickEvent
{
    OccurredAt = Clock(),
    Application = notepad,
    System = "Notepad",
    TargetRole = "MenuItem",
    TargetAccessibleName = "Save",
    TargetBoundingBox = new BoundingBox(20, 30, 180, 24),
    PageTitle = "Untitled - Notepad",
    ClickCount = 2,
});

tick = 5;
engine.Observe(new CopyEvent
{
    OccurredAt = Clock(),
    Application = notepad,
    System = "Notepad",
    TargetRole = "Edit",
    TargetAccessibleName = "Text editor",
    SelectedText = "invoice",
});

tick = 6;
engine.Observe(new ScrollEvent
{
    OccurredAt = Clock(),
    Application = notepad,
    System = "Notepad",
    TargetRole = "Document",
    PageTitle = "Untitled - Notepad",
});

// Denylisted owner: expected to land as an explicit gap, never as an event.
tick = 7;
engine.Observe(new ClickEvent
{
    OccurredAt = Clock(),
    Application = new AppIdentity(
        AppIdentity.ExecutablePathNamespace,
        DeniedApplication,
        "1Password"),
    System = "1Password",
    TargetRole = "Edit",
    TargetAccessibleName = "Master password",
    IsSensitive = true,
    ClickCount = 1,
});

tick = 8;
var stopped = engine.Stop();
Console.WriteLine(
    $"stopped: {stopped.ObservationCount} observations, {stopped.GapCount} gaps, " +
    $"{stopped.CapabilityObservationCount} capability observations");

var archivePath = engine.ConfirmAndExport(queueDir);
Console.WriteLine($"archive directory: {engine.ArchiveDirectory}");
Console.WriteLine($"exported package:  {archivePath}");
Console.WriteLine($"package bytes:     {new FileInfo(archivePath).Length}");
Console.WriteLine($"package sha256:    {JasnostCaptureCore.Archive.JazzArchiveContainer.Sha256File(archivePath)}");
