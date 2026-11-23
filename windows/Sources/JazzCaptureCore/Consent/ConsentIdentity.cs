using System.Globalization;
using System.Text;
using System.Text.Json;

namespace JazzCaptureCore.Consent;

public enum ConsentRoute
{
    /// <summary>The device uses Entra ID. The person is the tenant ID plus the object ID.</summary>
    Entra,

    /// <summary>No Entra ID. The person is the qualified Windows user name plus the Windows SID.</summary>
    Signed,
}

/// <summary>
/// The person a consent answer belongs to. The decision of 2026-11-23 replaced the OS user name key:
/// the person is <c>tid</c> + <c>oid</c> on a device with Entra ID, else the qualified Windows user
/// name plus the Windows SID.
/// </summary>
/// <param name="StoreKey">Key of the local answer. Stable when the Windows account is renamed.</param>
/// <param name="ConsentKey">Value of <c>consentKey</c> in <c>POST /device/consent</c>.</param>
/// <param name="QualifiedUser">Lower case <c>domain\user</c>, sent as <c>X-Jazz-Os-User</c>.</param>
/// <param name="WindowsSid">The SID. It is sent only on the signed route.</param>
public sealed record ConsentIdentity(
    ConsentRoute Route,
    string StoreKey,
    string ConsentKey,
    string QualifiedUser,
    string? WindowsSid)
{
    public static ConsentIdentity ForEntra(string tenantId, string objectId, string qualifiedUser)
    {
        string person = tenantId.ToLowerInvariant() + "/" + objectId.ToLowerInvariant();
        return new ConsentIdentity(ConsentRoute.Entra, "entra:" + person, person, Qualify(qualifiedUser), null);
    }

    public static ConsentIdentity ForWindows(string qualifiedUser, string sid)
    {
        string user = Qualify(qualifiedUser);
        return new ConsentIdentity(ConsentRoute.Signed, "sid:" + sid.ToUpperInvariant(), user, user, sid.ToUpperInvariant());
    }

    /// <summary>Case does not change the person: <c>ACME\JNovak</c> and <c>acme\jnovak</c> are one key.</summary>
    public static string Qualify(string qualifiedUser) => qualifiedUser.Trim().ToLowerInvariant();
}

/// <summary>Reads the person from the claims of the Entra access token the client already holds.</summary>
public static class EntraPerson
{
    /// <summary>
    /// The client only reads its own token to name the person. The server verifies the token and
    /// takes the person from the verified claims, never from what the client says.
    /// </summary>
    public static bool TryRead(string jwt, out string tenantId, out string objectId)
    {
        tenantId = string.Empty;
        objectId = string.Empty;
        string[] parts = jwt.Split('.');
        if (parts.Length < 2) return false;
        try
        {
            string padded = parts[1].Replace('-', '+').Replace('_', '/');
            padded = padded.PadRight(padded.Length + ((4 - (padded.Length % 4)) % 4), '=');
            using JsonDocument claims = JsonDocument.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(padded)));
            JsonElement root = claims.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return false;
            string? tid = Claim(root, "tid");
            string? oid = Claim(root, "oid");
            if (!Guid.TryParse(tid, out Guid tenant) || !Guid.TryParse(oid, out Guid person)) return false;
            tenantId = tenant.ToString("D", CultureInfo.InvariantCulture);
            objectId = person.ToString("D", CultureInfo.InvariantCulture);
            return true;
        }
        catch (Exception exception) when (exception is FormatException or JsonException or InvalidOperationException)
        {
            return false;
        }
    }

    private static string? Claim(JsonElement root, string name) =>
        root.TryGetProperty(name, out JsonElement element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;
}
