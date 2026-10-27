import AppKit
import SwiftUI

@main
struct MacActionRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Mac Action Recorder", id: "main") {
            MainView()
                .environmentObject(model)
        }
        .defaultSize(width: 1040, height: 780)
        .commands {
            AppCommands()
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 660)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Used by the install self-test: proves this copy starts, then quits at once.
        if CommandLine.arguments.contains("--print-version") {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            FileHandle.standardOutput.write(("Mac Action Recorder " + version + "\n").data(using: .utf8) ?? Data())
            exit(0)
        }
        // CI only: test the install machinery and quit (see InstallSelfTest).
        if let folder = InstallSelfTest.requestedFolder {
            DispatchQueue.global(qos: .userInitiated).async { InstallSelfTest.run(in: folder) }
            return
        }
        // CI only: draw the screens to image files and quit (see Screenshotter).
        if let folder = Screenshotter.requestedFolder {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async { Screenshotter.run(into: folder) }
            return
        }
        // Only one copy of the app may run. If another one should stay, this copy quits here.
        // CI only (--selftest-instance <file>): writes what the one-copy check decided.
        var reportFile: URL?
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-instance"), index + 1 < CommandLine.arguments.count {
            reportFile = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        let quitting = InstallDoctor.resolveDuplicateInstancesAtLaunch(beforeQuitting: {
            if let file = reportFile { try? "quit".write(to: file, atomically: true, encoding: .utf8) }
        })
        if let file = reportFile {
            if !quitting {
                try? "stayed".write(to: file, atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
            }
            return
        }
        if quitting {
            return
        }
        // Makes `swift run` (no app bundle) behave like a normal windowed app as well.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // CI only: run the whole setup by itself (see SetupSelfTest).
        if SetupSelfTest.startIfRequested() {
            return
        }
        SetupManager.shared.launchCheck(model: AppModel.shared)
        // Look for updates shortly after launch, then every few hours (if enabled in Settings).
        // Not before the Welcome screen has been closed: nothing is contacted until you have seen it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if AppModel.shared.settings.hasCompletedWelcome {
                UpdateManager.shared.startSchedule()
            }
        }
    }

    /// The app keeps running in the menu bar after the window is closed, so a running macro
    /// or recording is never interrupted by closing the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var model = AppModel.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("Welcome & Setup…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.showSetupScreen()
            }
        }

        CommandMenu("Macro") {
            Button("Start Recording") { model.startRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.status.isBusy)
            Button("Stop Recording") { model.stopRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.status.isRecordingPhase)
            Divider()
            Button("Play") { model.play() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.status.isBusy || model.current == nil)
            Button(model.status == .paused ? "Resume" : "Pause") { model.togglePause() }
                .disabled(!model.status.isPlaybackPhase)
            Button("Restart") { model.restart() }
                .disabled(model.current == nil || model.status.isRecordingPhase)
            Divider()
            Button("Emergency Stop") { model.emergencyStop() }
                .disabled(!model.status.isBusy)
        }
    }
}
