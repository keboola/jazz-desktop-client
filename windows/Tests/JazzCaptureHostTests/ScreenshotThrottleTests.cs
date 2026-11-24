using JazzCapture.Capture;

namespace JazzCaptureHostTests;

public sealed class ScreenshotThrottleTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 12, 10, 0, 0, TimeSpan.Zero);
    private static readonly TimeSpan Window = TimeSpan.FromMilliseconds(800);

    [Fact]
    public void FirstGestureIsAdmittedAndTheRestOfTheWindowIsNot()
    {
        var throttle = new ScreenshotThrottle(Window);

        Assert.True(throttle.TryAdmit(Start));
        Assert.False(throttle.TryAdmit(Start.AddMilliseconds(1)));
        Assert.False(throttle.TryAdmit(Start.AddMilliseconds(799)));
    }

    [Fact]
    public void GestureAtTheWindowEdgeIsAdmittedAndStartsANewWindow()
    {
        var throttle = new ScreenshotThrottle(Window);

        Assert.True(throttle.TryAdmit(Start));
        Assert.True(throttle.TryAdmit(Start.AddMilliseconds(800)));
        Assert.False(throttle.TryAdmit(Start.AddMilliseconds(1000)));
        Assert.True(throttle.TryAdmit(Start.AddMilliseconds(1600)));
    }

    [Fact]
    public void RefusedGesturesDoNotExtendTheWindow()
    {
        var throttle = new ScreenshotThrottle(Window);

        Assert.True(throttle.TryAdmit(Start));
        for (int ms = 100; ms < 800; ms += 100)
        {
            Assert.False(throttle.TryAdmit(Start.AddMilliseconds(ms)));
        }

        Assert.True(throttle.TryAdmit(Start.AddMilliseconds(800)));
    }

    [Fact]
    public void ClockMovingBackwardsAdmitsInsteadOfBlocking()
    {
        var throttle = new ScreenshotThrottle(Window);

        Assert.True(throttle.TryAdmit(Start));
        Assert.True(throttle.TryAdmit(Start.AddHours(-1)));
    }
}
