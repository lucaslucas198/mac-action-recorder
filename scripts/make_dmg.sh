#!/usr/bin/env bash
#
# Makes the disk image people download. Opening it shows a window with the app on the left, the
# Applications folder on the right and an arrow between them: drag the app onto Applications.
#
# Usage: ./scripts/make_dmg.sh [app path] [output .dmg path]
# Defaults: build/Mac Action Recorder.app -> build/MacActionRecorder-macOS.dmg
#
# The styled window is made with dmgbuild (a Python tool installed into a temporary virtual
# environment; needs internet and python3). If that is not possible a plain disk image with the
# same two items is made instead, unless REQUIRE_STYLED=1 is set, which turns that into an error.
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/Mac Action Recorder.app}"
OUT="${2:-build/MacActionRecorder-macOS.dmg}"
VOLNAME="Mac Action Recorder"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this script must be run on macOS." >&2
    exit 1
fi
if [[ ! -f "$APP/Contents/Info.plist" ]]; then
    echo "error: app not found: $APP (run ./scripts/build_app.sh first)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true' EXIT
mkdir -p "$(dirname "$OUT")"

styled() {
    # Retina-ready background: both sizes in one TIFF.
    tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png \
        -out "$WORK/background.tiff" >/dev/null 2>&1 || return 1
    python3 -m venv "$WORK/venv" || return 1
    "$WORK/venv/bin/pip" install --quiet dmgbuild || return 1
    rm -f "$OUT"
    "$WORK/venv/bin/dmgbuild" -s scripts/dmg/settings.py \
        -D app="$APP" -D background="$WORK/background.tiff" \
        "$VOLNAME" "$OUT" || return 1
}

plain() {
    local stage="$WORK/plain"
    mkdir -p "$stage"
    ditto "$APP" "$stage/Mac Action Recorder.app"
    ln -s /Applications "$stage/Applications"
    # hdiutil occasionally fails with "Resource busy" on a busy machine, so try a few times.
    for attempt in 1 2 3; do
        rm -f "$OUT"
        if hdiutil create -volname "$VOLNAME" -srcfolder "$stage" -ov -format UDZO "$OUT"; then
            return 0
        fi
        echo "warning: hdiutil failed (attempt $attempt); retrying..." >&2
        sleep 3
    done
    return 1
}

if styled; then
    echo "Styled disk image created."
elif [[ "${REQUIRE_STYLED:-0}" == "1" ]]; then
    echo "error: could not make the styled disk image (REQUIRE_STYLED=1)." >&2
    exit 1
else
    echo "warning: could not make the styled disk image; making a plain one." >&2
    plain || { echo "error: could not create the disk image." >&2; exit 1; }
fi

hdiutil verify "$OUT" >/dev/null
echo "Disk image: $OUT"
