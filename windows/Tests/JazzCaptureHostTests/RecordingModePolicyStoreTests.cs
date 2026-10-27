using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

public sealed class RecordingModePolicyStoreTests
{
    [Fact]
    public void ParsesManagedContinuousAndSessionStrings()
    {
        var store = new RecordingModePolicyStore((_, _, _) => RecordingModeParser.ContinuousValue);
        RecordingModePolicyRead read = store.Read();
        Assert.Equal(RecordingMode.Continuous, read.Mode);
        Assert.Null(read.Detail);

        store = new RecordingModePolicyStore((_, _, _) => RecordingModeParser.SessionValue);
        read = store.Read();
        Assert.Equal(RecordingMode.Session, read.Mode);
    }

    [Fact]
    public void MalformedValueFallsBackWithDetail()
    {
        var store = new RecordingModePolicyStore((_, _, _) => "always-on");
        RecordingModePolicyRead read = store.Read();
        Assert.Null(read.Mode);
        Assert.Contains("not a recognised value", read.Detail, StringComparison.Ordinal);
    }
}
