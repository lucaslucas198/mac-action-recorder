# Mac Action Recorder

A small native macOS app that records your mouse and keyboard, then plays the recording back at a speed you choose. It is built for repetitive Discord desktop tasks (open a channel, click the message box, type a message, press Return, repeat), but it works with any app.

> **Status: first version.** The version before the "Improve", "Draft" and "Show Clicks" additions built and passed 155 unit tests on macOS 27.2 with Xcode (Swift 6.4, Apple Silicon); the newest additions have not been built yet (see the table below). Recording and playback in real apps, including Discord, have **not been tested yet**. See [Verification status](#verification-status).

## What it does

- **Record** left/right/double clicks, mouse movement, scrolling, key presses, shortcuts and typed text, with their timing.
- **Play back** with Play, Pause, Resume, Stop, Restart, replay of a selected section, a progress bar, the current action highlighted, and an emergency-stop shortcut (default `⌃⌥⌘S`).
- **Speed**: 0.25× (very slow), 0.5× (slow), 1× (original timing), 1.5×, 2×, 5× (very fast), or any custom value from 0.05× to 20×. Clicks, key presses and typing keep a configurable minimum delay at high speeds so they stay reliable.
- **Repeat**: once, N times, or loop until stopped, with a delay between repetitions and a countdown before playback. Starting an endless loop always asks for confirmation.
- **Edit** a recording: rename, delete, duplicate, reorder (drag or buttons), insert a delay, change delays, change click coordinates, edit typed text and key presses.
- **Save**: macros are stored as versioned JSON, with autosave, rename, duplicate, import, export and automatic backups.
- **Settings window**: recording options, playback defaults, storage, permissions and privacy.
- **Menu bar item** that shows `REC 0:12` while recording and has Stop / Emergency Stop, so you can always stop even when the window is hidden.
- **Check macro** (the **Check** button above the action list): fixed rules that flag common causes of unreliable or risky macros, each with a one-click fix where one exists. Examples: no foreground check, hundreds of mouse-move actions, long idle pauses, a changed display size, typed text that looks like a password, and a loop that could send messages very quickly.
- **Improve this macro** (inside Check): proposes shortening and fixing steps (remove mouse paths, join split typing, wait before typing that follows a click, shorten long pauses). You tick what to apply, and can undo.
- **AI features** (optional, on-device, need macOS 26+ with Apple Intelligence): AI suggestions for the Improve list, **Draft steps with AI** (describe what you want in words; get keyboard steps to review), a plain-language review, and name suggestions. See [Check macro and AI review](#check-macro-and-ai-review).
- **Show Clicks**: draws numbered markers on screen where a macro will click, so a moved window is easy to spot before you play.
- **Play Macro** submenu in the menu bar for starting a saved macro without opening the window.
- **Discord presets** (optional): keyboard-only building blocks that use Discord's Quick Switcher (`⌘K`). The app contains **no hardcoded screen coordinates**.

## Requirements

- macOS 13 (Ventura) or newer, Apple Silicon or Intel.
- **Full Xcode** (free, Mac App Store) is recommended. On macOS 27 the standalone Command Line Tools are not enough: the build fails with `plugin for module 'SwiftUIMacros' not found`, and the unit tests cannot run because XCTest is missing. After installing Xcode run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

## Install on another Mac

### Easiest: download the zip and double-click

1. On the repository page click **Code > Download ZIP**, then double-click the downloaded zip to unpack it.
2. Install **Xcode** from the Mac App Store if you do not have it (free, several GB), and open it once.
3. In the unpacked folder, **right-click `Install.command` > Open > Open** (a plain double-click is blocked the first time because the file came from the internet).
4. Wait for it to finish. It builds the app, copies it to `/Applications`, and opens it. It may ask for your Mac password to accept Xcode's license.
5. In the app, open **Settings > Permissions & Privacy** and switch on Input Monitoring and Accessibility.

Everything the build needs is in the zip. The first build needs an internet connection only if Xcode has to download components.

### Option A: build from source in Terminal

```bash
git clone https://github.com/<your-username>/mac-action-recorder.git
cd mac-action-recorder
./init/setup.sh
```

`init/setup.sh` checks your macOS and Swift versions, runs the unit tests, builds the app, and prints the permission steps. The result is `build/Mac Action Recorder.app`, plus a zip next to it.

```bash
open "build/Mac Action Recorder.app"
```

To build without running the tests: `./scripts/build_app.sh`. Environment variables for that script:

| Variable | Meaning |
| --- | --- |
| `VERSION` | Version string written into the app (default `0.1.0`) |
| `BUILD_NUMBER` | Build number (default `1`) |
| `CODESIGN_IDENTITY` | Signing identity (default `-`, ad-hoc) |
| `NATIVE_ONLY=1` | Build only for this Mac's architecture (default tries a universal arm64 + x86_64 build and falls back) |

You can also open `Package.swift` in Xcode (File > Open) and run the `MacActionRecorder` scheme. Running from Xcode works, but macOS then grants permissions to Xcode's build product, not to a copy in `build/`.

### Option B: download a release build

Pushing a tag such as `v0.1.0` makes GitHub Actions build the app and attach a zip to a GitHub Release. These builds are **ad-hoc signed and not notarized**. After downloading, macOS may refuse to open it. Fix that with either right-click > Open, or:

```bash
xattr -dr com.apple.quarantine "/path/to/Mac Action Recorder.app"
```

Notarization needs an Apple Developer account ($99/year) and signing credentials that this repository does not contain. See [Notarization](#code-signing-and-notarization).

## Permissions (required)

macOS asks for two separate permissions. Enable **Mac Action Recorder** in both lists under **System Settings > Privacy & Security**:

| Permission | Needed for | What happens without it |
| --- | --- | --- |
| **Input Monitoring** | Recording, and the emergency-stop shortcut | Recording will not start |
| **Accessibility** | Playback (moving the pointer, clicking, typing) | Playback will not start |

Steps:

1. Open the app, then **Settings > Permissions & Privacy**. Each row shows whether the permission is granted. The page re-checks every couple of seconds.
2. Click **Open System Settings**, switch the app on, and quit and reopen the app if macOS asks.
3. If a permission shows as granted but still does not work, see [Troubleshooting](#troubleshooting).

## Using it

1. **Start Recording.** (First time only: read the privacy notice.) By default there is a 3-second countdown and the window hides so you can switch to Discord.
2. Do your actions normally: click, scroll, type, press shortcuts.
3. **Stop Recording** with the button, the menu bar item, or `⌃⌥⌘S`. The macro appears in the left-hand list and is saved.
4. Check the action list on the right. Edit anything that looks wrong.
5. Choose a **speed** and **repeat** setting. Start with a slow speed for a new macro.
6. Click **Play**. The window hides (optional) after a countdown. Stop at any time with `⌃⌥⌘S`, **Emergency Stop**, or the menu bar item.

Tips:

- Select actions in the list and click **Play selection** (or right-click > *Play from here*) to test just one section.
- Turn off **mouse movement** in Settings > Recording for small, clean macros that jump from click to click.
- Turn on **Only play while the recorded app is in front** (Settings > Playback) so the macro stops instead of typing into the wrong window.
- Speed, repeat and loop delay are saved with each macro.
- **Export** writes a `.macro.json` file. Copy it to your other Mac and use **Import**.

## Reliability: read this

Coordinate-based playback **can fail** whenever the interface or screen layout changes:

- If the Discord window moves, resizes, or is on another display, clicks land on whatever is at the old position.
- If your display resolution or arrangement changes, recorded coordinates no longer match. The app warns when the main display size differs from the one used to record, but it cannot detect every change.
- Discord can change its layout at any time. Servers and channels in different positions break click-based macros.
- Keyboard-only macros (Quick Switcher with `⌘K`, typing, Return) are much more robust than click-based ones.
- Discord may not be focused when playback starts. The optional foreground check helps but is not a guarantee.

This app does not and cannot promise perfect replay.

## Known limitations

These are design limits, not bugs. Items marked **untested** have not been observed on a real Mac yet.

- **Recording and playback have not been tried on a real Mac yet.** Only the build and the core-logic unit tests have been run.
- Recording fidelity is below playback fidelity. Events are timestamped when the app receives them on the main thread, so timing can be off by a few milliseconds, more if the Mac is busy.
- Mouse movement is sampled (default: at most every 30 ms and 3 points apart). Playback reproduces the path approximately, not pixel for pixel.
- Scroll events within 80 ms of each other are combined into one action.
- Typed text is replayed as characters, independent of keyboard layout. Dead-key sequences and input methods (Chinese/Japanese/Korean IMEs, emoji picker) may not record as intended. Shortcuts are replayed by key code.
- Text typed while a **password field** has focus is not delivered to the app by macOS (Secure Input), and the app also discards keys while Secure Input is on. Do not rely on this; do not type secrets while recording.
- Clicks on your menu bar or the Dock may be recorded when you did not intend that, including the menu bar item used to stop recording. Use `⌃⌥⌘S` to stop and review the end of the list. **Untested.**
- Playback of mouse events is generated through the standard macOS event interfaces. Some apps and games read input in other ways and ignore it. Discord's normal desktop interface is expected to work (**untested**).
- macOS may block events in some secure contexts (login window, some system dialogs, apps using Secure Input).
- Mouse position uses the global coordinate space of the main display. Multi-display setups with different scaling are **untested**.
- Ad-hoc code signing means macOS treats each rebuild as a new app for privacy permissions.
- The emergency-stop shortcut needs Input Monitoring. If that is missing, use the Emergency Stop button or the menu bar item.

## Check macro and AI review

Click **Check** above the action list.

**Built-in checks** are fixed rules, not AI. They run on your Mac, always. Each finding explains the problem, and some have a button to fix it:

| Check | Fix offered |
| --- | --- |
| Many mouse-move actions | Remove mouse movements (the pointer jumps straight to each click) |
| Pauses longer than 10 s | Shorten them to 2 s |
| Foreground check is off | Turn it on |
| Text and Return repeated 5+ times (or looped) with under 3 s between repeats | Set 5 s between repeats |
| Typed text that looks like a password, or a changed display size | Warning only |

The password check is a guess based on the shape of the text, and can be wrong either way.

**Improve this macro** (top of the same sheet) finds changes that make a macro shorter and less likely to fail. You see every proposed change with its reason, tick the ones you want, and click **Apply**. **Undo last improvements** restores the previous actions.

- *Rules* (always available, no AI): remove runs of mouse movements, combine typing that was split into chunks, wait a moment before typing that comes right after a click or shortcut, shorten very long pauses.
- *AI suggestions* (when available): the on-device model may propose deleting a clearly pointless step or adding a short wait before a step. It can only ask for those two things. Its reply is parsed strictly (unknown words, non-existent step numbers, mouse movements and long deletion lists are discarded), it cannot write text, coordinates or keys into your macro, and nothing is applied until you tick it. Suggestions are marked **AI**.

**Draft steps with AI** turns a sentence such as "open general and say hello" into keyboard steps. The model may only use three line types (press a key or shortcut, type text, wait), so a draft has no mouse clicks and no screen positions. Drafts are shown for review and are added to the end of the macro only when you click **Add to end of macro**. A Return key press in a draft sends a message for real, so read it first.

**AI review** uses Apple's on-device Foundation Models framework. It needs macOS 26 or newer on a Mac with Apple Intelligence turned on, and the app must have been built with an Xcode that includes that framework. It can review a macro in plain language and suggest a name.

- It runs on your Mac. The app has no network code and sends nothing anywhere.
- It receives a short text summary of the steps (typed text included), not the macro file.
- The review text and name suggestion change nothing by themselves. Edits only happen through **Improve this macro**, after you choose them.
- It can be wrong, and the on-device model is small. Treat its answers as suggestions.
- If the model is unavailable, the section says why; the built-in checks and the rule-based improvements still work.

## Privacy and safety

- Recording happens only after you click **Start Recording**, and stops when you stop it. There is no background recording and no hidden keylogger. The window header and menu bar show a red recording indicator the whole time.
- The emergency-stop key listener runs only while a recording or playback is active.
- Recordings are plain JSON files in `~/Library/Application Support/Mac Action Recorder/Recordings` (or the folder you choose). Typed text is stored as typed, **so a recording may contain passwords or private messages**. Delete such recordings, and be careful before exporting or sharing a file.
- The app has no network code and sends nothing anywhere.
- Playback only posts mouse and keyboard events. A recording cannot run shell commands or scripts, and files with invalid or out-of-range values are rejected before playback.
- Do not use this tool to violate the rules of any service you use. Discord's Terms of Service and Community Guidelines restrict some kinds of automation (for example spam, and automating user accounts in ways Discord forbids). You are responsible for how you use macros. Check Discord's current terms before relying on repeated automated messages.

## Project layout

```
Sources/MacActionRecorderCore/   Platform-independent logic: recording format, validation,
                                 recording builder, editing, speed math, playback engine,
                                 settings, storage, macro checks. Foundation only.
Sources/MacActionRecorder/       macOS app: CGEvent recorder and performer, permissions,
                                 on-screen click preview, on-device AI wrapper,
                                 SwiftUI views, menu bar item.
Tests/MacActionRecorderCoreTests/  Unit tests for the core.
Samples/                         A sample macro with no personal data.
Resources/                       Info.plist, app icon (AppIcon.svg and the rendered iconset).
docs/RECORDING_FORMAT.md         File format reference.
scripts/build_app.sh             Builds, bundles, ad-hoc signs and zips the app.
Install.command                  Double-click installer: builds, copies to /Applications, opens.
init/setup.sh                    One-shot setup for a new Mac (tests, then build).
.github/workflows/ci.yml         Build and test on macOS; release on version tags.
```

## Testing

```bash
swift test
```

The tests cover: serialization and deserialization, action ordering, timestamp and delay calculations, speed scaling, repeat counts, pause/resume, cancellation and emergency stop (using a fake performer, so no real input is generated), invalid and malicious files, editing operations, store behavior (save/load/duplicate/import/export/backup) and settings persistence.

They do **not** cover the macOS-specific parts (event taps, posting events, permissions, the SwiftUI interface). Those need manual testing; see the checklist below.

### Verification status

| Item | Status |
| --- | --- |
| Code compiles | **Verified** on macOS 27.2, Xcode, Swift 6.4, Apple Silicon (a release build succeeded). Other macOS/Xcode versions untested. |
| Unit tests pass | **Verified**: 155 tests, 0 failures, same machine (includes the 14 macro-check tests). They cover only the core logic. |
| Recording / playback on a real Mac | **Not verified.** Event capture, posting events, permissions and the SwiftUI interface have no automated tests. |
| Check macro, AI review, app icon | **Compiles and builds** (icon generation ran without warnings; the 14 check-rule tests pass). **Not yet run in the app:** the Check sheet UI, and the AI review, which calls Apple's Foundation Models API. |
| Improve this macro, Draft steps with AI, Show Clicks, Play Macro menu, permission rescue buttons, Install.command | **Written but not compiled or run.** Their core logic has unit tests that have not been executed. If the build fails, the first `error:` line says which file. |
| Universal (arm64 + x86_64) build | The build script produced a universal build, but the Intel half was not run. Xcode warns that x86_64 is deprecated for macOS 27. |

Manual checklist (not done yet):

1. Grant both permissions; confirm both show **Granted**.
2. Record: click somewhere in TextEdit, type a sentence, stop. Check the list matches.
3. Play at 1×, then 0.25×, then 5×. Confirm the sentence is typed again.
4. Pause and resume mid-playback; then Stop. Confirm nothing more is typed.
5. Loop until stopped, press `⌃⌥⌘S`, and confirm it stops at once.
6. Export a macro, import it, and compare.
7. Only then try Discord, with a harmless target (a private test server or DM to yourself).

## Troubleshooting

**"Recording needs the Input Monitoring permission" even though it is switched on.**
Remove Mac Action Recorder from the Input Monitoring list (select it, click `−`), quit the app, reopen it, and add it again when prompted. This is common after rebuilding, because ad-hoc signatures change on every build.

**The app is not in the Privacy lists, or the switch is on but it still says Not granted.**
Open Settings > Permissions & Privacy in the app. Click **Request** for the permission, or use **Show App in Finder** / **Copy App Path** and add the app with the `+` button (press `⌘⇧G` in the file picker and paste the path). If a grant seems stuck, use **Reset This App's Permissions**, request again, switch it on, then **Quit and Reopen**.

**Playback does nothing or only moves the pointer.**
Check **Accessibility**. Same fix as above. Also check that the target app is not using Secure Input (a password field focused) and that the macro's coordinates are still valid.

**Clicks land in the wrong place.**
The window moved or the display changed. Re-record, or edit the coordinates in the action list. Turn on the foreground check, and test at a slower speed.

**Typing is garbled or letters are dropped at high speed.**
Raise *Delay per typed character* and *Minimum action delay* in Settings > Playback, or lower the speed.

**The emergency-stop shortcut does nothing.**
It needs Input Monitoring. It also must include `⌃`, `⌥` or `⌘`. Change it in Settings > Playback. The Emergency Stop button and the menu bar item always work.

**macOS says the app is damaged or from an unidentified developer.**
This applies to downloaded release zips because they are not notarized. Use right-click > Open, or run `xattr -dr com.apple.quarantine "<path to the .app>"`.

**The app window disappeared.**
Closing the window leaves the app running in the menu bar. Choose **Show Window** from the menu bar item. The window also hides itself during recording and playback if you left those options on.

**`plugin for module 'SwiftUIMacros' not found` (many errors in the `Views` files).**
Only the Command Line Tools are installed. Install Xcode from the Mac App Store, open it once, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, and build again.

**Build errors.**
Check `swift --version` (5.9 or newer) and macOS 13 or newer. Open an issue and paste the first error. 

## Code signing and notarization

Builds are signed ad-hoc (`codesign --sign -`), which is enough to run on the Mac that built them. To distribute a build that opens without warnings on other Macs you need:

1. An Apple Developer account and a *Developer ID Application* certificate.
2. `CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh`
3. Notarization: `xcrun notarytool submit <zip> --apple-id … --team-id … --password … --wait`, then `xcrun stapler staple` on the app.

None of that is configured here because it needs credentials that must not be committed. If you add them, store them as GitHub Actions secrets.

## Publishing this repository to GitHub

If you have the folder locally and no GitHub repository exists yet:

```bash
git remote add origin https://github.com/<your-username>/mac-action-recorder.git
git branch -M main
git push -u origin main
```

Create the empty repository first at <https://github.com/new> (no README, no license), or with the GitHub CLI: `gh repo create mac-action-recorder --private --source=. --push`.

To publish a downloadable build: `git tag v0.1.0 && git push origin v0.1.0`.

## Recording format

Macros are JSON files with an explicit `formatVersion`. See [docs/RECORDING_FORMAT.md](docs/RECORDING_FORMAT.md).

## License

MIT. See [LICENSE](LICENSE).
