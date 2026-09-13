# Reviewed pilot package preparation — 2026-09-13

**Build/staging complete; stable signing pending, NOT launch-ready.** The owner prohibited all
Keychain access in this preparation slice. The existing `Jazz Dev Code Signing` certificate signer
requires access to its Keychain private key; the existing packaging policy prohibits ad-hoc fallback.
Neither restriction was relaxed. No signing identity lookup or `codesign --sign` was attempted.
This is a permission boundary for this slice, not evidence that stable signing is technically unavailable.

## Build and staged artifact

- Source HEAD: `c6710488af820923f53ec88b9f5e5703307c2539`.
- Accepted fix: `3dced1dfa3d108bc9efc8a37d4b3649108aedebf`; macOS source trees identical.
- macOS tree: `618f8e4e6eb90b9bfa5a85a49c7d0cb2ac53a483`.
- Fresh debug scratch build: `swift build --configuration debug --scratch-path "$R/build"`,
  passed in **24.30s**. No source edits or new dependencies; prior914-test review remains separate evidence.
- `$R`: `/tmp/jazz-continuous-eaa688eb/direct-client-pilot/package-prep-plLfHu` (private0700).
- App: `$R/Jazz Direct Pilot.app` — outside both installed applications and both state roots.
- ZIP: `$R/Jazz-Direct-Pilot-3dced1d-NOT-STABLE-SIGNED.zip` (0600).
- Executable:32,715,536bytes, SHA256`357cd7d2456285646375dde8440afe809efd43931548645251da400d5bf28ed1`.
- ZIP:8,965,328bytes, SHA256`d239566c5747d2c3f8fa080cb58e0fa6e04a966833e90cc54cf000b81b9b104c`.
- Info.plist SHA256`d982fcc7b1e9acdbac0b80d4bd749b2cb7a052f55e5ee3d27af00f87abdb7836`.

Staged executable equals the fresh build byte-for-byte. ZIP CRCs, contained executable digest and
contained plist were checked. `nm` confirms the reviewed `loadCredential`, `mediaHasCapacity`,
`pilotWindowIndex` and `privacyInfo` symbol families in the staged binary, without execution.
Build/version metadata names3dced1d. Public pilot scope/trust pins were
copied from the strictly verified existing pilot, with only source/build revision updated; no private
key, token, endpoint, credential or capability was added. Audio remains disabled; TextEdit/Calculator
allowlist and source/device bindings unchanged.

## Signature and isolation checks — distinguish metadata from signing

The plist's bundle ID is `dev.jazz.capture.direct-pilot`. Accepted source selects this ID before legacy
owners, uses Keychain service of the same name, and resolves state to
`/Users/maziak/.jazz-direct-pilot`. That existing directory remained0700 with unchanged device/inode/mtime.
These are source/plist/filesystem checks, **not executable preflight**; the app was never invoked.

The Swift linker leaves an **ad-hoc Mach-O signature**, not the required signed application:

- `codesign --display --verbose=4`: `Signature=adhoc`, `Info.plist=not bound`, no sealed resources.
- `codesign --verify --strict --verbose=2`: exit1,
  **“code has no resources but signature indicates they must be present”**.
- Required stable certificate/bundle identity verification: exit1 for the same unsealed-bundle reason.

No deliberate ad-hoc bundle-signing fallback was performed. The staged plist ID is **not yet sealed
into the signature**, and no stable-identity/TCC/notarization qualification is claimed. Stable signing
needs explicit permission to use the existing signing key; this does not authorize pilot credential
access, installation, capability provisioning, a prompt or a launch. Final signing will change hashes.

## Preservation evidence

Read-only, bounded, no-follow hashing reused the existing `spool_inventory.scan`, without its CLI's
TCC/review/launch diagnostics. Two stable baseline passes before the build match two post-staging
passes over **`~/.jazz/spool`**:

- 1,783 entries /1,539 files /125,017,638bytes.
- Tree SHA256`1ecda58c6654247c5a6547c42294e8b712418632fb42957da19f40fefb39751a`.
- Tree covers hashed relative paths, types, sizes, mtimes, inodes and file digests; no private paths or
  media contents published. This root differs from the historical whole-`~/.jazz` inventory, so its
  tree digest is not compared with that historical digest. Family counters are not queue-state claims.
- No writer locks, WAL replay, cleanup, delivery, journal recovery or spool writes.

Both installed bundle trees matched across staging. Before-build/after-stage executable pins match:

| Installed executable (untouched) | SHA256 |
| --- | --- |
| `/Applications/Jazz Capture.app` | `4ec1e731a217e314d53ccf2ece6d23c646f342c6a044e4ced566d0575e2e0737` |
| `/Applications/Jazz Direct Pilot.app` | `90bab20182a4808c1696a16651c7d2bcb1dd17def5e7a53cce0a3e15af67d020` |

No app installed/launched or signaled; pilot process absent. No Keychain item/signing-key operation
or `security` command issued; `codesign` inspection only. No credential provisioning, permission
prompt, capture, server work, or installed-app mutation.

## Receipt hashes

Private exclusive0600 receipts under `$R`; `integrity.json` verifies these plus ZIP contents:

| File | SHA256 |
| --- | --- |
| `build.log` | `b112c6f8153a73c1a73fa1266cf596b20cb53d5b209e9f46c0b8c79754c2b9cd` |
| `before.json` | `19c12eccb848b5838e94cdea4315f421ea61605be9e2dd63be5350e087b71294` |
| `codesign-inspection.json` | `905ef1b8b0ebd6e90eebc3a41fee42aea7701773de09a7518e6c170b9b063b74` |
| `package-receipt.json` | `af5047c9998419ed337130c789e8985a114b100a1132f3ab517ab0378f37e6e8` |
| `stage.py` (one-shot; do not replay) | `996c2cfa440dbbae11404d983362572145626f856353eea38cd7470ad6100364` |

Wait for explicit owner authorization before signing-key access. Independently, fresh capability or
launch remains gated on explicit owner presence/readiness to approve. Prior token/item cleanup and
stopped monitor remain unchanged; no new monitoring or cleanup. No E2E PASS or terminal-status.
