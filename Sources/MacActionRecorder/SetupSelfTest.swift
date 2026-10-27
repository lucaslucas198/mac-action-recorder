import AppKit
import Foundation
import MacActionRecorderCore

/// CI only: runs the real setup end to end. The CI job opens the app from a mounted disk image with
/// `--selftest-setup <report file>`. That copy runs setup as if Get Started had been clicked: it
/// copies, signs, installs into Applications and reopens. The reopened copy carries on (ejects the
/// disk, tidies up) and, when it is done, writes a report and a picture of its window, then quits.
/// The report path travels between the two copies in the app's preferences.
enum SetupSelfTest {
    private static let reportKey = "selftestSetupReport"

    /// Called at launch with the command line. Returns true when the first half was started.
    static func startIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest-setup"), index + 1 < args.count else { return false }
        UserDefaults.standard.set(args[index + 1], forKey: reportKey)
        UserDefaults.standard.synchronize()
        AppModel.shared.showingWelcome = true
        AppModel.shared.welcomeStartsOnSetup = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SetupManager.shared.run()
        }
        return true
    }

    /// Called when setup finishes or fails. In a self-test run, writes the report and quits.
    static func finishIfRunning(_ setup: SetupManager) {
        guard let path = UserDefaults.standard.string(forKey: reportKey) else { return }
        // Let the screen show the final state before it is pictured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var lines: [String] = []
            lines.append("Running from: " + InstallDoctor.selfPath)
            lines.append("Location: \(InstallDoctor.location)")
            lines.append("Signature: " + InstallDoctor.requirement)
            lines.append("Phase: \(setup.phase)")
            lines.append("Completed steps: " + setup.completed.map { "\($0.step.title) (\($0.note ?? "-"))" }.joined(separator: "; "))
            lines.append("Results: " + setup.results.joined(separator: " "))
            lines.append("Needs setup now: \(InstallDoctor.needsSetup)")
            let report = URL(fileURLWithPath: path)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 500 }),
               let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let picture = report.deletingPathExtension().appendingPathExtension("png")
                try? rep.representation(using: .png, properties: [:])?.write(to: picture)
                lines.append("Picture: " + picture.lastPathComponent)
            }
            UserDefaults.standard.removeObject(forKey: reportKey)
            UserDefaults.standard.synchronize()
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
            if case .failed = setup.phase { exit(1) }
            exit(0)
        }
    }
}
