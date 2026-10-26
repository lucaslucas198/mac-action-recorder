import AppKit
import Foundation

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

    static var signingUnavailable: Bool {
        get { UserDefaults.standard.bool(forKey: signingUnavailableKey) }
        set { UserDefaults.standard.set(newValue, forKey: signingUnavailableKey) }
    }

    static var applicationsFolder: URL {
        return URL(fileURLWithPath: "/Applications", isDirectory: true)
    }

    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// True when the app is signed with a fixed certificate rather than an ad-hoc signature, so
    /// permissions granted to it keep matching after it is replaced by a newer build.
    static var hasStableSignature: Bool {
        return Permissions.signatureRequirement().contains("certificate leaf")
    }

    /// Whether the "Set Up This Mac" step still has something to do.
    static var needsSetup: Bool {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return false }
        if !isInstalledInApplications { return true }
        return !(hasStableSignature || signingUnavailable)
    }

    /// Where the app should live: where it is now if that is already an Applications folder,
    /// otherwise /Applications.
    static var destination: URL {
        if isInstalledInApplications {
            return Bundle.main.bundleURL
        }
        return applicationsFolder.appendingPathComponent(appName, isDirectory: true)
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
    static func prepare(_ app: URL, completion: @escaping (PrepareResult) -> Void) {
        guard let script = bundledScript("prepare_app") else {
            completion(.failed("The app's helper script is missing. Download the app again."))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, app.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { finished in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
            completion(.failed("Could not run the helper script: \(error.localizedDescription)"))
        }
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
    /// this app. If copying fails, the old app is kept and reopened.
    static func swapAndRelaunch(staged: URL, destination: URL) throws {
        let parent = destination.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw InstallError.message("This account cannot write to \(parent). Drag the app into Applications yourself, or sign in as an administrator.")
        }
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
        helper.arguments = ["-c", script, "sh", staged.path, destination.path]
        try helper.run()
        NSApp.terminate(nil)
    }
}
