# Changelog

## Unreleased

## 0.6.0

Mac app (Windows unchanged). Focus: installing, one copy of the app, permissions, and a smoother first run.

**One copy of the app**

- Only one copy runs at a time. If you open a second one, the newer version (or, for the same version, the one in Applications) stays and the other quits.
- **Quit and Reopen** now waits until the app has really quit and then opens the copy in Applications. Before, it could start a second copy, or an old copy from a disk image that was still open.
- Old Mac Action Recorder disk images that are still open are ejected, and other copies of the app (for example in Downloads) are moved to the **Trash**, not deleted. This runs during setup and quietly at each launch, and a note says what was done.

**Installing**

- The welcome screen now fills the window. **Get Started** slides over to the setup page and starts installing by itself.
- The setup page shows every step with a moving progress bar and percentage, the step's explanation, the latest line from the signing tool, seconds spent, and a checklist with the time each finished step took. If signing waits on a macOS prompt, it says so; after 30 s you can **Continue Without Signing**.
- Opening a newly downloaded copy (dragged into Applications, or straight from the disk image) finishes its own setup: it is signed with the same certificate as before, so the permissions you already switched on keep working, and the setup page closes by itself when nothing is left to do.
- Setup never repeats itself in a loop: if replacing the app fails, it stops and says what to do.
- New disk image instructions: 1. drag onto Applications, 2. open it from there.

**Permissions**

- When the app's signature changed and the permissions stopped working, the old entries are removed from the Input Monitoring and Accessibility lists automatically (they looked switched on but did nothing, and blocked adding the app again). The first launch of 0.6.0 does this once if the permissions are not working.
- The permission step has numbered instructions, an **Open … Settings** button for each list, live checkmarks, **Check Again**, **Quit and Reopen** and **Repair…**. The orange bar in the main window has **Fix Permissions…**.

**On-device AI**

- The model is loaded ahead of time when the Check sheet opens, answers use a low temperature so the strict reply formats are followed more often, one request runs at a time, prompts are kept short, and a request that takes longer than 60 seconds is stopped with a clear message instead of spinning forever.

**Layout**

- Playback controls no longer clip at the smallest window size (repeat count and wait now have their own row).
- CI now draws every main screen to images on each push (`ci-screenshots-mac` branch), which is how these layout problems were found.

**Verification**

- CI runs the real install machinery on a macOS 26 runner on every push and fails if any check fails (see README > Verification status for exactly what is and is not covered).

## 0.5.0

Mac app (the Windows app is unchanged in this version). CI compiles the app and runs the core unit tests; none of the new behavior has been run on a real Mac yet, see README > Verification status.

**More accurate playback (it cannot be 100%, see README > Accuracy)**

- Clicks, drags and scrolls now remember the Shift, Option, Control and Command keys held during them (for example Shift-click) and replay them.
- Recording uses the time macOS stamps on each input event, so gaps do not depend on how busy the app was. Switch it off in Settings > Recording > Accuracy.
- Clicks and key presses use configurable timing (pause before a click, button held down, double-click gap, key held down) in Settings > Playback.
- New recordings save the target app's window position. If the window has only moved since, every click is shifted by the same amount ("follow the window"). If its size changed, nothing is guessed and the run stops.
- Playback brings the macro's app to the front first, and opens it if it is closed.
- Optionally puts the mouse pointer back where it was after a run.
- New pause/resume shortcut (default `⌃⌥⌘P`) next to the emergency stop.

**Automatic stop (Settings > Safety)**

- Before each click or key press, playback checks facts macOS can report: the app is still running, its window is still the recorded size, the display size is unchanged, and (optional) nobody else moved the mouse. It stops only when one of these is certain and says why. Values it cannot read never cause a stop.
- The AI is not used to decide. It cannot see the screen. In Check, it can explain a stop in plain words.
- "Only play while the recorded app is in front" is now on by default for new settings. Existing settings files keep their saved value.

**Add actions by hand**

- New **Add** menu: click, double-click, right-click, move, scroll, key press, type text, wait, Discord preset. Mouse actions have **Pick on screen**: click anywhere to fill in the position. Clicks can include held modifier keys.

**Discord**

