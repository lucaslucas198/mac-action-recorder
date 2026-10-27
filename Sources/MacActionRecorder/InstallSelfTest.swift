import AppKit
import Foundation
import MacActionRecorderCore

/// CI only (`--selftest-install <work folder>`): runs the real install machinery on the runner and
/// writes a report. It checks that old disk images are found and ejected, that a copy gets signed
/// with the local certificate, that the swap helper waits for the old process and replaces the app,
/// and that the reopen helper waits too. It never opens another copy of the app.
enum InstallSelfTest {
    static var requestedFolder: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest-install"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func log(_ text: String) {
        lines.append(text)
        // Unbuffered, so nothing is lost if the run is stopped.
        FileHandle.standardOutput.write((text + "\n").data(using: .utf8) ?? Data())
    }

    private static func check(_ ok: Bool, _ what: String) {
        log((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    /// Runs the signing script and waits for it. Must be called off the main thread: the
    /// script's results are delivered on the main thread.
    private static func prepareAndWait(_ app: URL, onLine: @escaping (String) -> Void) -> AppInstaller.PrepareResult? {
        let done = DispatchSemaphore(value: 0)
        var result: AppInstaller.PrepareResult?
        DispatchQueue.main.async {
            AppInstaller.prepare(app, onLine: onLine) { outcome in
                result = outcome
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 90)
        return result
    }

    static func run(in work: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)

        log("App: " + InstallDoctor.selfPath)
        log("Location: \(InstallDoctor.location)")
        log("Requirement: " + InstallDoctor.requirement)
        log("Signature kind: \(InstallDoctor.signatureKind)")
        check(InstallDoctor.isAppBundle, "running as the app bundle with the expected bundle ID")

        // 1. Disk images.
        let info = InstallDoctor.run("/usr/bin/hdiutil", ["info", "-plist"])
        let points = info.output.map(Installation.diskImageMountPoints(fromHdiutilInfo:)) ?? []
        log("Mounted disk images: \(points)")
        let ours = points.filter { FileManager.default.fileExists(atPath: $0 + "/Mac Action Recorder.app/Contents/Info.plist") }
        check(!ours.isEmpty, "the test disk image with the app is listed by hdiutil")
        let ejected = InstallDoctor.ejectOldDiskImages()
        log("Ejected: \(ejected)")
        check(!ejected.isEmpty, "old disk images were ejected")
        for point in ours {
            check(!fm.fileExists(atPath: point + "/Mac Action Recorder.app"), "\(point) is no longer mounted")
        }

        // 2. Copy and sign.
        let staged = work.appendingPathComponent("staged/Mac Action Recorder.app")
        try? fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copied = InstallDoctor.run("/usr/bin/ditto", [InstallDoctor.selfPath, staged.path])
        check(copied.status == 0, "copied the app with ditto")
        var seenLines: [String] = []
        let signResult = prepareAndWait(staged) { line in
            seenLines.append(line)
            log("  script: " + line)
        }
        log("Signing result: \(String(describing: signResult)); lines seen: \(seenLines)")
        check(signResult == .signed, "the copy was signed with the local certificate")
        check(!seenLines.isEmpty, "the progress screen received live lines from the signing script")
        let stagedRequirement = Permissions.signatureRequirement(of: staged)
        log("Staged requirement: " + stagedRequirement)
        check(Installation.signatureKind(ofRequirement: stagedRequirement) == .certificate, "the signed copy has a fixed (certificate) requirement")

        // A second signing must give the same requirement, or permissions would not survive updates.
        let second = work.appendingPathComponent("second/Mac Action Recorder.app")
        try? fm.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = InstallDoctor.run("/usr/bin/ditto", [InstallDoctor.selfPath, second.path])
        let secondResult = prepareAndWait(second) { _ in }
        log("Second signing result: \(String(describing: secondResult))")
        check(secondResult == .signed && Permissions.signatureRequirement(of: second) == stagedRequirement, "signing again gives the same requirement (permissions survive updates)")

        // 3. Swap helper: waits for the old process, replaces the app, removes the staged copy.
        let dest = work.appendingPathComponent("Applications/Mac Action Recorder.app")
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = InstallDoctor.run("/usr/bin/ditto", [InstallDoctor.selfPath, dest.path])
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1.5"]
        try? sleeper.run()
        let started = Date()
        let swap = InstallDoctor.run(
            "/bin/sh",
            ["-c", Installation.swapScript, "sh", String(sleeper.processIdentifier), staged.path, dest.path, "--no-open"],
            timeout: 60
        )
        let waited = Date().timeIntervalSince(started)
        log(String(format: "Swap helper finished after %.2f s with status %d", waited, swap.status))
        check(waited >= 1.2, "the swap helper waited for the old process to quit")
        check(Permissions.signatureRequirement(of: dest) == stagedRequirement, "the app in the destination is the signed copy")
        check(!fm.fileExists(atPath: staged.path), "the staged copy was removed")
        check(!fm.fileExists(atPath: dest.path + ".new"), "no half-finished copy was left behind")

        // The installed, locally signed copy must start. Run its program directly so the
        // system's code-signature checks apply, and ask it only to print its version.
        let launched = InstallDoctor.run(dest.path + "/Contents/MacOS/MacActionRecorder", ["--print-version"], timeout: 60)
        let printed = launched.output.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        log("Signed copy said: " + printed.trimmingCharacters(in: .whitespacesAndNewlines) + " (status \(launched.status))")
        check(launched.status == 0 && printed.contains("Mac Action Recorder"), "the locally signed copy starts")
        let verify = InstallDoctor.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", dest.path])
        check(verify.status == 0, "codesign --verify accepts the locally signed copy")

        // 4. Reopen helper waits too.
        let sleeper2 = Process()
        sleeper2.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper2.arguments = ["1"]
        try? sleeper2.run()
        let started2 = Date()
        let reopen = InstallDoctor.run(
            "/bin/sh",
            ["-c", Installation.reopenScript, "sh", String(sleeper2.processIdentifier), dest.path, "20", "--no-open"],
            timeout: 30
        )
        let waited2 = Date().timeIntervalSince(started2)
        log(String(format: "Reopen helper finished after %.2f s with status %d", waited2, reopen.status))
        check(waited2 >= 0.8 && reopen.status == 0, "the reopen helper waited for the old process to quit")

        // 5. Other copies go to the Trash; the kept copy, the running copy and build output stay.
        let stray = work.appendingPathComponent("Downloads/Mac Action Recorder.app")
        try? fm.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = InstallDoctor.run("/usr/bin/ditto", [InstallDoctor.selfPath, stray.path])
        _ = InstallDoctor.run("/usr/bin/mdimport", [stray.path, dest.path])
        var moved: [String] = []
        for _ in 0..<20 where moved.isEmpty {
            Thread.sleep(forTimeInterval: 1)
            moved = InstallDoctor.trashCopies(keeping: dest.path)
        }
        log("Moved to the Trash: \(moved)")
        check(moved.contains { $0.hasSuffix("/Downloads/Mac Action Recorder.app") }, "a stray copy was moved to the Trash")
        check(!fm.fileExists(atPath: stray.path), "the stray copy is gone from its folder")
        check(fm.fileExists(atPath: dest.path), "the kept copy is still there")
        check(fm.fileExists(atPath: InstallDoctor.selfPath), "the running copy is still there")
        check(InstallDoctor.isSameItem("/System/Volumes/Data" + dest.path, dest.path) || !fm.fileExists(atPath: "/System/Volumes/Data" + dest.path),
              "a firmlinked path counts as the same copy")

        // 6. One copy at a time: a second copy started later quits and leaves the first one running.
        let fileA = work.appendingPathComponent("instance-a.txt")
        let fileB = work.appendingPathComponent("instance-b.txt")
        _ = InstallDoctor.run("/usr/bin/open", ["-n", "-g", dest.path, "--args", "--selftest-instance", fileA.path])
        for _ in 0..<40 where !fm.fileExists(atPath: fileA.path) { Thread.sleep(forTimeInterval: 0.25) }
        let firstSaid = (try? String(contentsOf: fileA, encoding: .utf8)) ?? "nothing"
        log("First copy: " + firstSaid)
        check(firstSaid == "stayed", "the first copy stays when it is the only one")
        let second = Process()
        second.executableURL = URL(fileURLWithPath: InstallDoctor.selfPath + "/Contents/MacOS/MacActionRecorder")
        second.arguments = ["--selftest-instance", fileB.path]
        try? second.run()
        let quitBy = Date().addingTimeInterval(15)
        while second.isRunning && Date() < quitBy { Thread.sleep(forTimeInterval: 0.2) }
        let secondSaid = (try? String(contentsOf: fileB, encoding: .utf8)) ?? "nothing"
        log("Second copy: " + secondSaid + (second.isRunning ? " (still running)" : " (quit)"))
        check(secondSaid == "quit" && !second.isRunning, "a second copy started later quits by itself")
        let firstStillRuns = !NSRunningApplication.runningApplications(withBundleIdentifier: Installation.bundleID)
            .filter { $0.bundleURL?.standardizedFileURL.path == dest.standardizedFileURL.path }.isEmpty
        check(firstStillRuns, "the first copy is still running")
        if second.isRunning { second.terminate() }

        // 7. Spotlight and the permission reset command run without errors.
        let found = InstallDoctor.run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(Installation.bundleID)'"])
        log("mdfind status \(found.status): " + (found.output.flatMap { String(data: $0, encoding: .utf8) } ?? "").replacingOccurrences(of: "\n", with: " | "))
        check(found.status == 0, "Spotlight search runs")
        let reset = InstallDoctor.run("/usr/bin/tccutil", ["reset", "All", Installation.bundleID])
        log("tccutil reset status: \(reset.status)")
        check(reset.status == 0, "tccutil reset for this app's bundle ID succeeds")

        log(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? lines.joined(separator: "\n").write(to: work.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
}
