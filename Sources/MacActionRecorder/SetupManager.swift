import AppKit
import Combine
import Foundation

/// Runs the "Set Up This Mac" step of the Welcome screen: puts the app in Applications and signs it
/// with a certificate made on this Mac, so macOS permissions keep working after updates.
final class SetupManager: ObservableObject {
    static let shared = SetupManager()

    enum Phase: Equatable {
        case idle
        case working
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Shown after a run that could not create the certificate but left the app usable.
    @Published private(set) var note: String?

    private init() {}

    /// True once the app is in Applications with a fixed signature (or signing was tried and is
    /// not possible here).
    var isDone: Bool {
        return !AppInstaller.needsSetup
    }

    func run() {
        guard phase != .working else { return }
        if AppModel.shared.status.isBusy {
            phase = .failed("Finish or stop the current recording or playback first.")
            return
        }
        phase = .working
        note = nil

        AppInstaller.makeWorkingCopy { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            case .success(let copy):
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
                note = "A signing certificate could not be created on this Mac. The app works, but macOS may forget its permissions after each update; you would then switch them on again."
                return
            }
        case .signed:
            AppInstaller.signingUnavailable = false
        }

        do {
            try AppInstaller.swapAndRelaunch(staged: copy, destination: AppInstaller.destination)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
