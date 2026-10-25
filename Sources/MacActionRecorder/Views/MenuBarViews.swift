import AppKit
import SwiftUI

/// Always-visible status in the menu bar. While recording it shows a REC label with the
/// elapsed time, so recording is never invisible even when the window is hidden.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if model.status == .recording {
                Text("REC " + Fmt.duration(model.recordingElapsed))
                    .monospacedDigit()
            } else if case .recordingCountdown(let seconds) = model.status {
                Text("REC in \(seconds)")
            } else if model.status.isPlaybackPhase {
                Text(model.status == .paused ? "Paused" : "Playing")
            }
        }
    }

    private var symbol: String {
        switch model.status {
        case .recording, .recordingCountdown: return "record.circle.fill"
        case .playing, .preparing: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        default: return "cursorarrow.click.2"
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(statusLine)
            Divider()
        }
        Group {
            Button("Start Recording") { model.startRecording() }
                .disabled(model.status.isBusy)
            Button("Stop Recording") { model.stopRecording() }
                .disabled(!model.status.isRecordingPhase)
            Divider()
        }
        Group {
            Button("Play") { model.play() }
                .disabled(model.status.isBusy || model.current == nil)
            Menu("Play Macro") {
                ForEach(model.recordings.prefix(15)) { recording in
                    Button(recording.name) {
                        model.selectedID = recording.id
                        model.play()
                    }
                }
            }
            .disabled(model.status.isBusy || model.recordings.isEmpty)
            Button(model.status == .paused ? "Resume" : "Pause") { model.togglePause() }
                .disabled(!model.status.isPlaybackPhase)
            Button("Emergency Stop") { model.emergencyStop() }
                .disabled(!model.status.isBusy)
            Divider()
        }
        Group {
            Button("Show Window") {
                openWindow(id: "main")
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Check for Updates…") { UpdateManager.shared.check(userInitiated: true) }
            Divider()
            Button("Quit Mac Action Recorder") { NSApp.terminate(nil) }
        }
    }

    private var statusLine: String {
        var line = model.status.label
        if let detail = model.status.detail { line += " · " + detail }
        if let name = model.current?.name { line += "\n" + name }
        return line
    }
}
