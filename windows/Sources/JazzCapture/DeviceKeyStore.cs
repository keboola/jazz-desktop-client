using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using JazzCaptureCore.Consent;

namespace JazzCapture;

/// <summary>What the client keeps for the signed route. Everything is protected for the current Windows user.</summary>
/// <param name="ProofKeyName">Name of the TPM-held CNG key. Null for a software key.</param>
/// <param name="ProofKeyPkcs8">The software request key, base64. Null for a TPM key.</param>
/// <param name="WrappingKeyPkcs8">The wrapping key the server seals row keys to, base64.</param>
public sealed record DeviceKeyRecord(
    string DeviceId,
    string KeyProtection,
    string? ProofKeyName,
    string? ProofKeyPkcs8,
    string WrappingKeyPkcs8,
    bool Enrolled,
    string? FilesTokenId,
    DateTimeOffset? FilesTokenExpiresAt);

/// <summary>A P-256 key that signs with ECDSA and SHA-256. The private key stays inside the <see cref="ECDsa"/>.</summary>
internal sealed class EcdsaDeviceSigner : IDeviceSigner, IDisposable
{
    private readonly ECDsa _key;

    internal EcdsaDeviceSigner(ECDsa key)
    {
        _key = key;
        ECParameters parameters = key.ExportParameters(false);
        byte[] point = new byte[65];
        point[0] = 4;
        parameters.Q.X!.CopyTo(point, 1 + 32 - parameters.Q.X!.Length);
        parameters.Q.Y!.CopyTo(point, 33 + 32 - parameters.Q.Y!.Length);
        PublicKeyX963 = point;
    }

    public byte[] PublicKeyX963 { get; }

    public byte[] SignRaw(byte[] message) =>
        _key.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

    public void Dispose() => _key.Dispose();
}

/// <summary>
/// The per-device request key of the signed route. It is a P-256 key held by the TPM through CNG
/// (<c>hardware-non-exportable</c>) when the TPM can create one, otherwise a software key protected
/// with DPAPI for the current user (<c>software</c>). The class is the <c>keyProtection</c> the
/// server expects at enrollment.
/// </summary>
internal sealed class DeviceKeyStore
{
    internal const string TpmProvider = "Microsoft Platform Crypto Provider";
    private static readonly byte[] Entropy = "JazzCapture/device-key/v1"u8.ToArray();

    private readonly string _path;
    private readonly bool _tryHardware;
    private readonly Func<string?> _bundleDeviceId;
    private readonly object _gate = new();

    internal DeviceKeyStore(string securityDirectory, Func<string?> bundleDeviceId, bool tryHardware = true)
    {
        _path = Path.Combine(securityDirectory, "device-key-v1.bin");
        _bundleDeviceId = bundleDeviceId;
        _tryHardware = tryHardware;
    }

    /// <summary>Reads the record, or creates the keys and the record on first use.</summary>
    internal DeviceKeyRecord LoadOrCreate()
    {
        lock (_gate)
        {
            DeviceKeyRecord? existing = Read();
            if (existing is not null) return existing;
            DeviceKeyRecord created = Create();
            Write(created);
            return created;
        }
    }

    internal void Save(DeviceKeyRecord record)
    {
        lock (_gate) Write(record);
    }

    internal IDeviceSigner OpenProofKey(DeviceKeyRecord record)
    {
        if (record.ProofKeyName is not null)
            return new EcdsaDeviceSigner(new ECDsaCng(CngKey.Open(record.ProofKeyName, new CngProvider(TpmProvider))));
        ECDsa key = ECDsa.Create();
        key.ImportPkcs8PrivateKey(Convert.FromBase64String(record.ProofKeyPkcs8!), out _);
        return new EcdsaDeviceSigner(key);
    }

    internal byte[] WrappingPublicKey(DeviceKeyRecord record)
    {
        using ECDiffieHellman key = ECDiffieHellman.Create();
        key.ImportPkcs8PrivateKey(Convert.FromBase64String(record.WrappingKeyPkcs8), out _);
        ECParameters parameters = key.ExportParameters(false);
        byte[] point = new byte[65];
        point[0] = 4;
        parameters.Q.X!.CopyTo(point, 1 + 32 - parameters.Q.X!.Length);
        parameters.Q.Y!.CopyTo(point, 33 + 32 - parameters.Q.Y!.Length);
        return point;
    }

    private DeviceKeyRecord Create()
    {
        string deviceId = NewDeviceId();
        string wrapping;
        using (ECDiffieHellman key = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256))
            wrapping = Convert.ToBase64String(key.ExportPkcs8PrivateKey());

        if (_tryHardware)
        {
            string name = "Jazz-Device-Request-" + Guid.NewGuid().ToString("N");
            try
            {
                var parameters = new CngKeyCreationParameters
                {
                    Provider = new CngProvider(TpmProvider),
                    ExportPolicy = CngExportPolicies.None,
                    KeyUsage = CngKeyUsages.Signing,
                };
                using CngKey tpmKey = CngKey.Create(CngAlgorithm.ECDsaP256, name, parameters);
                return new DeviceKeyRecord(deviceId, DeviceRequestSigning.KeyProtectionHardware, name, null, wrapping, false, null, null);
            }
            catch (Exception exception) when (exception is CryptographicException or PlatformNotSupportedException)
            {
                // No usable TPM: the software key below is protected with DPAPI.
            }
        }

        using ECDsa software = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        return new DeviceKeyRecord(
            deviceId,
            DeviceRequestSigning.KeyProtectionSoftware,
            null,
            Convert.ToBase64String(software.ExportPkcs8PrivateKey()),
            wrapping,
            false,
            null,
            null);
    }

    /// <summary>The id of the device bundle when the server accepts it as a device id, else a new random id.</summary>
    private string NewDeviceId()
    {
        string? fromBundle = _bundleDeviceId();
        return fromBundle is not null && System.Text.RegularExpressions.Regex.IsMatch(fromBundle, "^[a-z0-9][a-z0-9-]{0,63}$")
            ? fromBundle
            : "jazz-" + Guid.NewGuid().ToString("N");
    }

    private DeviceKeyRecord? Read()
    {
        if (!File.Exists(_path)) return null;
        try
        {
            byte[] plain = ProtectedData.Unprotect(File.ReadAllBytes(_path), Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<DeviceKeyRecord>(plain);
        }
        catch (Exception exception) when (exception is CryptographicException or JsonException or IOException)
        {
            // A record that cannot be read is not replaced here: replacing it would hide the loss.
            throw new InvalidDataException("The protected device key could not be read.", exception);
        }
    }

    private void Write(DeviceKeyRecord record)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        byte[] protectedBytes = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(record), Entropy, DataProtectionScope.CurrentUser);
        string temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, protectedBytes);
            File.Move(temporary, _path, true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
