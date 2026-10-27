using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class ContinuousCaptureTests
{
    [Fact]
    public void RolloverRequiresACommitAndNeverResumesAPauseOrShutdown()
    {
        for (int bits = 0; bits < 16; bits++)
        {
            bool enabled = (bits & 1) != 0;
            bool committed = (bits & 2) != 0;
            bool paused = (bits & 4) != 0;
            bool terminating = (bits & 8) != 0;
            Assert.Equal(bits == 3, ContinuousCapture.ShouldContinue(enabled, committed, paused, terminating));
        }

        for (int bits = 0; bits < 8; bits++)
        {
            Assert.Equal(
                bits == 3,
                ContinuousCapture.ShouldRemind((bits & 1) != 0, (bits & 2) != 0, (bits & 4) != 0));
        }
    }
}
