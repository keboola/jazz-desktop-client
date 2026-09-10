using System.IO.Pipes;
using System.Security.Principal;
using JazzCapture;

namespace JazzCaptureHostTests;

public sealed class UserActivationTests
{
    [Fact]
    public async Task SameUserActivationInvokesOnlyActivationCallback()
    {
        using var invoked = new ManualResetEventSlim();
        using var server = new UserActivation(invoked.Set);
        server.Start();
        await Task.Delay(50);
        Assert.True(UserActivation.TryActivateExisting());
        Assert.True(invoked.Wait(TimeSpan.FromSeconds(2)));
    }

    [Fact]
    public async Task MalformedCommandDoesNotInvokeCallback()
    {
        using var invoked = new ManualResetEventSlim();
        using var server = new UserActivation(invoked.Set);
        server.Start();
        await Task.Delay(50);
        string sid = WindowsIdentity.GetCurrent().User!.Value;
        using (var client = new NamedPipeClientStream(".", "JazzCapture.Activate." + sid, PipeDirection.Out, PipeOptions.Asynchronous))
        {
            await client.ConnectAsync(1000);
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes("StartCapture");
            await client.WriteAsync(bytes);
        }
        Assert.False(invoked.Wait(TimeSpan.FromMilliseconds(300)));
    }

    [Fact]
    public void DisposeIsBoundedWhenNoClientConnects()
    {
        var server = new UserActivation(() => { });
        server.Start();
        DateTimeOffset started = DateTimeOffset.UtcNow;
        server.Dispose();
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(2));
    }
}
