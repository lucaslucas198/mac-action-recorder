import AppKit
import Combine
import Foundation
import MacActionRecorderCore

/// Keeps the app up to date from its GitHub repository.
///
/// How it works:
/// 1. A single read-only request fetches the repository's `VERSION` file (at most every few hours).
/// 2. If that version is newer, the bundled `update.sh` downloads the newest source, builds it with
///    Xcode, and leaves the finished app in a staging folder. The installed app is not touched.
/// 3. When you choose "Restart to Update", a short helper replaces the installed app with the staged
///    one and reopens it.
///
/// Nothing is installed without that last click. The only addresses contacted are the two fixed
/// GitHub URLs in `UpdateConfig`. Building needs Xcode, as building from source always does.
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case building(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let lastCheckKey = "lastUpdateCheckTime"
    private let checkInterval: TimeInterval = 6 * 3600
    private var schedule: Timer?

    private var stagingDirectory: URL {
        return AppModel.supportDirectory.appendingPathComponent("Updates", isDirectory: true)
    }

    private var stagedAppURL: URL {
        return stagingDirectory.appendingPathComponent("Mac Action Recorder.app", isDirectory: true)
    }

    private var logURL: URL {
        return stagingDirectory.appendingPathComponent("update.log")
    }

    private init() {
        resumeStagedUpdateIfAny()
    }

    // MARK: Information

    /// The version of the running app, or nil when started without an app bundle (`swift run`).
    var installedVersionText: String? {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private var scriptURL: URL? {
        return Bundle.main.url(forResource: "update", withExtension: "sh")
    }

    /// Updating needs the real app bundle with its bundled script.
    var canUpdate: Bool {
        guard let installed = installedVersionText, AppVersion(installed) != nil else { return false }
        return scriptURL != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    var statusText: String {
        switch state {
        case .idle: return canUpdate ? "Not checked yet in this session." : "Updates are unavailable when the app is not run from its app bundle."
        case .checking: return "Checking for updates…"
        case .upToDate: return "You have the latest version."
        case .available(let version): return "Version \(version) is available."
        case .building(let version): return "Building version \(version)…"
        case .ready(let version): return "Version \(version) is ready to install."
        case .failed(let message): return message
        }
    }

    // MARK: Checking

    /// Starts the periodic check. Call once after launch.
    func startSchedule() {
        checkIfDue()
        schedule?.invalidate()
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        schedule = timer
    }

    private func checkIfDue() {
        let settings = AppModel.shared.settings
        guard settings.checkForUpdates, canUpdate else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        if Date().timeIntervalSince1970 - last < checkInterval - 60 { return }
        check(userInitiated: false)
    }

    /// Looks for a newer version now. When `userInitiated`, problems are shown instead of ignored.
    func check(userInitiated: Bool) {
        switch state {
        case .checking, .building:
            return
        default:
            break
        }
        guard canUpdate else {
            if userInitiated { state = .failed("Updates need the installed app, not a development run.") }
            return
        }
        state = .checking

        var request = URLRequest(
            url: UpdateConfig.versionFileURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("MacActionRecorder-UpdateCheck", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.finishCheck(data: data, response: response, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func finishCheck(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        func fail(_ message: String) {
            state = userInitiated ? .failed(message) : .idle
        }
        if let error = error {
            fail("Could not reach GitHub: \(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            fail("GitHub answered with status \(http.statusCode) when looking for updates.")
            return
        }
        guard let data = data, data.count < 1024, let text = String(data: data, encoding: .utf8),
              let remote = AppVersion(text) else {
            fail("The update information on GitHub could not be read.")
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard let installedText = installedVersionText,
              UpdateCheck.isNewer(remote: text, installed: installedText) else {
            state = .upToDate
            return
        }
        state = .available(remote.description)

        let settings = AppModel.shared.settings
        if settings.autoBuildUpdates && !AppModel.shared.status.isBusy {
            startBuild()
        }
    }

    // MARK: Building

    /// Downloads and builds the available version in the background.
    func startBuild() {
        guard case .available(let version) = state, let script = scriptURL else { return }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, stagingDirectory.path, UpdateConfig.sourceZipURL.absoluteString]
            process.qualityOfService = .utility
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] finished in
                try? log.close()
                let status = finished.terminationStatus
                DispatchQueue.main.async {
                    self?.finishBuild(version: version, exitStatus: status)
                }
            }
            state = .building(version)
            try process.run()
        } catch {
            state = .failed("Could not start the update: \(error.localizedDescription)")
        }
    }

    private func finishBuild(version: String, exitStatus: Int32) {
        if exitStatus == 0, FileManager.default.fileExists(atPath: stagedAppURL.path) {
            state = .ready(version)
        } else {
            state = .failed("The update could not be built. " + logTail())
        }
    }

    private func logTail() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").map(String.init)
        let errors = lines.filter { $0.contains("error:") }
        let shown = errors.isEmpty ? Array(lines.suffix(3)) : Array(errors.prefix(3))
        return shown.joined(separator: " ")
    }

    /// If an update was built earlier but not installed, offer it again after a relaunch.
    private func resumeStagedUpdateIfAny() {
        guard FileManager.default.fileExists(atPath: stagedAppURL.path),
              let stagedText = Bundle(url: stagedAppURL)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              let installedText = installedVersionText,
              let staged = AppVersion(stagedText),
              UpdateCheck.isNewer(remote: stagedText, installed: installedText) else {
            return
        }
        state = .ready(staged.description)
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: Installing

    /// Replaces the installed app with the staged one and reopens it.
    func installAndRelaunch() {
        guard case .ready = state else { return }
        if AppModel.shared.status.isBusy {
            AppModel.shared.showNotice("Finish or stop the current recording or playback before updating.", isError: true)
            return
        }
        let destination = Bundle.main.bundleURL.path
        let staged = stagedAppURL.path

        // Copy next to the old app first, swap only when the copy succeeded, and reopen
        // whatever is installed afterwards. Runs after this app has quit.
        let script = """
        sleep 1.5
        if /usr/bin/ditto "$1" "$2.new"; then
            rm -rf "$2"
            mv "$2.new" "$2"
            /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
            rm -rf "$1"
        else
            rm -rf "$2.new"
        fi
        /usr/bin/open "$2"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", staged, destination]
        do {
            try helper.run()
        } catch {
            state = .failed("Could not start the installer: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
