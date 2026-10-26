#!/usr/bin/env bash
#
# Makes the disk image people download: open it, drag "Mac Action Recorder" onto "Applications".
#
# Usage: ./scripts/make_dmg.sh [app path] [output .dmg path]
# Defaults: build/Mac Action Recorder.app -> build/MacActionRecorder-macOS.dmg
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/Mac Action Recorder.app}"
OUT="${2:-build/MacActionRecorder-macOS.dmg}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this script must be run on macOS." >&2
    exit 1
fi
if [[ ! -f "$APP/Contents/Info.plist" ]]; then
    echo "error: app not found: $APP (run ./scripts/build_app.sh first)" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Mac Action Recorder.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.txt "$STAGE/READ ME FIRST.txt"

mkdir -p "$(dirname "$OUT")"
# hdiutil occasionally fails with "Resource busy" on a busy machine, so try a few times.
for attempt in 1 2 3; do
    rm -f "$OUT"
    if hdiutil create -volname "Mac Action Recorder" -srcfolder "$STAGE" -ov -format UDZO "$OUT"; then
        break
    fi
    if [[ "$attempt" == 3 ]]; then
        echo "error: could not create the disk image." >&2
        exit 1
    fi
    echo "warning: hdiutil failed (attempt $attempt); retrying..." >&2
    sleep 3
done
hdiutil verify "$OUT" >/dev/null
echo "Disk image: $OUT"
