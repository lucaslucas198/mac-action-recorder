import AppKit
import MacActionRecorderCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            RecordingSettingsTab()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            PlaybackSettingsTab()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            SafetySettingsTab()
                .tabItem { Label("Safety", systemImage: "shield.lefthalf.filled") }
            DiscordSettingsTab()
                .tabItem { Label("Discord", systemImage: "bubble.left.and.bubble.right") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            PermissionsSettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

/// A slider with its current value shown next to it.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Multiplier from the stored value to the shown value (1000 shows seconds as milliseconds).
    var scale: Double = 1000
    var unit = "ms"

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text("\(Int((value * scale).rounded())) \(unit)")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.settings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Action list rows", selection: $model.settings.rowDensity) {
                    ForEach(RowDensity.allCases, id: \.self) { density in
                        Text(density.label).tag(density)
                    }
                }
                Toggle("Show the wait before each action in the list", isOn: $model.settings.showDelaysInList)
            }

            Section("Macros") {
                TextField("Name for new recordings", text: $model.settings.newMacroNamePrefix)
                Hint("A new recording is named like “\(model.settings.newMacroNamePrefix) 2026-01-31 14.05”.")
                Toggle("Ask before deleting a macro or several actions", isOn: $model.settings.confirmBeforeDelete)
                Toggle("Play a sound when a run starts, ends or is stopped", isOn: $model.settings.soundEffects)
            }

            Section {
                Button("Reset All Settings…", role: .destructive) {
                    model.resetSettings()
                }
                Hint("Your saved macros are not touched.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recording

struct RecordingSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    private enum Precision: String, CaseIterable, Identifiable {
        case smooth, balanced, small
        var id: String { rawValue }
        var label: String {
            switch self {
            case .smooth: return "Smooth path"
            case .balanced: return "Balanced"
            case .small: return "Small files"
            }
        }
        var interval: Double {
            switch self {
            case .smooth: return 0.008
            case .balanced: return 0.03
            case .small: return 0.08
            }
        }
        var distance: Double {
            switch self {
            case .smooth: return 1
            case .balanced: return 3
            case .small: return 8
            }
        }
    }

    var body: some View {
        Form {
            Section("What to record") {
                Toggle("Mouse movement", isOn: $model.settings.recording.includeMouseMove)
                Toggle("Scrolling", isOn: $model.settings.recording.recordScroll)
                Toggle("Keyboard shortcuts and special keys", isOn: $model.settings.recording.recordShortcuts)
                Toggle("Typed text", isOn: $model.settings.recording.recordText)
                Hint("Clicks are always recorded, together with any Shift, Option, Control or Command key held during them. Turning off mouse movement gives smaller, cleaner macros that jump straight to each click.")
            }

            Section("Accuracy") {
                Toggle("Use the exact time macOS stamps on each event", isOn: $model.settings.recording.preciseTiming)
                Hint("Timing then does not depend on how busy this app was at the moment. Switch it off only if gaps look wrong.")
                Picker("Mouse path detail", selection: precisionBinding) {
                    ForEach(Precision.allCases) { item in
                        Text(item.label).tag(Optional(item))
                    }
                    Text("Custom").tag(Optional<Precision>.none)
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Minimum interval", value: $model.settings.recording.minEventInterval, range: 0.005...0.2)
                SliderRow(title: "Minimum distance", value: $model.settings.recording.minMoveDistance, range: 0...20, scale: 1, unit: "pt")
                Hint("A mouse-move sample is stored only when both limits are exceeded. Lower values follow the pointer more closely but make larger files.")
            }

            Section("Start") {
                Stepper(value: $model.settings.recordingCountdown, in: 0...30) {
                    Text("Countdown before recording: \(model.settings.recordingCountdown) s")
                }
                Toggle("Hide this window while recording", isOn: $model.settings.hideWindowWhileRecording)
                Hint("While hidden, the menu bar item shows a red REC indicator and the emergency-stop shortcut stays active.")
            }
        }
        .formStyle(.grouped)
    }

    private var precisionBinding: Binding<Precision?> {
        return Binding(
            get: {
                let options = model.settings.recording
                return Precision.allCases.first {
                    abs($0.interval - options.minEventInterval) < 0.0005 && abs($0.distance - options.minMoveDistance) < 0.05
                }
            },
            set: { value in
                guard let value = value else { return }
                model.settings.recording.minEventInterval = value.interval
                model.settings.recording.minMoveDistance = value.distance
            }
        )
    }
}

// MARK: - Playback

struct PlaybackSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Defaults for new macros") {
                Picker("Speed", selection: $model.settings.defaultSpeed) {
                    ForEach(SpeedPreset.all) { preset in
                        Text("\(preset.label) — \(preset.detail)").tag(preset.value)
                    }
                    if !SpeedPreset.all.contains(where: { abs($0.value - model.settings.defaultSpeed) < 0.0001 }) {
                        Text("Custom (\(PlaybackTiming.formatSpeed(model.settings.defaultSpeed)))")
                            .tag(model.settings.defaultSpeed)
                    }
                }
                TextField("Custom speed", value: $model.settings.defaultSpeed, format: .number.precision(.fractionLength(0...2)))
                Stepper(value: $model.settings.defaultRepeatCount, in: 0...100_000) {
                    Text(model.settings.defaultRepeatCount == 0
                         ? "Repeat: loop until stopped"
                         : "Repeat: \(model.settings.defaultRepeatCount) time(s)")
                }
                TextField("Delay between repeats (s)", value: $model.settings.defaultLoopDelay, format: .number.precision(.fractionLength(0...2)))
            }

            Section("Before it starts") {
                Stepper(value: $model.settings.playbackCountdown, in: 0...60) {
                    Text("Countdown before playback: \(model.settings.playbackCountdown) s")
                }
                Toggle("Ask before playing", isOn: $model.settings.confirmBeforePlay)
                Toggle("Bring the macro's app to the front first", isOn: $model.settings.bringTargetToFront)
                Toggle("Open the app if it is closed", isOn: $model.settings.launchTargetIfClosed)
                    .disabled(!model.settings.bringTargetToFront)
                Toggle("Hide this window during playback", isOn: $model.settings.hideWindowDuringPlayback)
            }

            Section("While it runs") {
                Toggle("Follow the app's window if it moved", isOn: $model.settings.followTargetWindow)
                Hint("If the window is the same size as when recorded but in a different place, every click is shifted by the same amount. It needs a window reference, which new recordings save automatically (or use “Use current position” in the macro's “App and Discord” section).")
                Toggle("Only play while the recorded app is in front", isOn: $model.settings.verifyForeground)
                Hint("Before each click or key press, playback checks that the app the macro was recorded against (for example Discord) is frontmost and stops with an error if it is not.")
                Toggle("Put the mouse pointer back where it was afterwards", isOn: $model.settings.restorePointerAfterPlayback)
            }

            Section("Shortcuts") {
                LabeledContent("Emergency stop") {
                    HotKeyField(hotKey: $model.settings.emergencyStop, defaultKey: HotKey.defaultEmergencyStop)
                }
                LabeledContent("Pause / resume") {
                    HotKeyField(hotKey: $model.settings.pauseHotKey, defaultKey: HotKey.defaultPause)
                }
                Hint("These work only while recording or playing and need the Input Monitoring permission. The menu bar item always works as a fallback. The two shortcuts must be different.")
            }

            Section("Timing and reliability") {
                SliderRow(title: "Minimum action delay", value: $model.settings.minActionDelay, range: 0...0.5)
                SliderRow(title: "Delay per typed character", value: $model.settings.typingCharDelay, range: 0...0.2)
                Hint("At speeds above 1×, clicks and key presses never wait less than the minimum action delay, and typing is never faster than the typing delay allows. Raise these if Discord drops input.")
                SliderRow(title: "Pause before a click", value: $model.settings.inputTiming.settleBeforeClick, range: 0...0.3)
                SliderRow(title: "Mouse button held down", value: $model.settings.inputTiming.clickHold, range: 0.001...0.2)
                SliderRow(title: "Gap in a double-click", value: $model.settings.inputTiming.doubleClickGap, range: 0.005...0.3)
                SliderRow(title: "Key held down", value: $model.settings.inputTiming.keyHold, range: 0.001...0.2)
                Button("Restore timing defaults") {
                    model.settings.minActionDelay = AppSettings().minActionDelay
                    model.settings.typingCharDelay = AppSettings().typingCharDelay
                    model.settings.inputTiming = InputTiming()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Safety

struct SafetySettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Automatic stop") {
                Toggle("Stop the macro automatically when it looks broken", isOn: $model.settings.safety.enabled)
                Hint("Before each click or key press (and at the start of each repeat), playback checks facts that macOS can report. It stops only when one of the checks below is certain. It never guesses, and if a value cannot be read it carries on.")
            }

            Section("Stop when…") {
                Toggle("The app has quit", isOn: $model.settings.safety.stopIfTargetGone)
                Toggle("The app's window changed size, or has no window", isOn: $model.settings.safety.stopIfWindowChanged)
                Toggle("The display size changed", isOn: $model.settings.safety.stopIfDisplayChanged)
                Toggle("Something else moved the mouse during the run", isOn: $model.settings.safety.stopIfUserMovesMouse)
                Hint("The last one stops the macro if you grab the mouse yourself. It is off by default because a mouse that is nudged by accident would end a long run.")
            }
            .disabled(!model.settings.safety.enabled)

            Section("Also") {
                Toggle("Only play while the recorded app is in front", isOn: $model.settings.verifyForeground)
                Hint("This is a separate check and is on by default. It stops the run the moment another app takes focus.")
            }

            Section("What this cannot do") {
                Hint("The checks look at windows and apps, not at what is drawn inside them. They cannot tell that a button moved inside Discord, that a message failed to send, or that a pop-up appeared. The AI cannot see the screen either, so it is not used to decide whether to stop. It is used only to explain a stop in plain words (Check > Discord coach).")
            }

            if let reason = model.lastSafetyStop {
                Section("Last automatic stop") {
                    Text(reason)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Discord

/// An editable list of short strings.
struct StringListEditor: View {
    let title: String
    let placeholder: String
    @Binding var items: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { pair in
                HStack {
                    Text(pair.element)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer()
                    Button {
                        if items.indices.contains(pair.offset) { items.remove(at: pair.offset) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        draft = ""
    }
}

struct DiscordSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Favorite channels and people") {
                StringListEditor(title: "Channels", placeholder: "Name as you would type it in Quick Switcher", items: $model.settings.discord.favoriteChannels)
                Hint("Used to pick a channel to open first, and by the Check coach to suggest steps. Only the name is stored.")
            }

            Section("Messages you send often") {
                StringListEditor(title: "Messages", placeholder: "A message", items: $model.settings.discord.messageTemplates)
                Hint("They appear in the Check coach as one-click “type and send” steps. Do not put passwords or private details here.")
            }

            Section("Pacing") {
                SliderRow(title: "Shortest gap between messages", value: $model.settings.discord.minSecondsBetweenMessages, range: 0...60, scale: 1, unit: "s")
                Hint("The check warns when a macro would send messages closer together than this. Discord limits how fast messages can be sent, and servers can add their own limits; this app does not try to get around them.")
            }

            Section("About you (optional)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What do you use Discord macros for?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.settings.discord.about)
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your own rules for macros")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.settings.discord.rules)
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                }
                Hint("Both are given to the on-device AI so its suggestions fit you (AI tab). They stay on this Mac.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI

struct AISettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let availability = AIAssistant.availability
        Form {
            Section("On-device AI") {
                HStack {
                    Image(systemName: availability.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(availability.isAvailable ? Color.green : Color.secondary)
                    Text(availability.isAvailable ? "Available" : "Not available")
                }
                if !availability.isAvailable {
                    Hint(availability.message)
                }
                Hint("It runs entirely on this Mac through Apple's on-device model. Nothing is sent to any server. Its answers can be wrong, so every suggestion is shown for you to approve before anything changes.")
            }

            Section("Personal suggestions") {
                Toggle("Use my Discord profile in AI suggestions", isOn: $model.settings.aiUsesDiscordProfile)
                Hint("Adds your favorite channels, message habits, pacing and rules (Discord tab) to what the AI is told, so its review and drafts fit how you use Discord.")
                if model.settings.aiUsesDiscordProfile {
                    DisclosureGroup("Exactly what the AI is told about you") {
                        Text(model.settings.discord.promptContext)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("What the AI is not used for") {
                Hint("The automatic stop does not depend on the AI. The AI cannot see your screen, so it cannot confirm that a macro worked. The safety checks use only facts from macOS.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Click "Change…", then press the new shortcut. It must include ⌃, ⌥ or ⌘.
struct HotKeyField: View {
    @Binding var hotKey: HotKey
    var defaultKey: HotKey = HotKey.defaultEmergencyStop
    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(capturing ? "Press a shortcut… (Esc cancels)" : hotKey.displayString)
                .font(.body.monospaced())
            Button(capturing ? "Cancel" : "Change…") {
                if capturing { stopCapture() } else { startCapture() }
            }
            Button("Reset") { hotKey = defaultKey }
                .disabled(hotKey == defaultKey)
        }
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopCapture()
                return nil
            }
            let modifiers = EventTapSupport.modifiers(from: event.modifierFlags)
            if modifiers.isDisjoint(with: [.control, .option, .command]) {
                NSSound.beep()
                return nil
            }
            hotKey = HotKey(keyCode: Int(event.keyCode), modifiers: modifiers)
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        capturing = false
    }
}

// MARK: - Storage

struct StorageSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Macros") {
                LabeledContent("Save location") {
                    Text(model.recordingsDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") {
                        if let path = model.pickFolder(startingAt: model.recordingsDirectory.path) {
                            model.settings.saveDirectoryPath = path
                        }
                    }
                    Button("Show in Finder") { model.revealRecordingsFolder() }
                    Button("Use Default") { model.settings.saveDirectoryPath = nil }
                        .disabled(model.settings.saveDirectoryPath == nil)
                }
                .disabled(model.status.isBusy)
                Toggle("Save changes automatically", isOn: $model.settings.autoSave)
                if !model.settings.autoSave {
                    Text("Autosave is off. Edited macros show an orange dot and a Save button until you save them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Import and export") {
                LabeledContent("Folder") {
                    Text(model.settings.exportDirectoryPath ?? "Not set (the last-used folder is remembered)")
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") {
                        if let path = model.pickFolder(startingAt: model.settings.exportDirectoryPath) {
                            model.settings.exportDirectoryPath = path
                        }
                    }
                    Button("Clear") { model.settings.exportDirectoryPath = nil }
                        .disabled(model.settings.exportDirectoryPath == nil)
                }
            }

            Section("Backups") {
                Toggle("Back up all macros each time the app starts", isOn: $model.settings.backupEnabled)
                Stepper(value: $model.settings.backupKeepCount, in: 1...100) {
                    Text("Keep the newest \(model.settings.backupKeepCount) backups")
                }
                LabeledContent("Backup folder") {
                    Text(model.backupDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") {
                        if let path = model.pickFolder(startingAt: model.backupDirectory.path) {
                            model.settings.backupDirectoryPath = path
                        }
                    }
                    Button("Use Default") { model.settings.backupDirectoryPath = nil }
                        .disabled(model.settings.backupDirectoryPath == nil)
                    Button("Back Up Now") { model.backupNow() }
                    Button("Show in Finder") { model.revealBackupsFolder() }
                }
            }

            Section("Delete") {
                Button("Delete All Saved Macros…", role: .destructive) {
                    model.deleteAllRecordings()
                }
                .disabled(model.recordings.isEmpty || model.status.isBusy)
                Text("Deleting is permanent. Backups and exported files are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions and privacy

struct PermissionsSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmReset = false
    @State private var diagnostics = ""

    var body: some View {
        Form {
            Section("macOS permissions") {
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Lets the app see your mouse and keyboard while recording, and the emergency-stop shortcut while a macro runs.",
                    granted: model.inputMonitoringGranted,
                    request: { Permissions.requestInputMonitoring() },
                    open: { Permissions.openInputMonitoringSettings() }
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets the app move the pointer, click, scroll and type for you during playback.",
                    granted: model.accessibilityGranted,
                    request: { Permissions.requestAccessibility() },
                    open: { Permissions.openAccessibilitySettings() }
                )
                Text("Enable Mac Action Recorder in System Settings > Privacy & Security for both. This page re-checks every couple of seconds. macOS ties permissions to the app's code signature, so after you rebuild or replace the app you may need to remove it from each list (with the minus button), add it again, and relaunch it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App missing from the lists, or switched on but still not working?") {
                Text("1. Click Request above: macOS then adds the app to the list by itself. 2. If it is still missing, click the + button in the list, press ⌘⇧G, paste the path below, and choose the app. 3. After switching a permission on, use Quit and Reopen. 4. If a permission shows as switched on but is not granted here, reset this app's entries and request again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Permissions.appURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Show App in Finder") { Permissions.revealAppInFinder() }
                    Button("Copy App Path") { Permissions.copyAppPath() }
                    Button("Reset This App's Permissions…") { confirmReset = true }
                    Button("Quit and Reopen") { Permissions.relaunch() }
                }
                HStack {
                    Button("Run Permission Diagnostics") { diagnostics = Permissions.diagnosticsReport() }
                    if !diagnostics.isEmpty {
                        Button("Copy Report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnostics, forType: .string)
                        }
                    }
                }
                if !diagnostics.isEmpty {
                    Text(diagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Section("What this app records") {
                bullet("Only while you have clicked Start Recording and until you stop it. A red indicator shows in the window and the menu bar the whole time.")
                bullet("Mouse position, clicks, scrolling, and the keys you press, in any app.")
                bullet("The name of the app that was in front when you started, used only for the optional foreground check.")
                bullet("Keystrokes typed into macOS password fields are not delivered to this app by the system, and the app discards keys while macOS Secure Input is on. Do not rely on this; do not type secrets while recording.")
            }

            Section("What happens to recordings") {
                bullet("They are saved as plain, readable JSON files on this Mac. Typed text is stored as typed, so a recording can contain passwords or private messages.")
                bullet("Recordings are never uploaded or sent anywhere. The only network use is the optional update check (Updates tab), which reads one version file from GitHub. A file leaves this Mac only if you export or copy it yourself.")
                bullet("Playback only posts normal mouse and keyboard events. Recordings cannot run shell commands or scripts.")
            }

        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset this app's permission entries?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                let done = Permissions.resetStoredPermissions()
                model.refreshPermissions()
                model.showNotice(
                    done
                        ? "Permission entries cleared. Click Request for each permission, switch it on, then use Quit and Reopen."
                        : "Could not reset the entries. Remove the app from each list with the minus button instead.",
                    isError: !done
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Mac Action Recorder from the Accessibility and Input Monitoring lists. Nothing else is touched. You will need to grant both again.")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
                .font(.callout)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? Color.green : Color.red)
                Text(title)
                    .font(.headline)
                Text(granted ? "Granted" : "Not granted")
                    .foregroundStyle(.secondary)
                Spacer()
                if !granted {
                    Button("Request") { request() }
                }
                Button("Open System Settings") { open() }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
