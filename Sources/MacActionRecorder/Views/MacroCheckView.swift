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
                    checksSection(findings)
                    Divider()
                    aiSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
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
            Text("Uses Apple's on-device model, so nothing leaves this Mac. It only gives advice and never changes your macro. It can be wrong, so treat it as a suggestion.")
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
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .disabled(isWorking || model.current == nil)

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
        Task { @MainActor in
            do {
                reviewText = try await AIAssistant.review(recording)
            } catch {
                aiError = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func runSuggestName() {
        guard let recording = model.current else { return }
        isWorking = true
        aiError = nil
        Task { @MainActor in
            do {
                suggestedName = try await AIAssistant.suggestName(for: recording)
            } catch {
                aiError = error.localizedDescription
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
