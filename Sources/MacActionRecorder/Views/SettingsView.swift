import AppKit
import MacActionRecorderCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            RecordingSettingsTab()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            PlaybackSettingsTab()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions & Privacy", systemImage: "lock.shield") }
            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(minWidth: 580, minHeight: 540)
    }
}

// MARK: - Recording

struct RecordingSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("What to record") {
                Toggle("Mouse movement", isOn: $model.settings.recording.includeMouseMove)
                Toggle("Scrolling", isOn: $model.settings.recording.recordScroll)
                Toggle("Keyboard shortcuts and special keys", isOn: $model.settings.recording.recordShortcuts)
                Toggle("Typed text", isOn: $model.settings.recording.recordText)
                Text("Clicks are always recorded. Turning off mouse movement gives smaller, cleaner macros that jump straight to each click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Movement precision") {
                LabeledContent("Minimum interval") {
                    HStack {
                        Slider(value: $model.settings.recording.minEventInterval, in: 0.005...0.2)
                        Text("\(Int((model.settings.recording.minEventInterval * 1000).rounded())) ms")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent("Minimum distance") {
                    HStack {
                        Slider(value: $model.settings.recording.minMoveDistance, in: 0...20)
                        Text("\(Int(model.settings.recording.minMoveDistance.rounded())) pt")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Text("A mouse-move sample is stored only when both limits are exceeded. Lower values follow the pointer more closely but make larger files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Start") {
                Stepper(value: $model.settings.recordingCountdown, in: 0...30) {
                    Text("Countdown before recording: \(model.settings.recordingCountdown) s")
                }
                Toggle("Hide this window while recording", isOn: $model.settings.hideWindowWhileRecording)
                Text("While hidden, the menu bar item shows a red REC indicator and the emergency-stop shortcut stays active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

            Section("Start and stop") {
                Stepper(value: $model.settings.playbackCountdown, in: 0...60) {
                    Text("Countdown before playback: \(model.settings.playbackCountdown) s")
                }
                Toggle("Hide this window during playback", isOn: $model.settings.hideWindowDuringPlayback)
                Toggle("Ask before playing", isOn: $model.settings.confirmBeforePlay)
                LabeledContent("Emergency stop") {
                    HotKeyField(hotKey: $model.settings.emergencyStop)
                }
                Text("The shortcut is active only while recording or playing. It needs the Input Monitoring permission; the menu bar item always works as a fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reliability") {
                Toggle("Only play while the recorded app is in front", isOn: $model.settings.verifyForeground)
                Text("Before each click or key press, playback checks that the app the macro was recorded against (for example Discord) is the frontmost app and stops with an error if it is not. This reduces, but does not remove, the chance of input going to the wrong place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Minimum action delay") {
                    HStack {
                        Slider(value: $model.settings.minActionDelay, in: 0...0.5)
                        Text("\(Int((model.settings.minActionDelay * 1000).rounded())) ms")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent("Delay per typed character") {
                    HStack {
                        Slider(value: $model.settings.typingCharDelay, in: 0...0.2)
                        Text("\(Int((model.settings.typingCharDelay * 1000).rounded())) ms")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Text("At speeds above 1×, clicks and key presses never wait less than the minimum action delay, and typing is never faster than the typing delay allows, so fast playback stays reliable. Raise these if Discord drops input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click "Change…", then press the new shortcut. It must include ⌃, ⌥ or ⌘.
struct HotKeyField: View {
    @Binding var hotKey: HotKey
    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(capturing ? "Press a shortcut… (Esc cancels)" : hotKey.displayString)
                .font(.body.monospaced())
            Button(capturing ? "Cancel" : "Change…") {
                if capturing { stopCapture() } else { startCapture() }
            }
            Button("Reset") { hotKey = HotKey.defaultEmergencyStop }
                .disabled(hotKey == HotKey.defaultEmergencyStop)
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

            Section {
                Button("Reset All Settings…", role: .destructive) {
                    model.resetSettings()
                }
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
