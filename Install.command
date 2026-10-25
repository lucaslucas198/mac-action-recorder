#!/bin/bash
#
# Double-click this file in Finder to build and install Mac Action Recorder.
# (First time only: right-click it > Open, then click Open, because macOS blocks
# scripts downloaded from the internet on a plain double-click.)
#
# What it does:
#   1. Checks that full Xcode is installed (needed to build SwiftUI apps).
#   2. Builds the app from the source in this folder.
#   3. Copies it to /Applications and opens it.
#
cd "$(dirname "$0")" || exit 1

pause_and_exit() {
    echo
    read -n 1 -s -r -p "Press any key to close this window."
    echo
    exit "${1:-0}"
}

clear
echo "Mac Action Recorder - installer"
echo "================================"
echo

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This only works on a Mac."
    pause_and_exit 1
fi

# macOS marks everything inside a downloaded zip as "from the internet". Clearing that mark
# on this folder avoids extra warnings for the scripts and the app we are about to build.
xattr -dr com.apple.quarantine . 2>/dev/null || true

# --- Xcode ---------------------------------------------------------------------------------
XCODE_APP="/Applications/Xcode.app"
if [[ ! -d "$XCODE_APP" ]]; then
    echo "Xcode is not installed."
    echo
    echo "Xcode is free. It is a large download (several GB), so start it now:"
    echo "  1. Install Xcode from the App Store page that is about to open."
    echo "  2. Open Xcode once and let it finish installing extra components."
    echo "  3. Double-click Install.command again."
    open "https://apps.apple.com/app/xcode/id497799835" 2>/dev/null || true
    pause_and_exit 1
fi

if [[ "$(xcode-select -p 2>/dev/null)" != "$XCODE_APP"* ]]; then
    echo "Pointing the command line tools at Xcode (your Mac password may be needed)..."
    sudo xcode-select -s "$XCODE_APP/Contents/Developer" || pause_and_exit 1
fi

# Xcode refuses to build until its license is accepted.
if xcodebuild -version 2>&1 | grep -qi "license"; then
    echo "Xcode's license has not been accepted yet (your Mac password may be needed)..."
    sudo xcodebuild -license accept || pause_and_exit 1
fi
xcodebuild -runFirstLaunch >/dev/null 2>&1 || true

# --- Build ---------------------------------------------------------------------------------
echo "Building the app. This takes a minute or two the first time..."
echo
if ! ./scripts/build_app.sh; then
    echo
    echo "The build failed. Scroll up for the first line that starts with 'error:'."
    echo "Copy it and send it to whoever maintains this project."
    pause_and_exit 1
fi

# --- Install -------------------------------------------------------------------------------
APP_NAME="Mac Action Recorder.app"
SRC="build/$APP_NAME"
DEST="/Applications/$APP_NAME"

if [[ ! -d "$SRC" ]]; then
    echo "The build finished but $SRC was not found."
    pause_and_exit 1
fi

# Quit a running copy before replacing it.
osascript -e 'tell application "Mac Action Recorder" to quit' >/dev/null 2>&1 || true
sleep 1

echo
echo "Copying to /Applications..."
rm -rf "$DEST" 2>/dev/null || sudo rm -rf "$DEST"
ditto "$SRC" "$DEST" 2>/dev/null || sudo ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
echo "Installed: $DEST"
echo
echo "Next, in the app: Settings > Permissions & Privacy, and switch on both"
echo "Input Monitoring and Accessibility. If a permission was granted to an older"
echo "copy, use 'Reset This App's Permissions' there and grant it again."
echo
open "$DEST"
pause_and_exit 0
