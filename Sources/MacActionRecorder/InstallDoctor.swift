import AppKit
import CoreServices
import Foundation
import MacActionRecorderCore

/// Keeps exactly one working copy of the app on this Mac.
///
/// - Only one copy runs at a time (`resolveDuplicateInstancesAtLaunch`).
/// - Old installer disk images are ejected and other copies are moved to the Trash, so macOS can
///   never open an outdated copy by mistake (`ejectOldDiskImages`, `trashOtherCopies`).
/// - When the app's signature changed and the permissions stopped working, the stale entries in
///   System Settings are removed so the switches work again (`repairPermissionsIfNeeded`).
/// - "Quit and Reopen" waits for this copy to quit before opening the installed one (`relaunch`).
///
/// Every command it runs is a fixed macOS tool with fixed arguments (hdiutil, mdfind, tccutil, open).
enum InstallDoctor {
    private static let grantedRequirementKey = "grantedSignatureRequirement"
    private static let permissionCleanupDoneKey = "permissionEntriesCleanedOnce"

    static var selfURL: URL { return Bundle.main.bundleURL.standardizedFileURL }
    static var selfPath: String { return selfURL.path }
    static var home: String { return NSHomeDirectory() }

    static var isAppBundle: Bool {
        return selfPath.hasSuffix(".app") && Bundle.main.bundleIdentifier == Installation.bundleID
    }

    static var location: Installation.Location {
        return Installation.location(ofAppAt: selfPath, home: home)
    }

    /// The designated requirement of this copy. Read once per launch (it does not change while running).
    static let requirement: String = Permissions.signatureRequirement()

    static var signatureKind: Installation.SignatureKind {
        return Installation.signatureKind(ofRequirement: requirement)
    }

