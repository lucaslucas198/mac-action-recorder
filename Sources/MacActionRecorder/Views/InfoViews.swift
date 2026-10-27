import MacActionRecorderCore
import SwiftUI

/// Name, counts, target app and warnings for the selected macro.
struct RecordingInfoView: View {
    @EnvironmentObject private var model: AppModel
    @State private var nameDraft = ""
    @State private var showTarget = false
    @State private var showHelp = false

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
                    Button {
                        showHelp.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("How playback finds things, and its limits")
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                        AccuracyHelp()
                    }
                }

                HStack(spacing: 0) {
                    InfoCell(title: "Actions", value: "\(recording.actions.count)")
                    InfoCell(title: "Length at 1×", value: Fmt.duration(recording.originalDuration))
                    InfoCell(title: "Speed", value: PlaybackTiming.formatSpeed(PlaybackTiming.clampSpeed(model.speed)))
                    InfoCell(title: "Repeat", value: model.repeatDescription)
                    InfoCell(title: "Estimated run", value: estimateText)
                }

                if model.screenMismatch, let recorded = recording.recordedScreen {
                    Label(
                        "Recorded on a " + String(Int(recorded.width)) + "×" + String(Int(recorded.height)) + " display. The main display is different now, so clicks may land in the wrong place.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup(isExpanded: $showTarget) {
                    TargetEditor()
                        .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Text("App and Discord")
                            .font(.callout.weight(.medium))
                        Text(targetSummary(recording))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .disabled(!model.canEdit)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onAppear { nameDraft = recording.name }
            .onChange(of: recording.id) { _ in nameDraft = recording.name }
            .onChange(of: recording.name) { value in nameDraft = value }
        }
    }

    private func targetSummary(_ recording: Recording) -> String {
        guard let target = recording.targetApp else { return "No app set" }
        var parts = [target.name]
        if let channel = recording.startChannel, !channel.isEmpty { parts.append("opens “\(channel)” first") }
        if recording.targetWindow != nil && model.settings.followTargetWindow { parts.append("follows its window") }
        return parts.joined(separator: " · ")
    }

    private var estimateText: String {
        if model.repeatMode == .infinite { return "Until stopped" }
        guard let seconds = model.estimatedPlaybackSeconds else { return "—" }
        return Fmt.duration(seconds)
    }
}

/// Plain statement of what playback can and cannot guarantee.
struct AccuracyHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How accurate is playback?")
                .font(.headline)
            Text("Playback repeats the recorded clicks and keys exactly as they were captured, with the recorded timing. It does not look at the screen, so it cannot know whether a button is where it was.")
            Text("It stays accurate while the app's window is the same size and the display has not changed. If the window only moved, the app can shift the clicks to match. If something looks wrong, the safety check stops the run instead of carrying on.")
            Text("It cannot be guaranteed 100%: Discord can change its layout, a message or pop-up can appear, or the computer can be busy. Test with a slow speed first.")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 380)
    }
}

