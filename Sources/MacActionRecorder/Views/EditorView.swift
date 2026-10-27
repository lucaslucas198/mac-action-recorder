import MacActionRecorderCore
import SwiftUI

/// What the Add menu can create.
enum AddKind: String, Identifiable, CaseIterable {
    case click, doubleClick, rightClick, move, scroll, key, text, wait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .click: return "Click"
        case .doubleClick: return "Double-click"
        case .rightClick: return "Right-click"
        case .move: return "Move mouse"
        case .scroll: return "Scroll"
        case .key: return "Key press or shortcut"
        case .text: return "Type text"
        case .wait: return "Wait"
        }
    }

    var symbol: String {
        switch self {
        case .click: return "cursorarrow.click"
        case .doubleClick: return "cursorarrow.click.2"
        case .rightClick: return "contextualmenu.and.cursorarrow"
        case .move: return "cursorarrow.motionlines"
        case .scroll: return "arrow.up.and.down"
        case .key: return "command"
        case .text: return "keyboard"
        case .wait: return "timer"
        }
    }

    /// A starting action for the Add sheet. Mouse actions start at the pointer's current position.
    func makeAction() -> MacroAction {
        let point = Platform.pointerLocation() ?? CGPoint(x: 200, y: 200)
        let x = Double(point.x.rounded())
        let y = Double(point.y.rounded())
        switch self {
        case .click: return .click(x: x, y: y)
        case .doubleClick: return .click(x: x, y: y, count: 2)
        case .rightClick: return .click(x: x, y: y, button: .right)
        case .move: return .move(x: x, y: y)
        case .scroll: return .scroll(dx: 0, dy: -120)
        case .key: return .key(KeyCodes.returnKey)
        case .text: return .text("")
        case .wait: return .wait(1)
        }
    }
}

