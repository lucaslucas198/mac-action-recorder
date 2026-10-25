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
        .defaultSize(width: 940, height: 700)
        .commands {
            AppCommands()
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
        }
        .defaultSize(width: 600, height: 560)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Makes `swift run` (no app bundle) behave like a normal windowed app as well.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Look for updates shortly after launch, then every few hours (if enabled in Settings).
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            UpdateManager.shared.startSchedule()
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
