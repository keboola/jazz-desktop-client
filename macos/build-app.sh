#!/usr/bin/env bash
#
# Build "Jazz Capture.app" — a release binary wrapped in a proper .app bundle with the
# Info.plist (LSUIElement + usage descriptions) and an ad-hoc code signature, so macOS TCC
# can attribute and remember the Accessibility / Screen Recording / Microphone grants.
set -euo pipefail
cd "$(dirname "$0")"

APP="Jazz Capture.app"

# SwiftPM's .build/build.db is SQLite; on some paths (cloud-synced volumes, or filesystems whose
# locking SQLite can't use) `swift build` dies with `accessing build database ... disk I/O error`
# even though compilation would have succeeded. So always build into a LOCAL-disk scratch dir.
# Override with JASNOST_BUILD_DIR if you want it elsewhere (must NOT be on a synced volume).
SCRATCH="${JASNOST_BUILD_DIR:-$HOME/Library/Caches/jasnost-macos-agent}"
mkdir -p "$SCRATCH"
BIN="$SCRATCH/release/JasnostCapture"

echo "[build] swift build -c release --scratch-path $SCRATCH"
swift build -c release --scratch-path "$SCRATCH"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JasnostCapture"

# Git-stamped version so every build is identifiable in Settings (no more "am I on the old app?").
# Short = product version; build = <commit-count>.<short-hash>[+] (+ marks an uncommitted tree).
# build-release.sh overrides both via JAZZ_VERSION / JAZZ_BUILD_VERSION to stamp a release tag.
SHORT_VERSION="${JAZZ_VERSION:-0.23.0}"
COMMITS="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
HASH="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
git diff --quiet 2>/dev/null || HASH="${HASH}+"
BUILD_VERSION="${JAZZ_BUILD_VERSION:-${COMMITS}.${HASH}}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>JasnostCapture</string>
  <key>CFBundleIdentifier</key><string>dev.jasnost.capture</string>
  <key>CFBundleName</key><string>Jazz Capture</string>
  <key>CFBundleDisplayName</key><string>Jazz Capture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <!-- Allow the embedded WKWebView (#3) to load the local processor over http://127.0.0.1. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSMicrophoneUsageDescription</key>
  <string>Jazz records your spoken narration to align it with the actions you take.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Jazz transcribes your spoken answers during a BDM workshop so the consultant can ask the next question.</string>
</dict>
</plist>
PLIST

# Enrollment trust is public key material, but it must arrive out of band from the copied bundle
# and be covered by the app's code signature. The deployment-owned plist has exactly these fields:
# JazzEnrollmentIssuer (string), JazzEnrollmentAudience (string), and
# JazzEnrollmentEd25519PublicKeys (kid -> unpadded base64url 32-byte Ed25519 public key).
# Development builds may omit it and then signed enrollment deliberately fails closed.
TRUST_PLIST="${JAZZ_ENROLLMENT_TRUST_PLIST:-}"
if [ -n "$TRUST_PLIST" ]; then
    if [ ! -f "$TRUST_PLIST" ]; then
        echo "error: JAZZ_ENROLLMENT_TRUST_PLIST is not a readable file" >&2
        exit 2
    fi
    plutil -lint "$TRUST_PLIST" >/dev/null
    TRUST_ISSUER="$(plutil -extract JazzEnrollmentIssuer raw -expect string -o - "$TRUST_PLIST")"
    TRUST_AUDIENCE="$(plutil -extract JazzEnrollmentAudience raw -expect string -o - "$TRUST_PLIST")"
    TRUST_KEY_IDS="$(
        plutil -extract JazzEnrollmentEd25519PublicKeys raw \
            -expect dictionary -o - "$TRUST_PLIST"
    )"
    TRUST_KEYS_JSON="$(
        plutil -extract JazzEnrollmentEd25519PublicKeys json \
            -expect dictionary -o - "$TRUST_PLIST"
    )"
    if [ -z "$TRUST_ISSUER" ] || [ -z "$TRUST_AUDIENCE" ] || [ -z "$TRUST_KEY_IDS" ]; then
        echo "error: enrollment trust issuer, audience, and public-key set must be non-empty" >&2
        exit 2
    fi
    plutil -insert JazzEnrollmentIssuer -string "$TRUST_ISSUER" \
        "$APP/Contents/Info.plist"
    plutil -insert JazzEnrollmentAudience -string "$TRUST_AUDIENCE" \
        "$APP/Contents/Info.plist"
    plutil -insert JazzEnrollmentEd25519PublicKeys -json "$TRUST_KEYS_JSON" \
        "$APP/Contents/Info.plist"
    echo "[build] Stamped code-signed enrollment issuer, audience, and public-key set."
else
    echo "[build] No enrollment trust plist; signed bundle import will fail closed."
fi

# Pick a signing identity. A STABLE identity keeps TCC grants (Accessibility / Screen Recording)
# across rebuilds; ad-hoc ("-") changes the cdhash every build, so macOS forgets those grants and
# you must re-grant each time. Priority: $JASNOST_SIGN_IDENTITY → "Jazz Dev Code Signing"
# (created by ./dev-codesign-setup.sh) → ad-hoc fallback.
IDENTITY="${JASNOST_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null \
    | grep -q "Jazz Dev Code Signing"; then
    IDENTITY="Jazz Dev Code Signing"
fi

if [ -n "$IDENTITY" ]; then
    echo "[build] Signing with stable identity: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "[build] Signing ad-hoc (TCC grants will NOT survive rebuilds — run"
    echo "        ./dev-codesign-setup.sh once for a stable identity)."
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "[build] Built ./$APP  (version $SHORT_VERSION, build $BUILD_VERSION)"
echo "        Run it, then grant Accessibility + Screen Recording + Microphone in Settings → Permissions."
