import AppKit
import MacActionRecorderCore

/// Small helpers around AppKit state, kept in one place.
enum Platform {
    static func frontmost() -> TargetApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let identifier = app.bundleIdentifier else {
            return nil
        }
        return TargetApp(bundleID: identifier, name: app.localizedName ?? identifier)
    }

    static func isThisApp(_ app: TargetApp) -> Bool {
        return app.bundleID == Bundle.main.bundleIdentifier
    }

    static func primaryScreenSize() -> ScreenSize? {
        guard let frame = NSScreen.screens.first?.frame else { return nil }
        return ScreenSize(width: Double(frame.width), height: Double(frame.height))
    }

    /// Frames of this app's visible windows in the same global, top-left-origin coordinate
    /// space that CGEvent uses. Used so clicks on our own Stop button are not recorded.
    static func ownWindowFrames() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSApp.windows
            .filter { $0.isVisible && !$0.isMiniaturized }
            .map { window in
                let frame = window.frame
                return CGRect(
                    x: frame.minX,
                    y: primaryHeight - frame.maxY,
                    width: frame.width,
                    height: frame.height
                )
            }
    }

    /// Regular (Dock-visible) apps that are currently running, for the "target app" picker.
    static func runningApps() -> [TargetApp] {
        let ownID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != ownID }
            .compactMap { (app) -> TargetApp? in
                guard let identifier = app.bundleIdentifier else { return nil }
                return TargetApp(bundleID: identifier, name: app.localizedName ?? identifier)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func bundleIDOfFrontmostApp() -> String? {
        if Thread.isMainThread {
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        return DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }
}
