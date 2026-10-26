#!/bin/bash
#
# Prepares a downloaded "Mac Action Recorder.app" for use on THIS Mac:
#   1. removes the download ("quarantine") flag, and
#   2. signs the app with a certificate that exists only on this Mac, so the macOS privacy
#      permissions you grant (Accessibility, Input Monitoring) keep matching after updates.
#
# The prebuilt app from GitHub is signed ad hoc, and an ad-hoc signature changes with every
# build, which makes macOS forget permissions. Signing locally with one fixed certificate
# avoids that. This does NOT make the app notarized and does not affect other Macs.
#
# Usage: prepare_app.sh <path to Mac Action Recorder.app>
# Exit:  0 = signed with the local certificate
#        2 = the certificate could not be created or used; the app is left as it was
#            (apart from the quarantine flag) and still works, but permissions may need to be
#            switched on again after each update
#        1 = bad usage / not an app
#
set -uo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

APP="${1:-}"
if [[ -z "$APP" || ! -f "$APP/Contents/Info.plist" ]]; then
    echo "error: not an app bundle: ${APP:-<none>}" >&2
    exit 1
fi
HERE="$(cd "$(dirname "$0")" && pwd)"

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

IDENTITY=""
if [[ -f "$HERE/ensure_signing_identity.sh" ]]; then
    IDENTITY="$(bash "$HERE/ensure_signing_identity.sh" 2>&1 | tail -n 1)"
fi
case "$IDENTITY" in
    "Mac Action Recorder Local Signing") ;;
    *)
        echo "note: no local signing certificate is available." >&2
        exit 2
        ;;
esac

if codesign --force --deep --sign "$IDENTITY" "$APP"; then
    echo "Signed with: $IDENTITY"
    exit 0
fi
echo "note: signing with the local certificate failed." >&2
exit 2
