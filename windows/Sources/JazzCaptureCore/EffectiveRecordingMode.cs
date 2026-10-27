namespace JazzCaptureCore;

/// <summary>Where the effective recording mode came from.</summary>
public enum RecordingModeSource
{
    Default,
    ManagedPolicy,
    RemotePolicy,
}

/// <summary>
/// The recording mode a running client applies. Remote command-center policy wins over managed
/// registry; both fall back to <see cref="RecordingMode.Session"/> when absent or unreadable.
/// </summary>
public sealed record EffectiveRecordingMode(
    RecordingMode Mode,
    RecordingModeSource Source,
    bool UsingDocumentedDefault)
{
    public static EffectiveRecordingMode SessionDefault { get; } =
        new(RecordingMode.Session, RecordingModeSource.Default, UsingDocumentedDefault: true);

    public static EffectiveRecordingMode Resolve(
        RecordingMode? remotePolicyMode,
        RecordingMode? managedPolicyMode)
    {
        if (remotePolicyMode is RecordingMode remote)
        {
            return new EffectiveRecordingMode(remote, RecordingModeSource.RemotePolicy, UsingDocumentedDefault: false);
        }

        if (managedPolicyMode is RecordingMode managed)
        {
            return new EffectiveRecordingMode(managed, RecordingModeSource.ManagedPolicy, UsingDocumentedDefault: false);
        }

        return SessionDefault;
    }

    public string TrayDescription =>
        UsingDocumentedDefault
            ? "Recording: session (default)"
            : Mode == RecordingMode.Continuous
                ? "Recording: continuous"
                : "Recording: session";
}
