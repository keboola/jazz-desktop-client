using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class UpdateResumeTests
{
    [Fact]
    public void ClearsPauseWhenTheBuildChangedOrHasNeverBeenRecorded()
    {
        Assert.True(UpdateResume.ShouldClearPause(null, "0.26.10"));
        Assert.True(UpdateResume.ShouldClearPause("0.26.9", "0.26.10"));
        Assert.False(UpdateResume.ShouldClearPause("0.26.10", "0.26.10"));
        Assert.False(UpdateResume.ShouldClearPause("0.26.10", ""));
    }
}
