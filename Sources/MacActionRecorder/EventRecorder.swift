import AppKit
import Carbon
import CoreGraphics
import MacActionRecorderCore

enum RecorderError: LocalizedError {
    case permissionDenied
    case tapFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Input Monitoring permission is required to record. Open Help > Welcome & Setup to switch it on."
        case .tapFailed:
            return "macOS would not let the app observe input events. Check the Input Monitoring permission and try again."
        }
    }
}

/// Captures mouse and keyboard input through a listen-only event tap.
///
/// Fidelity notes (see README > Known limitations):
/// - Timing uses a monotonic clock (`systemUptime`) sampled when the tap callback runs on the
///   main thread, so heavy main-thread work can add a few milliseconds of jitter.
/// - The tap is listen-only: it never changes or blocks input.
/// - Events from this app's own windows, and keystrokes while this app is active, are ignored,
///   so pressing "Stop" or renaming a macro is not recorded.
/// - macOS does not deliver keystrokes typed into password fields (Secure Input) to event taps;
///   if Secure Input is active the app records nothing and tells you.
final class EventRecorder {
    struct Output {
        var events: [RawEvent]
        var targetApp: TargetApp?
        var secureInputSeen: Bool
        var truncated: Bool
        /// The target app's front window when recording started (see `WindowRelocation`).
        var targetWindow: WindowFrame?
        /// How many event times came from macOS's own stamp, and how many from the arrival time.
        var stampedEvents = 0
        var arrivalTimedEvents = 0
        /// The largest delay seen between an event happening and this app reading it, in seconds.
        var largestReadDelay = 0.0
    }

    private(set) var isRecording = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var events: [RawEvent] = []
    private var options = RecordingOptions()
    private var ignoredHotKey = HotKey.defaultEmergencyStop
    private var otherIgnoredHotKey: HotKey?
    private var targetWindow: WindowFrame?
    private var lastEventTime = 0.0
    private var stampedEvents = 0
    private var arrivalTimedEvents = 0
    private var largestReadDelay = 0.0
    private var throttle = MoveThrottle(minInterval: 0.03, minDistance: 3)
    private var targetApp: TargetApp?
    private var secureInputSeen = false
    private var truncated = false

    private var cachedFrames: [CGRect] = []
    private var framesCachedAt: Double = 0
    private var screenWindows: [ScreenWindow]?
    private var windowsReadAt: Double = 0
    /// Keeps macOS from putting the app into App Nap while it records in the background, which
    /// would delay reading events (and can make macOS switch the event tap off).
    private var activity: NSObjectProtocol?

    private let maxEvents = 500_000

    var eventCount: Int {
        return events.count
    }

