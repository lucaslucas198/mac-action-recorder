import AppKit
import Combine
import Foundation
import MacActionRecorderCore

/// Runs the "Set Up This Mac" step of the Welcome screen: puts the app in Applications and signs it
/// with a certificate made on this Mac, so macOS permissions keep working after updates.
final class SetupManager: ObservableObject {
    static let shared = SetupManager()

    enum Phase: Equatable {
        case idle
        case working(SetupStage)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Shown after a run that could not create the certificate but left the app usable.
    @Published private(set) var note: String?

    /// True once the app is in Applications with a fixed signature (or signing was tried and is
    /// not possible here). Worked out once (reading the signature is not free) and updated when
    /// a run finishes, instead of on every screen redraw.
    @Published private(set) var isDone: Bool

    private init() {
        isDone = !AppInstaller.needsSetup
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    func run() {
        guard !isWorking else { return }
        if AppModel.shared.status.isBusy {
            phase = .failed("Finish or stop the current recording or playback first.")
            return
        }
        phase = .working(.copying)
        note = nil

        AppInstaller.makeWorkingCopy { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            case .success(let copy):
                self.phase = .working(.signing)
                AppInstaller.prepare(copy) { [weak self] outcome in
                    self?.finish(copy: copy, outcome: outcome)
                }
            }
        }
    }

    private func finish(copy: URL, outcome: AppInstaller.PrepareResult) {
        switch outcome {
        case .failed(let message):
            phase = .failed(message.isEmpty ? "Setting up the app failed." : message)
            return
        case .unsigned:
            AppInstaller.signingUnavailable = true
            if AppInstaller.isInstalledInApplications {
                // Nothing to move and nothing to sign with: keep the app as it is.
                phase = .idle
                isDone = true
                note = "A signing certificate could not be created on this Mac. The app works, but macOS may forget its permissions after each update; you would then switch them on again."
                return
            }
        case .signed:
            AppInstaller.signingUnavailable = false
        }

        phase = .working(.installing)
        do {
            try AppInstaller.swapAndRelaunch(staged: copy, destination: AppInstaller.destination)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
