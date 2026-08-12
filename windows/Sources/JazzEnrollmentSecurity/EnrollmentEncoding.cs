using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore.Json;

namespace JazzEnrollmentSecurity;

/// <summary>
/// Base64url, canonical JSON and small digest helpers shared by every enrollment document.
/// </summary>
/// <remarks>
/// These are all exact ports. A signed document is authenticated over its bytes, so any place where
/// this file disagrees with the macOS <c>EnrollmentEncoding</c> is a place where one of the two
/// clients would accept a bundle the other rejects.
/// </remarks>
public static partial class EnrollmentEncoding
{
    /// <summary>Unpadded base64url, as every enrollment segment is encoded.</summary>
    public static string EncodeBase64Url(ReadOnlySpan<byte> data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    /// <summary>
    /// Decodes unpadded base64url, or returns <see langword="null"/>.
    /// </summary>
    /// <remarks>
    /// The re-encode comparison at the end is the point of this method: it rejects a segment whose
    /// trailing bits are non-zero, which would otherwise give two distinct spellings of the same
    /// bytes and therefore two distinct signing inputs for one payload.
    /// </remarks>
    public static byte[]? DecodeBase64Url(string? value, int maximumBytes)
    {
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }

        foreach (char c in value)
        {
            bool allowed = char.IsAsciiLetterOrDigit(c) || c is '-' or '_';
            if (!allowed)
            {
                return null;
            }
        }

        // The character count is bounded before allocating, matching the macOS ceiling exactly.
        if (value.Length > ((maximumBytes * 4) + 2) / 3)
        {
            return null;
        }

        string standard = value.Replace('-', '+').Replace('_', '/');
        standard += new string('=', (4 - (standard.Length % 4)) % 4);

        byte[] decoded;
        try
        {
            decoded = Convert.FromBase64String(standard);
        }
        catch (FormatException)
        {
            return null;
        }

        if (decoded.Length > maximumBytes || !string.Equals(EncodeBase64Url(decoded), value, StringComparison.Ordinal))
        {
            return null;
        }

        return decoded;
    }

    /// <summary>Whether <paramref name="value"/> is a well-formed protected-header <c>kid</c>.</summary>
    public static bool IsValidKeyId(string? value) =>
        value is not null && KeyIdPattern().IsMatch(value);

    /// <summary>
    /// RFC 8785 canonical JSON bytes for <paramref name="value"/>, or <see langword="null"/> when
    /// the tree cannot be canonicalized.
    /// </summary>
    /// <remarks>
    /// For the ASCII keys, integer numbers and Unicode string values that enrollment documents
    /// carry, RFC 8785 output is byte-identical to Foundation's
    /// <c>[.sortedKeys, .withoutEscapingSlashes]</c>, which is what the server and the macOS client
    /// sign over. <c>JsonEnrollmentDocumentTests</c> pins that agreement against the contract
    /// fixtures rather than leaving it as an assumption.
    /// </remarks>
    public static byte[]? TryCanonicalJson(JsonNode? value)
    {
        try
        {
            return new UTF8Encoding(false).GetBytes(JsonCanonicalizer.Canonicalize(value));
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>Lowercase hex SHA-256.</summary>
    public static string HexSha256(ReadOnlySpan<byte> data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    /// <summary>Length-independent byte comparison.</summary>
    public static bool ConstantTimeEquals(ReadOnlySpan<byte> left, ReadOnlySpan<byte> right) =>
        left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);

    /// <summary>
    /// Counts Unicode scalars, which is what the server's schema <c>maxLength</c> counts.
    /// </summary>
    /// <remarks>
    /// <see cref="string.Length"/> counts UTF-16 code units, so an 8192-scalar token made of
    /// astral-plane characters would measure 16384 and be rejected on Windows while the macOS
    /// client accepted it. That divergence would be a real interoperability bug, not a nicety.
    /// </remarks>
    public static int ScalarCount(string value)
    {
        int count = 0;
        for (int i = 0; i < value.Length; i++)
        {
            count++;
            if (char.IsHighSurrogate(value[i]) && i + 1 < value.Length && char.IsLowSurrogate(value[i + 1]))
            {
                i++;
            }
        }

        return count;
    }

    /// <summary>Parses lowercase or uppercase hex into bytes; <see langword="null"/> when malformed.</summary>
    public static byte[]? TryDecodeHex(string value)
    {
        if (value.Length % 2 != 0)
        {
            return null;
        }

        try
        {
            return Convert.FromHexString(value);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    [GeneratedRegex(@"^[A-Za-z0-9._-]{1,128}$")]
    private static partial Regex KeyIdPattern();
}
