using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class EffectiveRecordingModeTests
{
    [Fact]
    public void RemotePolicyWinsOverManagedAndDefault()
    {
        EffectiveRecordingMode remote = EffectiveRecordingMode.Resolve(
            RecordingMode.Session, RecordingMode.Continuous);
        Assert.Equal(RecordingMode.Session, remote.Mode);
        Assert.Equal(RecordingModeSource.RemotePolicy, remote.Source);
        Assert.False(remote.UsingDocumentedDefault);

        EffectiveRecordingMode managed = EffectiveRecordingMode.Resolve(null, RecordingMode.Continuous);
        Assert.Equal(RecordingMode.Continuous, managed.Mode);
        Assert.Equal(RecordingModeSource.ManagedPolicy, managed.Source);

        EffectiveRecordingMode defaultMode = EffectiveRecordingMode.Resolve(null, null);
        Assert.Equal(RecordingMode.Session, defaultMode.Mode);
        Assert.True(defaultMode.UsingDocumentedDefault);
        Assert.Contains("default", defaultMode.TrayDescription, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData(RecordingMode.Continuous, true, false, true)]
    [InlineData(RecordingMode.Continuous, false, false, true)]
    [InlineData(RecordingMode.Continuous, true, true, false)]
    [InlineData(RecordingMode.Session, true, false, true)]
    [InlineData(RecordingMode.Session, false, false, false)]
    public void StartupHonoursRecordingMode(
        RecordingMode mode,
        bool captureAtLaunchEnabled,
        bool paused,
        bool expected)
    {
        Assert.Equal(
            expected,
            CaptureStartupDecision.ShouldStart(true, true, true, captureAtLaunchEnabled, paused, mode));
    }
}
