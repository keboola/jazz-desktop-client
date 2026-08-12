namespace JazzEnrollmentSecurity;

/// <summary>Fail-closed reasons a signed enrollment bundle can be refused.</summary>
public enum SignedEnrollmentError
{
    /// <summary>No trusted Jazz enrollment issuer is configured on this machine.</summary>
    TrustUnavailable,

    /// <summary>The enrollment bundle is not a flattened signed Jazz bundle.</summary>
    MalformedEnvelope,

    /// <summary>The signed enrollment bundle contains invalid base64url.</summary>
    InvalidBase64Url,

    /// <summary>The signed enrollment protected header is not canonical JSON.</summary>
    NonCanonicalProtectedHeader,

    /// <summary>The signed enrollment protected header is not the required Jazz profile.</summary>
    InvalidProtectedHeader,

    /// <summary>The signed enrollment bundle does not use EdDSA.</summary>
    UnsupportedAlgorithm,

    /// <summary>The enrollment signing key is not trusted by this machine.</summary>
    UnknownKey,

    /// <summary>The enrollment bundle signature is invalid.</summary>
    InvalidSignature,

    /// <summary>The signed enrollment payload is not canonical JSON.</summary>
    NonCanonicalPayload,

    /// <summary>The signed enrollment payload does not satisfy the v2 contract.</summary>
    InvalidPayload,

    /// <summary>The enrollment bundle was signed for a different Jazz issuer.</summary>
    IssuerMismatch,

    /// <summary>The enrollment bundle was signed for a different client audience.</summary>
    AudienceMismatch,

    /// <summary>The enrollment bundle was issued in the future.</summary>
    NotYetValid,

    /// <summary>The copied enrollment bundle has expired.</summary>
    BundleExpired,

    /// <summary>The scoped enrollment credential has expired.</summary>
    CredentialExpired,

    /// <summary>This device has already accepted a newer enrollment generation.</summary>
    Rollback,

    /// <summary>The generation or bundle id was reused with different signed content.</summary>
    Collision,

    /// <summary>The local enrollment replay state is unavailable.</summary>
    AcceptanceStateUnavailable,
}

/// <summary>A signed enrollment bundle was refused.</summary>
public sealed class SignedEnrollmentException : Exception
{
    /// <summary>Creates an exception carrying <paramref name="reason"/>.</summary>
    public SignedEnrollmentException(SignedEnrollmentError reason)
        : base(Describe(reason))
    {
        Reason = reason;
    }

    /// <summary>Why the bundle was refused.</summary>
    public SignedEnrollmentError Reason { get; }

    /// <summary>
    /// An operator-safe description. These strings are surfaced in Settings, so they deliberately
    /// contain no token bytes, key material, URLs or server response content.
    /// </summary>
    public static string Describe(SignedEnrollmentError reason) => reason switch
    {
        SignedEnrollmentError.TrustUnavailable =>
            "No trusted Jazz enrollment issuer is configured on this PC.",
        SignedEnrollmentError.MalformedEnvelope =>
            "The enrollment bundle is not a flattened signed Jazz bundle.",
        SignedEnrollmentError.InvalidBase64Url =>
            "The signed enrollment bundle contains invalid base64url.",
        SignedEnrollmentError.NonCanonicalProtectedHeader =>
            "The signed enrollment protected header is not canonical JSON.",
        SignedEnrollmentError.InvalidProtectedHeader =>
            "The signed enrollment protected header is not the required Jazz profile.",
        SignedEnrollmentError.UnsupportedAlgorithm =>
            "The signed enrollment bundle does not use EdDSA.",
        SignedEnrollmentError.UnknownKey =>
            "The enrollment signing key is not trusted by this PC.",
        SignedEnrollmentError.InvalidSignature =>
            "The enrollment bundle signature is invalid.",
        SignedEnrollmentError.NonCanonicalPayload =>
            "The signed enrollment payload is not canonical JSON.",
        SignedEnrollmentError.InvalidPayload =>
            "The signed enrollment payload does not satisfy the v2 contract.",
        SignedEnrollmentError.IssuerMismatch =>
            "The enrollment bundle was signed for a different Jazz issuer.",
        SignedEnrollmentError.AudienceMismatch =>
            "The enrollment bundle was signed for a different client audience.",
        SignedEnrollmentError.NotYetValid =>
            "The enrollment bundle was issued in the future.",
        SignedEnrollmentError.BundleExpired =>
            "The copied enrollment bundle has expired; issue a new one.",
        SignedEnrollmentError.CredentialExpired =>
            "The scoped enrollment credential has expired; issue a new bundle.",
        SignedEnrollmentError.Rollback =>
            "This device has already accepted a newer enrollment generation.",
        SignedEnrollmentError.Collision =>
            "The enrollment generation or bundle id was reused with different signed content.",
        SignedEnrollmentError.AcceptanceStateUnavailable =>
            "The local enrollment replay state is unavailable; import was stopped safely.",
        _ => "The enrollment bundle was refused.",
    };
}

