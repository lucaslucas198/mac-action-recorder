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

    /// The frontmost app's bundle ID. Off the main thread it is answered at once from
    /// `FrontmostTracker` when that runs, so playback never waits for a busy main thread.
    static func bundleIDOfFrontmostApp() -> String? {
        if !Thread.isMainThread, FrontmostTracker.shared.isRunning {
            return FrontmostTracker.shared.current
        }
        if Thread.isMainThread {
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        return DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    // MARK: Apps, windows and displays

    /// The process ID of the running app with this bundle ID, looked up on the main thread.
    static func pid(ofBundleID bundleID: String) -> pid_t? {
        return onMain { runningApplication(bundleID: bundleID)?.processIdentifier }
    }

    /// True while the process exists (from any thread, without asking the main thread).
    static func isProcessAlive(_ pid: pid_t) -> Bool {
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The app with this bundle ID, if it is running and has not quit.
    static func runningApplication(bundleID: String) -> NSRunningApplication? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    struct WindowReading {
        /// False when the system's window list could not be read at all, so "no window" is not a fact.
        var readable: Bool
        var frame: WindowFrame?
    }

    /// The front-most normal window of a process that is on screen, in the same global,
    /// top-left-origin coordinates that mouse events use. Needs no extra permission (it reads
    /// positions and sizes only, never window contents), and is safe to call from any thread.
    static func frontWindow(pid: pid_t) -> WindowReading {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return WindowReading(readable: false, frame: nil)
        }
        // The list is ordered front to back, so the first match is the front-most window.
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, pid_t(owner) == pid else { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
            // Skip tiny helper windows.
            guard rect.width >= 200, rect.height >= 150 else { continue }
            return WindowReading(
                readable: true,
                frame: WindowFrame(
                    x: Double(rect.origin.x),
                    y: Double(rect.origin.y),
                    width: Double(rect.width),
                    height: Double(rect.height)
                )
            )
        }
        return WindowReading(readable: true, frame: nil)
    }

    /// Size of the display that has the menu bar, in points. Same numbers as `primaryScreenSize`,
    /// but safe to call from any thread.
    static func primaryDisplaySize() -> ScreenSize {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return ScreenSize(width: Double(bounds.width), height: Double(bounds.height))
    }

    static func isOnAnyDisplay(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        var display: CGDirectDisplayID = 0
        let result = CGGetDisplaysWithPoint(point, 1, &display, &count)
        return result == .success && count > 0
    }

    /// Where the pointer is right now, in global top-left coordinates.
    static func pointerLocation() -> CGPoint? {
        return CGEvent(source: nil)?.location
    }

    /// Runs `work` on the main thread and returns its result (directly if already there).
    static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// A running Discord (any release channel), if there is one.
    static func findDiscord() -> TargetApp? {
        return runningApps().first { DiscordProfile.isDiscord(bundleID: $0.bundleID, name: $0.name) }
    }
}

/// Follows which app is in front through macOS's activation notifications, so the playback
/// thread can read it instantly instead of waiting for the main thread (which may be busy
/// drawing the window) before every click and key press.
final class FrontmostTracker {
    static let shared = FrontmostTracker()

    private let lock = NSLock()
    private var bundleID: String?
    private var observer: NSObjectProtocol?

    /// Call on the main thread. Calling it again does nothing.
    func start() {
        lock.lock()
        let started = observer != nil
        lock.unlock()
        guard !started else { return }
        set(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(app?.bundleIdentifier)
        }
        lock.lock()
        observer = token
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observer != nil
    }

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return bundleID
    }

    private func set(_ value: String?) {
        lock.lock()
        bundleID = value
        lock.unlock()
    }
}
