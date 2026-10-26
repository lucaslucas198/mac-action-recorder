import AppKit
import Combine
import Foundation
import MacActionRecorderCore

/// Keeps the app up to date from its GitHub Releases.
///
/// How it works:
/// 1. One read-only request asks GitHub for the newest release (at most every few hours).
/// 2. If that version is newer, the bundled `update.sh` downloads the finished app from the release,
///    checks it, signs it for this Mac, and leaves it in a staging folder. The installed app is not touched.
/// 3. When you choose "Restart to Update", a short helper replaces the installed app with the staged
///    one and reopens it.
///
/// Nothing is installed without that last click. The only addresses contacted are the fixed GitHub
/// addresses in `UpdateConfig`. No Xcode or building is involved.
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// The release found by the last check; its file is what gets downloaded.
    private var pendingRelease: ReleaseInfo?

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
        case .downloading(let version): return "Downloading version \(version)…"
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
        case .checking, .downloading:
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
            url: UpdateConfig.latestReleaseAPIURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("MacActionRecorder-UpdateCheck", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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
            // 404 means GitHub has no published release yet, which is not an error worth showing.
            if http.statusCode == 404 {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                state = userInitiated ? .upToDate : .idle
            } else {
                fail("GitHub answered with status \(http.statusCode) when looking for updates.")
            }
            return
        }
        guard let data = data, let release = ReleaseInfo.parse(data) else {
            fail("The update information on GitHub could not be read.")
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard let installedText = installedVersionText,
              UpdateCheck.isNewer(remote: release.version.description, installed: installedText) else {
            state = .upToDate
            return
        }
        pendingRelease = release
        state = .available(release.version.description)

        let settings = AppModel.shared.settings
        if settings.autoBuildUpdates && !AppModel.shared.status.isBusy {
            startDownload()
        }
    }

    // MARK: Downloading

    /// Downloads and prepares the available version in the background.
    func startDownload() {
        guard case .available(let version) = state, let release = pendingRelease, let script = scriptURL else { return }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, stagingDirectory.path, release.assetURL.absoluteString]
            process.qualityOfService = .utility
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] finished in
                try? log.close()
                let status = finished.terminationStatus
                DispatchQueue.main.async {
                    self?.finishDownload(version: version, exitStatus: status)
                }
            }
            state = .downloading(version)
            try process.run()
        } catch {
            state = .failed("Could not start the update: \(error.localizedDescription)")
        }
    }

    private func finishDownload(version: String, exitStatus: Int32) {
        if exitStatus == 0, FileManager.default.fileExists(atPath: stagedAppURL.path) {
            state = .ready(version)
        } else {
            state = .failed("The update could not be downloaded. " + logTail())
        }
    }

    private func logTail() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").map(String.init)
        let errors = lines.filter { $0.contains("error:") || $0.contains("curl:") }
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
        do {
            try AppInstaller.swapAndRelaunch(staged: stagedAppURL, destination: Bundle.main.bundleURL)
        } catch {
            state = .failed("Could not install the update: \(error.localizedDescription)")
        }
    }
}
