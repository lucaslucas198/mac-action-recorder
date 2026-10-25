# Changelog

## Unreleased

Added (not yet compiled or run):

- Auto-update from the GitHub repository: version check, background build, one-click Restart to Update. Settings > Updates, menu bar item "Check for Updates…". `VERSION` file is now the source of the app version.

Fixed (not yet compiled or run):

- Permissions appearing "not granted" after being switched on: builds now use a stable local signing certificate (falls back to ad-hoc), the Input Monitoring check tests a real event tap when the system's quick check says no, and the permission banner has Quit and Reopen.

Added (written but **not yet compiled or run**; see README > Verification status):

- Improve this macro: rule-based cleanup plus strictly parsed AI suggestions, with preview and undo.
- Draft steps with AI: plain-English request to keyboard-only steps, reviewed before adding.
- Show Clicks: on-screen numbered markers at each click position.
- Play Macro submenu in the menu bar.
- Permission rescue buttons (show app in Finder, copy path, reset this app's entries, quit and reopen).
- `Install.command`: double-click installer for people who download the GitHub zip.

## 0.1.0

- Recording, playback, speed presets and custom speed, repeat/loop, editor, saved macros with import/export, settings window, menu bar item, emergency stop.
- Check macro (rules with one-click fixes) and optional on-device AI review.
- App icon.
- Verified on macOS 27.2: builds with Xcode; 155 core unit tests pass. Recording and playback not yet tried in real apps.
