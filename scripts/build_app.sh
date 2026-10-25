#!/usr/bin/env bash
#
# Builds "Mac Action Recorder.app" from the Swift package (no Xcode project needed).
#
# Usage:   ./scripts/build_app.sh
# Options (environment variables):
#   VERSION            Marketing version written to Info.plist (default 0.1.0)
#   BUILD_NUMBER       Build number written to Info.plist (default 1)
#   CODESIGN_IDENTITY  Signing identity. If unset, a local self-signed certificate is created
#                      on first use (see scripts/ensure_signing_identity.sh) so macOS privacy
#                      permissions survive rebuilds; if that is not possible, or on CI, an
#                      ad-hoc signature ("-") is used. See README for notarization notes.
#   STABLE_SIGNING=0   Skip the local certificate and always sign ad-hoc.
#   NATIVE_ONLY=1      Skip the universal (arm64 + x86_64) build attempt.
#
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IDENTITY="${CODESIGN_IDENTITY:-}"
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
    BUILD_LOG="$(mktemp)"
    if ! swift build -c release 2>&1 | tee "$BUILD_LOG"; then
        if grep -q "SwiftUIMacros" "$BUILD_LOG"; then
            cat >&2 <<'HINT'

error: the build failed because the SwiftUI macro plugin ("SwiftUIMacros") is missing.
       This happens when only the Command Line Tools are installed. SwiftUI apps
       need the full Xcode app on current macOS versions. To fix:
         1. Install Xcode from the Mac App Store and open it once to finish setup.
         2. sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
         3. Re-run ./scripts/build_app.sh
HINT
        fi
        rm -f "$BUILD_LOG"
        exit 1
    fi
    rm -f "$BUILD_LOG"
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

if [[ -d Resources/AppIcon.iconset ]]; then
    echo "==> Building the app icon"
    if ! iconutil -c icns Resources/AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"; then
        echo "warning: could not build the app icon; continuing without it." >&2
    fi
fi

if [[ -z "$IDENTITY" && -z "${CI:-}" && "${STABLE_SIGNING:-1}" != "0" ]]; then
    IDENTITY="$(./scripts/ensure_signing_identity.sh || true)"
fi
IDENTITY="${IDENTITY:--}"

echo "==> Signing (identity: ${IDENTITY})..."
if ! codesign --force --deep --sign "$IDENTITY" "$APP_DIR"; then
    if [[ "$IDENTITY" == "-" ]]; then
        echo "error: code signing failed." >&2
        exit 1
    fi
    echo "warning: signing with '${IDENTITY}' failed; falling back to an ad-hoc signature." >&2
    echo "         (Permissions will then not survive rebuilds.)" >&2
    codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --verbose=2 "$APP_DIR" || true
echo "    Signature requirement macOS will match permissions against:"
codesign -dr - "$APP_DIR" 2>&1 | sed 's/^/      /' || true

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
