import MacActionRecorderCore
import SwiftUI

/// Ordered list of the selected macro's actions with editing tools.
struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<UUID>()
    @State private var editing: MacroAction?
    @State private var showWaitSheet = false
    @State private var showPresetSheet = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let recording = model.current {
                if recording.actions.isEmpty {
                    Text("This macro has no actions. Insert a delay or a preset, or record again.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    actionList(recording)
                }
            }
        }
        .sheet(item: $editing) { action in
            ActionEditSheet(action: action)
        }
        .sheet(isPresented: $showWaitSheet) {
            InsertWaitSheet(afterID: insertionPoint)
        }
        .sheet(isPresented: $showPresetSheet) {
            PresetSheet(afterID: insertionPoint)
        }
        .onChange(of: model.selectedID) { _ in
            selection = []
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text("Actions")
                .font(.headline)
            Spacer()

            Group {
                Button {
                    editSelected()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(selection.count != 1)
                .help("Edit the selected action (or double-click it)")

                Button {
                    model.duplicateActions(selection)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(selection.isEmpty)
                .help("Duplicate the selected actions")

                Button {
                    model.deleteActions(selection)
                    selection = []
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .help("Delete the selected actions (Delete key)")

                Button {
                    model.moveUp(selection)
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                .disabled(selection.isEmpty)
                .help("Move the selected actions up")

                Button {
                    model.moveDown(selection)
                } label: {
                    Label("Move down", systemImage: "arrow.down")
                }
                .disabled(selection.isEmpty)
                .help("Move the selected actions down")

                Button {
                    showWaitSheet = true
                } label: {
                    Label("Insert delay", systemImage: "timer")
                }
                .help("Insert a delay after the selected action (or at the end)")

                Button {
                    showPresetSheet = true
                } label: {
                    Label("Insert preset", systemImage: "text.badge.plus")
                }
                .help("Insert keyboard-only Discord steps")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.canEdit)

            Divider().frame(height: 16)

            Button {
                model.playSelection(ids: selection)
            } label: {
                Label("Play selection", systemImage: "play.rectangle")
            }
            .labelStyle(.iconOnly)
            .disabled(selection.isEmpty || model.status.isBusy)
            .help("Replay only the section from the first to the last selected action")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: List

    private func actionList(_ recording: Recording) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(Array(recording.actions.enumerated()), id: \.element.id) { pair in
                    ActionRow(
                        index: pair.offset,
                        action: pair.element,
                        isCurrent: model.currentActionIndex == pair.offset
                    )
                    .tag(pair.element.id)
                    .onTapGesture(count: 2) {
                        if model.canEdit { editing = pair.element }
                    }
                    .contextMenu {
                        Button("Edit…") { editing = pair.element }
                        Button("Duplicate") { model.duplicateActions([pair.element.id]) }
                        Button("Delete", role: .destructive) { model.deleteActions([pair.element.id]) }
                        Divider()
                        Button("Play from here") {
                            model.play(range: pair.offset..<recording.actions.count)
                        }
                    }
                }
                .onMove { source, destination in
                    model.moveActions(from: source, to: destination)
                }
            }
            .onDeleteCommand {
                if model.canEdit {
                    model.deleteActions(selection)
                    selection = []
                }
            }
            .onChange(of: model.currentActionIndex) { index in
                guard let index = index, recording.actions.indices.contains(index) else { return }
                proxy.scrollTo(recording.actions[index].id, anchor: .center)
            }
        }
    }

    // MARK: Helpers

    private var insertionPoint: UUID? {
        guard let recording = model.current else { return nil }
        return recording.actions.last(where: { selection.contains($0.id) })?.id
    }

    private func editSelected() {
        guard selection.count == 1, let id = selection.first,
              let action = model.current?.actions.first(where: { $0.id == id }) else { return }
        editing = action
    }
}

struct ActionRow: View {
    let index: Int
    let action: MacroAction
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(ActionDescriber.describe(action))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if action.delay > 0.0005 {
                Text("+" + ActionDescriber.formatSeconds(action.delay))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch action.kind {
        case .move: return "cursorarrow.motionlines"
        case .drag: return "hand.draw"
        case .mouseDown: return "arrow.down.to.line"
        case .mouseUp: return "arrow.up.to.line"
        case .click: return "cursorarrow.click"
        case .scroll: return "arrow.up.and.down"
        case .key: return "command"
        case .text: return "keyboard"
        case .wait: return "timer"
        }
    }
}

// MARK: - Edit sheet

struct ActionEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MacroAction

    init(action: MacroAction) {
        _draft = State(initialValue: action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.kind.displayName)
                .font(.headline)

            Form {
                fields
                TextField("Delay before (seconds)", value: $draft.delay, format: .number.precision(.fractionLength(0...3)))
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.updateAction(draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .move, .drag:
            coordinateFields
        case .mouseDown, .mouseUp:
            coordinateFields
            buttonPicker
        case .click:
            coordinateFields
            buttonPicker
            Picker("Clicks", selection: intBinding(\.clickCount, fallback: 1)) {
                Text("Single").tag(1)
                Text("Double").tag(2)
                Text("Triple").tag(3)
            }
        case .scroll:
            TextField("Horizontal (pixels)", value: intBinding(\.scrollX, fallback: 0), format: .number)
            TextField("Vertical (pixels)", value: intBinding(\.scrollY, fallback: 0), format: .number)
        case .key:
            keyFields
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text("Text to type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: textBinding)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                Text("A line break is typed as Shift+Return (a new line, not send).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .wait:
            TextField("Wait (seconds)", value: doubleBinding(\.duration, fallback: 0), format: .number.precision(.fractionLength(0...3)))
        }
    }

    @ViewBuilder
    private var coordinateFields: some View {
        TextField("X", value: doubleBinding(\.x, fallback: 0), format: .number.precision(.fractionLength(0...2)))
        TextField("Y", value: doubleBinding(\.y, fallback: 0), format: .number.precision(.fractionLength(0...2)))
    }

    private var buttonPicker: some View {
        Picker("Button", selection: buttonBinding) {
            ForEach(MouseButton.allCases, id: \.self) { button in
                Text(button.displayName).tag(button)
            }
        }
    }

    @ViewBuilder
    private var keyFields: some View {
        TextField("Key code", value: intBinding(\.keyCode, fallback: 0), format: .number)
        LabeledContent("Key") {
            HStack {
                Text(KeyNames.name(for: draft.keyCode ?? -1))
                Menu("Common keys") {
                    commonKey("Return", KeyCodes.returnKey)
                    commonKey("Tab", KeyCodes.tab)
                    commonKey("Space", KeyCodes.space)
                    commonKey("Delete", KeyCodes.delete)
                    commonKey("Escape", KeyCodes.escape)
                    commonKey("Left arrow", KeyCodes.leftArrow)
                    commonKey("Right arrow", KeyCodes.rightArrow)
                    commonKey("Down arrow", KeyCodes.downArrow)
                    commonKey("Up arrow", KeyCodes.upArrow)
                    commonKey("K", KeyCodes.ansiK)
                }
            }
        }
        HStack {
            Toggle("⌃", isOn: modifierBinding(.control))
            Toggle("⌥", isOn: modifierBinding(.option))
            Toggle("⇧", isOn: modifierBinding(.shift))
            Toggle("⌘", isOn: modifierBinding(.command))
        }
    }

    private func commonKey(_ title: String, _ code: Int) -> some View {
        Button(title) { draft.keyCode = code }
    }

    // MARK: Bindings

    private func doubleBinding(_ keyPath: WritableKeyPath<MacroAction, Double?>, fallback: Double) -> Binding<Double> {
        return Binding(
            get: { draft[keyPath: keyPath] ?? fallback },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<MacroAction, Int?>, fallback: Int) -> Binding<Int> {
        return Binding(
            get: { draft[keyPath: keyPath] ?? fallback },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    private var textBinding: Binding<String> {
        return Binding(
            get: { draft.text ?? "" },
            set: { draft.text = $0 }
        )
    }

    private var buttonBinding: Binding<MouseButton> {
        return Binding(
            get: { draft.button ?? .left },
            set: { draft.button = $0 }
        )
    }

    private func modifierBinding(_ flag: KeyModifiers) -> Binding<Bool> {
        return Binding(
            get: { (draft.modifiers ?? []).contains(flag) },
            set: { isOn in
                var modifiers = draft.modifiers ?? []
                if isOn { modifiers.insert(flag) } else { modifiers.remove(flag) }
                draft.modifiers = modifiers
            }
        )
    }
}

// MARK: - Insert sheets

struct InsertWaitSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let afterID: UUID?
    @State private var seconds = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert delay")
                .font(.headline)
            TextField("Seconds", value: $seconds, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
            Text(afterID == nil ? "The delay is added at the end." : "The delay is added after the selected action.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") {
                    model.insertWait(seconds: seconds, after: afterID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

struct PresetSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let afterID: UUID?
    @State private var presetID = Presets.all.first?.id ?? ""
    @State private var input = ""
    @State private var secondInput = ""

    private var preset: Presets.Info? {
        return Presets.all.first { $0.id == presetID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Discord preset")
                .font(.headline)

            Picker("Preset", selection: $presetID) {
                ForEach(Presets.all) { item in
                    Text(item.title).tag(item.id)
                }
            }

            if let preset = preset {
                Text(preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let label = preset.inputLabel {
                    TextField(label, text: $input)
                        .textFieldStyle(.roundedBorder)
                }
                if let label = preset.secondInputLabel {
                    TextField(label, text: $secondInput)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("Presets use Discord's keyboard shortcuts and contain no screen coordinates. Discord may change its shortcuts, so check the result with a slow test run.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") {
                    model.insertPreset(presetID, input: input, secondInput: secondInput, after: afterID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(input.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
