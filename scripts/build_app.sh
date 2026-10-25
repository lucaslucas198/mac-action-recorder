#!/usr/bin/env bash
#
# Builds "Mac Action Recorder.app" from the Swift package (no Xcode project needed).
#
# Usage:   ./scripts/build_app.sh
# Options (environment variables):
#   VERSION            Marketing version written to Info.plist (default 0.1.0)
#   BUILD_NUMBER       Build number written to Info.plist (default 1)
#   CODESIGN_IDENTITY  Signing identity. Default "-" = ad-hoc signature (no developer
#                      account required). See README for notarization notes.
#   NATIVE_ONLY=1      Skip the universal (arm64 + x86_64) build attempt.
#
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP_DIR="build/Mac Action Recorder.app"
ZIP_PATH="build/MacActionRecorder-${VERSION}-macOS.zip"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this script must be run on macOS." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found. Install Xcode or the Command Line Tools: xcode-select --install" >&2
    exit 1
fi

echo "==> Swift toolchain:"
swift --version

BIN_PATH=""
if [[ "${NATIVE_ONLY:-0}" != "1" ]]; then
    echo "==> Building universal binary (arm64 + x86_64)..."
    if swift build -c release --arch arm64 --arch x86_64; then
        BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
    else
        echo "warning: universal build failed; falling back to a native-architecture build." >&2
    fi
fi

if [[ -z "$BIN_PATH" ]]; then
    echo "==> Building for the native architecture..."
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)"
fi

EXECUTABLE="$BIN_PATH/MacActionRecorder"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: built executable not found at: $EXECUTABLE" >&2
    exit 1
fi

echo "==> Assembling app bundle: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/MacActionRecorder"
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__BUILD__/${BUILD_NUMBER}/g" \
    Resources/Info.plist > "$APP_DIR/Contents/Info.plist"

echo "==> Signing (identity: ${IDENTITY})..."
codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" || true

echo "==> Creating zip: $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo
echo "Done."
echo "  App: $APP_DIR"
echo "  Zip: $ZIP_PATH"
echo
echo "Next: open the app, then grant Accessibility and Input Monitoring"
echo "(System Settings > Privacy & Security). See README.md > Permissions."
