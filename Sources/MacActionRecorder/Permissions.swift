import AppKit
import ApplicationServices
import CoreGraphics
import Security

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

    /// Tests Input Monitoring the way recording really uses it: by creating a listen-only event
    /// tap and removing it again. `CGPreflightListenEventAccess` can say "no" for a permission
    /// that was switched on while the app was running, so this is the more reliable answer.
    /// Call it on demand, not in a loop: creating a tap without permission can make macOS show
    /// its permission prompt.
    static func canObserveInput() -> Bool {
        let callback: CGEventTapCallBack = { _, _, event, _ in
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: nil
        ) else {
            return false
        }
        CFMachPortInvalidate(tap)
        return true
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

    // MARK: Diagnostics

    /// The code-signing requirement macOS matches permissions against, e.g. `cdhash H"..."` for an
    /// ad-hoc signature (changes with every build) or `certificate leaf = H"..."` for a stable one.
    static func signatureRequirement() -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return "unavailable (not a signed app bundle)"
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let found = requirement else {
            return "unavailable (no designated requirement)"
        }
        var text: CFString?
        guard SecRequirementCopyString(found, [], &text) == errSecSuccess, let string = text else {
            return "unavailable"
        }
        return string as String
    }

    /// A plain-text report for troubleshooting "I switched it on but it says I didn't".
    static func diagnosticsReport() -> String {
        let requirement = signatureRequirement()
        var lines: [String] = []
        lines.append("App path: \(appURL.path)")
        lines.append("Bundle id: \(Bundle.main.bundleIdentifier ?? "none")")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        lines.append("Version: \(version ?? "unknown")")
        lines.append("Accessibility (AXIsProcessTrusted): \(accessibilityGranted)")
        lines.append("Input Monitoring (preflight): \(inputMonitoringGranted)")
        lines.append("Post events (preflight): \(CGPreflightPostEventAccess())")
        lines.append("Signature requirement: \(requirement)")
        if requirement.contains("cdhash") {
            lines.append("-> Ad-hoc signature: it changes with every build, so permissions granted to an older build no longer match.")
        }
        if appURL.path.contains("AppTranslocation") {
            lines.append("-> Running from a temporary quarantine location. Move the app to /Applications, quit it, and open it from there.")
        } else if !appURL.path.hasPrefix("/Applications/") {
            lines.append("-> Not running from /Applications. Permissions are per copy; make sure you granted this exact copy.")
        }
        return lines.joined(separator: "\n")
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
