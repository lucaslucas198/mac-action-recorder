#!/usr/bin/env bash
#
# One-shot bootstrap for a fresh Mac: checks prerequisites, runs the tests,
# builds the app, and prints the permission steps.
#
# Usage:  ./init/setup.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: Mac Action Recorder only builds and runs on macOS." >&2
    exit 1
fi

echo "==> Checking macOS version"
sw_vers

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MAJOR < 13 )); then
    echo "error: macOS 13 (Ventura) or newer is required." >&2
    exit 1
fi

echo "==> Checking for Swift / developer tools"
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift not found. Installing the Command Line Tools (a dialog will appear)..."
    xcode-select --install || true
    echo "Re-run ./init/setup.sh once the installation has finished."
    exit 1
fi
swift --version

echo "==> Running unit tests"
swift test

echo "==> Building the app"
./scripts/build_app.sh

cat <<'EOF'

Setup complete.

To start the app:
    open "build/Mac Action Recorder.app"

Then grant the two permissions the first time you use it
(System Settings > Privacy & Security):
    1. Accessibility      - required to play back clicks and typing
    2. Input Monitoring   - required to record clicks and typing

Rebuilding changes the app's ad-hoc signature, which macOS can treat as a new app.
If recording/playback stops working after a rebuild, remove the app from both lists
and add it again. See README.md > Troubleshooting.
EOF
