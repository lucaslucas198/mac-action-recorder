import AppKit
import Combine
import MacActionRecorderCore
import UniformTypeIdentifiers

// MARK: - Supporting types

enum AppStatus: Equatable {
    case idle
    case recordingCountdown(Int)
    case recording
    case preparing(Int)
    case playing
    case paused
    case stopped(String)
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .recordingCountdown(let n): return "Recording in \(n)…"
        case .recording: return "Recording"
        case .preparing(let n): return n > 0 ? "Preparing playback (\(n))" : "Preparing playback"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }

    var detail: String? {
        if case .stopped(let text) = self, !text.isEmpty { return text }
        return nil
    }

    var isRecordingPhase: Bool {
        switch self {
        case .recordingCountdown, .recording: return true
        default: return false
        }
    }

    var isPlaybackPhase: Bool {
        switch self {
        case .preparing, .playing, .paused: return true
        default: return false
        }
    }

    var isBusy: Bool {
        return isRecordingPhase || isPlaybackPhase
    }
}

enum RepeatMode: String, CaseIterable, Identifiable {
    case once
    case times
    case infinite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .once: return "Once"
        case .times: return "Repeat"
        case .infinite: return "Loop until stopped"
        }
    }
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

/// Collapses the very frequent per-action progress events into a few UI updates per second,
/// so fast playback of long mouse paths does not flood the main thread.
private final class ProgressRelay {
    private let lock = NSLock()
    private var index: Int?
    private var progress: PlaybackProgress?
    private var scheduled = false
    var deliver: ((Int?, PlaybackProgress?) -> Void)?

    func update(index: Int? = nil, progress: PlaybackProgress? = nil) {
        lock.lock()
        if let index = index { self.index = index }
        if let progress = progress { self.progress = progress }
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        let latestIndex = index
        let latestProgress = progress
        index = nil
        progress = nil
        scheduled = false
        lock.unlock()
        deliver?(latestIndex, latestProgress)
    }
}

// MARK: - Model

