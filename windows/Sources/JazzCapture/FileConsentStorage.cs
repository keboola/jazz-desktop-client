using System.IO;
using JazzCaptureCore.Consent;

namespace JazzCapture;

/// <summary>The consent ledger and the cached device policy, in the profile of the Windows user.</summary>
internal sealed class FileConsentStorage : IConsentStorage
{
    private readonly string _ledgerPath;
    private readonly string _policyPath;

    internal FileConsentStorage(string profileDirectory)
    {
        _ledgerPath = Path.Combine(profileDirectory, "consent-state.json");
        _policyPath = Path.Combine(profileDirectory, "device-policy.json");
    }

    public string? ReadLedger() => Read(_ledgerPath);

    public void WriteLedger(string json) => Write(_ledgerPath, json);

    public string? ReadPolicy() => Read(_policyPath);

    public void WritePolicy(string json) => Write(_policyPath, json);

    private static string? Read(string path) => File.Exists(path) ? File.ReadAllText(path) : null;

    private static void Write(string path, string contents)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, contents);
            File.Move(temporary, path, true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
