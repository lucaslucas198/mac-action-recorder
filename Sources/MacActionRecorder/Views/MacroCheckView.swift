import MacActionRecorderCore
import SwiftUI

/// Built-in checks with one-click fixes, plus an optional on-device AI review.
struct MacroCheckSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var reviewText = ""
    @State private var suggestedName = ""
    @State private var isWorking = false
    @State private var aiError: String?

    var body: some View {
        let findings = model.findings()
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Check macro")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.lastSafetyStop != nil {
                        LastStopSection()
                        Divider()
                    }
                    checksSection(findings)
                    Divider()
                    DiscordCoachSection()
                    Divider()
                    ImproveSection()
                    Divider()
                    DraftSection()
                    Divider()
                    aiSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .onAppear { AIAssistant.prewarm() }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 480, idealHeight: 700)
    }

    // MARK: Built-in checks

    @ViewBuilder
    private func checksSection(_ findings: [MacroFinding]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Built-in checks")
                .font(.subheadline.weight(.semibold))
            Text("Fixed rules that run on this Mac. They look for common causes of unreliable macros. Passing them does not guarantee a macro will work.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if findings.isEmpty {
                Label("No problems found.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(findings) { finding in
                    FindingRow(finding: finding)
                }
            }
        }
    }

    // MARK: AI review

    @ViewBuilder
    private var aiSection: some View {
        let availability = AIAssistant.availability
        VStack(alignment: .leading, spacing: 10) {
            Text("AI review")
                .font(.subheadline.weight(.semibold))
            Text("Uses Apple's on-device model, so nothing leaves this Mac. This review is text only and changes nothing. It can be wrong, so treat it as a suggestion. To let it propose edits, use Improve this macro above.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if availability.isAvailable {
                HStack {
                    Button {
                        runReview()
                    } label: {
                        Label("Review with AI", systemImage: "sparkles")
                    }
                    Button {
                        runSuggestName()
                    } label: {
                        Label("Suggest a name", systemImage: "textformat")
                    }
                }
                .disabled(isWorking || model.current == nil)
                if isWorking {
                    AIWorkingView()
                }

                if !suggestedName.isEmpty {
                    HStack {
                        Text("Suggested name: ")
                            .foregroundStyle(.secondary)
                        Text(suggestedName)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Use this name") {
                            if let id = model.selectedID {
                                model.rename(id, to: suggestedName)
                            }
                        }
                    }
                    .font(.callout)
                }

                if !reviewText.isEmpty {
                    Text(reviewText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let aiError = aiError {
                    Label(aiError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } else {
                Label(availability.message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runReview() {
        guard let recording = model.current else { return }
        isWorking = true
        aiError = nil
        reviewText = ""
        AIActivity.shared.run { @MainActor in
            do {
                reviewText = try await AIAssistant.review(recording, profile: model.aiProfile) { partial in
                    reviewText = partial
                }
            } catch {
                aiError = AIAssistant.describe(error)
            }
            isWorking = false
        }
    }

    private func runSuggestName() {
        guard let recording = model.current else { return }
        isWorking = true
        aiError = nil
        AIActivity.shared.run { @MainActor in
            do {
                suggestedName = try await AIAssistant.suggestName(for: recording)
            } catch {
                aiError = AIAssistant.describe(error)
            }
            isWorking = false
        }
    }
}

struct FindingRow: View {
    @EnvironmentObject private var model: AppModel
    let finding: MacroFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(finding.severity == .warning ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title)
                    .font(.callout.weight(.semibold))
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = finding.fix, let label = finding.fixLabel {
                    Button(label) { model.applyFix(fix) }
                        .controlSize(.small)
                        .disabled(!model.canEdit)
                }
            }
        }
    }
}

// MARK: - Last automatic stop

/// Shows why the safety check last stopped a run, with an optional plain-words explanation.
struct LastStopSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var explanation = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why the last run was stopped")
                .font(.subheadline.weight(.semibold))
            if let reason = model.lastSafetyStop {
                Label(reason, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This message comes straight from the safety check. The explanation below is optional and written by the on-device AI, which cannot see your screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if AIAssistant.availability.isAvailable {
                HStack {
                    Button {
                        explain()
                    } label: {
                        Label("Explain in plain words (AI)", systemImage: "sparkles")
                    }
                    .disabled(isWorking)
                    if isWorking { AIWorkingView() }
                }
            }
            if !explanation.isEmpty {
                Text(explanation)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let errorText = errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func explain() {
        guard let reason = model.lastSafetyStop else { return }
        isWorking = true
        errorText = nil
        explanation = ""
        AIActivity.shared.run { @MainActor in
            do {
                explanation = try await AIAssistant.explainStop(reason) { partial in
                    explanation = partial
                }
            } catch {
                errorText = AIAssistant.describe(error)
            }
            isWorking = false
        }
    }
}

// MARK: - Discord coach

/// Suggestions built from the user's Discord profile. The one-click steps are plain rules; the
/// optional AI tips are text only and change nothing.
struct DiscordCoachSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var tips = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        let profile = model.settings.discord
        let recording = model.current
        VStack(alignment: .leading, spacing: 10) {
            Text("Discord coach")
                .font(.subheadline.weight(.semibold))
            Text("Quick steps built from your Discord profile in Settings > Discord. Nothing changes until you click.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if profile.favoriteChannels.isEmpty && profile.messageTemplates.isEmpty {
                Label("Add favorite channels and messages in Settings > Discord to get one-click suggestions here.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let recording = recording, !profile.favoriteChannels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recording.startChannel.map { "Opens “\($0)” first. Change it:" } ?? "Open a channel first:")
                        .font(.callout)
                    FlowButtons(titles: profile.favoriteChannels) { name in
                        model.setStartChannel(name)
                    }
                }
            }

            if !profile.messageTemplates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add a “type and send” step at the end:")
                        .font(.callout)
                    FlowButtons(titles: profile.messageTemplates) { message in
                        model.appendDraftedActions(Presets.sendMessage(message))
                    }
                }
            }

            if model.settings.aiUsesDiscordProfile {
                if AIAssistant.availability.isAvailable {
                    HStack {
                        Button {
                            ask()
                        } label: {
                            Label("Personal tips (AI)", systemImage: "sparkles")
                        }
                        .disabled(isWorking || recording == nil)
                        if isWorking { AIWorkingView() }
                    }
                } else {
                    Label(AIAssistant.availability.message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Personal AI tips are off. Switch them on in Settings > AI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !tips.isEmpty {
                Text(tips)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let errorText = errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func ask() {
        guard let recording = model.current else { return }
        isWorking = true
        errorText = nil
        let notes = model.settings.discord.promptContext
        tips = ""
        AIActivity.shared.run { @MainActor in
            do {
                tips = try await AIAssistant.discordTips(for: recording, profile: notes) { partial in
                    tips = partial
                }
            } catch {
                errorText = AIAssistant.describe(error)
            }
            isWorking = false
        }
    }
}

/// A wrapping row of small buttons.
struct FlowButtons: View {
    let titles: [String]
    let action: (String) -> Void

    var body: some View {
        // A lazy grid that wraps to the width available.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 260), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(titles, id: \.self) { title in
                Button {
                    action(title)
                } label: {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help(title)
            }
        }
    }
}