/// <summary>Reasons the code-signed trust configuration itself is unusable.</summary>
public enum EnrollmentTrustPolicyError
{
    /// <summary>The configured enrollment issuer is not a canonical HTTPS origin.</summary>
    InvalidIssuer,

    /// <summary>The configured enrollment audience is invalid.</summary>
    InvalidAudience,

    /// <summary>The configured enrollment clock skew is invalid.</summary>
    InvalidClockSkew,

    /// <summary>No Ed25519 enrollment trust anchor is configured.</summary>
    MissingPublicKeys,

    /// <summary>An enrollment trust-anchor key id is invalid.</summary>
    InvalidKeyId,

    /// <summary>An enrollment trust anchor is not a 32-byte Ed25519 public key.</summary>
    InvalidPublicKey,

    /// <summary>The native enrollment redemption origin allowlist is invalid.</summary>
    InvalidRedemptionOrigins,
}

/// <summary>The enrollment trust configuration is unusable.</summary>
public sealed class EnrollmentTrustPolicyException : Exception
{
    /// <summary>Creates an exception carrying <paramref name="reason"/>.</summary>
    public EnrollmentTrustPolicyException(EnrollmentTrustPolicyError reason)
        : base(Describe(reason))
    {
        Reason = reason;
    }

    /// <summary>Why the configuration is unusable.</summary>
    public EnrollmentTrustPolicyError Reason { get; }

    /// <summary>An operator-safe description.</summary>
    public static string Describe(EnrollmentTrustPolicyError reason) => reason switch
    {
        EnrollmentTrustPolicyError.InvalidIssuer =>
            "The configured enrollment issuer is not a canonical HTTPS origin.",
        EnrollmentTrustPolicyError.InvalidAudience =>
            "The configured enrollment audience is invalid.",
        EnrollmentTrustPolicyError.InvalidClockSkew =>
            "The configured enrollment clock skew is invalid.",
        EnrollmentTrustPolicyError.MissingPublicKeys =>
            "No Ed25519 enrollment trust anchor is configured.",
        EnrollmentTrustPolicyError.InvalidKeyId =>
            "An enrollment trust-anchor key id is invalid.",
        EnrollmentTrustPolicyError.InvalidPublicKey =>
            "An enrollment trust anchor is not a 32-byte Ed25519 public key.",
        EnrollmentTrustPolicyError.InvalidRedemptionOrigins =>
            "The native enrollment redemption origin allowlist is invalid.",
        _ => "The enrollment trust configuration is invalid.",
    };
}

/// <summary>Fail-closed reasons a device-bound claim or sealed bundle is refused.</summary>
public enum DeviceBoundEnrollmentError
{
    /// <summary>The device enrollment claim is not canonical strict JSON.</summary>
    MalformedClaim,

    /// <summary>The device enrollment claim does not satisfy the v1 contract.</summary>
    InvalidClaim,

    /// <summary>The P-256 proof of possession is invalid.</summary>
    InvalidClaimProof,

    /// <summary>The device enrollment proof is not canonical low-S ES256.</summary>
    NonCanonicalSignature,

    /// <summary>The sealed device bundle is malformed.</summary>
    MalformedSealedBundle,

    /// <summary>The sealed device bundle protected context is invalid.</summary>
    InvalidProtectedContext,

    /// <summary>The sealed device bundle belongs to a different claim or bundle.</summary>
    ContextMismatch,

    /// <summary>The sealed device bundle is bound to a different wrapping key.</summary>
    WrongRecipient,

    /// <summary>The sealed device bundle failed authenticated decryption.</summary>
    AuthenticationFailed,