    func start(options: RecordingOptions, ignoredHotKey: HotKey, otherIgnoredHotKey: HotKey? = nil) throws {
        guard !isRecording else { return }
        self.options = options
        self.ignoredHotKey = ignoredHotKey
        self.otherIgnoredHotKey = otherIgnoredHotKey
        targetWindow = nil
        lastEventTime = 0
        stampedEvents = 0
        arrivalTimedEvents = 0
        largestReadDelay = 0
        throttle = MoveThrottle(minInterval: options.minEventInterval, minDistance: options.minMoveDistance)
        events.removeAll(keepingCapacity: true)
        targetApp = nil
        secureInputSeen = false
        truncated = false
        cachedFrames = []
        framesCachedAt = 0
        screenWindows = nil
        windowsReadAt = 0

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon = refcon {
                let recorder = Unmanaged<EventRecorder>.fromOpaque(refcon).takeUnretainedValue()
                recorder.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
            .keyDown
        ]

        guard let installed = EventTapSupport.install(
            mask: EventTapSupport.mask(for: types),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // macOS refuses to create the tap when Input Monitoring is not (yet) effective.
            throw CGPreflightListenEventAccess() ? RecorderError.tapFailed : RecorderError.permissionDenied
        }
        tap = installed.tap
        source = installed.source
        isRecording = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Recording a macro"
        )
    }

    /// Stops capturing and returns everything recorded.
    func stop() -> Output {
        if let tap = tap, let source = source {
            EventTapSupport.remove(tap: tap, source: source)
        }
        if let running = activity {
            ProcessInfo.processInfo.endActivity(running)
            activity = nil
        }
        tap = nil
        source = nil
        isRecording = false
        return Output(
            events: events,
            targetApp: targetApp,
            secureInputSeen: secureInputSeen,
            truncated: truncated,
            targetWindow: targetWindow,
            stampedEvents: stampedEvents,
            arrivalTimedEvents: arrivalTimedEvents,
            largestReadDelay: largestReadDelay
        )
    }

    // MARK: Event handling (main thread, called from the tap callback)

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard isRecording else { return }
        if event.getIntegerValueField(.eventSourceUserData) == EventMarker.userData { return }
        if events.count >= maxEvents {
            truncated = true
            return
        }

        let time = eventTime(for: event)
        let location = event.location
        let held = EventTapSupport.modifiers(from: event.flags)

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard options.includeMouseMove else { return }
            if isInsideOwnWindow(location) { return }
            guard throttle.shouldAccept(time: time, x: Double(location.x), y: Double(location.y)) else { return }
            let kind: RawEventKind
            switch type {
            case .leftMouseDragged: kind = .mouseDrag(.left)
            case .rightMouseDragged: kind = .mouseDrag(.right)
            case .otherMouseDragged: kind = .mouseDrag(.other)
            default: kind = .mouseMove
            }
            if type == .mouseMoved {
                append(time, location, kind, modifiers: held)
            } else {
                let target = receiver(at: location, fresh: false)
                append(time, location, kind, modifiers: held, app: target.app, window: target.window)
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isInsideOwnWindow(location) { return }
            let target = receiver(at: location, fresh: true)
            noteTargetApp(target.app)
            let count = max(1, Int(event.getIntegerValueField(.mouseEventClickState)))
            append(time, location, .mouseDown(button(for: type), clickCount: count), modifiers: held, app: target.app, window: target.window)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if isInsideOwnWindow(location) { return }
            let target = receiver(at: location, fresh: true)
            let count = max(1, Int(event.getIntegerValueField(.mouseEventClickState)))
            append(time, location, .mouseUp(button(for: type), clickCount: count), modifiers: held, app: target.app, window: target.window)

        case .scrollWheel:
            guard options.recordScroll else { return }
            if isInsideOwnWindow(location) { return }
            let dy = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            if dx == 0 && dy == 0 { return }
            let target = receiver(at: location, fresh: false)
            append(time, location, .scroll(dx: dx, dy: dy), modifiers: held, app: target.app, window: target.window)

        case .keyDown:
            // Typing into this app's own windows (renaming a macro, settings) is not part of the macro.
            if NSRunningApplication.current.isActive { return }
            // Never record while macOS Secure Input (password fields) is active.
            if IsSecureEventInputEnabled() {
                secureInputSeen = true
                return
            }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = EventTapSupport.modifiers(from: event.flags)
            if ignoredHotKey.matches(keyCode: code, modifiers: modifiers) { return }
            if let other = otherIgnoredHotKey, other.matches(keyCode: code, modifiers: modifiers) { return }
            // Keys go to the app in front.
            let front = NSWorkspace.shared.frontmostApplication
            let frontApp = front?.activationPolicy == .regular ? front?.bundleIdentifier : nil
            noteTargetApp(frontApp)
            let characters = NSEvent(cgEvent: event)?.characters ?? ""
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            append(time, location, .keyDown(keyCode: code, modifiers: modifiers, characters: characters, isRepeat: isRepeat), app: frontApp)

        default:
            break
        }
    }

    private func append(_ time: Double, _ location: CGPoint, _ kind: RawEventKind, modifiers: KeyModifiers = [],
                        app: String? = nil, window: WindowFrame? = nil) {
        events.append(RawEvent(time: time, x: Double(location.x), y: Double(location.y), kind: kind, modifiers: modifiers,
                               app: app, window: window))
    }

    /// The normal app whose window is under the pointer (the one that receives a click there) and
    /// that window's frame. See-through windows of helpers on top are skipped; a click on the
    /// Dock or the menu bar is recorded without an app, so playback never checks it. `fresh: false`
    /// lets frequent events (scrolling, dragging) reuse a window list up to 0.1 s old.
    private func receiver(at point: CGPoint, fresh: Bool) -> (app: String?, window: WindowFrame?) {
        let now = ProcessInfo.processInfo.systemUptime
        if fresh || windowsReadAt == 0 || now - windowsReadAt > 0.1 {
            screenWindows = ScreenWindows.list()
            windowsReadAt = now
        }
        guard let windows = screenWindows, let hit = ScreenWindows.appWindow(at: point, in: windows),
              let bundleID = hit.info.bundleID else {
            return (nil, nil)
        }
        return (bundleID, hit.window.frame)
    }

    /// The time of an event in seconds on the same clock as `systemUptime`.
    ///
    /// The time macOS stamps on an event is when it happened, not when this app got round to
    /// reading it, so it is not affected by this app being busy for a few milliseconds. If the
    /// stamp is missing, or does not match the system clock (which would mean it uses another
    /// base), or goes backwards, the arrival time is used instead, so a bad stamp can never
    /// corrupt a recording.
    private func eventTime(for event: CGEvent) -> Double {
        let arrival = ProcessInfo.processInfo.systemUptime
        var time = arrival
        // The stamp is accepted when it lies before the arrival (by at most 10 s: the app can be
        // busy for a while, and then the stamp is exactly the time that matters). A stamp from
        // another clock would be hours off and is ignored.
        if options.preciseTiming, let stamp = NSEvent(cgEvent: event)?.timestamp,
           stamp > 0, stamp <= arrival + 0.05, arrival - stamp < 10 {
            time = stamp
            stampedEvents += 1
            largestReadDelay = max(largestReadDelay, arrival - stamp)
        } else {
            arrivalTimedEvents += 1
        }
        if time < lastEventTime { time = lastEventTime }
        lastEventTime = time
        return time
    }

    private func button(for type: CGEventType) -> MouseButton {
        switch type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        default: return .other
        }
    }

    /// The macro's app is the app that received its first input: for a click, the app whose window
    /// was clicked (which may not have been in front yet), for a key the app in front. When that is
    /// not known, the app in front at that moment is used, as before.
    private func noteTargetApp(_ receiver: String?) {
        guard targetApp == nil else { return }
        var chosen: TargetApp?
        if let bundleID = receiver, bundleID != Bundle.main.bundleIdentifier,
           let app = Platform.runningApplication(bundleID: bundleID) {
            chosen = TargetApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
        } else if let front = Platform.frontmost(), !Platform.isThisApp(front) {
            chosen = front
        }
        guard let target = chosen else { return }
        targetApp = target
        // Remember where its window is, so playback can follow it if it moves.
        if let app = Platform.runningApplication(bundleID: target.bundleID) {
            targetWindow = Platform.frontWindow(pid: app.processIdentifier).frame
        }
    }

    /// True when the event at `point` goes to one of this app's own windows: the main window, the
    /// menu bar item and its menu (for example Stop Recording). Being inside the area of one of our
    /// windows is not enough: another app's window may be in front of it there, and then the click
    /// belongs to that app and must be recorded.
    private func isInsideOwnWindow(_ point: CGPoint) -> Bool {
        // The window on top at that point, as macOS lists it; menus and the menu bar item are
        // windows of this process too.
        let now = ProcessInfo.processInfo.systemUptime
        if screenWindows == nil || now - windowsReadAt > 0.05 {
            screenWindows = ScreenWindows.list()
            windowsReadAt = now
        }
        if let windows = screenWindows, let top = ScreenWindows.window(at: point, in: windows) {
            return top.pid == ProcessInfo.processInfo.processIdentifier
        }
        // The list could not be read: fall back to this app's own window list.
        if now - framesCachedAt > 0.25 {
            cachedFrames = Platform.ownWindowFrames()
            framesCachedAt = now
        }
        guard cachedFrames.contains(where: { $0.contains(point) }) else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        let number = NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number) != nil
    }
}