- Each macro can name a Discord channel to open first (Quick Switcher, `⌘K`) and the app brings Discord to the front before it starts. The steps run in the first repetition only.
- Settings > Discord: favorite channels, messages you send often, shortest gap between messages, notes about how you use Discord, your own rules.
- Check > Discord coach: one-click "open this channel first" and "type and send this message", plus optional personal tips from the on-device AI. Settings > AI shows exactly what the AI is told about you and lets you switch it off.
- New checks: messages closer together than your gap, `@everyone` / `@here`, and a Discord macro that sends text with no channel chosen.

**Cleaner layout**

- Check, Show Clicks and Add have text labels and sit in their own row. The edit tools are on a second row and fall back to icons when narrow, so nothing is clipped or overlaps.
- Compact info and playback card; target app, channel and window reference are in a collapsible section; the control bar drops hints before it would overlap. Larger default and minimum window size.
- Settings has General, Recording, Playback, Safety, Discord, AI, Storage, Privacy and Updates tabs, with many more options (appearance, row density, new-macro name, confirm before delete, sounds, mouse-path presets, timing sliders).

**File format**

- Recordings may now contain `targetWindow`, `startChannel`, and `modifiers` on mouse actions. All are optional; older files open unchanged and `formatVersion` stays 1. Older app versions ignore the new fields.

## 0.4.0

- **Windows version** (new, in `windows/`): a native WPF app for Windows 10 1809+ and Windows 11 (64-bit) with the same features as the Mac app: recording, playback and speed/repeat/loop/countdown, pause/resume/restart/emergency stop, the action editor with undo and redo, the Check panel, the optional local AI helper (Ollama on this PC only), Show Clicks, Discord keyboard presets, settings, import/export and backups, and update checks against GitHub Releases (checksum verified before the installer runs).
- Releases now also contain `ActionRecorder-Windows-Setup.exe` and `ActionRecorder-Windows-Portable.zip`, and one `SHA256SUMS.txt` covers the Mac and Windows files. The Windows installer is not code-signed, so SmartScreen warns; the release notes say how to continue.
- Mac recordings can be opened on Windows (Command is converted to Ctrl); Windows recordings carry `"platform":"windows"`.
- CI builds, tests, starts and screenshots the Windows app on a Windows runner and runs a real input record/replay self-test.
- The Mac app itself is unchanged in this version.

## 0.3.2

- Welcome flow is now two pages: a home page with the big logo and a **Get Started** button, then the setup page ending in **Enter**. After "Set Up This Mac" reopens the app it starts on the setup page.
- "Set Up This Mac" shows a progress bar with three stages (copying, signing, installing) and what each one is doing.
- Disk image window shows a red box saying what macOS will say the first time and how to get past it. The README and release notes have the same warning.
- Release workflow publishes `SHA256SUMS.txt` and, if the owner adds a `VT_API_KEY` secret, adds VirusTotal's reported result to the release notes (it never claims a clean result by itself). README has an "Is it safe?" section.
- Faster launch: the automatic backup of recordings now runs a few seconds later on a background thread, and the Welcome screen no longer re-reads the app signature on every redraw.

## 0.3.1

- Disk image now opens with a styled window: app on the left, Applications on the right, an arrow, and the first-run "Open Anyway" hint. Built with dmgbuild; CI fails if the styled image cannot be made. (Not yet seen on a real Mac.)
- Release notes and README say plainly to download the `.dmg`, not "Source code (zip)".

## 0.3.0

Added (CI compiles and unit-tests the core on macOS 14; see README > Verification status for what is and is not verified):

- Downloadable disk image (`MacActionRecorder-macOS.dmg`) on GitHub Releases: drag the app onto Applications. No Xcode needed.
- Welcome screen on first launch with live permission status and an **Enter** button; reopen from Help > Welcome & Setup or the menu bar item. "Set Up This Mac" moves the app to Applications and signs it with a local certificate so permissions survive updates.
- Updater now downloads the finished app from GitHub Releases (`MacActionRecorder-macOS.zip`) instead of building from source. Update checks start only after the Welcome screen has been closed.
- `scripts/make_dmg.sh`, `scripts/prepare_app.sh`; release workflow builds on a macOS 26 runner so the on-device AI features are included.

- 0.2.1: Permission diagnostics report in Settings > Permissions & Privacy (shows whether the signature is stable, which copy is running, and what macOS reports).

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
