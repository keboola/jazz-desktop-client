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
        DateTimeOffset deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(2);
        while (DateTimeOffset.UtcNow < deadline)
        {
            try
            {
                string? sid = WindowsIdentity.GetCurrent().User?.Value;
                if (sid is null) return false;
                using var client = new NamedPipeClientStream(".", "JazzCapture.Activate." + sid, PipeDirection.Out, PipeOptions.Asynchronous);
                client.Connect(150); using var writer = new StreamWriter(client) { AutoFlush = true }; writer.Write(Activate); return true;
            }
            catch (IOException) { Thread.Sleep(25); } catch (TimeoutException) { Thread.Sleep(25); }
        }
        return false;
    }
    private async Task Listen()
    {
        while (!_stop.IsCancellationRequested)
        {
            using var server = NamedPipeServerStreamAcl.Create(_pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 256, 256, _security);
            try
            {
                using (var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token))
                {
                    connectTimeout.CancelAfter(TimeSpan.FromSeconds(1));
                    await server.WaitForConnectionAsync(connectTimeout.Token);
                }
                using var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
                readTimeout.CancelAfter(TimeSpan.FromSeconds(1));
                byte[] buffer = new byte[257];
                int total = 0;
                while (total < buffer.Length)
                {
                    int read = await server.ReadAsync(buffer.AsMemory(total, buffer.Length - total), readTimeout.Token);
                    if (read == 0) break;
                    total += read;
                }
                // Exactly one short activation command; 257 bytes proves an oversized request.
                if (total <= 256 && System.Text.Encoding.UTF8.GetString(buffer, 0, total) == Activate) _activate();
            }
            catch (OperationCanceledException) when (_stop.IsCancellationRequested) { return; }
            catch (OperationCanceledException) { } catch (IOException) { }
        }
    }
    public void Dispose() { _stop.Cancel(); try { _listener?.Wait(1000); } catch (AggregateException) { } _stop.Dispose(); }
}
