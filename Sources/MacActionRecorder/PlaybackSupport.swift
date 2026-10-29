import AppKit
import MacActionRecorderCore

/// Holds the safety rules for the run in progress and answers the engine's "is it safe to carry
/// on?" question on the playback thread. Every value it reads is a fact from macOS (is the app
/// running, which windows are where, which app is in front); it never guesses.
///
/// Recordings made with 0.6.1 and later know, for every step, which app received it and which
/// window was clicked; those are checked step by step. Older recordings only know the app that
/// was in front when recording started, and are checked against that.
final class SafetyBox {
    private let lock = NSLock()
    private var options = SafetyOptions()
    private var context: SafetyContext?
    private var verifyForeground = false
    private var stepInfo = false
    private var adjust: ((MacroAction) -> MacroAction)?

    func arm(options: SafetyOptions, context: SafetyContext, verifyForeground: Bool, stepInfo: Bool,
             adjust: ((MacroAction) -> MacroAction)? = nil) {
        lock.lock()
        self.options = options
        self.context = context
        self.verifyForeground = verifyForeground
        self.stepInfo = stepInfo
        self.adjust = adjust
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        context = nil
        adjust = nil
        lock.unlock()
    }

    /// Returns a reason to stop, or nil. `action` is nil at the start of each repetition.
    /// Called on the playback thread.
    func check(action: MacroAction?, performer: MacEventPerformer) -> String? {
        lock.lock()
        let options = self.options
        let context = self.context
        let verifyForeground = self.verifyForeground
        let stepInfo = self.stepInfo
        let adjust = self.adjust
        lock.unlock()
        guard let context = context else { return nil }

        if stepInfo {
            // At the start of a repetition only "has the app quit?" can be said for certain.
            guard let action = action, action.app != nil else {
                if action == nil, options.enabled, options.stopIfTargetGone, let target = context.target,
                   AppDirectory.shared.pid(ofBundleID: target.bundleID) == nil {
                    return SafetyWatchdog.messagePrefix + "\(target.name) is not running any more."
                }
                return nil
            }
            return checkStep(action, options: options, context: context, verifyForeground: verifyForeground,
                             adjust: adjust, performer: performer)
        }

        guard options.enabled else { return nil }
        var snapshot = SafetySnapshot()
        if let target = context.target {
            let pid = AppDirectory.shared.pid(ofBundleID: target.bundleID)
            snapshot.targetRunning = (pid != nil)
            if let pid = pid {
                if let windows = ScreenWindows.list() {
                    snapshot.windowKnown = true
                    let own = ScreenWindows.windows(of: pid, in: windows).filter { $0.width >= 200 && $0.height >= 150 }
                    // The recorded window if it is still there (another window of the app may be in
                    // front of it, such as a dialog), otherwise the front one.
                    if let recorded = context.recordedWindow, let match = SafetyWatchdog.matchingWindow(recorded, in: own) {
                        snapshot.window = match
                    } else {
                        snapshot.window = own.first
                    }
                }
            }
        }
        snapshot.screen = Platform.primaryDisplaySize()
        if options.stopIfUserMovesMouse {
            snapshot.pointerDrift = performer.pointerDrift()
        }
        return SafetyWatchdog.evaluate(
            options: options,
            context: context,
            snapshot: snapshot,
            actionKind: action?.kind ?? .wait
        )
    }

    private func checkStep(
        _ action: MacroAction,
        options: SafetyOptions,
        context: SafetyContext,
        verifyForeground: Bool,
        adjust: ((MacroAction) -> MacroAction)?,
        performer: MacEventPerformer
    ) -> String? {
        guard let app = action.app else { return nil }
        var snapshot = StepSnapshot()
        snapshot.frontmost = Platform.bundleIDOfFrontmostApp()
        let pid = AppDirectory.shared.pid(ofBundleID: app)
        snapshot.appRunning = (pid != nil)
        if WindowRelocation.isPositional(action.kind), let windows = ScreenWindows.list() {
            if let pid = pid {
                snapshot.appWindows = ScreenWindows.windows(of: pid, in: windows)
            }
            // Where the click will really go, after following a moved window.
            let aimed = adjust?(action) ?? action
            if let x = aimed.x, let y = aimed.y {
                snapshot.regularAppAtPoint = AppDirectory.shared.regularApp(at: CGPoint(x: x, y: y), in: windows)
            }
        }
        snapshot.screen = Platform.primaryDisplaySize()
        if options.enabled && options.stopIfUserMovesMouse {
            snapshot.pointerDrift = performer.pointerDrift()
        }
        return SafetyWatchdog.evaluate(
            step: action,
            options: options,
            verifyForeground: verifyForeground,
            followWindow: context.followWindow,
            recordedScreen: context.recordedScreen,
            snapshot: snapshot,
            names: { AppDirectory.shared.name(ofBundleID: $0) }
        )
    }
}

