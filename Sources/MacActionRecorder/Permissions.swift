import AppKit
import ApplicationServices
import CoreGraphics

/// The two macOS privacy permissions this app needs.
///
/// - Accessibility: lets the app post mouse/keyboard events (playback).
/// - Input Monitoring: lets the app observe mouse/keyboard events (recording and the
///   emergency-stop shortcut).
///
/// macOS ties both grants to the app's code signature. Ad-hoc builds change signature on
/// every rebuild, so a grant can stop working after rebuilding; see README > Troubleshooting.
enum Permissions {
    static var accessibilityGranted: Bool {
        return AXIsProcessTrusted()
    }

    static var inputMonitoringGranted: Bool {
        return CGPreflightListenEventAccess()
    }

    /// Shows the system prompt (if macOS still allows one) and registers the app in the list.
    static func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    // MARK: Helpers for when the app does not show up in the system lists

    /// The running app's location, for revealing it in Finder or copying its path.
    static var appURL: URL {
        return Bundle.main.bundleURL
    }

    /// Shows the app in Finder so it can be dragged into a System Settings list.
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    static func copyAppPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(appURL.path, forType: .string)
    }

    /// Clears this app's entries in the Privacy lists (Accessibility, Input Monitoring, ...), so the
    /// next request registers it again cleanly. This runs the fixed system command
    /// `tccutil reset All <this app's bundle id>`; it affects only this app. Returns false if the
    /// app has no bundle identifier (for example under `swift run`) or the command fails.
    @discardableResult
    static func resetStoredPermissions() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Starts a fresh copy of the app and quits this one. Some permission changes only take
    /// effect in a newly launched process.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
