import MacActionRecorderCore
import SwiftUI

/// Name, counts, and warnings for the selected macro.
struct RecordingInfoView: View {
    @EnvironmentObject private var model: AppModel
    @State private var nameDraft = ""

    var body: some View {
        if let recording = model.current {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Macro name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.weight(.semibold))
                        .onSubmit { model.rename(recording.id, to: nameDraft) }
                        .disabled(!model.canEdit)
                    if model.unsavedIDs.contains(recording.id) {
                        Button("Save") { model.saveNow(recording.id) }
                            .help("Autosave is off. Save the changes to this macro.")
                    }
                }

                HStack(spacing: 0) {
                    InfoCell(title: "Actions", value: "\(recording.actions.count)")
                    InfoCell(title: "Length at 1×", value: Fmt.duration(recording.originalDuration))
                    InfoCell(title: "Speed", value: PlaybackTiming.formatSpeed(PlaybackTiming.clampSpeed(model.speed)))
                    InfoCell(title: "Repeat", value: model.repeatDescription)
                    InfoCell(title: "Estimated run", value: estimateText)
                }

                if let target = recording.targetApp {
                    Text("Recorded against \(target.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.screenMismatch, let recorded = recording.recordedScreen {
                    Label(
                        "Recorded on a \(Int(recorded.width))×\(Int(recorded.height)) display. The main display is different now, so clicks may land in the wrong place.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Text("Playback clicks at recorded screen coordinates. If the window moves, the display changes, or Discord's layout changes, a click can land on the wrong thing. Test a new macro with a slow speed first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onAppear { nameDraft = recording.name }
            .onChange(of: recording.id) { _ in nameDraft = recording.name }
            .onChange(of: recording.name) { value in nameDraft = value }
        }
    }

    private var estimateText: String {
        if model.repeatMode == .infinite { return "Until stopped" }
        guard let seconds = model.estimatedPlaybackSeconds else { return "—" }
        return Fmt.duration(seconds)
    }
}

struct InfoCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Speed, repeat, loop delay.
struct PlaybackSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Speed")
                    .frame(width: 52, alignment: .leading)
                ForEach(SpeedPreset.all) { preset in
                    Button(preset.label) {
                        model.speed = preset.value
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected(preset) ? Color.accentColor : nil)
                    .help(preset.detail)
                }
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                TextField("1.0", value: $model.speed, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 56)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { model.speed = PlaybackTiming.clampSpeed(model.speed) }
                Text("×")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(model.speedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 58)

            HStack(spacing: 10) {
                Text("Repeat")
                    .frame(width: 52, alignment: .leading)
                Picker("Repeat", selection: $model.repeatMode) {
                    ForEach(RepeatMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                if model.repeatMode == .times {
                    Stepper(value: $model.repeatCount, in: 1...100_000) {
                        Text("\(model.repeatCount) times")
                            .monospacedDigit()
                    }
                }
                if model.repeatMode != .once {
                    Text("Delay between")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0", value: $model.loopDelay, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("s")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 62)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(model.status.isPlaybackPhase)
    }

    private func isSelected(_ preset: SpeedPreset) -> Bool {
        return abs(model.speed - preset.value) < 0.0001
    }

    private var footnote: String {
        let countdown = model.settings.playbackCountdown
        let start = countdown > 0 ? "Playback starts after a \(countdown) s countdown." : "Playback starts immediately."
        return start + " Change in Settings."
    }
}

/// Repetition counter, current action, progress bar.
struct PlaybackProgressView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(repetitionText)
                    .font(.callout.monospacedDigit())
                Spacer()
                if let progress = model.progress {
                    Text("Action \(progress.actionIndex + 1)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = model.progress?.fraction {
                ProgressView(value: min(1, max(0, fraction)))
            } else if model.status.isPlaybackPhase {
                ProgressView(value: 0.0)
                    .opacity(0.4)
            }
            Text(currentActionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var repetitionText: String {
        switch model.status {
        case .preparing(let remaining):
            return remaining > 0 ? "Starting in \(remaining)…" : "Preparing…"
        default:
            break
        }
        guard model.iteration > 0 else { return "Ready" }
        if let total = model.totalIterations {
            return "Repetition \(model.iteration) of \(total)"
        }
        return "Repetition \(model.iteration) (looping until stopped)"
    }

    private var currentActionText: String {
        guard let index = model.currentActionIndex,
              let recording = model.current,
              recording.actions.indices.contains(index) else {
            return " "
        }
        return "Now: " + ActionDescriber.describe(recording.actions[index])
    }
}
