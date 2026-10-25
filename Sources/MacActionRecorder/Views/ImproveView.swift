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
                    ProgressView().controlSize(.small)
                    Text("Asking the on-device AI…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        Task { @MainActor in
            do {
                let suggestions = try await AIAssistant.proposeEdits(for: recording)
                let known = Set(edits.map { $0.id })
                let fresh = suggestions.filter { !known.contains($0.id) }
                edits += fresh
                selected.formUnion(fresh.map { $0.id })
                aiNote = suggestions.isEmpty
                    ? "The AI had no further suggestions. Its suggestions can be wrong, so check each one."
                    : "Items marked AI come from the on-device model and can be wrong. Check each one."
            } catch {
                aiNote = "AI suggestions failed: \(error.localizedDescription)"
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