    /// <summary>The sealed device bundle reveal has expired.</summary>
    Expired,

    /// <summary>The decrypted signed bundle does not match its protected digest.</summary>
    DigestMismatch,
}

/// <summary>A device-bound claim or sealed bundle was refused.</summary>
public sealed class DeviceBoundEnrollmentException : Exception
{
    /// <summary>Creates an exception carrying <paramref name="reason"/>.</summary>
    public DeviceBoundEnrollmentException(DeviceBoundEnrollmentError reason)
        : base(Describe(reason))
    {
        Reason = reason;
    }

    /// <summary>Why the document was refused.</summary>
    public DeviceBoundEnrollmentError Reason { get; }

    /// <summary>
    /// An operator-safe description. Deliberately free of claim material, ciphertext and any part
    /// of the decrypted bundle.
    /// </summary>
    public static string Describe(DeviceBoundEnrollmentError reason) => reason switch
    {
        DeviceBoundEnrollmentError.MalformedClaim =>
            "The device enrollment claim is not canonical strict JSON.",
        DeviceBoundEnrollmentError.InvalidClaim =>
            "The device enrollment claim does not satisfy the v1 contract.",
        DeviceBoundEnrollmentError.InvalidClaimProof =>
            "The P-256 proof of possession is invalid.",
        DeviceBoundEnrollmentError.NonCanonicalSignature =>
            "The device enrollment proof is not canonical low-S ES256.",
        DeviceBoundEnrollmentError.MalformedSealedBundle =>
            "The sealed device bundle is malformed.",
        DeviceBoundEnrollmentError.InvalidProtectedContext =>
            "The sealed device bundle protected context is invalid.",
        DeviceBoundEnrollmentError.ContextMismatch =>
            "The sealed device bundle belongs to a different claim or bundle.",
        DeviceBoundEnrollmentError.WrongRecipient =>
            "The sealed device bundle is bound to a different wrapping key.",
        DeviceBoundEnrollmentError.AuthenticationFailed =>
            "The sealed device bundle failed authenticated decryption.",
        DeviceBoundEnrollmentError.Expired =>
            "The sealed device bundle reveal has expired.",
        DeviceBoundEnrollmentError.DigestMismatch =>
            "The decrypted signed bundle does not match its protected digest.",
        _ => "The sealed device bundle was refused.",
    };
}

/// <summary>Fail-closed reasons the local device enrollment identity is unusable.</summary>
public enum DeviceEnrollmentIdentityError
{
    /// <summary>The requested device enrollment identity binding is invalid.</summary>
    InvalidBinding,

    /// <summary>A hardware-backed device identity is unavailable.</summary>
    HardwareUnavailable,

    /// <summary>The device identity store is unavailable.</summary>
    PersistenceUnavailable,

    /// <summary>The persisted device identity failed closed validation.</summary>
    CorruptState,

    /// <summary>A different device enrollment binding already owns the identity slot.</summary>
    BindingConflict,

    /// <summary>The device enrollment identity has been revoked.</summary>
    Revoked,

    /// <summary>The expected device enrollment key set is no longer current.</summary>
    StaleKeySet,

    /// <summary>The hardware-backed device key operation failed.</summary>
    KeyOperationFailed,
}

/// <summary>The local device enrollment identity is unusable.</summary>
public sealed class DeviceEnrollmentIdentityException : Exception
{
    /// <summary>Creates an exception carrying <paramref name="reason"/>.</summary>
    public DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError reason)
        : base(Describe(reason))
    {
        Reason = reason;
    }

    /// <summary>Why the identity is unusable.</summary>
    public DeviceEnrollmentIdentityError Reason { get; }

    /// <summary>
    /// An operator-safe description. Deliberately free of stored key references, the device id and
    /// the authority binding, so an error path never becomes an export path.
    /// </summary>
    public static string Describe(DeviceEnrollmentIdentityError reason) => reason switch
    {
        DeviceEnrollmentIdentityError.InvalidBinding =>
            "The requested device enrollment identity binding is invalid.",
        DeviceEnrollmentIdentityError.HardwareUnavailable =>
            "A hardware-backed device identity is unavailable.",
        DeviceEnrollmentIdentityError.PersistenceUnavailable =>
            "The device identity store is unavailable.",
        DeviceEnrollmentIdentityError.CorruptState =>
            "The persisted device identity failed closed validation.",
        DeviceEnrollmentIdentityError.BindingConflict =>
            "A different device enrollment binding already owns the identity slot.",
        DeviceEnrollmentIdentityError.Revoked =>
            "The device enrollment identity has been revoked.",
        DeviceEnrollmentIdentityError.StaleKeySet =>
            "The expected device enrollment key set is no longer current.",
        DeviceEnrollmentIdentityError.KeyOperationFailed =>
            "The hardware-backed device key operation failed.",
        _ => "The device enrollment identity is unavailable.",
    };
}

