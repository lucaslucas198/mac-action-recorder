import MacActionRecorderCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renaming: Recording?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved macros")
                    .font(.headline)
                Spacer()
                Text("\(model.recordings.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if model.recordings.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing saved yet")
                        .foregroundStyle(.secondary)
                    Text("Recordings you make appear here and are saved automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.recordings) { recording in
                        LibraryRow(recording: recording, onRename: { renaming = recording })
                            .tag(recording.id)
                    }
                }
                .disabled(model.status.isBusy)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    model.importRecordings()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import a .macro.json file")

                Button {
                    model.exportSelected()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.current == nil)
                .help("Export the selected macro to a file you can copy to another Mac")

                Button {
                    model.duplicateSelected()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(model.current == nil || model.status.isBusy)
                .help("Duplicate the selected macro")
            }
            .labelStyle(.iconOnly)
            .padding(8)
        }
        .sheet(item: $renaming) { recording in
            RenameSheet(recording: recording)
        }
    }
}

struct LibraryRow: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(recording.name)
                        .lineLimit(1)
                    if model.unsavedIDs.contains(recording.id) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                }
                Text("\(Fmt.actionCount(recording.actions.count)) · \(Fmt.duration(recording.originalDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.selectedID = recording.id
                model.play()
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.status.isBusy || recording.actions.isEmpty)
            .help("Play this macro with its saved settings")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Rename…") { onRename() }
            Button("Duplicate") {
                model.selectedID = recording.id
                model.duplicateSelected()
            }
            Button("Export…") {
                model.selectedID = recording.id
                model.exportSelected()
            }
            Divider()
            Button("Delete…", role: .destructive) { model.delete(recording.id) }
        }
    }
}

struct RenameSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let recording: Recording
    @State private var name: String

    init(recording: Recording) {
        self.recording = recording
        _name = State(initialValue: recording.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename macro")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commit() {
        model.rename(recording.id, to: name)
        dismiss()
    }
}
