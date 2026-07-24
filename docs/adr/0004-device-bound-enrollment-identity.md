# ADR 0004: Device-bound enrollment identity

Status: accepted

## Context

The one-time bootstrap string authorizes an enrollment attempt; it is not proof that the claimant is
the Mac that created the claim. A copied bootstrap must not let another machine bind the same claim,
decrypt the returned signed device bundle, or create a second local identity after a restart race.
At the same time, Jazz Capture must retry unattended after the user has unlocked the Mac once. This
is physical-device binding, not a new local-security UX: it must not add biometric prompts and it
does not encrypt a Jazz Archive.

The device-bound redemption v1 contract therefore has two distinct P-256 public keys:

- an ES256 proof-of-possession key signs the canonical claim;
- an ECDH-ES wrapping key derives the AES-GCM key that opens the server's sealed response.

Reusing one EC private key for both purposes is forbidden.

The bootstrap id is short-lived claim authorization, not key identity. The persistent keyset is
bound instead to the enrolled `deviceId` and `authorityBindingSHA256`: the lower-hex SHA-256 of the
canonical signed authority tuple (issuer, audience, project, stack/archive origins, Company, and
Area). The enrollment API layer must derive that digest from authenticated server data; it must not
accept an unsigned digest supplied by UI or bootstrap payload.

## Decision

`JasnostEnrollmentSecurity` owns a single restart-safe `DeviceEnrollmentIdentityVault`. The
production constructor has no backend selector: it requires
[`SecureEnclave.P256`](https://developer.apple.com/documentation/cryptokit/secureenclave/p256) and
fails closed when `SecureEnclave.isAvailable` is false. CryptoKit supports both its Signing and
KeyAgreement variants on the macOS 14 deployment target. The key-agreement key is reloaded through
[`SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation:)`](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey);
the signing key uses the corresponding Signing initializer.

The two `dataRepresentation` values are device-bound, Secure Enclave-wrapped key references, not
plaintext EC private scalars. Jazz persists both references and their binding metadata in one
generic-password Keychain item with `AfterFirstUnlockThisDeviceOnly`. Each Secure Enclave key uses
an access control containing `privateKeyUsage`, without `userPresence` or biometry, so background
retry remains possible. The item is never synchronized.

One stable sidecar `flock` plus an in-process lock serializes first creation, rotation, and
revocation across app instances. The single Keychain write is the commit boundary:

- first creation uses add-only semantics; a losing writer discards its generated handles and
  exact-reloads the winner;
- exact restart reload reconstructs both keys and recomputes public points, RFC 7638-style
  thumbprints, role-specific key IDs, and the device/authority-bound key-set ID;
- a mismatched binding, malformed JSON, unknown key reference, changed public point, mixed pair,
  missing half, software backend, or unavailable Secure Enclave fails closed;
- a later bootstrap under the same device and signed authority reuses the exact keyset and passes
  its current bootstrap id only to claim construction;
- rotation requires the current key-set ID as a fence and cannot change device or authority
  binding; an authority migration needs a separately authenticated control-plane transition;
- revocation atomically drops both opaque references and leaves a non-secret tombstone. Already
  loaded capabilities exact-reload the persisted active key-set fence before every sign/open
  operation, and the same process/flock critical section stays held through the Secure Enclave
  sign/ECDH operation so rotation or revocation cannot commit in between.

The public identity API exposes only public key profiles, stable identifiers, claim signing, and
sealed-bundle opening. It cannot return a private scalar or opaque key reference. Its descriptions
and errors are deliberately redacted.

## Contract boundary

`JasnostCaptureCore` remains Foundation-only and has no Keychain, Security, CryptoKit Secure
Enclave, or TCC dependency. The portable claim/seal encoding and verification live in
`JasnostEnrollmentSecurity`; narrow signing and key-agreement protocols let tests exercise restart,
concurrency, corruption, rotation, and revocation with an in-memory fake. The deployed constructor
cannot select that fake and never falls back to software keys.

The server remains authoritative for bootstrap expiry, first-claim binding, credential lifecycle,
authority-digest derivation, authorized key rotation, and revocation. The local fence prevents stale
local use but is not a substitute for server-side atomic claim/redeem enforcement.

## Consequences

- Intel Macs or managed environments without an available Secure Enclave cannot use trusted
  device-bound enrollment until an explicitly reviewed, hardware-backed `SecKey`/Keychain backend
  is added. Silent software fallback is not permitted.
- Key rotation and revocation need control-plane API wiring and operator policy before they are
  user-visible.
- None of these keys or Keychain records enter a `.jazz-archive`, archive manifest, log, diagnostic
  report, command-line argument, or UserDefaults.
