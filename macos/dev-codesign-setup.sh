#!/usr/bin/env bash
#
# One-time: create a STABLE self-signed code-signing identity in your login keychain so the
# app's code identity (and therefore its macOS TCC grants for Accessibility / Screen Recording)
# survive rebuilds. With the default ad-hoc signature (`codesign --sign -`), every rebuild gets
# a new cdhash and macOS forgets the Accessibility / Screen Recording grants — you'd have to
# re-grant after each build. A stable self-signed cert fixes that: grant once, rebuild freely.
#
# Run this ONCE. It may prompt for your login keychain password (to trust the cert for code
# signing). After it succeeds, `./build-app.sh` auto-detects and uses the identity.
set -euo pipefail

CERT_NAME="Jazz Dev Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "[ok] Code-signing identity '$CERT_NAME' already exists. Nothing to do."
    echo "     build-app.sh will use it automatically."
    exit 0
fi

echo "[setup] Creating self-signed code-signing identity '$CERT_NAME'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Self-signed cert with the codeSigning extended key usage (required for a code-signing identity).
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -subj "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

# OpenSSL 3.x defaults to PBES2/AES + a SHA-256 MAC for PKCS#12, which macOS `security import`
# cannot read ("MAC verification failed"). -legacy emits the old RC2/3DES encryption and -macalg
# sha1 the old MAC that the macOS keychain understands. A non-empty passphrase is also more
# reliable than an empty one for `security import`. (All harmless on OpenSSL 1.x.)
P12_PASS="jasnost-dev"
openssl pkcs12 -export -legacy -macalg sha1 -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -name "$CERT_NAME" -passout "pass:$P12_PASS"

# Import the cert + private key into the login keychain and let /usr/bin/codesign use the key.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -A

# Trust it for code signing (login/user domain). May prompt for your login keychain password.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "[ok] Created '$CERT_NAME'. Now run ./build-app.sh — it will sign with this identity,"
    echo "     so your Accessibility / Screen Recording grants persist across rebuilds."
else
    echo "[warn] Identity not listed under code-signing yet. Open Keychain Access → 'login' →"
    echo "       find '$CERT_NAME' → Get Info → Trust → Code Signing: Always Trust, then rerun."
fi
