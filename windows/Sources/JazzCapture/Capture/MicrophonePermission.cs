using JazzCapture.Interop;

namespace JazzCapture.Capture;

/// <summary>
/// Asks Windows for microphone access once by activating the default capture endpoint. Desktop
/// apps have no per-application prompt API; touching the device is what raises the consent flyout.
/// </summary>
internal static class MicrophonePermission
{
    public static void RequestOnce()
    {
        try
        {
            Type? type = Type.GetTypeFromCLSID(AudioInterop.CLSID_MMDeviceEnumerator);
            if (type is null || Activator.CreateInstance(type) is not IMMDeviceEnumerator enumerator)
            {
                return;
            }

            int hr = enumerator.GetDefaultAudioEndpoint(
                AudioInterop.eCapture,
                AudioInterop.eConsole,
                out IMMDevice? endpoint);
            if (hr != 0 || endpoint is null)
            {
                return;
            }

            Guid iid = AudioInterop.IID_IAudioClient;
            _ = endpoint.Activate(ref iid, AudioInterop.CLSCTX_ALL, IntPtr.Zero, out _);
        }
        catch (Exception)
        {
            // A refused or missing microphone must not take the tray down.
        }
    }
}
