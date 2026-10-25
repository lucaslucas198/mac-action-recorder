import AppKit
import MacActionRecorderCore
import SwiftUI

struct MainView: View {
    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            BannerArea()
            ControlBar()
            Divider()
            HSplitView {
                LibraryView()
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 360)
                DetailView()
                    .frame(minWidth: 520)
            }
        }
        .frame(minWidth: 880, minHeight: 620)
    }
}

// MARK: - Header

struct HeaderView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Mac Action Recorder")
                .font(.headline)
            Spacer()
            StatusIndicator()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct StatusIndicator: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(model.status.label)
                .font(.callout.weight(.medium))
            if let detail = model.status.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch model.status {
        case .idle, .stopped: return Color.secondary
        case .recording, .recordingCountdown, .error: return Color.red
        case .preparing, .paused: return Color.orange
        case .playing: return Color.green
        }
    }
}

// MARK: - Banners

struct BannerArea: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.accessibilityGranted || !model.inputMonitoringGranted {
                PermissionBanner()
            }
            if let notice = model.notice {
                NoticeBanner(notice: notice)
            }
        }
    }
}

struct PermissionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                HStack {
                    if !model.inputMonitoringGranted {
                        Button("Grant Input Monitoring") {
                            Permissions.requestInputMonitoring()
                            Permissions.openInputMonitoringSettings()
                        }
                    }
                    if !model.accessibilityGranted {
                        Button("Grant Accessibility") {
                            Permissions.requestAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                    }
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var message: String {
        switch (model.inputMonitoringGranted, model.accessibilityGranted) {
        case (false, false):
            return "Recording needs Input Monitoring and playback needs Accessibility. Neither is granted yet."
        case (false, true):
            return "Recording needs the Input Monitoring permission, which is not granted yet."
        default:
            return "Playback needs the Accessibility permission, which is not granted yet."
        }
    }
}

struct NoticeBanner: View {
    @EnvironmentObject private var model: AppModel
    let notice: Notice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(notice.isError ? Color.red : Color.secondary)
            Text(notice.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.dismissNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background((notice.isError ? Color.red : Color.secondary).opacity(0.10))
    }
}

// MARK: - Controls

struct ControlBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
            .disabled(model.status.isBusy)

            Button {
                model.stopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle")
            }
            .disabled(!model.status.isRecordingPhase)

            Divider().frame(height: 20)

            Button {
                model.play()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(model.status.isBusy || (model.current?.actions.isEmpty ?? true))

            Button {
                model.togglePause()
            } label: {
                if model.status == .paused {
                    Label("Resume", systemImage: "playpause.fill")
                } else {
                    Label("Pause", systemImage: "pause.fill")
                }
            }
            .disabled(!model.status.isPlaybackPhase)

            Button {
                model.restart()
            } label: {
                Label("Restart", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.current == nil || model.status.isRecordingPhase)

            Spacer()

            Text("Emergency stop: \(model.hotKeyText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.emergencyStop()
            } label: {
                Label("Emergency Stop", systemImage: "octagon.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.status.isBusy)
            .help("Stops recording or playback immediately")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.status.isRecordingPhase {
                RecordingLiveView()
            } else if model.current != nil {
                RecordingInfoView()
                Divider()
                PlaybackSettingsView()
                if model.status.isPlaybackPhase || model.progress != nil {
                    Divider()
                    PlaybackProgressView()
                }
                Divider()
                EditorView()
            } else {
                EmptyDetailView()
            }
        }
    }
}

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "record.circle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No macro selected")
                .font(.headline)
            Text("Click Start Recording, do your actions, then click Stop Recording. Or import a macro from another Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingLiveView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            switch model.status {
            case .recordingCountdown(let seconds):
                Text("Recording starts in \(seconds)…")
                    .font(.title3)
                Text("Switch to the app you want to record.")
                    .foregroundStyle(.secondary)
            default:
                Text("Recording  \(Fmt.duration(model.recordingElapsed))")
                    .font(.title3.monospacedDigit())
                Text("\(model.recordedEventCount) input events captured")
                    .foregroundStyle(.secondary)
            }
            Text("Everything you click and type in other apps is being captured. Avoid typing passwords. Stop with \(model.hotKeyText), the Stop button, or the menu bar item.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
