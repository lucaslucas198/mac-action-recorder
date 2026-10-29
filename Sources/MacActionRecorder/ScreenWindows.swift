import AppKit
import MacActionRecorderCore

/// One window on screen, as macOS lists it (front to back). Positions are in the global,
/// top-left-origin coordinates that mouse events use. Reading the list needs no permission: it has
/// positions and sizes only, never window contents.
struct ScreenWindow {
    let pid: pid_t
    let frame: WindowFrame
    let layer: Int
}

enum ScreenWindows {
    /// Windows at or above this level are tooltips, the cursor and similar: they never take clicks.
    static let topLayerLimit = 200

    /// All on-screen windows that can take a click, front to back, or nil if macOS would not say.
    /// Safe from any thread.
    static func list() -> [ScreenWindow]? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var result: [ScreenWindow] = []
        result.reserveCapacity(raw.count)
        for info in raw {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer >= topLayerLimit { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 1, rect.height >= 1 else { continue }
            result.append(ScreenWindow(
                pid: pid_t(owner),
                frame: WindowFrame(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height)),
                layer: layer
            ))
        }
        return result
    }

    /// The window on top at `point` (the one a click there goes to).
    static func window(at point: CGPoint, in windows: [ScreenWindow]) -> ScreenWindow? {
        return windows.first { $0.frame.contains(x: Double(point.x), y: Double(point.y)) }
    }

    /// The windows of one process.
    static func windows(of pid: pid_t, in windows: [ScreenWindow]) -> [WindowFrame] {
        return windows.filter { $0.pid == pid }.map { $0.frame }
    }
}

/// Bundle ID, name and kind of the app behind a process, looked up once (on the main thread) and
/// then remembered, so the playback thread rarely has to wait for the main thread.
final class AppDirectory {
    static let shared = AppDirectory()

    struct Info {
        let bundleID: String?
        let name: String
        /// A normal app with a Dock icon (not a background helper or a menu bar tool).
        let isRegular: Bool
    }

    private let lock = NSLock()
    private var byPID: [pid_t: Info] = [:]
    private var pidByBundle: [String: pid_t] = [:]

    func info(for pid: pid_t) -> Info? {
        lock.lock()
        if let known = byPID[pid] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let found: Info? = Platform.onMain {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return Info(
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "another app",
                isRegular: app.activationPolicy == .regular
            )
        }
        if let found = found {
            lock.lock()
            byPID[pid] = found
            lock.unlock()
        }
        return found
    }

    /// The running process of an app, remembered while it stays alive.
    func pid(ofBundleID bundleID: String) -> pid_t? {
        lock.lock()
        let cached = pidByBundle[bundleID]
        lock.unlock()
        if let pid = cached, Platform.isProcessAlive(pid) { return pid }
        let found = Platform.pid(ofBundleID: bundleID)
        lock.lock()
        pidByBundle[bundleID] = found
        lock.unlock()
        return found
    }

    /// A readable name for a bundle ID ("Discord" for com.hnc.Discord).
    func name(ofBundleID bundleID: String) -> String {
        if let pid = pid(ofBundleID: bundleID), let info = info(for: pid) {
            return info.name
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// The regular app whose window is on top at `point`, or nil when the window there belongs to
    /// a background helper (or there is none).
    func regularApp(at point: CGPoint, in windows: [ScreenWindow]) -> String? {
        guard let top = ScreenWindows.window(at: point, in: windows), let info = info(for: top.pid), info.isRegular else {
            return nil
        }
        return info.bundleID
    }
}
