using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace JazzCaptureCore.Consent;

/// <summary>A P-256 key that signs. The private key never leaves the implementation.</summary>
public interface IDeviceSigner
{
    /// <summary>The public key as an uncompressed X9.63 point: 0x04, X, Y (65 bytes).</summary>
    byte[] PublicKeyX963 { get; }

    /// <summary>ECDSA with SHA-256 over <paramref name="message"/>, as raw <c>r || s</c> (64 bytes).</summary>
    byte[] SignRaw(byte[] message);
}

/// <summary>A request ready to send: the headers, and the JSON body when the call has one.</summary>
public sealed record SignedRequest(IReadOnlyDictionary<string, string> Headers, string? Body);

/// <summary>
/// The request signature of the Jazz <c>/device/</c> routes. It follows <c>device_auth_crypto.py</c>
/// and <c>device_auth.py</c> of the server: the signed bytes are a domain prefix plus the canonical
/// JSON of the request fields, the signature is raw low-S <c>r || s</c> in unpadded base64url.
/// </summary>
public static class DeviceRequestSigning
{
    public const string EnrollPath = "/device/enroll";
    public const string PolicyPath = "/device/policy";
    public const string RenewPath = "/device/token/renew";
    public const string ConsentPath = "/device/consent";
    public const string KeyProtectionSoftware = "software";
    public const string KeyProtectionHardware = "hardware-non-exportable";

    public static readonly byte[] EnrollDomain = Encoding.ASCII.GetBytes("JAZZ-DEVICE-ENROLL-V1\0");
    public static readonly byte[] RequestDomain = Encoding.ASCII.GetBytes("JAZZ-DEVICE-REQUEST-V1\0");

    private static readonly BigInteger CurveOrder = BigInteger.Parse(
        "0FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551",
        NumberStyles.HexNumber,
        CultureInfo.InvariantCulture);

    public static string B64Url(byte[] value) =>
        Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>
    /// The server's <c>json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=False)</c> for a
    /// flat object of strings, as UTF-8.
    /// </summary>
    public static byte[] CanonicalJson(IReadOnlyDictionary<string, string> fields)
    {
        var builder = new StringBuilder("{");
        bool first = true;
        foreach (string key in fields.Keys.OrderBy(name => name, StringComparer.Ordinal))
        {
            if (!first) builder.Append(',');
            first = false;
            AppendString(builder, key);
            builder.Append(':');
            AppendString(builder, fields[key]);
        }

        return new UTF8Encoding(false).GetBytes(builder.Append('}').ToString());
    }

    /// <summary>Signs <paramref name="domain"/> + <paramref name="payload"/> and returns canonical low-S <c>r || s</c>.</summary>
    public static byte[] Sign(IDeviceSigner signer, byte[] domain, byte[] payload)
    {
        byte[] raw = signer.SignRaw(domain.Concat(payload).ToArray());
        return NormalizeLowS(raw);
    }

    public static byte[] NormalizeLowS(byte[] raw)
    {
        if (raw.Length != 64) throw new ArgumentException("A P-256 signature is 64 bytes.", nameof(raw));
        var s = new BigInteger(raw.AsSpan(32), isUnsigned: true, isBigEndian: true);
        if (s <= CurveOrder / 2) return raw;
        byte[] flipped = (CurveOrder - s).ToByteArray(isUnsigned: true, isBigEndian: true);
        byte[] result = (byte[])raw.Clone();
        Array.Clear(result, 32, 32);
        flipped.CopyTo(result, 64 - flipped.Length);
        return result;
    }

    /// <summary>
    /// The body of <c>POST /device/enroll</c>, with the proof of possession. The code goes into the
    /// signed body only as its SHA-256; the code itself goes in <c>X-Jazz-Enrollment-Code</c>.
    /// </summary>
    public static string EnrollBody(
        IDeviceSigner proofKey,
        byte[] wrappingPublicKey,
        string deviceId,
        string enrollmentCode,
        string hostname,
        string osUser,
        string keyProtection)
    {
        var fields = new Dictionary<string, string>
        {
            ["deviceId"] = deviceId,
            ["enrollmentCodeSha256"] = B64Url(SHA256.HashData(Encoding.UTF8.GetBytes(enrollmentCode))),
            ["hostname"] = hostname,
            ["osUser"] = osUser,
            ["keyProtection"] = keyProtection,
            ["proofPublicKey"] = B64Url(proofKey.PublicKeyX963),
            ["wrappingPublicKey"] = B64Url(wrappingPublicKey),
        };
        fields["proof"] = B64Url(Sign(proofKey, EnrollDomain, CanonicalJson(fields)));
        return Encoding.UTF8.GetString(CanonicalJson(fields));
    }

    /// <summary>
    /// A signed <c>/device/</c> request. <paramref name="extraFields"/> are the consent fields. The
    /// server signs them into the body of <c>POST /device/consent</c>, so they are signed here too.
    /// </summary>
    public static SignedRequest Sign(
        IDeviceSigner signer,
        string method,
        string path,
        string deviceId,
        string timestamp,
        string nonce,
        string osUser,
        string hostname,
        string clientVersion,
        string filesTokenId,
        string? ifNoneMatch,
        IReadOnlyDictionary<string, string>? extraFields = null)
    {
        string user = HeaderSafe(osUser);
        string host = HeaderSafe(hostname);
        var signed = new Dictionary<string, string>
        {
            ["clientVersion"] = clientVersion,
            ["deviceId"] = deviceId,
            ["filesTokenId"] = filesTokenId,
            ["hostname"] = host,
            ["method"] = method,
            ["nonce"] = nonce,
            ["osUser"] = user,
            ["path"] = path,
            ["timestamp"] = timestamp,
        };
        string? body = null;
        if (extraFields is not null)
        {
            foreach ((string name, string value) in extraFields) signed[name] = value;
            body = Encoding.UTF8.GetString(CanonicalJson(extraFields));
        }

        var headers = new Dictionary<string, string>
        {
            ["X-Jazz-Device-Id"] = deviceId,
            ["X-Jazz-Device-Timestamp"] = timestamp,
            ["X-Jazz-Device-Nonce"] = nonce,
            ["X-Jazz-Device-Signature"] = B64Url(Sign(signer, RequestDomain, CanonicalJson(signed))),
            ["X-Jazz-Os-User"] = osUser,
            ["X-Jazz-Hostname"] = hostname,
            ["X-Jazz-Client-Version"] = clientVersion,
        };
        if (filesTokenId.Length > 0) headers["X-Jazz-Files-Token-Id"] = filesTokenId;
        if (ifNoneMatch is not null) headers["If-None-Match"] = ifNoneMatch;
        return new SignedRequest(headers, body);
    }

    public static string Timestamp(DateTimeOffset now) =>
        now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    public static string NewNonce() => B64Url(RandomNumberGenerator.GetBytes(16));

    /// <summary>
    /// The server reads a header value as Latin-1. A header with a non-ASCII character goes out as
    /// UTF-8 (the original value, not this result), so the server sees those bytes as Latin-1 text.
    /// The client signs this text, so the signature holds for a name such as "Novák".
    /// </summary>
    public static string HeaderSafe(string value) =>
        value.All(character => character < 0x80)
            ? value
            : Encoding.Latin1.GetString(Encoding.UTF8.GetBytes(value));

    private static void AppendString(StringBuilder builder, string value)
    {
        builder.Append('"');
        foreach (char character in value)
        {
            switch (character)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                case < ' ': builder.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture)); break;
                default: builder.Append(character); break;
            }
        }

        builder.Append('"');
    }
}
