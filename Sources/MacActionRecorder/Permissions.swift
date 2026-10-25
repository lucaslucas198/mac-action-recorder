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

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
