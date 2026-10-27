import AppKit
import Combine
import Foundation
import MacActionRecorderCore

/// Sets the app up on this Mac and keeps it tidy, with a progress screen that shows every step.
///
/// Part 1 runs in whatever copy was opened (for example the one on the downloaded disk image):
/// close other copies, copy, sign for this Mac, move into Applications, reopen.
/// Part 2 runs in the copy in Applications after it reopens: eject old installer disks, move other
/// copies to the Trash, and clear permission entries that belong to an older signature.
/// When the app is already installed and signed, only part 2 runs, quietly, at each launch.
final class SetupManager: ObservableObject {
    static let shared = SetupManager()

    enum Phase: Equatable {
        case idle
        case running
        /// Everything finished in this copy (it is installed and tidy).
        case finished
        case failed(String)
    }

    struct CompletedStep: Identifiable, Equatable {
        let step: SetupStep
        let seconds: Double
        let note: String?
        var id: Int { return step.rawValue }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentStep: SetupStep?
    @Published private(set) var completed: [CompletedStep] = []
    /// 0...1 for the bar.
    @Published private(set) var progress: Double = 0
    /// Seconds spent in the current step.
    @Published private(set) var stepElapsed: Double = 0
    /// The latest line a helper tool printed, so it is visible that something is happening.
    @Published private(set) var liveLine: String?
    /// Plain-language results of the tidy-up, shown once.
    @Published private(set) var results: [String] = []
    /// Shown after a run that could not create the certificate but left the app usable.
    @Published private(set) var note: String?
    /// True once this copy is installed and needs nothing more.
    @Published private(set) var isDone: Bool

    /// The steps this run will go through, for the list on screen.
    @Published private(set) var plannedSteps: [SetupStep] = []

    private static let continuationKey = "setupContinuation"
    private static let completedKey = "setupCompletedSteps"

    private var stepStartedAt = Date()
    private var signingProcess: Process?
    private var skippedSigning = false

    /// True while signing waits long enough that the user may want to go on without it.
    var canSkipSigning: Bool {
        return currentStep == .signing && signingProcess != nil && stepElapsed > 30
    }

    /// Stops waiting for signing (for example when a macOS password prompt cannot be answered)
    /// and installs the app without the local signature.
    func skipSigning() {
        guard let process = signingProcess, process.isRunning else { return }
        skippedSigning = true
        liveLine = "Skipping the signature…"
        process.terminate()
    }
    private var ticker: Timer?

    private init() {
        isDone = !InstallDoctor.needsSetup
    }

    var isWorking: Bool {
        return phase == .running
    }

    /// True when this launch is the second half of a setup that reopened the app.
    var isContinuing: Bool {
        return UserDefaults.standard.bool(forKey: SetupManager.continuationKey)
    }

    // MARK: Launch

    /// Called once at launch, after duplicates were dealt with. Decides whether the setup screen is
    /// needed and starts what can start by itself.
    func launchCheck(model: AppModel) {
        guard InstallDoctor.isAppBundle else { return }
        let defaults = UserDefaults.standard
        if isContinuing {
            model.showSetupScreen()
            if InstallDoctor.needsSetup {
                // The reopened copy is still not installed and signed: replacing the app did not
                // work. Stop here instead of trying again and again.
                defaults.removeObject(forKey: SetupManager.continuationKey)
                defaults.removeObject(forKey: SetupManager.completedKey)
                phase = .failed("The app in Applications could not be replaced with the prepared copy (" + InstallDoctor.selfPath + "). Quit the app, drag it from the disk image onto Applications yourself and choose Replace, then open it from Applications.")
                return
            }
            continueAfterReopen()
        } else if InstallDoctor.needsSetup {
            // A returning user who opened a new download: finish it without asking again, but only
            // once for the same copy, so a setup that cannot succeed never repeats by itself.
            let attemptKey = "autoSetupAttempt"
            let thisCopy = InstallDoctor.selfPath + "|" + InstallDoctor.requirement
            if model.settings.hasCompletedWelcome && defaults.string(forKey: attemptKey) != thisCopy {
                defaults.set(thisCopy, forKey: attemptKey)
                model.showSetupScreen()
                run()
            } else {
                model.showingWelcome = true
                if model.settings.hasCompletedWelcome { model.welcomeStartsOnSetup = true }
            }
        } else {
            quietMaintenance(model: model)
        }
    }

    /// Ejects old disks, trashes duplicates and repairs permission entries in the background.
    /// Says what it did (if anything) in a notice.
    private func quietMaintenance(model: AppModel) {
        DispatchQueue.global(qos: .utility).async {
            let ejected = InstallDoctor.ejectOldDiskImages()
            let moved = InstallDoctor.trashOtherCopies()
            let repaired = InstallDoctor.repairPermissionsIfNeeded()
            let messages = SetupManager.describe(ejected: ejected, moved: moved, repaired: repaired)
            DispatchQueue.main.async {
                model.refreshPermissions()
                if !messages.isEmpty {
                    model.showNotice(messages.joined(separator: " "))
                }
            }
        }
    }