/// The single source of truth for the UI. All methods are meant to be called on the main thread.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Settings and recordings
    @Published var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var recordings: [Recording] = []
    @Published var selectedID: UUID? {
        didSet {
            if oldValue != selectedID { selectionDidChange() }
        }
    }
    @Published private(set) var unsavedIDs: Set<UUID> = []
    @Published private(set) var loadIssues: [String] = []

    // Status
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var notice: Notice?

    // Playback controls for the selected recording
    @Published var speed = 1.0 {
        didSet { playbackSettingChanged() }
    }
    @Published var repeatMode: RepeatMode = .once {
        didSet { playbackSettingChanged() }
    }
    @Published var repeatCount = 1 {
        didSet { playbackSettingChanged() }
    }
    @Published var loopDelay = 0.0 {
        didSet { playbackSettingChanged() }
    }

    // Live information
    @Published private(set) var recordingElapsed = 0.0
    @Published private(set) var recordedEventCount = 0
    @Published private(set) var progress: PlaybackProgress?
    @Published private(set) var currentActionIndex: Int?
    @Published private(set) var iteration = 0
    @Published private(set) var totalIterations: Int?

    // Permissions
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false

    // Internals
    private let settingsStore: SettingsStore
    private var store: RecordingStore?
    private let recorder = EventRecorder()
    private let hotKeyMonitor = HotKeyMonitor()
    private let engine: PlaybackEngine
    private let relay = ProgressRelay()

    private var countdownTimer: Timer?
    private var elapsedTimer: Timer?
    private var permissionTimer: Timer?
    private var recordingStartedAt = 0.0
    private var saveItems: [UUID: DispatchWorkItem] = [:]
    private var settingsSaveItem: DispatchWorkItem?
    private var noticeItem: DispatchWorkItem?
    private var isApplyingDefaults = false
    private var didHideApp = false
    private var lastRange: Range<Int>?

    // MARK: Paths

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Mac Action Recorder", isDirectory: true)
    }

    var recordingsDirectory: URL {
        if let path = settings.saveDirectoryPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return AppModel.supportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    var backupDirectory: URL {
        if let path = settings.backupDirectoryPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return AppModel.supportDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: Init

    private init() {
        let settingsURL = AppModel.supportDirectory.appendingPathComponent("settings.json")
        let loadedStore = SettingsStore(fileURL: settingsURL)
        settingsStore = loadedStore
        settings = loadedStore.load()
        engine = PlaybackEngine(
            performer: MacEventPerformer(),
            frontmostBundleID: { Platform.bundleIDOfFrontmostApp() }
        )

        accessibilityGranted = Permissions.accessibilityGranted
        inputMonitoringGranted = Permissions.inputMonitoringGranted

        engine.onEvent = { [weak self] event in
            self?.receive(event)
        }
        relay.deliver = { [weak self] index, progress in
            self?.deliverProgress(index: index, progress: progress)
        }
        hotKeyMonitor.onTrigger = { [weak self] in
            self?.emergencyStop()
        }

        openStore()
        reloadRecordings()
        selectedID = recordings.first?.id
        applyDefaults(from: current)

        if settings.backupEnabled && !recordings.isEmpty {
            _ = try? store?.createBackup(into: backupDirectory, keep: settings.backupKeepCount)
        }

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: Derived values

    var current: Recording? {
        guard let id = selectedID else { return nil }
        return recordings.first { $0.id == id }
    }

    var canEdit: Bool {
        return !status.isBusy
    }

    var hotKeyText: String {
        return settings.emergencyStop.displayString
    }

    var speedDescription: String {
        return SpeedPreset.describe(PlaybackTiming.clampSpeed(speed))
    }

    var repeatDescription: String {
        switch repeatMode {
        case .once: return "Once"
        case .times: return "\(max(1, repeatCount))×"
        case .infinite: return "Until stopped"
        }
    }

    var currentDefaults: PlaybackDefaults {
        let count: Int
        switch repeatMode {
        case .once: count = 1
        case .times: count = max(1, repeatCount)
        case .infinite: count = 0
        }
        return PlaybackDefaults(speed: speed, repeatCount: count, loopDelay: loopDelay)
    }

    /// Estimated total playback time with the current controls, or nil when looping forever.
    var estimatedPlaybackSeconds: Double? {
        guard let recording = current else { return nil }
        return PlaybackTiming.estimatedTotal(of: recording.actions, config: makeConfig(for: recording, range: nil))
    }

    /// True when the main display size differs from the one the macro was recorded on.
    var screenMismatch: Bool {
        guard let recorded = current?.recordedScreen, let now = Platform.primaryScreenSize() else { return false }
        return abs(recorded.width - now.width) > 1 || abs(recorded.height - now.height) > 1
    }

    // MARK: Notices

    func showNotice(_ text: String, isError: Bool = false) {
        noticeItem?.cancel()
        notice = Notice(text: text, isError: isError)
        if !isError {
            let item = DispatchWorkItem { [weak self] in
                self?.notice = nil
            }
            noticeItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
        }
    }

    func dismissNotice() {
        noticeItem?.cancel()
        notice = nil
        if case .error = status {
            status = .idle
        }
    }

    private func fail(_ message: String) {
        status = .error(message)
        showNotice(message, isError: true)
    }

    // MARK: Permissions

    func refreshPermissions() {
        let accessibility = Permissions.accessibilityGranted
        let input = Permissions.inputMonitoringGranted
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if input != inputMonitoringGranted { inputMonitoringGranted = input }
    }

    // MARK: Recording

    func startRecording() {
        guard !status.isBusy else { return }
        refreshPermissions()
        guard Permissions.inputMonitoringGranted else {
            Permissions.requestInputMonitoring()
            fail("Recording needs the Input Monitoring permission. Enable Mac Action Recorder in System Settings > Privacy & Security > Input Monitoring (Settings > Permissions has a shortcut), then try again. You may need to quit and reopen the app afterwards.")
            return
        }

        if !settings.acknowledgedRecordingWarning {
            let accepted = confirm(
                title: "Before you record",
                message: "While recording, this app captures your mouse and keyboard activity in every app, including anything you type. That can include passwords or other private text. Recordings are stored only on this Mac unless you export them, and you can see the recording indicator at all times. macOS hides keystrokes typed into password fields from apps like this one, but do not rely on that: avoid typing secrets while recording.",
                confirmTitle: "Start Recording"
            )
            guard accepted else { return }
            settings.acknowledgedRecordingWarning = true
        }

        notice = nil
        if !startHotKeyMonitor() {
            showNotice("The emergency-stop shortcut (\(hotKeyText)) is unavailable. Use the Stop button or the menu bar item.")
        }

        let seconds = settings.recordingCountdown
        if seconds > 0 {
            beginRecordingCountdown(seconds)
        } else {
            beginRecording()
        }
    }

    private func beginRecordingCountdown(_ seconds: Int) {
        var remaining = seconds
        status = .recordingCountdown(remaining)
        hideAppIfWanted(settings.hideWindowWhileRecording)

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self.countdownTimer = nil
                self.beginRecording()
            } else {
                self.status = .recordingCountdown(remaining)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func beginRecording() {
        do {
            try recorder.start(options: settings.recording, ignoredHotKey: settings.emergencyStop)
        } catch {
            stopHotKeyMonitor()
            restoreAppIfHidden()
            fail(error.localizedDescription)
            return
        }
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        recordingElapsed = 0
        recordedEventCount = 0
        status = .recording
        hideAppIfWanted(settings.hideWindowWhileRecording)

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.recordingElapsed = ProcessInfo.processInfo.systemUptime - self.recordingStartedAt
            self.recordedEventCount = self.recorder.eventCount
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    func stopRecording() {
        switch status {
        case .recordingCountdown:
            countdownTimer?.invalidate()
            countdownTimer = nil
            stopHotKeyMonitor()
            restoreAppIfHidden()
            status = .stopped("Recording cancelled")
            return
        case .recording:
            break
        default:
            return
        }

        let output = recorder.stop()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        stopHotKeyMonitor()
        restoreAppIfHidden()

        let actions = RecordingBuilder.build(events: output.events, options: settings.recording)
        var warnings: [String] = []
        if output.secureInputSeen {
            warnings.append("Some keystrokes were not recorded because macOS Secure Input (for example a password field) was active.")
        }
        if output.truncated {
            warnings.append("The recording hit the maximum length and was cut off.")
        }

        guard !actions.isEmpty else {
            status = .stopped("Nothing was recorded")
            var message = "Nothing was recorded. Check that the recording options in Settings include what you did."
            if !warnings.isEmpty { message += " " + warnings.joined(separator: " ") }
            showNotice(message)
            return
        }

        let defaults = PlaybackDefaults(
            speed: settings.defaultSpeed,
            repeatCount: settings.defaultRepeatCount,
            loopDelay: settings.defaultLoopDelay
        )
        let recording = Recording(
            name: defaultName(),
            targetApp: output.targetApp,
            recordedScreen: Platform.primaryScreenSize(),
            playbackDefaults: defaults,
            actions: actions
        )
        recordings.insert(recording, at: 0)
        selectedID = recording.id
        markChanged(recording.id)
        status = .stopped("Recorded \(actions.count) actions")
        if !warnings.isEmpty {
            showNotice(warnings.joined(separator: " "))
        }
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Recording " + formatter.string(from: Date())
    }

    // MARK: Playback

    func play(range: Range<Int>? = nil, skipConfirmation: Bool = false) {
        guard !status.isBusy else { return }
        guard let recording = current else {
            showNotice("Select or record a macro first.")
            return
        }
        guard !recording.actions.isEmpty else {
            showNotice("This macro has no actions.")
            return
        }
        if let first = RecordingValidator.errors(in: RecordingValidator.validate(recording)).first {
            fail("This macro cannot be played. \(first.description)")
            return
        }

        refreshPermissions()
        guard Permissions.accessibilityGranted else {
            Permissions.requestAccessibility()
            fail("Playback needs the Accessibility permission. Enable Mac Action Recorder in System Settings > Privacy & Security > Accessibility (Settings > Permissions has a shortcut), then try again.")
            return
        }

        let config = makeConfig(for: recording, range: range)

        if !skipConfirmation {
            if config.infinite {
                let ok = confirm(
                    title: "Loop until stopped?",
                    message: "“\(recording.name)” will repeat continuously and keep clicking and typing until you stop it. Stop it with \(hotKeyText), the Stop button, or the menu bar item. Do not leave it running unattended.",
                    confirmTitle: "Start Loop"
                )
                guard ok else { return }
            } else if settings.confirmBeforePlay {
                let ok = confirm(
                    title: "Play “\(recording.name)”?",
                    message: "The macro will control your mouse and keyboard. Stop it any time with \(hotKeyText).",
                    confirmTitle: "Play"
                )
                guard ok else { return }
            }
            if screenMismatch, let recorded = recording.recordedScreen, let now = Platform.primaryScreenSize() {
                let ok = confirm(
                    title: "Screen size has changed",
                    message: "This macro was recorded on a \(Int(recorded.width))×\(Int(recorded.height)) display; the main display is now \(Int(now.width))×\(Int(now.height)). Recorded click positions are absolute and may land in the wrong place.",
                    confirmTitle: "Play Anyway"
                )
                guard ok else { return }
            }
        }

        if settings.verifyForeground && recording.targetApp == nil {
            showNotice("Foreground check skipped: this macro has no recorded target app.")
        }

        lastRange = range
        notice = notice?.isError == true ? nil : notice
        progress = nil
        currentActionIndex = nil
        iteration = 0
        totalIterations = nil
        status = config.countdown > 0 ? .preparing(config.countdown) : .playing

        if !startHotKeyMonitor() {
            showNotice("The emergency-stop shortcut (\(hotKeyText)) is unavailable. Use the menu bar item to stop playback.")
        }

        let hiding = settings.hideWindowDuringPlayback
        hideAppIfWanted(hiding)
        // Give macOS a moment to hand focus back to the previous app before the first
        // action (and the optional foreground check) runs.
        let delay = (hiding && config.countdown == 0) ? 0.4 : 0.0
        let launch: () -> Void = { [weak self] in
            guard let self = self, self.status.isPlaybackPhase else { return }
            do {
                try self.engine.start(recording: recording, config: config)
            } catch {
                self.finishPlayback(.error(error.localizedDescription))
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: launch)
        } else {
            launch()
        }
    }

    /// Plays from the first to the last of the given actions (contiguous section).
    func playSelection(ids: Set<UUID>) {
        guard let recording = current else { return }
        let indices = recording.actions.enumerated().filter { ids.contains($0.element.id) }.map { $0.offset }
        guard let first = indices.min(), let last = indices.max() else {
            play()
            return
        }
        play(range: first..<(last + 1))
    }

    func togglePause() {
        switch engine.state {
        case .paused:
            engine.resume()
        case .countdown, .playing:
            engine.pause()
        default:
            break
        }
        syncFromEngine()
    }

    func restart() {
        guard current != nil else { return }
        if status.isPlaybackPhase {
            engine.stop()
            finishPlayback(.stopped("Restarting"))
        }
        play(range: lastRange, skipConfirmation: true)
    }

    func stopPlayback() {
        engine.stop()
        finishPlayback(.stopped("Stopped"))
    }

    /// Stops whatever is running: a countdown, a recording or a playback.
    func emergencyStop() {
        if status.isRecordingPhase {
            stopRecording()
        } else if status.isPlaybackPhase {
            stopPlayback()
        }
    }

    private func finishPlayback(_ result: AppStatus) {
        stopHotKeyMonitor()
        restoreAppIfHidden()
        currentActionIndex = nil
        status = result
        if case .error(let message) = result {
            showNotice(message, isError: true)
        }
    }

    private func makeConfig(for recording: Recording, range: Range<Int>?) -> PlaybackConfig {
        var config = PlaybackConfig()
        config.speed = PlaybackTiming.clampSpeed(speed)
        switch repeatMode {
        case .once:
            config.repeatCount = 1
        case .times:
            config.repeatCount = max(1, repeatCount)
        case .infinite:
            config.repeatCount = 1
            config.infinite = true
        }
        config.loopDelay = max(0, loopDelay)
        config.countdown = settings.playbackCountdown
        config.minActionDelay = settings.minActionDelay
        config.typingCharDelay = settings.typingCharDelay
        if settings.verifyForeground, let target = recording.targetApp {
            config.requiredBundleID = target.bundleID
            config.requiredAppName = target.name
        }
        config.range = range
        return config
    }

    // MARK: Engine events

    private func receive(_ event: PlaybackEvent) {
        switch event {
        case .stateChanged:
            DispatchQueue.main.async { [weak self] in
                self?.syncFromEngine()
            }
        case .iterationStarted(let iteration, let total):
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.status.isPlaybackPhase else { return }
                self.iteration = iteration
                self.totalIterations = total
            }
        case .actionStarted(let index):
            relay.update(index: index)
        case .progress(let value):
            relay.update(index: value.actionIndex, progress: value)
        }
    }

    private func deliverProgress(index: Int?, progress value: PlaybackProgress?) {
        guard status.isPlaybackPhase else { return }
        if let index = index { currentActionIndex = index }
        if let value = value { progress = value }
    }

    /// The engine's own state is the source of truth; events only tell us to look again.
    /// This also makes late events from a previous run harmless.
    private func syncFromEngine() {
        guard status.isPlaybackPhase else { return }
        switch engine.state {
        case .countdown(let remaining):
            status = .preparing(remaining)
        case .playing:
            status = .playing
        case .paused:
            status = .paused
        case .finished:
            finishPlayback(.stopped("Finished"))
        case .failed(let message):
            finishPlayback(.error(message))
        case .stopped, .idle:
            break
        }
    }

    // MARK: Emergency-stop shortcut

    @discardableResult
    private func startHotKeyMonitor() -> Bool {
        return hotKeyMonitor.start(hotKey: settings.emergencyStop)
    }

    private func stopHotKeyMonitor() {
        hotKeyMonitor.stop()
    }

    // MARK: Window visibility

    private func hideAppIfWanted(_ wanted: Bool) {
        guard wanted, !didHideApp else { return }
        didHideApp = true
        NSApp.hide(nil)
    }

    private func restoreAppIfHidden() {
        guard didHideApp else { return }
        didHideApp = false
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Selection and playback defaults

    private func selectionDidChange() {
        progress = nil
        currentActionIndex = nil
        applyDefaults(from: current)
    }

    private func applyDefaults(from recording: Recording?) {
        let defaults = recording?.playbackDefaults ?? PlaybackDefaults(
            speed: settings.defaultSpeed,
            repeatCount: settings.defaultRepeatCount,
            loopDelay: settings.defaultLoopDelay
        )
        isApplyingDefaults = true
        speed = defaults.speed
        switch defaults.repeatCount {
        case 0:
            repeatMode = .infinite
            repeatCount = 1
        case 1:
            repeatMode = .once
            repeatCount = 1
        default:
            repeatMode = .times
            repeatCount = defaults.repeatCount
        }
        loopDelay = defaults.loopDelay
        isApplyingDefaults = false
    }

    private func playbackSettingChanged() {
        guard !isApplyingDefaults, let id = selectedID else { return }
        let defaults = currentDefaults
        guard let existing = recordings.first(where: { $0.id == id }), existing.playbackDefaults != defaults else {
            return
        }
        mutate(id) { $0.playbackDefaults = defaults }
    }

    // MARK: Editing

    private func mutate(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var copy = recordings[index]
        change(&copy)
        copy.modifiedAt = Date()
        recordings[index] = copy
        markChanged(id)
    }

    private func edit(_ change: (inout Recording) -> Void) {
        guard canEdit, let id = selectedID else { return }
        mutate(id, change)
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canEdit else { return }
        mutate(id) { $0.name = trimmed }
    }

    func setNotes(_ notes: String) {
        edit { $0.notes = notes.isEmpty ? nil : notes }
    }

    func deleteActions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        edit { $0.deleteActions(ids: ids) }
    }

    func duplicateActions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        edit { recording in _ = recording.duplicateActions(ids: ids) }
    }

    func moveActions(from source: IndexSet, to destination: Int) {
        edit { $0.moveActions(from: source, to: destination) }
    }

    func moveUp(_ ids: Set<UUID>) {
        edit { $0.moveUp(ids: ids) }
    }

    func moveDown(_ ids: Set<UUID>) {
        edit { $0.moveDown(ids: ids) }
    }

    func insertWait(seconds: Double, after id: UUID?) {
        let clamped = max(0, min(RecordingValidator.maxDelay, seconds.isFinite ? seconds : 0))
        edit { recording in _ = recording.insertWait(seconds: clamped, after: id) }
    }

    func insertPreset(_ presetID: String, input: String, secondInput: String, after id: UUID?) {
        let actions = Presets.actions(for: presetID, input: input, secondInput: secondInput)
        guard !actions.isEmpty else { return }
        edit { $0.insertActions(actions, after: id) }
    }

    /// Replaces one action with an edited copy, after checking that the values are valid.
    @discardableResult
    func updateAction(_ action: MacroAction) -> Bool {
        if let problem = RecordingValidator.errors(in: RecordingValidator.validate(action: action)).first {
            showNotice("That change was not applied. \(problem.description)", isError: true)
            return false
        }
        var applied = false
        edit { recording in applied = recording.replaceAction(action) }
        return applied
    }

    // MARK: Saving

    private func openStore() {
        do {
            store = try RecordingStore(directory: recordingsDirectory)
        } catch {
            store = nil
            showNotice("Recordings cannot be saved: \(error.localizedDescription)", isError: true)
        }
    }

    private func reloadRecordings() {
        guard let store = store else {
            recordings = []
            return
        }
        let result = store.loadAll()
        recordings = result.recordings
        loadIssues = result.failures.map { "\($0.url.lastPathComponent): \($0.error.localizedDescription)" }
        if !loadIssues.isEmpty {
            showNotice("\(loadIssues.count) recording file(s) could not be read and were skipped: \(loadIssues.joined(separator: "; "))")
        }
    }

    private func markChanged(_ id: UUID) {
        guard settings.autoSave else {
            unsavedIDs.insert(id)
            return
        }
        saveItems[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow(id)
        }
        saveItems[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    func saveNow(_ id: UUID) {
        saveItems[id]?.cancel()
        saveItems[id] = nil
        guard let store = store, let recording = recordings.first(where: { $0.id == id }) else { return }
        do {
            try store.save(recording)
            unsavedIDs.remove(id)
        } catch {
            unsavedIDs.insert(id)
            showNotice("Could not save “\(recording.name)”: \(error.localizedDescription)", isError: true)
        }
    }

    func saveAllUnsaved() {
        for id in unsavedIDs { saveNow(id) }
    }

    // MARK: Library actions

    func duplicateSelected() {
        guard canEdit, let recording = current, let store = store else { return }
        do {
            saveNow(recording.id)
            let copy = try store.duplicate(recording)
            recordings.insert(copy, at: 0)
            sortRecordings()
            selectedID = copy.id
        } catch {
            showNotice("Could not duplicate: \(error.localizedDescription)", isError: true)
        }
    }

    func delete(_ id: UUID) {
        guard canEdit, let recording = recordings.first(where: { $0.id == id }) else { return }
        let ok = confirm(
            title: "Delete “\(recording.name)”?",
            message: "The macro file will be permanently deleted from this Mac. Exported copies are not affected.",
            confirmTitle: "Delete",
            destructive: true
        )
        guard ok else { return }
        removeRecording(id)
    }

    private func removeRecording(_ id: UUID) {
        saveItems[id]?.cancel()
        saveItems[id] = nil
        unsavedIDs.remove(id)
        if let store = store, store.exists(id: id) {
            do {
                try store.delete(id: id)
            } catch {
                showNotice("Could not delete the file: \(error.localizedDescription)", isError: true)
                return
            }
        }
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings.remove(at: index)
        if selectedID == id {
            selectedID = recordings.indices.contains(index) ? recordings[index].id : recordings.last?.id
        }
    }

    func deleteAllRecordings() {
        guard canEdit, !recordings.isEmpty else { return }
        let ok = confirm(
            title: "Delete all \(recordings.count) recordings?",
            message: "Every saved macro will be permanently deleted from this Mac. Backups and exported files are not affected.",
            confirmTitle: "Delete All",
            destructive: true
        )
        guard ok else { return }
        for id in recordings.map({ $0.id }) { removeRecording(id) }
    }

    func importRecordings() {
        guard canEdit, let store = store else { return }
        let panel = NSOpenPanel()
        panel.title = "Import macros"
        panel.message = "Choose one or more .macro.json files exported from Mac Action Recorder."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let path = settings.exportDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        var imported = 0
        var failures: [String] = []
        for url in panel.urls {
            do {
                let recording = try store.importFile(at: url)
                recordings.append(recording)
                selectedID = recording.id
                imported += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        sortRecordings()
        if failures.isEmpty {
            showNotice("Imported \(imported) macro(s).")
        } else {
            showNotice("Imported \(imported). Skipped: \(failures.joined(separator: "; "))", isError: imported == 0)
        }
    }

    func exportSelected() {
        guard let recording = current, let store = store else { return }
        saveNow(recording.id)
        let panel = NSSavePanel()
        panel.title = "Export macro"
        panel.message = "The exported file contains every key you typed while recording, including any passwords. Only share it with people you trust."
        panel.allowedContentTypes = [.json]
        let safeName = recording.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = safeName + "." + RecordingFormat.fileExtension
        if let path = settings.exportDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(recording, to: url)
            settings.exportDirectoryPath = url.deletingLastPathComponent().path
            showNotice("Exported to \(url.path)")
        } catch {
            showNotice("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    func backupNow() {
        guard let store = store else { return }
        saveAllUnsaved()
        do {
            let folder = try store.createBackup(into: backupDirectory, keep: settings.backupKeepCount)
            showNotice("Backup saved to \(folder.path)")
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    func revealRecordingsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([recordingsDirectory])
    }

    func revealBackupsFolder() {
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([backupDirectory])
    }

    /// Lets the user choose a folder; returns its path, or nil if cancelled.
    func pickFolder(startingAt path: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let path = path {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func sortRecordings() {
        recordings.sort { $0.createdAt > $1.createdAt }
    }

    // MARK: Settings

    private func settingsDidChange(from old: AppSettings) {
        let clean = settings.sanitized()
        if clean != settings {
            settings = clean
        }

        settingsSaveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            do {
                try self.settingsStore.save(self.settings)
            } catch {
                self.showNotice("Could not save settings: \(error.localizedDescription)", isError: true)
            }
        }
        settingsSaveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)

        if old.saveDirectoryPath != settings.saveDirectoryPath, !status.isBusy {
            for id in Array(saveItems.keys) { saveNow(id) }
            openStore()
            reloadRecordings()
            selectedID = recordings.first?.id
            applyDefaults(from: current)
        }
        if old.emergencyStop != settings.emergencyStop, hotKeyMonitor.isRunning {
            startHotKeyMonitor()
        }
    }

    func resetSettings() {
        var fresh = AppSettings()
        fresh.acknowledgedRecordingWarning = settings.acknowledgedRecordingWarning
        settings = fresh
    }

    // MARK: Shutdown

    func shutdown() {
        if status.isRecordingPhase {
            stopRecording()
        }
        if status.isPlaybackPhase {
            engine.stop()
        }
        stopHotKeyMonitor()
        for id in Array(saveItems.keys) { saveNow(id) }
        if settings.autoSave { saveAllUnsaved() }
        settingsSaveItem?.cancel()
        try? settingsStore.save(settings)
    }

    // MARK: Alerts

    private func confirm(title: String, message: String, confirmTitle: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if destructive {
            alert.buttons.first?.hasDestructiveAction = true
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
