#!/usr/bin/env bash
#
# Release build for "Jazz Capture.app" — everything AROUND the (manual) notarization:
#
#   1. builds the Release app bundle via ./build-app.sh, stamping the release version into
#      CFBundleShortVersionString + CFBundleVersion (from --version or the latest git tag);
#   2. codesigns with a Developer ID identity when $JAZZ_SIGNING_IDENTITY is set (hardened
#      runtime + secure timestamp — both notarization requirements); otherwise keeps the
#      dev/ad-hoc signature build-app.sh applied and warns LOUDLY that the artifact is
#      NOT distributable;
#   3. zips the bundle with `ditto -c -k --keepParent` (the format notarytool expects);
#   4. prints the exact manual `xcrun notarytool submit` / `xcrun stapler staple` commands.
#
# Safe to run with no credentials at all: you still get the dev-signed zip + instructions.
#
# Usage:
#   ./build-release.sh [--version vX.Y.Z]
#   JAZZ_ENROLLMENT_TRUST_PLIST=/secure-build-config/jazz-enrollment-trust.plist \
#     JAZZ_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     ./build-release.sh --version v0.24.0
set -euo pipefail
cd "$(dirname "$0")"

APP="Jazz Capture.app"

usage() {
    echo "Usage: [JAZZ_SIGNING_IDENTITY=\"Developer ID Application: ...\"] $0 [--version vX.Y.Z]"
    echo "Without --version, the version is derived from the latest 'v*' git tag."
}

# --- resolve the version -----------------------------------------------------------------
VERSION_TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || { echo "error: --version needs a value (vX.Y.Z)" >&2; usage >&2; exit 2; }
            VERSION_TAG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$VERSION_TAG" ]; then
    # Releases are cut as vX.Y.Z git tags in this repository — the latest one is the default.
    VERSION_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    if [ -z "$VERSION_TAG" ]; then
        echo "error: no 'v*' git tag found — pass --version vX.Y.Z explicitly" >&2
        exit 2
    fi
    echo "[release] No --version given — using the latest git tag: $VERSION_TAG"
fi

# Accept "vX.Y.Z" or "X.Y.Z"; VERSION (no v) goes into the Info.plist, VERSION_TAG names the zip.
VERSION="${VERSION_TAG#v}"
VERSION_TAG="v$VERSION"
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
    echo "error: '$VERSION_TAG' does not look like a release version (expected vX.Y.Z)" >&2
    exit 2
fi

if [ -n "${JAZZ_SIGNING_IDENTITY:-}" ] && [ -z "${JAZZ_ENROLLMENT_TRUST_PLIST:-}" ]; then
    echo "error: a distributable build requires JAZZ_ENROLLMENT_TRUST_PLIST" >&2
    echo "       (issuer, audience, and the rotation-safe Ed25519 public-key set)." >&2
    exit 2
fi

# --- build the bundle (reuses build-app.sh: compile, Info.plist, dev signing) ------------
# Both plist fields get the release version: CFBundleShortVersionString is what users (and
# the in-app update check) see; CFBundleVersion must be monotonic per short version — for a
# tagged release the tag itself is the cleanest monotonic stamp.
echo "[release] Building $APP at version $VERSION"
JAZZ_VERSION="$VERSION" JAZZ_BUILD_VERSION="$VERSION" ./build-app.sh

# --- sign ---------------------------------------------------------------------------------
DISTRIBUTABLE=0
if [ -n "${JAZZ_SIGNING_IDENTITY:-}" ]; then
    echo "[release] Codesigning with: $JAZZ_SIGNING_IDENTITY"
    # Hardened runtime (--options runtime) + secure timestamp are notarization requirements.
    # --force replaces the dev signature build-app.sh applied. The bundle carries a single
    # executable and no nested code, so signing the .app directly covers everything
    # (Apple discourages --deep for distribution signing).
    codesign --force --options runtime --timestamp \
        --sign "$JAZZ_SIGNING_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    DISTRIBUTABLE=1
else
    cat >&2 <<'WARN'
[release] *********************************************************************
[release] *  WARNING: JAZZ_SIGNING_IDENTITY is not set.                       *
[release] *                                                                   *
[release] *  The bundle keeps its dev/ad-hoc signature. This artifact is      *
[release] *  NOT DISTRIBUTABLE: Gatekeeper blocks it on other machines,       *
[release] *  notarization would reject it, and macOS ties TCC grants          *
[release] *  (Accessibility / Screen Recording) to the code identity — so     *
[release] *  every user would re-grant after every update.                    *
[release] *                                                                   *
[release] *  For a distributable build, set JAZZ_SIGNING_IDENTITY to the      *
[release] *  exact name of your "Developer ID Application: ..." certificate   *
[release] *  (see: security find-identity -v -p codesigning) and re-run.      *
[release] *********************************************************************
WARN
fi

# --- zip (the artifact notarytool submits, and the one attached to the GitHub release) ----
ZIP="Jazz-Capture-${VERSION_TAG}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "[release] Wrote ./$ZIP"

# --- manual next steps ---------------------------------------------------------------------
echo
echo "[release] Next steps (manual — needs the Apple Developer account):"
if [ "$DISTRIBUTABLE" -eq 0 ]; then
    echo "  0. This zip is dev-signed — notarization WILL reject it. Re-run with"
    echo "     JAZZ_SIGNING_IDENTITY set (see the warning above) before submitting."
fi
cat <<EOF
  1. One-time: store notary credentials in the keychain (prompts for the
     app-specific password — never put it on the command line):
       xcrun notarytool store-credentials jazz-notary \\
         --apple-id <your-apple-id> --team-id <TEAMID>
  2. Submit and wait for the verdict (~1-5 min):
       xcrun notarytool submit "$ZIP" --keychain-profile jazz-notary --wait
     (on 'Invalid', inspect: xcrun notarytool log <submission-id> --keychain-profile jazz-notary)
  3. Staple the ticket to the app so it verifies offline:
       xcrun stapler staple "$APP"
  4. Re-zip the STAPLED bundle — the zip submitted in step 2 does NOT contain the ticket:
       ditto -c -k --keepParent "$APP" "$ZIP"
  5. Attach it to the GitHub release:
       gh release upload $VERSION_TAG "$ZIP"
EOF
