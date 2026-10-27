import AppKit
import MacActionRecorderCore

/// Holds the safety rules for the run in progress and answers the engine's "is it safe to carry
/// on?" question on the playback thread. Every value it reads is a fact from macOS (is the app
/// running, where is its window, how big is the display); it never guesses.
final class SafetyBox {
    private let lock = NSLock()
    private var options = SafetyOptions()
    private var context: SafetyContext?
    /// The target app's process, remembered so most checks need not ask the main thread.
    private var targetPID: pid_t?

    func arm(options: SafetyOptions, context: SafetyContext) {
        lock.lock()
        self.options = options
        self.context = context
        targetPID = nil
        lock.unlock()
    }

    /// The target's process if it is running: the remembered one while it is alive, otherwise
    /// looked up again (the app may have been opened or reopened since).
    private func runningPID(of bundleID: String) -> pid_t? {
        lock.lock()
        let cached = targetPID
        lock.unlock()
        if let pid = cached, Platform.isProcessAlive(pid) { return pid }
        let found = Platform.pid(ofBundleID: bundleID)
        lock.lock()
        targetPID = found
        lock.unlock()
        return found
    }

    func disarm() {
        lock.lock()
        context = nil
        lock.unlock()
    }

    /// Returns a reason to stop, or nil. Called on the playback thread.
    func check(kind: ActionKind?, performer: MacEventPerformer) -> String? {
        lock.lock()
        let options = self.options
        let context = self.context
        lock.unlock()
        guard let context = context, options.enabled else { return nil }

        var snapshot = SafetySnapshot()
        if let target = context.target {
            let pid = runningPID(of: target.bundleID)
            snapshot.targetRunning = (pid != nil)
            if let pid = pid {
                let reading = Platform.frontWindow(pid: pid)
                snapshot.windowKnown = reading.readable
                snapshot.window = reading.frame
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
            actionKind: kind ?? .wait
        )
    }
}

/// Shifts recorded click positions to follow the target window when it has moved. The window's
/// position is re-read for every action (with a very short cache so fast mouse paths stay cheap),
/// so dragging the window during a run is followed too.
final class WindowFollower {
    private let lock = NSLock()
    private var recorded: WindowFrame?
    private var bundleID: String?
    private var cachedFrame: WindowFrame?
    private var cachedAt = 0.0
    private var cachedPID: pid_t?

    func configure(recorded: WindowFrame?, bundleID: String?) {
        lock.lock()
        self.recorded = recorded
        self.bundleID = bundleID
        cachedFrame = nil
        cachedAt = 0
        cachedPID = nil
        lock.unlock()
    }

    func adjust(_ action: MacroAction) -> MacroAction {
        guard WindowRelocation.isPositional(action.kind) else { return action }
        lock.lock()
        let recorded = self.recorded
        let bundleID = self.bundleID
        lock.unlock()
        guard let reference = recorded, let identifier = bundleID, let current = currentFrame(bundleID: identifier) else {
            return action
        }
        switch WindowRelocation.assess(recorded: reference, current: current) {
        case .moved(let dx, let dy):
            return WindowRelocation.translate([action], recorded: reference, dx: dx, dy: dy)[0]
        case .same, .resized:
            return action
        }
    }

    private func currentFrame(bundleID: String) -> WindowFrame? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let cached = cachedFrame, now - cachedAt < 0.05 {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // The process is remembered, so reading the window position needs no trip to the main thread.
        lock.lock()
        var pid = cachedPID
        lock.unlock()
        if pid == nil || !Platform.isProcessAlive(pid!) {
            pid = Platform.pid(ofBundleID: bundleID)
        }
        guard let process = pid, let frame = Platform.frontWindow(pid: process).frame else { return nil }
        lock.lock()
        cachedPID = process
        cachedFrame = frame
        cachedAt = now
        lock.unlock()
        return frame
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