/// Which app a macro belongs to, which Discord channel to open first, and the window reference.
struct TargetEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var channelDraft = ""

    var body: some View {
        if let recording = model.current {
            VStack(alignment: .leading, spacing: 10) {
                row("App") {
                    Menu {
                        if let discord = Platform.findDiscord() {
                            Button("Discord (running)") { model.setTargetApp(discord) }
                        } else {
                            Button("Discord") {
                                model.setTargetApp(TargetApp(bundleID: "com.hnc.Discord", name: "Discord"))
                            }
                        }
                        Divider()
                        ForEach(Platform.runningApps(), id: \.bundleID) { app in
                            Button(app.name) { model.setTargetApp(app) }
                        }
                        Divider()
                        Button("None") { model.setTargetApp(nil) }
                    } label: {
                        Text(recording.targetApp?.name ?? "Choose an app…")
                    }
                    .fixedSize()
                    Text("Playback brings this app to the front first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.isDiscordMacro(recording) {
                    row("Open channel") {
                        TextField("Channel or person, for example general", text: $channelDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.setStartChannel(channelDraft) }
                        if !model.settings.discord.favoriteChannels.isEmpty {
                            Menu {
                                ForEach(model.settings.discord.favoriteChannels, id: \.self) { name in
                                    Button(name) {
                                        channelDraft = name
                                        model.setStartChannel(name)
                                    }
                                }
                            } label: {
                                Image(systemName: "star")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Pick one of your favorite channels (add them in Settings > Discord)")
                        }
                        Button("Set") { model.setStartChannel(channelDraft) }
                            .disabled(channelDraft == (recording.startChannel ?? ""))
                    }
                    Text("Before the first run, Discord is brought to the front and its Quick Switcher (⌘K) opens this channel. Leave it empty to skip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                row("Window") {
                    Text(windowText(recording))
                        .font(.callout)
                        .foregroundStyle(recording.targetWindow == nil ? .secondary : .primary)
                    Button("Use current position") { model.captureTargetWindow() }
                        .disabled(recording.targetApp == nil)
                        .help("Only use this if the app's window is exactly where it was when the clicks were recorded")
                    if recording.targetWindow != nil {
                        Button("Clear") { model.clearTargetWindow() }
                    }
                }
                Text("With a window reference, clicks follow the window if you move it, and the safety check stops the run if its size changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { channelDraft = recording.startChannel ?? "" }
            .onChange(of: recording.id) { _ in channelDraft = recording.startChannel ?? "" }
        }
    }

    private func windowText(_ recording: Recording) -> String {
        guard let frame = recording.targetWindow else { return "Not saved" }
        return "\(Int(frame.width))×\(Int(frame.height)) at (\(Int(frame.x)), \(Int(frame.y)))"
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
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
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Speed, repeat, loop delay and the safety switch.
struct PlaybackSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("Speed")
                    HStack(spacing: 8) {
                        // A custom speed shows no highlighted preset; the field on the right shows it.
                        Picker("Speed", selection: presetBinding) {
                            ForEach(SpeedPreset.all) { preset in
                                Text(preset.label).tag(preset.value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Choose a preset, or type any speed in the box")
                        TextField("1.0", value: $model.speed, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 56)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { model.speed = PlaybackTiming.clampSpeed(model.speed) }
                            .help("Custom speed, from 0.05× to 20×")
                        Text("×")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                GridRow {
                    label("Repeat")
                    HStack(spacing: 10) {
                        Picker("Repeat", selection: $model.repeatMode) {
                            Text("Once").tag(RepeatMode.once)
                            Text("Several times").tag(RepeatMode.times)
                            Text("Until stopped").tag(RepeatMode.infinite)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                if model.repeatMode != .once {
                    GridRow {
                        Color.clear.frame(width: 48, height: 1)
                        HStack(spacing: 8) {
                            if model.repeatMode == .times {
                                Stepper(value: $model.repeatCount, in: 1...100_000) {
                                    Text("\(model.repeatCount) times")
                                        .monospacedDigit()
                                }
                                .fixedSize()
                                Text("·")
                                    .foregroundStyle(.secondary)
                            }
                            Text("wait")
                                .foregroundStyle(.secondary)
                            TextField("0", value: $model.loopDelay, format: .number.precision(.fractionLength(0...2)))
                                .frame(width: 52)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                            Text("seconds between repeats")
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                }
                GridRow {
                    label("Safety")
                    HStack(spacing: 8) {
                        Toggle("Stop automatically if the macro looks broken", isOn: $model.settings.safety.enabled)
                            .toggleStyle(.checkbox)
                            .help("Stops only when it is certain: the app quit, its window changed size, or the display changed. It never guesses. More options in Settings > Safety.")
                        Spacer(minLength: 0)
                    }
                }
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(model.status.isPlaybackPhase)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .leading)
    }

    private var presetBinding: Binding<Double> {
        return Binding(
            get: {
                SpeedPreset.all.first { abs($0.value - model.speed) < 0.0001 }?.value ?? -1
            },
            set: { value in
                if value > 0 { model.speed = value }
            }
        )
    }

    private var footnote: String {
        let countdown = model.settings.playbackCountdown
        let start = countdown > 0 ? "Starts after a \(countdown) s countdown." : "Starts immediately."
        return model.speedDescription + ". " + start
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
                if let index = model.currentActionIndex {
                    Text("Action \(index + 1)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if model.status.isPlaybackPhase, model.progress != nil {
                    Text("Opening the start channel")
                        .font(.callout)
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
