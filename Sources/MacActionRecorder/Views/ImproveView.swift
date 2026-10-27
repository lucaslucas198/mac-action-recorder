import MacActionRecorderCore
import SwiftUI

/// Finds changes that make the selected macro shorter and more reliable. Fixed rules always run;
/// the on-device AI adds suggestions when it is available. Nothing changes until the user applies
/// the ticked items, and the last run can be undone.
struct ImproveSection: View {
    @EnvironmentObject private var model: AppModel

    @State private var edits: [MacroEdit] = []
    @State private var selected: Set<String> = []
    @State private var searched = false
    @State private var isAsking = false
    @State private var aiNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Improve this macro")
                .font(.subheadline.weight(.semibold))
            Text("Finds steps that can be removed or combined and places where the app may need a moment to catch up. Fixed rules always run; the on-device AI adds suggestions when it is available. You choose what to apply, and you can undo it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    find()
                } label: {
                    Label("Find improvements", systemImage: "wand.and.stars")
                }
                .disabled(isAsking || model.current == nil || !model.canEdit)

                if isAsking {
                    AIWorkingView()
                }

                Spacer()

                if let undo = model.improvementUndo, undo.id == model.selectedID {
                    Button("Undo last improvements") {
                        model.undoImprovements()
                    }
                    .disabled(!model.canEdit)
                }
            }

            if searched {
                if edits.isEmpty {
                    Label("No improvements found.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(edits) { edit in
                        EditRow(edit: edit, isOn: binding(for: edit))
                    }
                    HStack {
                        Button("Apply \(selected.count) selected") {
                            apply()
                        }
                        .disabled(selected.isEmpty || !model.canEdit)
                        Button("Select all") { selected = Set(edits.map { $0.id }) }
                            .controlSize(.small)
                        Button("Select none") { selected = [] }
                            .controlSize(.small)
                    }
                }
                if let aiNote = aiNote {
                    Label(aiNote, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func binding(for edit: MacroEdit) -> Binding<Bool> {
        Binding(
            get: { selected.contains(edit.id) },
            set: { isOn in
                if isOn { selected.insert(edit.id) } else { selected.remove(edit.id) }
            }
        )
    }

    private func find() {
        guard let recording = model.current else { return }
        let rules = MacroOptimizer.plan(for: recording)
        edits = rules
        selected = Set(rules.map { $0.id })
        searched = true
        aiNote = nil

        let availability = AIAssistant.availability
        guard availability.isAvailable else {
            aiNote = "AI suggestions are off: \(availability.message)"
            return
        }
        isAsking = true
        AIActivity.shared.run { @MainActor in
            do {
                let suggestions = try await AIAssistant.proposeEdits(for: recording, profile: model.aiProfile)
                let known = Set(edits.map { $0.id })
                let fresh = suggestions.filter { !known.contains($0.id) }
                edits += fresh
                selected.formUnion(fresh.map { $0.id })
                aiNote = suggestions.isEmpty
                    ? "The AI had no further suggestions. Its suggestions can be wrong, so check each one."
                    : "Items marked AI come from the on-device model and can be wrong. Check each one."
            } catch {
                aiNote = "AI suggestions failed: \(AIAssistant.describe(error))"
            }
            isAsking = false
        }
    }

    private func apply() {
        let chosen = edits.filter { selected.contains($0.id) }
        model.applyImprovements(chosen)
        edits = []
        selected = []
        searched = false
        aiNote = nil
    }
}

private struct EditRow: View {
    let edit: MacroEdit
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(edit.title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if edit.source == .ai {
                        Text("AI")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
                Text(edit.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Turns a plain-English request into keyboard steps with the on-device model. The steps are only
/// added to the macro after the user has looked at them.
struct DraftSection: View {
    @EnvironmentObject private var model: AppModel

    @State private var request = ""
    @State private var draft: MacroDraft?
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        let availability = AIAssistant.availability
        VStack(alignment: .leading, spacing: 10) {
            Text("Draft steps with AI")
                .font(.subheadline.weight(.semibold))
            Text("Describe what you want in plain words, for example “open the general channel and say hello”. The on-device AI drafts keyboard steps (no clicks and no screen positions). Read them, then add them to the end of this macro. A Return key press sends a message for real.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if availability.isAvailable {
                HStack {
                    TextField("What should the macro do?", text: $request)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { run() }
                    Button("Draft") { run() }
                        .disabled(isWorking || trimmedRequest.isEmpty || !model.canEdit)
                    if isWorking {
                        AIWorkingView()
                    }
                }

                if let draft = draft {
                    if draft.actions.isEmpty {
                        Label(
                            draft.unsupported
                                ? "The AI says this cannot be done with keyboard steps."
                                : "The AI did not return any usable steps. Try rewording the request.",
                            systemImage: "info.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(draft.actions.enumerated()), id: \.offset) { pair in
                                Text("\(pair.offset + 1). \(ActionDescriber.describe(pair.element))")
                                    .font(.system(.callout, design: .monospaced))
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        if draft.skippedLines > 0 {
                            Text("\(draft.skippedLines) line(s) from the AI were not understood and were left out.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Add to end of macro") {
                                model.appendDraftedActions(draft.actions)
                                self.draft = nil
                                request = ""
                            }
                            .disabled(!model.canEdit)
                            Button("Discard") { self.draft = nil }
                        }
                    }
                }
                if let errorText = errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
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

    private var trimmedRequest: String {
        return request.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run() {
        let text = trimmedRequest
        guard !text.isEmpty, !isWorking else { return }
        isWorking = true
        errorText = nil
        draft = nil
        AIActivity.shared.run { @MainActor in
            do {
                draft = try await AIAssistant.draftSteps(for: text, profile: model.aiProfile)
            } catch {
                errorText = AIAssistant.describe(error)
            }
            isWorking = false
        }
    }
}