    /// Where setup puts the app: where it already is if that is an Applications folder, otherwise
    /// /Applications, or ~/Applications when this account cannot write to /Applications.
    static var destination: URL {
        if location.isInstalled { return selfURL }
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) {
            return system.appendingPathComponent(Installation.appName, isDirectory: true)
        }
        let user = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return user.appendingPathComponent(Installation.appName, isDirectory: true)
    }

    /// True when setup still has something to do: the app is not in Applications, or it is but has
    /// a signature that changes with every download (and signing on this Mac is possible).
    static var needsSetup: Bool {
        guard isAppBundle else { return false }
        if !location.isInstalled { return true }
        return signatureKind == .adHoc && !AppInstaller.signingUnavailable
    }

    // MARK: Running copies

    static func otherInstances() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Installation.bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
    }

    private static func describe(_ app: NSRunningApplication) -> Installation.RunningCopy {
        let path = app.bundleURL?.standardizedFileURL.path ?? ""
        let version = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        return Installation.RunningCopy(path: path, version: version, launchDate: app.launchDate)
    }

    /// Called first thing at launch. If another copy is already running and should stay, it is
    /// brought to the front and this copy quits (returns true). If this copy should stay, the
    /// others are asked to quit.
    @discardableResult
    static func resolveDuplicateInstancesAtLaunch() -> Bool {
        guard isAppBundle else { return false }
        let others = otherInstances()
        guard !others.isEmpty else { return false }
        let me = Installation.RunningCopy(
            path: selfPath,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            launchDate: NSRunningApplication.current.launchDate
        )
        for other in others {
            if !Installation.shouldKeepSelf(me, over: describe(other), home: home) {
                Platform.activate(other)
                NSApp.terminate(nil)
                return true
            }
        }
        for other in others {
            other.terminate()
        }
        return false
    }

    /// Asks every other running copy to quit and waits up to `timeout` seconds (off the main thread).
    static func closeOtherInstances(timeout: Double, completion: @escaping (Int) -> Void) {
        let others = otherInstances()
        guard !others.isEmpty else {
            completion(0)
            return
        }
        for other in others { other.terminate() }
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline && others.contains(where: { !$0.isTerminated }) {
                Thread.sleep(forTimeInterval: 0.1)
            }
            for other in others where !other.isTerminated {
                other.forceTerminate()
            }
            DispatchQueue.main.async { completion(others.count) }
        }
    }

    // MARK: Old disk images and copies (call off the main thread)

    /// Ejects every mounted disk image that contains Mac Action Recorder, except the one this copy
    /// runs from. Returns the names of the disks that were ejected.
    static func ejectOldDiskImages() -> [String] {
        guard let data = run("/usr/bin/hdiutil", ["info", "-plist"]).output else { return [] }
        var ejected: [String] = []
        let myPath = selfPath
        for point in Installation.diskImageMountPoints(fromHdiutilInfo: data) {
            guard containsThisApp(volume: point) else { continue }
            if myPath.hasPrefix(point + "/") { continue }
            var result = run("/usr/bin/hdiutil", ["detach", point, "-quiet"])
            if result.status != 0 {
                // A Finder window showing the disk can keep it busy; the disk only holds the installer.
                result = run("/usr/bin/hdiutil", ["detach", point, "-force", "-quiet"])
            }
            if result.status == 0 {
                ejected.append((point as NSString).lastPathComponent)
            }
        }
        return ejected
    }

    private static func containsThisApp(volume: String) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: volume) else { return false }
        for item in items where item.hasSuffix(".app") {
            let plist = (volume as NSString).appendingPathComponent(item + "/Contents/Info.plist")
            if let info = NSDictionary(contentsOfFile: plist),
               (info["CFBundleIdentifier"] as? String) == Installation.bundleID {
                return true
            }
        }
        return false
    }

    /// Moves every other copy of the app that Spotlight knows about to the Trash. Copies inside
    /// a source checkout's build folder are left alone. Returns the paths that were moved.
    static func trashOtherCopies() -> [String] {
        guard isAppBundle, location.isInstalled else { return [] }
        let query = "kMDItemCFBundleIdentifier == '\(Installation.bundleID)'"
        guard let data = run("/usr/bin/mdfind", [query]).output,
              let text = String(data: data, encoding: .utf8) else { return [] }
        let found = text.split(separator: "\n").map { String($0) }
        let candidates = Installation.copiesToRemove(
            found: found,
            keeping: selfPath,
            home: home,
            supportFolder: AppModel.supportDirectory.path
        )
        var moved: [String] = []
        for path in candidates {
            guard isOurApp(at: path), !isBuildOutput(path) else { continue }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                moved.append(path)
            } catch {
                continue
            }
        }
        if !moved.isEmpty {
            registerWithLaunchServices()
        }
        return moved
    }

    private static func isOurApp(at path: String) -> Bool {
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: plist) else { return false }
        return (info["CFBundleIdentifier"] as? String) == Installation.bundleID
    }

    /// `.../mac-action-recorder/build/Mac Action Recorder.app` from building the source yourself.
    private static func isBuildOutput(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let checkout = (parent as NSString).deletingLastPathComponent
        return FileManager.default.fileExists(atPath: (checkout as NSString).appendingPathComponent("Package.swift"))
    }

    /// Makes sure macOS opens this copy when something asks for the app by name or identifier.
    static func registerWithLaunchServices() {
        _ = LSRegisterURL(selfURL as CFURL, true)
    }

    // MARK: Permissions

    /// Remembers the signature that the permissions were granted to. Call when both are granted.
    static func rememberGrantedSignature() {
        guard isAppBundle else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: grantedRequirementKey) != requirement {
            defaults.set(requirement, forKey: grantedRequirementKey)
        }
        defaults.set(true, forKey: permissionCleanupDoneKey)
    }

    /// Removes this app's old entries from the Accessibility and Input Monitoring lists when they
    /// belong to a different signature and do not work. With `force`, removes them regardless.
    /// Returns true if entries were removed.
    @discardableResult
    static func repairPermissionsIfNeeded(force: Bool = false) -> Bool {
        guard isAppBundle else { return false }
        let defaults = UserDefaults.standard
        let accessibility = Permissions.accessibilityGranted
        let input = Permissions.inputMonitoringGranted
        let previous = defaults.string(forKey: grantedRequirementKey)
        var shouldReset = force || Installation.shouldResetPermissionEntries(
            previousRequirement: previous,
            currentRequirement: requirement,
            accessibilityGranted: accessibility,
            inputMonitoringGranted: input
        )
        // Versions before 0.6 did not record the signature. If permissions are not working on the
        // first launch of this version, entries from those older copies are the likely reason.
        if !shouldReset && previous == nil && !defaults.bool(forKey: permissionCleanupDoneKey) && !(accessibility && input) {
            shouldReset = true
        }
        guard shouldReset else { return false }
        let done = Permissions.resetStoredPermissions()
        defaults.set(true, forKey: permissionCleanupDoneKey)
        defaults.removeObject(forKey: grantedRequirementKey)
        return done
    }

    // MARK: Reopening

    /// Quits this copy and opens the installed one (or this one, when nothing is installed) after
    /// this process has really ended, so two copies never run at once.
    static func relaunch() {
        let installed = destinationIfInstalled()
        let target = installed ?? selfPath
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", Installation.reopenScript, "sh", String(ProcessInfo.processInfo.processIdentifier), target, "20"]
        do {
            try helper.run()
        } catch {
            // Fall back to the old way if the helper cannot start.
            NSWorkspace.shared.open(URL(fileURLWithPath: target))
        }
        NSApp.terminate(nil)
    }

    /// The installed copy's path, if there is one (this copy if it is installed).
    private static func destinationIfInstalled() -> String? {
        if location.isInstalled { return selfPath }
        let candidates = [
            Installation.installedPath,
            (home as NSString).appendingPathComponent("Applications/" + Installation.appName)
        ]
        return candidates.first { isOurApp(at: $0) }
    }

    // MARK: Running fixed tools

    struct ToolResult {
        var status: Int32
        var output: Data?
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], timeout: Double = 30) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ToolResult(status: -1, output: nil)
        }
        // Read before waiting so a large output cannot fill the pipe and stall the tool.
        var collected = Data()
        let reader = DispatchQueue(label: "installdoctor.read")
        let group = DispatchGroup()
        group.enter()
        reader.async {
            collected = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return ToolResult(status: process.terminationStatus, output: collected)
    }
}
