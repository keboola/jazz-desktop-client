using System.IO.Pipes;
using System.Security.Principal;
using System.Security.AccessControl;
using System.IO;

namespace JazzCapture;

/// <summary>Current-user activation-only IPC. It intentionally has one command and no capture verbs.</summary>
internal sealed class UserActivation : IDisposable
{
    private const string Activate = "Activate";
    private readonly string _pipeName;
    private readonly CancellationTokenSource _stop = new();
    private readonly Action _activate;
    private readonly PipeSecurity _security;
    private Task? _listener;
    public UserActivation(Action activate)
    {
        string sid = WindowsIdentity.GetCurrent().User?.Value ?? throw new InvalidOperationException("Current SID is unavailable.");
        _pipeName = "JazzCapture.Activate." + sid;
        _activate = activate;
        _security = new PipeSecurity();
        _security.SetAccessRuleProtection(true, false);
        _security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(sid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
    }
    public void Start() => _listener = Task.Run(Listen);
    public static bool TryActivateExisting()
    {
        try
        {
            string? sid = WindowsIdentity.GetCurrent().User?.Value;
            if (sid is null) return false;
            using var client = new NamedPipeClientStream(".", "JazzCapture.Activate." + sid, PipeDirection.Out, PipeOptions.Asynchronous);
            client.Connect(500); using var writer = new StreamWriter(client) { AutoFlush = true }; writer.Write(Activate); return true;
        }
        catch (IOException) { return false; } catch (TimeoutException) { return false; }
    }
    private async Task Listen()
    {
        while (!_stop.IsCancellationRequested)
        {
            using var server = NamedPipeServerStreamAcl.Create(_pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 256, 256, _security);
            try { await server.WaitForConnectionAsync(_stop.Token); using var reader = new StreamReader(server); string text = await reader.ReadToEndAsync(_stop.Token); if (text == Activate) _activate(); }
            catch (OperationCanceledException) { return; } catch (IOException) { }
        }
    }
    public void Dispose() { _stop.Cancel(); try { _listener?.Wait(1000); } catch (AggregateException) { } _stop.Dispose(); }
}