/// Ordered list of the selected macro's actions with editing tools.
struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<UUID>()
    @State private var editing: MacroAction?
    @State private var adding: AddKind?
    @State private var showPresetSheet = false
    @State private var showCheckSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolsRow
            Divider()
            if let recording = model.current {
                if recording.actions.isEmpty {
                    VStack(spacing: 6) {
                        Text("This macro has no actions yet.")
                            .font(.headline)
                        Text("Record again, or use Add to build one by hand.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    actionList(recording)
                }
            }
        }
        .sheet(item: $editing) { action in
            ActionEditSheet(action: action, mode: .edit)
        }
        .sheet(item: $adding) { kind in
            ActionEditSheet(action: kind.makeAction(), mode: .add(afterID: insertionPoint))
        }
        .sheet(isPresented: $showPresetSheet) {
            PresetSheet(afterID: insertionPoint)
        }
        .sheet(isPresented: $showCheckSheet) {
            MacroCheckSheet()
        }
        .onChange(of: model.selectedID) { _ in
            selection = []
        }
    }

    // MARK: Toolbar

    /// Title and the main tools. Every button has a text label, so none can be missed or clipped.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Actions")
                .font(.headline)
            if let count = model.current?.actions.count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Menu {
                ForEach(AddKind.allCases) { kind in
                    Button {
                        adding = kind
                    } label: {
                        Label(kind.title + "…", systemImage: kind.symbol)
                    }
                }
                Divider()
                Button {
                    showPresetSheet = true
                } label: {
                    Label("Discord preset…", systemImage: "text.badge.plus")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!model.canEdit || model.current == nil)
            .help("Add a click, key press, text, wait and more. It goes after the selected action, or at the end.")

            Button {
                showCheckSheet = true
            } label: {
                Label("Check", systemImage: "checkmark.shield")
            }
            .fixedSize()
            .disabled(model.current == nil)
            .help("Check this macro for common problems, get Discord tips, and optionally ask the on-device AI")

            Button {
                if !ClickPreview.shared.show(for: model.current ?? Recording(name: "")) {
                    model.showNotice("This macro has no clicks to show.")
                }
            } label: {
                Label("Show Clicks", systemImage: "scope")
            }
            .fixedSize()
            .disabled(model.current == nil)
            .help("Briefly draw numbered markers on screen where this macro will click, to see whether anything has moved")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Edit tools. Shows labels when there is room, otherwise falls back to icons.
    private var toolsRow: some View {
        ViewThatFits(in: .horizontal) {
            tools(showLabels: true)
            tools(showLabels: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .disabled(!model.canEdit)
    }

    private func tools(showLabels: Bool) -> some View {
        HStack(spacing: 6) {
            toolButton("Edit", "pencil", showLabels, enabled: selection.count == 1, help: "Edit the selected action (or double-click it)") {
                editSelected()
            }
            toolButton("Duplicate", "plus.square.on.square", showLabels, enabled: !selection.isEmpty, help: "Duplicate the selected actions") {
                model.duplicateActions(selection)
            }
            toolButton("Delete", "trash", showLabels, enabled: !selection.isEmpty, help: "Delete the selected actions (Delete key)") {
                model.deleteActions(selection)
                selection = []
            }
            Divider().frame(height: 14)
            toolButton("Up", "arrow.up", showLabels, enabled: !selection.isEmpty, help: "Move the selected actions up") {
                model.moveUp(selection)
            }
            toolButton("Down", "arrow.down", showLabels, enabled: !selection.isEmpty, help: "Move the selected actions down") {
                model.moveDown(selection)
            }
            Divider().frame(height: 14)
            toolButton("Play selection", "play.rectangle", showLabels, enabled: !selection.isEmpty && !model.status.isBusy,
                       help: "Replay only the section from the first to the last selected action") {
                model.playSelection(ids: selection)
            }
            Spacer(minLength: 0)
            Text(selection.isEmpty ? "Select actions to edit them" : "\(selection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func toolButton(
        _ title: String, _ symbol: String, _ showLabels: Bool, enabled: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if showLabels {
                Label(title, systemImage: symbol)
            } else {
                Image(systemName: symbol)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(title)
    }

    // MARK: List

    private func actionList(_ recording: Recording) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(Array(recording.actions.enumerated()), id: \.element.id) { pair in
                    ActionRow(
                        index: pair.offset,
                        action: pair.element,
                        isCurrent: model.currentActionIndex == pair.offset,
                        compact: model.settings.rowDensity == .compact,
                        showDelay: model.settings.showDelaysInList
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
    var compact = false
    var showDelay = true

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
            if showDelay && action.delay > 0.0005 {
                Text("+" + ActionDescriber.formatSeconds(action.delay))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, compact ? 0 : 3)
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
    enum Mode {
        case edit
        case add(afterID: UUID?)
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MacroAction
    let mode: Mode

    init(action: MacroAction, mode: Mode) {
        _draft = State(initialValue: action)
        self.mode = mode
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text((isAdding ? "Add " : "Edit ") + title)
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
                Button(isAdding ? "Add" : "Save") {
                    switch mode {
                    case .edit:
                        if model.updateAction(draft) { dismiss() }
                    case .add(let afterID):
                        if model.insertAction(draft, after: afterID) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var title: String {
        switch draft.kind {
        case .click:
            if (draft.clickCount ?? 1) >= 2 { return "double-click" }
            return (draft.button ?? .left) == .left ? "click" : "\(draft.button?.displayName.lowercased() ?? "") click"
        default:
            return draft.kind.displayName.lowercased()
        }
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
            heldKeys
        case .scroll:
            TextField("Horizontal (pixels)", value: intBinding(\.scrollX, fallback: 0), format: .number)
            TextField("Vertical (pixels)", value: intBinding(\.scrollY, fallback: 0), format: .number)
            Text("Positive and negative values scroll in opposite directions. Run it slowly once to check which way it goes.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        LabeledContent("Position") {
            Button {
                model.pickPoint { point in
                    guard let point = point else { return }
                    draft.x = Double(point.x.rounded())
                    draft.y = Double(point.y.rounded())
                }
            } label: {
                Label("Pick on screen", systemImage: "scope")
            }
            .help("Click anywhere on screen to fill in X and Y. This window hides for a moment.")
        }
    }

    /// Keys held while clicking (for example Shift+click).
    @ViewBuilder
    private var heldKeys: some View {
        LabeledContent("Hold while clicking") {
            HStack(spacing: 10) {
                Toggle("⌃", isOn: modifierBinding(.control))
                Toggle("⌥", isOn: modifierBinding(.option))
                Toggle("⇧", isOn: modifierBinding(.shift))
                Toggle("⌘", isOn: modifierBinding(.command))
            }
        }
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