    // MARK: Part 1

    /// Installs and signs this copy, then reopens from Applications.
    func run() {
        guard !isWorking else { return }
        if AppModel.shared.status.isBusy {
            phase = .failed("Finish or stop the current recording or playback first.")
            return
        }
        guard InstallDoctor.isAppBundle else {
            phase = .failed("Setup works only in the downloaded app, not in a development build.")
            return
        }
        guard InstallDoctor.needsSetup else {
            // Nothing to install: just tidy up with the progress screen.
            startTidyUp(resuming: false)
            return
        }
        phase = .running
        note = nil
        results = []
        completed = []
        plannedSteps = [.checking, .closingOthers, .copying, .signing, .installing, .reopening, .ejecting, .removingCopies, .permissions]
        startTicker()

        begin(.checking)
        let destination = InstallDoctor.destination
        liveLine = "This copy is " + SetupManager.describe(location: InstallDoctor.location) + "."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.isWorking else { return }
            self.finish(.checking, note: "Will install to " + destination.deletingLastPathComponent().path)
            self.closeOthers(destination: destination)
        }
    }

    private func closeOthers(destination: URL) {
        begin(.closingOthers)
        InstallDoctor.closeOtherInstances(timeout: 4) { [weak self] count in
            guard let self = self, self.isWorking else { return }
            self.finish(.closingOthers, note: count == 0 ? "None were running" : "Closed \(count)")
            self.copy(destination: destination)
        }
    }

    private func copy(destination: URL) {
        begin(.copying)
        AppInstaller.makeWorkingCopy { [weak self] result in
            guard let self = self, self.isWorking else { return }
            switch result {
            case .failure(let error):
                self.fail(error.localizedDescription)
            case .success(let copy):
                self.finish(.copying, note: nil)
                self.sign(copy: copy, destination: destination)
            }
        }
    }

    private func sign(copy: URL, destination: URL) {
        begin(.signing)
        skippedSigning = false
        signingProcess = AppInstaller.prepare(copy, onLine: { [weak self] line in
            self?.liveLine = SetupManager.friendly(line)
        }, completion: { [weak self] result in
            guard let self = self, self.isWorking else { return }
            self.signingProcess = nil
            // Skipping stops the script; carry on with the copy as it is.
            let outcome: AppInstaller.PrepareResult = self.skippedSigning ? .unsigned : result
            switch outcome {
            case .failed(let message):
                self.fail(message.isEmpty ? "Signing the app failed." : message)
                return
            case .unsigned:
                AppInstaller.signingUnavailable = true
                self.finish(.signing, note: self.skippedSigning ? "Skipped" : "Not possible on this Mac; permissions may need switching on again after updates")
                self.note = "A signing certificate could not be created on this Mac. The app works, but macOS may forget its permissions after each update."
                if InstallDoctor.location.isInstalled {
                    // Nothing to move: carry on with the tidy-up here.
                    self.plannedSteps.removeAll { $0 == .installing || $0 == .reopening }
                    self.startTidyUp(resuming: true)
                    return
                }
                if self.skippedSigning {
                    // The stopped script may have left the copy half-signed: start from a fresh copy.
                    AppInstaller.makeWorkingCopy { [weak self] fresh in
                        guard let self = self, self.isWorking else { return }
                        switch fresh {
                        case .success(let clean): self.install(copy: clean, destination: destination)
                        case .failure(let error): self.fail(error.localizedDescription)
                        }
                    }
                    return
                }
            case .signed:
                AppInstaller.signingUnavailable = false
                self.finish(.signing, note: "Signed with this Mac's certificate")
            }
            self.install(copy: copy, destination: destination)
        })
    }

