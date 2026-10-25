#!/bin/bash
#
# Used by the app's updater (and runnable by hand): downloads the newest source from GitHub,
# builds it, and leaves the finished app in a staging folder. It does NOT replace the installed
# app; the app does that when you choose "Restart to Update".
#
# Usage: update.sh <staging folder> <source zip url>
#
# Needs Xcode (the same requirement as building from source) and an internet connection.
#
set -euo pipefail

STAGE="${1:?staging folder required}"
URL="${2:?source zip url required}"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

case "$URL" in
    https://github.com/*) ;;
    *) echo "error: refusing to download from $URL" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STAGE"

echo "==> Checking for Xcode"
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "error: Xcode (or the Command Line Tools) is not set up on this Mac." >&2
    exit 1
fi
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
    echo "error: building needs the full Xcode app, not only the Command Line Tools." >&2
    exit 1
fi

echo "==> Downloading the newest version"
curl -fsSL --max-time 300 -o "$WORK/source.zip" "$URL"
ditto -x -k "$WORK/source.zip" "$WORK/source"
SRC="$(find "$WORK/source" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "$SRC" || ! -f "$SRC/Package.swift" || ! -f "$SRC/scripts/build_app.sh" ]]; then
    echo "error: the download does not look like the Mac Action Recorder source." >&2
    exit 1
fi

echo "==> Building (this takes a minute or two)"
cd "$SRC"
NATIVE_ONLY=1 bash ./scripts/build_app.sh

APP="$SRC/build/Mac Action Recorder.app"
if [[ ! -d "$APP" ]]; then
    echo "error: the build finished but produced no app." >&2
    exit 1
fi

echo "==> Staging the new app"
rm -rf "$STAGE/Mac Action Recorder.app"
ditto "$APP" "$STAGE/Mac Action Recorder.app"
echo "==> Done"