/// Shifts recorded click positions to follow a window that has moved. For recordings that know
/// which window each click was in, that window is found again (same app, same size); for older
/// ones the app's window from when recording started is used. Window positions are re-read for
/// every action, with a very short cache so fast mouse paths stay cheap, so dragging the window
/// during a run is followed too.
final class WindowFollower {
    private let lock = NSLock()
    private var recorded: WindowFrame?
    private var bundleID: String?
    private var enabled = false
    private var cachedList: [ScreenWindow]?
    private var cachedAt = 0.0

    func configure(enabled: Bool, recorded: WindowFrame?, bundleID: String?) {
        lock.lock()
        self.enabled = enabled
        self.recorded = recorded
        self.bundleID = bundleID
        cachedList = nil
        cachedAt = 0
        lock.unlock()
    }

    func adjust(_ action: MacroAction) -> MacroAction {
        guard WindowRelocation.isPositional(action.kind), action.x != nil, action.y != nil else { return action }
        lock.lock()
        let enabled = self.enabled
        let recordingWindow = self.recorded
        let recordingApp = self.bundleID
        lock.unlock()
        guard enabled else { return action }

        // Which window, of which app, this action was aimed at when recorded.
        let reference: WindowFrame?
        let app: String?
        if let window = action.window, let stepApp = action.app {
            reference = window
            app = stepApp
        } else if action.app == nil && action.window == nil {
            reference = recordingWindow
            app = recordingApp
        } else {
            return action
        }
        guard let recorded = reference, let bundleID = app,
              let pid = AppDirectory.shared.pid(ofBundleID: bundleID),
              let windows = currentList() else { return action }
        let own = ScreenWindows.windows(of: pid, in: windows)
        guard let match = SafetyWatchdog.matchingWindow(recorded, in: own) else { return action }
        let dx = match.x - recorded.x
        let dy = match.y - recorded.y
        guard abs(dx) > 1 || abs(dy) > 1 else { return action }
        return WindowRelocation.translate([action], recorded: recorded, dx: dx, dy: dy)[0]
    }

    private func currentList() -> [ScreenWindow]? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let cached = cachedList, now - cachedAt < 0.05 {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let fresh = ScreenWindows.list()
        lock.lock()
        cachedList = fresh
        cachedAt = now
        lock.unlock()
        return fresh
    }
}

/// Short system sounds for start, finish and automatic stops. Off unless turned on in Settings.
enum Sounds {
    enum Cue {
        case start
        case finish
        case warning

        var name: String {
            switch self {
            case .start: return "Pop"
            case .finish: return "Glass"
            case .warning: return "Basso"
            }
        }
    }

    static func play(_ cue: Cue, enabled: Bool) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(cue.name))?.play()
    }
}

// MARK: - Picking a point on screen

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

private final class PickerView: NSView {
    var onPick: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { return true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onPick?(ScreenPicker.currentGlobalPoint())
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.20).setFill()
        dirtyRect.fill()

        let text = "Click where the macro should click.   Esc cancels."
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(
            x: bounds.midX - size.width / 2 - 16,
            y: bounds.maxY - 90,
            width: size.width + 32,
            height: size.height + 18
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 16, y: box.minY + 9), withAttributes: attributes)
    }
}

/// Lets the user click anywhere on screen to choose a position. It darkens the screen slightly,
/// shows a crosshair, and returns the clicked point in the same global top-left coordinates the
/// macro uses. It reads nothing from the screen and needs no extra permission.
final class ScreenPicker {
    static let shared = ScreenPicker()

    private var windows: [NSWindow] = []
    private var dimmed: [NSWindow] = []
    private var completion: ((CGPoint?) -> Void)?

    var isPicking: Bool { return !windows.isEmpty }

    func pick(completion: @escaping (CGPoint?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion
        // Make this app's own windows see-through while picking, so the app underneath is visible.
        dimmed = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }
        for window in dimmed { window.alphaValue = 0 }
        for screen in NSScreen.screens {
            let window = PickerWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onPick = { [weak self] point in self?.finish(point) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func currentGlobalPoint() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
    }

    private func finish(_ point: CGPoint?) {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for window in dimmed { window.alphaValue = 1 }
        dimmed.removeAll()
        let done = completion
        completion = nil
        done?(point)
    }
}
