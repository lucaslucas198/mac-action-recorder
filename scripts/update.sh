#!/bin/bash
#
# Used by the app's updater: downloads the newest finished app from GitHub Releases, checks it,
# prepares it for this Mac (see prepare_app.sh), and leaves it in a staging folder. It does NOT
# replace the installed app; the app does that when you choose "Restart to Update".
#
# Needs only an internet connection. No Xcode, no building.
#
# Usage: update.sh <staging folder> <release zip url>
#
set -euo pipefail

STAGE="${1:?staging folder required}"
URL="${2:?release zip url required}"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Only this project's own release downloads are accepted.
case "$URL" in
    https://github.com/lucaslucas198/mac-action-recorder/releases/download/*) ;;
    *) echo "error: refusing to download from $URL" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STAGE"

echo "==> Downloading the newest version"
curl -fsSL --max-time 600 -o "$WORK/app.zip" "$URL"
ditto -x -k "$WORK/app.zip" "$WORK/unzipped"

APP="$WORK/unzipped/Mac Action Recorder.app"
PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
    echo "error: the download does not contain Mac Action Recorder.app." >&2
    exit 1
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
if [[ "$BUNDLE_ID" != "io.github.macactionrecorder.app" ]]; then
    echo "error: the download is not Mac Action Recorder (bundle id: ${BUNDLE_ID:-none})." >&2
    exit 1
fi
if ! codesign --verify --deep "$APP" 2>/dev/null; then
    echo "error: the downloaded app's signature is damaged." >&2
    exit 1
fi

echo "==> Preparing it for this Mac"
# The staged copy keeps working if the local certificate is unavailable (exit status 2).
bash "$HERE/prepare_app.sh" "$APP" || echo "note: continuing without the local signature."

echo "==> Staging the new app"
rm -rf "$STAGE/Mac Action Recorder.app"
ditto "$APP" "$STAGE/Mac Action Recorder.app"
echo "==> Done"
