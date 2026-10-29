# Mac Action Recorder

**Install on a Mac:** download `MacActionRecorder-macOS.dmg` from the [latest release](https://github.com/lucaslucas198/mac-action-recorder/releases/latest), drag the app onto Applications, and follow the Welcome screen. Detailed steps: [Install on a Mac](#install-on-a-mac-no-xcode-needed).

**Install on Windows:** download `ActionRecorder-Windows-Setup.exe` from the same page and run it. Details and the SmartScreen warning: [Windows version](#windows-version).

A small native macOS app that records your mouse and keyboard, then plays the recording back at a speed you choose. It is built for repetitive Discord desktop tasks (open a channel, click the message box, type a message, press Return, repeat), but it works with any app.

> **Status: early version.** On every push GitHub Actions compiles it, runs the unit tests, builds the disk image, runs the install machinery for real on a macOS runner, and draws every main screen to images (see [Verification status](#verification-status)). Recording and playback in real apps, including Discord, the setup screen end to end, and updating from one release to the next have **not been tested on a real Mac by me**.

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
- **Welcome screen** on first launch: sets the app up on your Mac, shows the live status of the two permissions, and closes with an **Enter** button (see [Install](#install-on-a-mac-no-xcode-needed)).
- **Auto-update** from this repository's GitHub Releases (see [Updates](#updates)): the app notices a newer version, downloads the finished app in the background, and installs it when you click Restart to Update.
- **Play Macro** submenu in the menu bar for starting a saved macro without opening the window.
- **Discord presets** (optional): keyboard-only building blocks that use Discord's Quick Switcher (`⌘K`). The app contains **no hardcoded screen coordinates**.

## Windows version

The same recorder for Windows 10 (1809+) and Windows 11, 64-bit. It lives in [`windows/`](windows/) and is a separate app (C# / WPF, .NET 10, self-contained: nothing else to install). It has the same features as the Mac app: recording, playback with speed / repeat / loop / countdown, pause / resume / restart / emergency stop (default `Ctrl+Alt+Shift+S`), the action editor with undo and redo, the **Check** panel, the optional **AI helper**, Show Clicks, Discord keyboard presets, settings, import / export, backups, and updates from GitHub Releases. The Mac and Windows apps read the same recording format; see [Moving macros between Mac and Windows](#moving-macros-between-mac-and-windows).

> [!CAUTION]
> **Windows SmartScreen will warn you the first time.** It says *"Windows protected your PC"* because the installer is not code-signed (a signing certificate costs money and none is used here). Click **More info**, then **Run anyway**. The release has `SHA256SUMS.txt` so you can compare the file's hash first: `Get-FileHash .\ActionRecorder-Windows-Setup.exe` in PowerShell.

**Install:** run `ActionRecorder-Windows-Setup.exe`. It installs for your user only (no administrator prompt) and adds a Start menu entry. `ActionRecorder-Windows-Portable.zip` is the same app without an installer: unzip anywhere and run `ActionRecorder.exe`.

**Permissions:** Windows has no permission prompts for recording or sending input. One limit: Windows blocks a normal app from seeing or sending input to a window that is running **as administrator** (this is called UIPI). If recording or playback does nothing in such a window, start Action Recorder as administrator too. The app warns when it detects this.

**AI helper (optional):** install [Ollama](https://ollama.com), then in the app open the AI helper tab and press **Download model** (the recommended model is `llama3.2:3b`). The app only talks to Ollama on this computer (`127.0.0.1`), never to the internet. Whatever the model writes goes through strict parsers; it can only propose deleting or pausing steps, or adding keyboard steps, and nothing changes until you tick it. The AI can be wrong; always read what it proposes. Without Ollama the app works fully; only the AI buttons are disabled.

**Windows-specific limitations (honest list):**

- Coordinates are screen pixels: if a window moves, the display scale or resolution changes, or the app's layout changes, clicks land in the wrong place. The Check panel and **Show Clicks** help; test at a slow speed first.
- Text is replayed as Unicode characters, which should work across keyboard layouts. Dead-key and IME input (typing accents or East Asian text by combining keys) has **not been tested** and may not record or replay faithfully.
- Secure desktops (the sign-in screen, the UAC prompt) cannot be recorded or controlled by any normal app.
- Some games and anti-cheat protected programs ignore or block simulated input. This app does not try to get around that.
- Reordering actions uses the up / down buttons (no drag and drop yet).
- Discord can rate-limit or restrict accounts that send many messages quickly. The Check panel warns about this; keep delays between repeats.

**Build it yourself (needs Windows and the .NET 10 SDK):**

```powershell
git clone https://github.com/lucaslucas198/mac-action-recorder.git
cd mac-action-recorder\windows
$env:DOTNET_ROLL_FORWARD = "Major"                                # the tests target .NET 8; lets them run on a .NET 10-only machine
dotnet run --project tests\ActionRecorder.Tests -c Release       # unit tests
dotnet run --project src\ActionRecorder.App -c Release            # start the app
```

To build the installer, publish with `dotnet publish src\ActionRecorder.App -c Release -r win-x64 --self-contained -o artifacts\publish` and compile `installer\ActionRecorder.iss` with Inno Setup.

### Moving macros between Mac and Windows

Files carry a `platform` field. Opening a Mac recording on Windows converts it: Command becomes Ctrl and Mac key codes are translated to Windows ones (keys with no Windows equivalent are reported, not guessed); the target app is cleared (the foreground check then needs a new recording). Keyboard-only macros convert best. Mouse positions are copied as they are and almost certainly need adjusting for a different screen. Check the result before playing it.

### Windows verification status

What the GitHub Actions run on a `windows-latest` runner (Windows Server image, 1024×768 virtual display, running as administrator) actually did for the commit that added this section:

| Item | Status |
| --- | --- |
| App compiles | **Verified** by CI (.NET 10, WPF). |
| Unit tests | **Verified**: the custom test program passed on the runner (engine, file format, editing, storage, settings, update logic, AI reply parsers, and the app model with fake input and fake Ollama / GitHub responses). |
| App starts, every screen and all 8 settings pages open, no data-binding errors | **Verified** by CI (`--smoke`). |
| Real recording and playback | **Verified in a narrow case** by CI (`--selftest`): the app opened a test window, recorded real injected mouse and keyboard input through the Windows hooks, replayed it with `SendInput`, and the test window received the click and the typed text; the emergency-stop hotkey fired from real key input. This ran on a CI machine, not on a person's PC, and **not in Discord**. |
| Look of the interface | Rendered screenshots from CI were reviewed; they are not a substitute for using it on your screen. |
| Installer | **Built** by CI. **Not yet installed or run on a real PC by the author.** The silent update path (download, checksum check, run installer, relaunch) has unit tests with fake downloads but has **not been run end to end** against a real release. |
| AI helper with a real Ollama | The client and the parsers are tested with fake replies. **Not tested against a real running Ollama or real model output.** |
| Display scaling above 100%, several monitors, Discord | **Not tested.** |

## Install on a Mac (no Xcode needed)

You download one file, drag one app, and the app's Welcome screen does the rest.

**Requirements:** macOS 13 (Ventura) or newer, Apple Silicon or Intel. Nothing else has to be installed. The optional on-device AI helper needs macOS 26 or newer with Apple Intelligence turned on; the app tells you if it is not available.

> [!CAUTION]
> **macOS will block the app the first time you open it.** It will say *"Apple could not verify 'Mac Action Recorder' is free of malware"* with the buttons **Move to Trash** and **Done**. This is expected: the app is not notarized by Apple (see [why](#code-signing-and-notarization)). Click **Done**, not Move to Trash, then follow step 4 below.

### Step by step

1. **Download** `MacActionRecorder-macOS.dmg` from the [latest release](https://github.com/lucaslucas198/mac-action-recorder/releases/latest). It is in the **Assets** list at the bottom of the release. Do **not** use "Source code (zip)": that is the program's source files, not the app.
2. **Open the downloaded file.** A window shows the app, an arrow and the *Applications* folder.
3. **Drag *Mac Action Recorder* onto *Applications*.** If Finder asks, choose **Replace**.
4. **Open it from Applications.** The first time, macOS refuses with *"Apple could not verify…"*. That is expected (the app is not notarized, see [why](#code-signing-and-notarization)). Click **Done**, then:
   1. Open **System Settings > Privacy & Security** and scroll down to **Security**.
   2. Click **Open Anyway** next to the message about Mac Action Recorder, enter your password or use Touch ID, and click **Open Anyway** again.

   These are the steps in [Apple's guide](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac). Terminal alternative: `xattr -dr com.apple.quarantine "/Applications/Mac Action Recorder.app"`.
5. **Click Get Started.** The setup screen installs everything by itself and shows each step as it happens, with a progress bar, what it is doing right now, and how long each step took:
   - closes any other copy of the app that is running,
   - copies the app, signs it with a certificate made on your Mac (if macOS asks whether `codesign` may use a key, click **Always Allow**),
   - puts it in Applications and reopens it from there,
   - ejects old Mac Action Recorder disk images, moves other copies of the app to the Trash, and clears permission entries left by older versions.
6. **Allow the two permissions.** Each has an **Open … Settings** button that opens the right list in System Settings. Switch **Mac Action Recorder** on. If it is not in the list, click **+**, choose *Applications > Mac Action Recorder* and click **Open**. If macOS offers **Quit & Reopen**, click it. The checkmarks turn green by themselves.
7. **Click Enter.** You can open the setup screen again any time from **Help > Welcome & Setup** or the menu bar item.

Opening the app from the disk image directly also works: setup then copies it into Applications for you.

**Installing a new version by hand** (instead of the built-in updater): repeat steps 1 to 4 and choose **Replace**. When the new copy opens it finishes its own setup (signing it with the same certificate as before), so the permissions you already switched on keep working, and the setup screen closes by itself. If the copy you had before was never set up by the app itself (no *Mac Action Recorder Local Signing* certificate yet), macOS needs the two permissions switched on one more time; after that they stay.

**Why one copy matters.** macOS ties the Input Monitoring and Accessibility switches to one copy of the app and its signature. Old disk images left open, or a second copy in Downloads, made macOS open the wrong copy, and each download had a different signature, so the switches stopped working. Since 0.6.0 the app keeps exactly one copy, the one in Applications, and signs it the same way every time.

### What gets installed, and what does not

- The app itself (about a few MB) in `/Applications`.
- Your settings and recordings in `~/Library/Application Support/Mac Action Recorder`.
- A self-signed certificate named *Mac Action Recorder Local Signing* in your login keychain (created during setup). It is only used to sign this app on this Mac. You can delete it in Keychain Access.
- Nothing else. Old copies of the app that setup finds are moved to the **Trash**, not deleted, so you can put them back.
- The app downloads no dependencies, because it has none. The only network use is the optional update check.

To uninstall: quit the app, drag it from Applications to the Trash, and delete the support folder above if you want your recordings gone. Remove the app from the Privacy lists in System Settings if you like.

### Other ways to install

**Download the source zip and build it.** Needs **Xcode** (free, Mac App Store; on macOS 27 the standalone Command Line Tools are not enough: the build fails with `plugin for module 'SwiftUIMacros' not found`). After installing it, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

1. On the repository page click **Code > Download ZIP** and unpack it.
2. Right-click `Install.command` > **Open** > **Open**. It builds the app, copies it to `/Applications`, and opens it.

**Build in Terminal:**

```bash
git clone https://github.com/lucaslucas198/mac-action-recorder.git
cd mac-action-recorder
./init/setup.sh          # runs the tests, builds the app, prints the permission steps
open "build/Mac Action Recorder.app"
```

To build without running the tests: `./scripts/build_app.sh`. To make the disk image yourself: `./scripts/make_dmg.sh` (needs Python 3 and internet for the window styling; falls back to a plain image otherwise). Environment variables for the build script:

| Variable | Meaning |
| --- | --- |
| `VERSION` | Version string written into the app (default: the `VERSION` file) |
| `BUILD_NUMBER` | Build number (default `1`) |
| `CODESIGN_IDENTITY` | Signing identity (default: a local certificate created on first use, else ad-hoc `-`) |
| `STABLE_SIGNING=0` | Always sign ad-hoc |
| `NATIVE_ONLY=1` | Build only for this Mac's architecture (default tries a universal arm64 + x86_64 build and falls back) |

You can also open `Package.swift` in Xcode (File > Open) and run the `MacActionRecorder` scheme. Running from Xcode works, but macOS then grants permissions to Xcode's build product, not to a copy in `build/`.

## Permissions (required)

macOS asks for two separate permissions. Enable **Mac Action Recorder** in both lists under **System Settings > Privacy & Security**:

| Permission | Needed for | What happens without it |
| --- | --- | --- |
| **Input Monitoring** | Recording, and the emergency-stop and pause shortcuts | Recording will not start |
| **Accessibility** | Playback (moving the pointer, clicking, typing) | Playback will not start |

The easiest way is **Help > Welcome & Setup** (or **Fix Permissions…** in the orange bar): it shows both permissions with live status, buttons that open the right list, and numbered instructions.

If a switch is on but the app still says *Not allowed*:

1. Click **Quit and Reopen**. Input Monitoring often only takes effect after a restart.
2. Still not working? Click **Repair…**. It removes this app's entries from both lists (`tccutil reset All io.github.macactionrecorder.app`, nothing else), then macOS asks again and you switch both on.

The app also does step 2 by itself when it notices that its signature changed since the permissions were granted and they no longer work.

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
- Keep **Check that each step goes to the app it was recorded in** on (Settings > Playback, on by default) so the macro stops instead of typing into the wrong window.
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

## Accuracy, safety stop and Discord

**Can it be 100% accurate? No.** Playback repeats clicks at recorded screen positions and does not look at the screen. It cannot know whether a button is still there. What this version does is remove the causes it can measure and stop when something is certainly wrong:

| Cause | What the app does |
| --- | --- |
| Slow or jittery recording | Uses the exact time macOS stamps on each event (Settings > Recording > Accuracy). |
| Shift-click, Command-click | Records and replays the held modifier keys. |
| Window moved | If the window has the same size, every click is shifted by the same amount. |
| Window resized, app quit, display changed | The run stops with a message (Settings > Safety). It never guesses. |
| Another app took focus, or covers a click's spot | Stops before that step (on by default: *Check that each step goes to the app it was recorded in*). Each step knows which app received it, so a macro may still click from one app into another. A failed check is looked at again for up to 1 second first, because an app a click brings forward, or a menu it opens, can take a moment to appear (since 0.6.1). |
| App not in front or closed at the start | Brings it to the front, and opens it if closed (Settings > Playback). |
| Clicks shortened, typing at a different pace | Each click is held as long as it was recorded and text is typed at the recorded pace (since 0.6.0; Settings > Playback > *Match the recording*). |
| Small delays adding up over a long macro | Every step is scheduled on the recorded timeline, so a late step is made up in the next gap (since 0.6.0). |
| Clicks too fast for an app | Adjustable pause before a click, button hold time, double-click gap and key hold time (used for steps added by hand). |

What it **cannot** detect: a button that moved inside the window, a message that failed to send, a pop-up. The AI cannot see your screen either, so it is **not** used to decide whether to stop. It is used only to explain a stop in plain words (Check > Why the last run was stopped) and to personalize suggestions. Test every macro slowly first.

**Adding actions by hand.** Click **Add** above the action list and choose click, double-click, right-click, move, scroll, key press, type text, wait or a Discord preset. For mouse actions, **Pick on screen** lets you click the spot instead of typing coordinates. The new action goes after the selected one, or at the end.

**Choosing Discord and its channel.** Open **App and Discord** under the macro name, pick Discord as the app, and type a channel (or choose a favorite from Settings > Discord). On Play the app brings Discord to the front and opens that channel with Discord's Quick Switcher (`⌘K`) before the first repetition. This relies on Discord keeping that shortcut and on the Quick Switcher choosing the first match for the name you typed, so test it. Discord's bundle identifier `com.hnc.Discord` comes from a third-party source, not from Discord; the app also finds Discord by name when it is running.

**Personalized Discord help.** Settings > Discord holds your favorite channels, messages you send often, your minimum gap between messages, a note about how you use Discord, and your own rules. Check > Discord coach turns them into one-click steps. If you switch on *Use my Discord profile in AI suggestions* (Settings > AI), the on-device AI is also told these notes; the same page shows exactly what it is told. Nothing leaves your Mac. This app does not try to get around Discord's rate limits; the gap setting only warns you.

## Known limitations

These are design limits, not bugs. Items marked **untested** have not been observed on a real Mac yet.

- **Recording and playback have not been tried on a physical Mac yet.** They run on GitHub's macOS virtual machines in CI (see [Verification status](#verification-status)), which uses the same macOS event system but no real mouse, keyboard or Discord.
- Timing: with *Use the exact time macOS stamps on each event* on (the default), the recording keeps the system's own event times, even when the app reads an event late. Playback can only be as punctual as macOS wakes it; on a busy Mac a step can run late, and a step that is more than 0.15 s behind restarts the timeline from there rather than rushing the next steps. See [Measured timing](#measured-timing).
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

- It runs on your Mac and sends nothing anywhere.
- It receives a short text summary of the steps (typed text included), not the macro file.
- The review text and name suggestion change nothing by themselves. Edits only happen through **Improve this macro**, after you choose them.
- It can be wrong, and the on-device model is small. Treat its answers as suggestions.
- If the model is unavailable, the section says why; the built-in checks and the rule-based improvements still work.

## Updates

The app checks GitHub for a newer version shortly after launch (once the Welcome screen has been closed) and then every few hours (Settings > Updates, on by default).

1. **Check:** it asks GitHub for this repository's latest release (`api.github.com/repos/lucaslucas198/mac-action-recorder/releases/latest`). That is the only network request besides the download. It sends no recordings, settings or personal data (GitHub sees your IP address, like any web request).
2. **Download:** if the version is newer, the app downloads the finished app from that release (`MacActionRecorder-macOS.zip`), checks that it is Mac Action Recorder and that its signature is intact, and signs it for your Mac with the same local certificate. No Xcode, no building. The installed app is not touched.
3. **Install:** a banner says the update is ready. **Restart to Update** replaces the app and reopens it. Nothing is installed without that click.

Notes:

- A new version is only offered once it is published as a GitHub **Release** (pushing a tag like `v0.3.1` does this through GitHub Actions). Changes on `main` alone do not reach installed apps.
- The update is whatever the release contains, so it is controlled by whoever can publish releases to this repository. If you do not want that, turn the checks off in Settings > Updates.
- Because the update is signed with the same local certificate, macOS permissions should carry over. This is the intended design and has not been verified across a real update yet. If permissions stop working, see [Troubleshooting](#troubleshooting).
- Copies older than 0.3.0 check the old way (they build from source). Install 0.3.0 once from the disk image, or update by hand, and later updates use releases.
- Updating is unavailable when the app is started with `swift run`, because there is no app bundle to replace.

## Is it safe?

What I can state, and what I cannot:

- **The source code is public** in this repository, and the downloadable app is built from it by GitHub Actions. The build logs are public in the repository's **Actions** tab.
- **It is not notarized by Apple**, so macOS cannot vouch for it. That is why the warning above appears.
- **It does read your keyboard and mouse**, but only after you click Start Recording, with a visible indicator, and it only saves what you record on your Mac. See [Privacy and safety](#privacy-and-safety).
- **Check your download:** each release has a `SHA256SUMS.txt`. In Terminal, `shasum -a 256 ~/Downloads/MacActionRecorder-macOS.dmg` must print the same value as the line for the `.dmg`.
- **VirusTotal:** when the repository owner has set up the optional `VT_API_KEY` secret, the release workflow uploads the `.dmg` to [VirusTotal](https://www.virustotal.com) and adds the result VirusTotal returned (how many vendors flagged it) to the release notes. A release whose notes say no scan was run has no VirusTotal result. You can scan any file yourself by dragging it onto virustotal.com. A result with no detections is evidence, not proof of safety, and programs that watch keyboard and mouse input can be flagged by mistake (a false positive).

Setting up the scan (repository owner): create a free VirusTotal account, copy your API key from your profile page, then in the repository go to **Settings > Secrets and variables > Actions > New repository secret**, name it `VT_API_KEY`, and paste the key. It is used on the next release.

## Privacy and safety

- Recording happens only after you click **Start Recording**, and stops when you stop it. There is no background recording and no hidden keylogger. The window header and menu bar show a red recording indicator the whole time.
- The emergency-stop key listener runs only while a recording or playback is active.
- Recordings are plain JSON files in `~/Library/Application Support/Mac Action Recorder/Recordings` (or the folder you choose). Typed text is stored as typed, **so a recording may contain passwords or private messages**. Delete such recordings, and be careful before exporting or sharing a file.
- Recordings and settings are never sent anywhere. The only network use is the optional update check (see [Updates](#updates)), which you can turn off.
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

CI also starts the built app with a few test-only options. They are meant for a throw-away CI machine, not your Mac:

| Option | What it does |
| --- | --- |
| `--screenshots <folder>` | Draws the main screens with made-up sample data to PNG files and quits. |
| `--selftest-install <folder>` | Ejects mounted Mac Action Recorder disk images, signs test copies, runs the swap and reopen helpers, moves a test copy to the Trash, opens a second copy, and runs `tccutil reset` for this app (which clears its permission switches). |
| `--selftest-setup <report file>` | Runs the whole setup by itself, including installing into `/Applications`. |
| `--print-version` | Prints the version and quits. |

The results of the last CI run (pictures and reports) are in the [`ci-screenshots-mac`](https://github.com/lucaslucas198/mac-action-recorder/tree/ci-screenshots-mac) branch.

### Verification status

| Item | Status |
| --- | --- |
| Code compiles | **Verified** by GitHub Actions on every push: debug build on macOS 15 (Xcode 16), and the release app build on macOS 26 (current Xcode) including the on-device AI code (word-by-word answers included). |
| Unit tests pass | **Verified** by GitHub Actions on macOS 15 on every push (`swift test`; failures are shown as annotations). They cover the core logic, including the timeline rules, without a clock. |
| Disk image and update zip | **Built and structurally checked** by GitHub Actions (disk image mounts; contains the app and an Applications link; app signature verifies; helper scripts are inside). **Not yet opened or installed on a real Mac by the author.** |
| Recording and playback | **Run on a GitHub macOS 26 virtual machine on every push** (`--selftest-input`, report `input-selftest-output.txt` in the `ci-screenshots-mac` branch): the real recorder records a click, the word "hello" and Return sent to TextEdit as hardware-like events (since 0.6.1 with Calculator in front, so the recorded click is the one that switches to TextEdit, and the test checks that each step was recorded as going to TextEdit), then the real playback engine replays it at 1× and 2×, and once more with Calculator in front, with the app's real step checks on, while a separate listener measures when each press really happened. Results are listed under [Measured timing](#measured-timing). **Not covered:** a physical Mac with a real mouse and keyboard, Discord, other keyboard layouts, multiple displays. |
| Welcome screen, Set Up This Mac, release-based update, local re-signing | **Compiles. Not run.** Whether permissions survive an update after local re-signing is the design intent, not an observed result. |
| Check macro, Improve, Draft with AI, AI review, Show Clicks, Play Macro menu, permission rescue buttons | **Compiles.** Core rules have unit tests. The interface and the AI calls (Apple's Foundation Models) have not been exercised in the running app by me. |
| Window follow, safety stop, bring-to-front, open-channel-first, Add and Pick on screen, new Settings tabs, Discord coach (0.5.0) | **Compiles, and the core rules have unit tests** (window shift and resize rules, every stop rule, prefix steps, settings, profile, new checks). Reading and saving the recorded app's window position is exercised by the CI input test (TextEdit). **Not run anywhere:** launching Discord, the Quick Switcher step, the safety stop firing in the app, and the screen picker overlay on multiple displays. |
| Install and one-copy machinery (0.6.0) | **Run for real on a GitHub macOS 26 runner on every push** (`--selftest-install`, report in the `ci-screenshots-mac` branch): finds and ejects a mounted Mac Action Recorder disk image; signs a copy with a newly created local certificate (requirement `certificate leaf`, identical when signed again); the signed copy starts and passes `codesign --verify`; the swap helper waits for the old process, replaces the app and leaves nothing behind; the reopen helper waits; a stray copy is moved to the Trash (found in its folder even when Spotlight has not indexed it yet, which happened on the runner) while the kept and the running copy stay; a second copy opened while one is running quits by itself and leaves the first running; `mdfind` and `tccutil reset` run. The runner uses a throw-away keychain, so the macOS prompt a real Mac may show ("codesign wants to use a key") is **not** covered. Also run end to end on the runner (`--selftest-setup`): the app is opened from the mounted disk image, setup copies, signs, installs into `/Applications` and reopens; the reopened copy ejects the disk image, moves a stray copy to the Trash, clears permission entries, and pictures its own window (`setup-e2e.png`). Not covered: a real login keychain (the prompt it may show), switching the permissions on in System Settings, and the rule that a newer or installed copy wins over an older one (unit tests only). |
| Layout (0.6.0) | **Checked in screenshots** that CI renders on every push (`--screenshots`, published to the `ci-screenshots-mac` branch): welcome, setup (start, running, finished, permissions needed), main window at 960×700, 1040×780 and 1440×900, dark mode, Check sheet, Add sheet, every Settings tab. They are drawn off screen, so window chrome and animations are not shown. |
| Universal (arm64 + x86_64) build | The build script produced a universal build, but the Intel half was not run. Xcode warns that x86_64 is deprecated for macOS 27. |

#### Measured timing

From the CI input test on shared GitHub macOS 26 virtual machines (not a physical Mac). The machines are sometimes heavily loaded, so results vary from run to run; each line is one run.

| Code version | Recording (largest error) | Playback at 1× (largest difference per run) | Playback at 2× |
| --- | --- | --- | --- |
| Start of this work (`fc9d320`) | 85.1 ms (click hold not kept) | not measured | not measured |
| Click hold and typing pace kept, gaps still slept one by one (`650bdeb`) | 1.5 ms | 202.9 ms | 176.3 ms |
| Timeline scheduling, checks 20 ms early (`b89d3e9`) | 29.6 ms | 47.6 ms | 52.2 ms |
| Same, three runs at 1× (`adb0cc1`) | 3.9 ms | 33.6, 53.9, 95.3 ms (median 53.9) | 53.5 ms |
| No main-thread waits during playback (`d6d5ec0`) | 6.2 ms | 12.0, 54.3, 226.6 ms (median 54.3) | 42.8 ms |
| No App Nap while playing or recording (`b785e6f`) | 24.0 ms ¹ | 20.0, 55.2, 64.6 ms (median 55.2) | 54.9 ms |
| Last 15 ms of each wait on the Mach clock (`ff7271d`) | 0.5 ms | 37.6, 43.9, 45.1 ms (median 43.9) | 37.6 ms |
| Long waits made in halves (`33187b3`, current code) | 0.3 ms | 34.4, 38.3, 38.6 ms (median 38.3) | 40.2 ms |
| Same code, next run (`fafc4be`, documentation change only) | 128.3 ms ¹ | 49.7, 81.9, 119.5 ms (median 81.9) | 27.6 ms |
| Same code, next run (`e872e1c`, documentation change only) | 0.9 ms | 31.3, 47.7, 180.6 ms (median 47.7) | 25.3 ms |
| 0.6.1: recorded with another app in front, step checks on during playback (`63473b0`) | under 20 ms (passed; exact value not kept) | 33.6, 36.5, 59.2 ms (median 36.5) | 20.2 ms |
| 0.6.1: press lands on its time instead of after the 12 ms settle (`eb55bab`) | 0.5 ms | 6.9, 34.0, 50.9 ms (median 34.0) | 58.8 ms |

In the 0.6.1 runs the virtual machine passed the playback's mouse press on 20–63 ms after it was handed over (key presses 0.5–4 ms), which accounts for most of the larger differences; the 30 ms target for the median is still missed on these machines. The 0.6.1 test also plays once with Calculator in front, so the first click has to switch to TextEdit, with the real step checks on: it finished and typed the right text in both runs. In that run macOS took a moment to report TextEdit as the app in front, so the text started 0.1–0.15 s later than recorded (the 1-second re-check waited for it instead of stopping); that run's timing is shown in the report but not counted above.

¹ In those runs macOS stamped a test key press 24 ms (`b785e6f`) and 128 ms (`fafc4be`) after the test sent it; the recorder keeps macOS's stamp, so this is the virtual machine's delay in taking the event, not a recording error.

In the 226.6 ms run, the machine woke playback late in the middle of typing; because that was more than 0.15 s behind, the rest of the macro continued from there (by design, instead of rushing the next steps). With the current code, three CI runs gave medians of 38, 82 and 48 ms at 1×, with single playbacks between 25 and 181 ms. The machines vary a lot: in the 119.5 ms playback the engine handed the Return to macOS within 0.5 ms of its recorded time, and the virtual machine then took 119 ms to pass it on. Three runs on shared machines are not enough to say how it behaves in general, and a physical Mac has not been measured. The test also logs when the engine handed each step to macOS and when macOS passed it on: macOS passed events on within about 1–10 ms; the remaining differences come from when the virtual machine woke the playback thread. **Not measured:** a physical Mac, where this is expected to be lower but cannot be confirmed from here.

What the numbers mean: *recording* is how far the recorded timeline (click, first letter, Return) is from when the input was really sent; *playback* is how far the replayed presses are from the recorded timeline. On a loaded virtual machine the system sometimes wakes the app 50–300 ms late; one late wake-up delays only that one step, because every later step is scheduled on the timeline.

Manual checklist (not done yet):

1. Grant both permissions; confirm both show **Granted**.
2. Record: click somewhere in TextEdit, type a sentence, stop. Check the list matches.
3. Play at 1×, then 0.25×, then 5×. Confirm the sentence is typed again.
4. Pause and resume mid-playback; then Stop. Confirm nothing more is typed.
5. Loop until stopped, press `⌃⌥⌘S`, and confirm it stops at once.
6. Export a macro, import it, and compare.
7. Only then try Discord, with a harmless target (a private test server or DM to yourself).

## Troubleshooting

**The switch is on but the app says *Not allowed*, or the app is missing from the list.**
Open **Help > Welcome & Setup**. Click **Quit and Reopen** first (Input Monitoring often needs a restart). If that does not help, click **Repair…**, then switch the app on again in both lists. If it is missing from a list, click **+**, choose *Applications > Mac Action Recorder*, and click **Open**. Make sure you open the copy in Applications; since 0.6.0 the app moves other copies to the Trash so there is only one.

**Quit and Reopen opened a different (older) copy, or two copies run at once.**
Fixed in 0.6.0: only one copy runs (a newer or installed copy wins and the other quits), Quit and Reopen waits until the app has quit and then opens the copy in Applications, and old disk images are ejected. If you still see it, open **Help > Welcome & Setup** and click **Check for Old Copies Again**.

**Every new download needs the permissions switched on again.**
That happens when the app could not be signed on your Mac, so each download keeps its own changing signature. Setup tries again for each new version. If it keeps failing, see *setup fails* below.

**Playback does nothing or only moves the pointer.**
Check **Accessibility**. Same fix as above. Also check that the target app is not using Secure Input (a password field focused) and that the macro's coordinates are still valid.

**Clicks land in the wrong place.**
The window moved or the display changed. Re-record, or edit the coordinates in the action list. Turn on the foreground check, and test at a slower speed.

**Typing is garbled or letters are dropped at high speed.**
Raise *Delay per typed character* and *Minimum action delay* in Settings > Playback, or lower the speed.

**The emergency-stop shortcut does nothing.**
It needs Input Monitoring. It also must include `⌃`, `⌥` or `⌘`. Change it in Settings > Playback. The Emergency Stop button and the menu bar item always work.

**macOS says it cannot verify the app, or that it is damaged.**
Expected for downloaded releases (not notarized). Follow step 4 of the [install steps](#step-by-step): System Settings > Privacy & Security > Open Anyway, or run `xattr -dr com.apple.quarantine "/Applications/Mac Action Recorder.app"`. If *Open Anyway* is missing, try opening the app again; it is only offered for about an hour after an attempt.

**Setup fails, or waits a long time at "Signing it for this Mac".**
Signing creates a certificate in your login keychain and may make macOS ask whether `codesign` may use it: click **Always Allow** (enter your Mac password if asked). If no window appears, look behind other windows. After 30 seconds the setup screen offers **Continue Without Signing**: the app then works, but macOS may forget its permissions after the next update. Setup also needs write access to `/Applications` (an administrator account); otherwise it uses `~/Applications`. If replacing the app fails, setup stops and says so instead of trying again and again; drag the app from the disk image onto Applications yourself and choose Replace.

**The app window disappeared.**
Closing the window leaves the app running in the menu bar. Choose **Show Window** from the menu bar item. The window also hides itself during recording and playback if you left those options on.

**`plugin for module 'SwiftUIMacros' not found` (many errors in the `Views` files).**
Only the Command Line Tools are installed. Install Xcode from the Mac App Store, open it once, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, and build again.

**Build errors.**
Check `swift --version` (5.9 or newer) and macOS 13 or newer. Open an issue and paste the first error. 

## Code signing and notarization

**Release builds are not notarized.** Apple only notarizes apps from paid Apple Developer accounts ($99/year), and this repository has no such credentials. That is why macOS shows the "cannot verify" message the first time (see [Install](#install-on-a-mac-no-xcode-needed), step 4). The app's source code is in this repository, so you can read or build it yourself.

How signing works here:

- GitHub Actions builds the release and signs it **ad hoc** (no identity). An ad-hoc signature is enough to run, but it is different for every build.
- *Set Up This Mac* (and every update) then re-signs the app **on your Mac** with a self-signed certificate that exists only in your login keychain. Re-signing with the same certificate each time keeps the signature requirement identical, which is what lets macOS keep your Accessibility and Input Monitoring permissions across updates. This does not make the app trusted by Gatekeeper and is not Apple notarization.
- No private key is ever published or stored in this repository.

To distribute a build that opens without any warning you would need:

1. An Apple Developer account and a *Developer ID Application* certificate.
2. `CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh`
3. Notarization: `xcrun notarytool submit <zip> --apple-id … --team-id … --password … --wait`, then `xcrun stapler staple` on the app.

If you add credentials, store them as GitHub Actions secrets, never in the repository.

## Publishing this repository to GitHub

If you have the folder locally and no GitHub repository exists yet:

```bash
git remote add origin https://github.com/<your-username>/mac-action-recorder.git
git branch -M main
git push -u origin main
```

Create the empty repository first at <https://github.com/new> (no README, no license), or with the GitHub CLI: `gh repo create mac-action-recorder --private --source=. --push`.

To publish a downloadable build (this is what installed apps update from): bump the `VERSION` file, commit, push, then `git tag v0.3.1 && git push origin v0.3.1` (use the same number as `VERSION`). GitHub Actions builds the app, makes the disk image and the update zip, and publishes the release. Check the **Actions** tab if the release does not appear.

## Recording format

Macros are JSON files with an explicit `formatVersion`. See [docs/RECORDING_FORMAT.md](docs/RECORDING_FORMAT.md).

## License

MIT. See [LICENSE](LICENSE).
