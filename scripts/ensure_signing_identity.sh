#!/usr/bin/env bash
#
# Prints the name of a local code-signing identity on stdout, creating a self-signed one the
# first time. Prints nothing (and exits 0) if that is not possible, so callers can fall back to
# an ad-hoc signature.
#
# Why: macOS ties the Accessibility and Input Monitoring permissions to the app's code
# signature. An ad-hoc signature changes with every build, so a permission you switched on
# stops matching the rebuilt app ("I enabled it but it says I didn't"). Signing every build
# with the same certificate keeps the signature requirement the same, so permissions survive
# rebuilds. The certificate is created only on this Mac, lives in your login keychain, is not
# trusted for anything else, and cannot make the app pass Gatekeeper on other Macs.
#
# macOS may ask once whether "codesign" may use the new key: choose "Always Allow".
#
set -uo pipefail

NAME="Mac Action Recorder Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "$(uname -s)" != "Darwin" ]]; then
    exit 0
fi

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "$NAME"
    exit 0
fi

if [[ ! -f "$KEYCHAIN" ]]; then
    echo "note: login keychain not found; using an ad-hoc signature." >&2
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="mac-action-recorder-local"

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

echo "==> Creating a local code-signing certificate (one time) so permissions survive rebuilds" >&2
if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1 \
    && /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/identity.p12" -passout "pass:$PASS" >/dev/null 2>&1 \
    && security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null 2>&1; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
        echo "$NAME"
        exit 0
    fi
fi

echo "note: could not create a local signing certificate; using an ad-hoc signature." >&2
exit 0