    private func install(copy: URL, destination: URL) {
        begin(.installing)
        liveLine = "Replacing " + destination.path
        // Remember the finished steps so the reopened app can show them and carry on.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: SetupManager.continuationKey)
        defaults.set(completed.map { $0.step.rawValue }, forKey: SetupManager.completedKey)
        // Give the screen a moment to show the step before the app closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            self.finish(.installing, note: nil)
            self.begin(.reopening)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                do {
                    try AppInstaller.swapAndRelaunch(staged: copy, destination: destination)
                } catch {
                    defaults.removeObject(forKey: SetupManager.continuationKey)
                    self?.fail(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Part 2

    /// Runs in the reopened copy in Applications.
    func continueAfterReopen() {
        let defaults = UserDefaults.standard
        let done = (defaults.array(forKey: SetupManager.completedKey) as? [Int] ?? []).compactMap(SetupStep.init(rawValue:))
        defaults.removeObject(forKey: SetupManager.continuationKey)
        defaults.removeObject(forKey: SetupManager.completedKey)
        completed = done.map { CompletedStep(step: $0, seconds: 0, note: nil) }
        if !completed.contains(where: { $0.step == .installing }) {
            completed.append(CompletedStep(step: .installing, seconds: 0, note: nil))
        }
        completed.append(CompletedStep(step: .reopening, seconds: 0, note: "Now running from " + InstallDoctor.selfURL.deletingLastPathComponent().path))
        plannedSteps = SetupStep.allCases
        startTidyUp(resuming: true)
    }

    /// Ejects old disk images, moves other copies to the Trash and clears stale permission entries,
    /// one visible step at a time.
    private func startTidyUp(resuming: Bool) {
        phase = .running
        if !resuming {
            completed = []
            plannedSteps = [.ejecting, .removingCopies, .permissions]
            results = []
        }
        startTicker()

        begin(.ejecting)
        background({ InstallDoctor.ejectOldDiskImages() }) { [weak self] ejected in
            guard let self = self else { return }
            self.finish(.ejecting, note: ejected.isEmpty ? "None were open" : "Ejected " + ejected.joined(separator: ", "))
            self.begin(.removingCopies)
            self.background({ InstallDoctor.trashOtherCopies() }) { [weak self] moved in
                guard let self = self else { return }
                self.finish(.removingCopies, note: moved.isEmpty ? "No other copies found" : "Moved \(moved.count) to the Trash")
                self.begin(.permissions)
                self.background({ InstallDoctor.repairPermissionsIfNeeded() }) { [weak self] repaired in
                    guard let self = self else { return }
                    self.finish(.permissions, note: repaired ? "Old entries removed" : "Nothing to clear")
                    self.results = SetupManager.describe(ejected: ejected, moved: moved, repaired: repaired)
                    self.complete()
                }
            }
        }
    }

    private func complete() {
        stopTicker()
        currentStep = nil
        liveLine = nil
        progress = 1
        phase = .finished
        isDone = !InstallDoctor.needsSetup
        AppModel.shared.refreshPermissions()
    }

    // MARK: Step bookkeeping

    private func begin(_ step: SetupStep) {
        currentStep = step
        stepStartedAt = Date()
        stepElapsed = 0
        progress = max(progress, step.range.lowerBound)
        if step != .checking && step != .signing { liveLine = nil }
    }

    private func finish(_ step: SetupStep, note: String?) {
        let seconds = Date().timeIntervalSince(stepStartedAt)
        completed.removeAll { $0.step == step }
        completed.append(CompletedStep(step: step, seconds: seconds, note: note))
        progress = max(progress, step.range.upperBound)
    }

    private func fail(_ message: String) {
        stopTicker()
        currentStep = nil
        phase = .failed(message)
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let step = self.currentStep else { return }
            self.stepElapsed = Date().timeIntervalSince(self.stepStartedAt)
            self.progress = max(self.progress, step.fraction(afterSeconds: self.stepElapsed))
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func background<T>(_ work: @escaping () -> T, then: @escaping (T) -> Void) {
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            // Keep each step on screen long enough to be read.
            let wait = max(0, 0.6 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { then(value) }
        }
    }

    // MARK: Screenshots

    /// Shows a made-up moment of the setup, for the screenshot run in CI only.
    func simulateForScreenshots(step: SetupStep?, done: [SetupStep], finished: Bool, installed: Bool) {
        stopTicker()
        plannedSteps = SetupStep.allCases
        completed = done.map { CompletedStep(step: $0, seconds: 0.4 + Double($0.rawValue) * 0.3, note: nil) }
        currentStep = step
        isDone = installed
        if let step = step {
            phase = .running
            stepElapsed = 3
            progress = step.fraction(afterSeconds: 3)
            liveLine = "Signing the app with \"Mac Action Recorder Local Signing\""
        } else if finished {
            phase = .finished
            progress = 1
            results = ["Ejected 3 old installer disks.", "Moved 1 other copy of the app to the Trash (from /Users/you/Downloads)."]
        } else {
            phase = .idle
            progress = 0
            results = []
        }
    }

    // MARK: Text

    static func describe(location: Installation.Location) -> String {
        switch location {
        case .applications: return "in Applications"
        case .volume: return "on the downloaded disk image"
        case .translocated: return "running from a temporary download location"
        case .elsewhere: return "outside Applications"
        }
    }

    static func describe(ejected: [String], moved: [String], repaired: Bool) -> [String] {
        var lines: [String] = []
        if !ejected.isEmpty {
            lines.append("Ejected \(ejected.count) old installer disk\(ejected.count == 1 ? "" : "s").")
        }
        if !moved.isEmpty {
            let names = moved.map { ($0 as NSString).deletingLastPathComponent }.joined(separator: ", ")
            lines.append("Moved \(moved.count) other cop\(moved.count == 1 ? "y" : "ies") of the app to the Trash (from \(names)).")
        }
        if repaired {
            lines.append("Cleared old permission entries: switch Input Monitoring and Accessibility on again for this copy.")
        }
        return lines
    }

    /// Turns a helper script line into something readable.
    static func friendly(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("==> ") { text.removeFirst(4) }
        if text.hasPrefix("note: ") { text.removeFirst(6) }
        if text.contains("replacing existing signature") { return "Replacing the downloaded signature" }
        return text
    }
}
