import AppKit
import Foundation
import MacActionRecorderCore

/// Moves, signs and swaps the app bundle. Used by the Welcome screen ("Set Up This Mac") and by
/// the updater ("Restart to Update").
///
/// The bundled helper scripts do the work that needs the command line (`prepare_app.sh` signs a
/// copy with a certificate made on this Mac). The running app is never modified in place: a copy
/// is prepared first, and a short helper swaps it in after this app has quit.
enum AppInstaller {
    static let appName = "Mac Action Recorder.app"

    /// Set when the local signing certificate could not be created, so the Welcome screen does
    /// not ask for it again and again.
    private static let signingUnavailableKey = "localSigningUnavailable"

    /// Remembered per app version, so a later version tries again (the reason it failed, such as
    /// a locked keychain, may be gone by then).
    static var signingUnavailable: Bool {
        get {
            return UserDefaults.standard.string(forKey: signingUnavailableKey) == currentVersion
        }
        set {
            if newValue {
                UserDefaults.standard.set(currentVersion, forKey: signingUnavailableKey)
            } else {
                UserDefaults.standard.removeObject(forKey: signingUnavailableKey)
            }
        }
    }

    private static var currentVersion: String {
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    /// True when the app is signed with a fixed certificate rather than an ad-hoc signature, so
    /// permissions granted to it keep matching after it is replaced by a newer build.
    static var hasStableSignature: Bool {
        return InstallDoctor.signatureKind == .certificate
    }

    static func bundledScript(_ name: String) -> URL? {
        return Bundle.main.url(forResource: name, withExtension: "sh")
    }

    enum PrepareResult: Equatable {
        /// Signed with the local certificate.
        case signed
        /// The certificate could not be used; the app is unchanged apart from the download flag.
        case unsigned
        case failed(String)
    }

    /// Runs `prepare_app.sh` on `app` in the background and reports on the main thread.
    /// `onLine` receives each line the script prints, so the progress screen can show what it is doing.
    @discardableResult
    static func prepare(_ app: URL, onLine: ((String) -> Void)? = nil, completion: @escaping (PrepareResult) -> Void) -> Process? {
        guard let script = bundledScript("prepare_app") else {
            completion(.failed("The app's helper script is missing. Download the app again."))
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, app.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let lock = NSLock()
        var collected = ""
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            collected += text
            lock.unlock()
            let lines = text.split(whereSeparator: { $0.isNewline }).map { String($0) }.filter { !$0.isEmpty }
            if !lines.isEmpty {
                DispatchQueue.main.async { lines.forEach { onLine?($0) } }
            }
        }
        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            collected += String(data: rest, encoding: .utf8) ?? ""
            let text = collected
            lock.unlock()
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                switch status {
                case 0: completion(.signed)
                case 2: completion(.unsigned)
                default: completion(.failed(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            completion(.failed("Could not run the helper script: \(error.localizedDescription)"))
            return nil
        }
        return process
    }

    /// Copies the running app next to the support folder so it can be prepared without touching
    /// the original. Runs off the main thread.
    static func makeWorkingCopy(completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = AppModel.supportDirectory.appendingPathComponent("Setup", isDirectory: true)
            let copy = folder.appendingPathComponent(appName, isDirectory: true)
            let result: Result<URL, Error>
            do {
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = [Bundle.main.bundleURL.path, copy.path]
                try ditto.run()
                ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else {
                    throw InstallError.message("Copying the app failed (status \(ditto.terminationStatus)).")
                }
                result = .success(copy)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    enum InstallError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    /// Replaces the app at `destination` with the prepared copy at `staged`, reopens it, and quits
    /// this app. The helper waits until this app has really quit before it touches anything. If
    /// copying fails, the old app is kept and reopened.
    static func swapAndRelaunch(staged: URL, destination: URL) throws {
        let parent = destination.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw InstallError.message("This account cannot write to \(parent). Drag the app into Applications yourself, or sign in as an administrator.")
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c", Installation.swapScript, "sh",
            String(ProcessInfo.processInfo.processIdentifier), staged.path, destination.path
        ]
        try helper.run()
        NSApp.terminate(nil)
    }
}