/// <summary>Fail-closed reasons native device-bound redemption stops.</summary>
public enum DeviceEnrollmentRedemptionError
{
    /// <summary>The device enrollment bootstrap is malformed.</summary>
    MalformedBootstrap,

    /// <summary>The device enrollment redemption route is not a canonical HTTPS endpoint.</summary>
    InsecureRedemptionRoute,

    /// <summary>The device enrollment bootstrap has expired.</summary>
    BootstrapExpired,

    /// <summary>Another device enrollment is already pending on this PC.</summary>
    PendingConflict,

    /// <summary>The pending device enrollment state is unavailable.</summary>
    PendingStateUnavailable,

    /// <summary>The enrollment server returned an invalid device context.</summary>
    MalformedContext,

    /// <summary>The server context does not match this PC's trusted enrollment authority.</summary>
    AuthorityMismatch,

    /// <summary>The enrollment server returned an invalid redemption response.</summary>
    MalformedResponse,

    /// <summary>The one-time device enrollment authorization was rejected.</summary>
    Unauthorized,

    /// <summary>The device enrollment was quarantined by the server.</summary>
    Quarantined,

    /// <summary>The device enrollment server is temporarily unavailable.</summary>
    ServerUnavailable,

    /// <summary>The redeemed signed enrollment does not match its reserved device context.</summary>
    SignedBundleMismatch,
}

/// <summary>Native device-bound redemption stopped.</summary>
public sealed class DeviceEnrollmentRedemptionException : Exception
{
    /// <summary>Creates an exception carrying <paramref name="reason"/>.</summary>
    public DeviceEnrollmentRedemptionException(DeviceEnrollmentRedemptionError reason)
        : base(Describe(reason))
    {
        Reason = reason;
    }

    /// <summary>Why redemption stopped.</summary>
    public DeviceEnrollmentRedemptionError Reason { get; }

    /// <summary>
    /// An operator-safe description. Deliberately free of bootstrap bearer bytes, URLs, claims,
    /// ciphertext, decrypted bundle content and server response bodies.
    /// </summary>
    public static string Describe(DeviceEnrollmentRedemptionError reason) => reason switch
    {
        DeviceEnrollmentRedemptionError.MalformedBootstrap =>
            "The device enrollment bootstrap is malformed.",
        DeviceEnrollmentRedemptionError.InsecureRedemptionRoute =>
            "The device enrollment redemption route is not a canonical HTTPS endpoint.",
        DeviceEnrollmentRedemptionError.BootstrapExpired =>
            "The device enrollment bootstrap has expired; issue a new one.",
        DeviceEnrollmentRedemptionError.PendingConflict =>
            "Another device enrollment is already pending on this PC.",
        DeviceEnrollmentRedemptionError.PendingStateUnavailable =>
            "The pending device enrollment state is unavailable.",
        DeviceEnrollmentRedemptionError.MalformedContext =>
            "The enrollment server returned an invalid device context.",
        DeviceEnrollmentRedemptionError.AuthorityMismatch =>
            "The enrollment server context does not match this PC's trusted enrollment authority.",
        DeviceEnrollmentRedemptionError.MalformedResponse =>
            "The enrollment server returned an invalid redemption response.",
        DeviceEnrollmentRedemptionError.Unauthorized =>
            "The one-time device enrollment authorization was rejected.",
        DeviceEnrollmentRedemptionError.Quarantined =>
            "The device enrollment was quarantined by the server.",
        DeviceEnrollmentRedemptionError.ServerUnavailable =>
            "The device enrollment server is temporarily unavailable.",
        DeviceEnrollmentRedemptionError.SignedBundleMismatch =>
            "The redeemed signed enrollment does not match its reserved device context.",
        _ => "The device enrollment could not be redeemed.",
    };
}
