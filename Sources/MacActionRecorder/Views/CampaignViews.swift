import MacActionRecorderCore
import SwiftUI

/// Messages and channels that change every repetition, send windows and the daily limit.
struct CampaignEditor: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let recording = model.current {
            let campaign = recording.campaign ?? Campaign()
            VStack(alignment: .leading, spacing: 12) {
                messagesSection(recording, campaign)
                Divider()
                channelsSection(recording, campaign)
                Divider()
                rotationSection(recording, campaign)
                Divider()
                scheduleSection(recording, campaign)
                Text("Every repetition sends the current message to the next channel; after the last channel the next message starts. Each server's rules and slowmode still apply, and Discord can restrict accounts that send a lot of messages. This only types into Discord's normal window: it does not log in for you or use your account token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Messages

    private func messagesSection(_ recording: Recording, _ campaign: Campaign) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Messages")
                    .font(.callout.weight(.medium))
                Text(countText(campaign.activeMessages.count, max: Campaign.maxEntries))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !campaign.activeMessages.isEmpty && !recording.usesPlaceholder(Campaign.messagePlaceholder) {
                    Button("Add send-message steps") { model.addSendMessageSteps() }
                        .help("Adds “Type {message}” and Return to the end of the macro")
                }
            }
            LinesEditor(lines: Binding(
                get: { campaign.messages },
                set: { lines in model.editCampaign { $0.messages = Array(lines.prefix(Campaign.maxEntries)) } }
            ))
            .frame(height: 76)
            Text("One message per line, used in order. Steps that type \(Campaign.messagePlaceholder) type the current one. (A line break would press Return, so each message is a single line.)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Channels

    private func channelsSection(_ recording: Recording, _ campaign: Campaign) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Channels")
                    .font(.callout.weight(.medium))
                Text(countText(campaign.activeChannels.count, max: Campaign.maxEntries))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.settings.discord.favoriteChannels.isEmpty {
                    Menu("Add favorite") {
                        ForEach(model.settings.discord.favoriteChannels, id: \.self) { name in
                            Button(name) {
                                model.editCampaign { campaign in
                                    var lines = campaign.channels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                                    lines.append(name)
                                    campaign.channels = Array(lines.prefix(Campaign.maxEntries))
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            LinesEditor(lines: Binding(
                get: { campaign.channels },
                set: { lines in model.editCampaign { $0.channels = Array(lines.prefix(Campaign.maxEntries)) } }
            ))
            .frame(height: 60)
            Text(channelHelp(recording, campaign))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func channelHelp(_ recording: Recording, _ campaign: Campaign) -> String {
        if recording.usesPlaceholder(Campaign.channelPlaceholder) {
            return "One channel or person per line. This macro types \(Campaign.channelPlaceholder) itself, so the app does not open the channel for it."
        }
        var text = "One channel or person per line, as you would type it in Discord's Quick Switcher (⌘K). Before every repetition the app opens the next one."
        if !campaign.activeChannels.isEmpty, let start = recording.startChannel, !start.isEmpty {
            text += " This list replaces “Open channel” (\(start)) while it has entries."
        }
        return text
    }

    // MARK: Rotation

    private func rotationSection(_ recording: Recording, _ campaign: Campaign) -> some View {
        HStack(spacing: 8) {
            Text("Next run")
                .font(.callout.weight(.medium))
            if campaign.activeMessages.isEmpty && campaign.activeChannels.isEmpty {
                Text("No rotation (add messages or channels)")
                    .foregroundStyle(.secondary)
            } else {
                Text(campaign.step(at: campaign.position).summary)
                Text("· run \(campaign.position % campaign.cycleLength + 1) of \(campaign.cycleLength) in the cycle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Start from the beginning") { model.resetRotation() }
                .disabled(campaign.position == 0)
                .help("Stopping keeps the place in the rotation; this goes back to the first message and channel")
        }
        .font(.callout)
    }

    // MARK: Schedule

    private func scheduleSection(_ recording: Recording, _ campaign: Campaign) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("Only start runs during these times", isOn: Binding(
                    get: { !campaign.sendWindows.isEmpty },
                    set: { on in
                        model.editCampaign { $0.sendWindows = on ? [SendWindow(start: 9 * 60, end: 21 * 60)] : [] }
                    }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                if !campaign.sendWindows.isEmpty && campaign.sendWindows.count < Campaign.maxWindows {
                    Button("Add time window") {
                        model.editCampaign { $0.sendWindows.append(SendWindow(start: 18 * 60, end: 22 * 60)) }
                    }
                }
            }
            ForEach(Array(campaign.sendWindows.enumerated()), id: \.offset) { index, window in
                HStack(spacing: 8) {
                    Text("From")
                        .foregroundStyle(.secondary)
                    DatePicker("From", selection: minuteBinding(index: index, start: true, window: window), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("to")
                        .foregroundStyle(.secondary)
                    DatePicker("To", selection: minuteBinding(index: index, start: false, window: window), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    if window.end < window.start {
                        Text("(past midnight)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !window.isValid {
                        Text("Start and end must differ")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button {
                        model.editCampaign { campaign in
                            if campaign.sendWindows.indices.contains(index) {
                                campaign.sendWindows.remove(at: index)
                            }
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this time window")
                }
                .padding(.leading, 20)
            }

            HStack(spacing: 8) {
                Toggle("Daily limit", isOn: Binding(
                    get: { campaign.dailyLimit != nil },
                    set: { on in model.editCampaign { $0.dailyLimit = on ? 20 : nil } }
                ))
                .toggleStyle(.checkbox)
                if let limit = campaign.dailyLimit {
                    Stepper(value: Binding(
                        get: { limit },
                        set: { value in model.editCampaign { $0.dailyLimit = min(100_000, max(1, value)) } }
                    ), in: 1...100_000) {
                        Text("\(limit) runs per day")
                            .monospacedDigit()
                    }
                    .fixedSize()
                    Text("· \(model.sentToday(recording)) finished today")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Times are this Mac's local time. Outside them, and after the daily limit, playback waits (Stop and Pause still work) and carries on when allowed. Discord must stay open and the screen unlocked (input cannot reach apps behind the lock screen).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func minuteBinding(index: Int, start: Bool, window: SendWindow) -> Binding<Date> {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        return Binding(
            get: {
                let minute = start ? window.start : window.end
                return calendar.date(byAdding: .minute, value: minute, to: midnight) ?? midnight
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                model.editCampaign { campaign in
                    guard campaign.sendWindows.indices.contains(index) else { return }
                    if start {
                        campaign.sendWindows[index].start = minute
                    } else {
                        campaign.sendWindows[index].end = minute
                    }
                }
            }
        )
    }

    private func countText(_ count: Int, max: Int) -> String {
        return count == 0 ? "none" : "\(count)"
    }
}

/// A plain multi-line text box bound to a list of lines. Splitting on line breaks and joining
/// them again gives back exactly the same text, so typing a new line is never lost.
struct LinesEditor: View {
    @Binding var lines: [String]

    var body: some View {
        TextEditor(text: Binding(
            get: { lines.joined(separator: "\n") },
            set: { text in lines = text.components(separatedBy: "\n") }
        ))
        .font(.callout)
        .scrollContentBackground(.hidden)
        .padding(4)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Shown under the progress bar: which message and channel this run uses, what playback is
/// waiting for, and the session's counts.
struct CampaignStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.campaignStep != nil || model.playbackWait != nil || model.sessionSent > 0 || model.sessionFailed > 0 {
            HStack(spacing: 10) {
                if let wait = model.playbackWait, model.status.isPlaybackPhase {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(waitText(wait, now: context.date), systemImage: "hourglass")
                            .monospacedDigit()
                    }
                } else if let step = model.campaignStep, model.status.isPlaybackPhase {
                    Label(step.summary, systemImage: "arrow.triangle.2.circlepath")
                }
                Spacer()
                Text("Finished \(model.sessionSent)" + (model.sessionFailed > 0 ? " · Failed \(model.sessionFailed)" : ""))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Activity") { model.showingActivity = true }
                    .controlSize(.small)
            }
            .font(.caption)
        }
    }

    private func waitText(_ wait: PlaybackWait, now: Date) -> String {
        let left = max(0, wait.until.timeIntervalSince(now))
        let time = wait.until.formatted(date: .omitted, time: .shortened)
        switch wait.reason {
        case .loopDelay:
            return "Next run in " + Fmt.duration(left)
        case .sendWindow:
            return "Outside the send times. Next run at \(time) (in \(Fmt.duration(left)))"
        case .dailyLimit:
            return "Daily limit reached. Next run at \(time) tomorrow"
        }
    }
}

/// Every finished, failed and stopped repetition, newest first. Kept only on this Mac.
struct ActivityLogView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var onlyThisMacro = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity")
                    .font(.title3.weight(.semibold))
                Spacer()
                if model.current != nil {
                    Toggle("Only this macro", isOn: $onlyThisMacro)
                        .toggleStyle(.checkbox)
                }
            }
            Table(rows) {
                TableColumn("Time") { entry in
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                        .monospacedDigit()
                }
                .width(min: 140, ideal: 160)
                TableColumn("Macro") { entry in
                    Text(entry.recordingName)
                }
                TableColumn("Result") { entry in
                    Text(resultText(entry.outcome))
                        .foregroundStyle(entry.outcome == .sent ? Color.primary : (entry.outcome == .failed ? Color.red : Color.secondary))
                }
                .width(70)
                TableColumn("Message") { entry in
                    Text(entry.messageNumber.map { "\($0)" } ?? "—")
                }
                .width(60)
                TableColumn("Channel") { entry in
                    Text(entry.channel ?? "—")
                }
                TableColumn("Details") { entry in
                    Text(entry.detail ?? "")
                        .foregroundStyle(.secondary)
                        .help(entry.detail ?? "")
                }
            }
            .frame(minHeight: 260)
            HStack {
                Text("\(rows.count) entries. The log records which message number and channel each run used, not the message text. It stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Log") { model.clearActivity() }
                    .disabled(model.activity.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 380)
    }

    private var rows: [ActivityEntry] {
        let all = model.activity.reversed()
        guard onlyThisMacro, let id = model.current?.id else { return Array(all) }
        return all.filter { $0.recordingID == id }
    }

    private func resultText(_ outcome: ActivityEntry.Outcome) -> String {
        switch outcome {
        case .sent: return "Finished"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}
