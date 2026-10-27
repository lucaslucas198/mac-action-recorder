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
    private var throttle = MoveThrottle(minInterval: 0.03, minDistance: 3)
    private var targetApp: TargetApp?
    private var secureInputSeen = false
    private var truncated = false

    private var cachedFrames: [CGRect] = []
    private var framesCachedAt: Double = 0

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
        throttle = MoveThrottle(minInterval: options.minEventInterval, minDistance: options.minMoveDistance)
        events.removeAll(keepingCapacity: true)
        targetApp = nil
        secureInputSeen = false
        truncated = false
        cachedFrames = []
        framesCachedAt = 0

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
    }

    /// Stops capturing and returns everything recorded.
    func stop() -> Output {
        if let tap = tap, let source = source {
            EventTapSupport.remove(tap: tap, source: source)
        }
        tap = nil
        source = nil
        isRecording = false
        return Output(
            events: events,
            targetApp: targetApp,
            secureInputSeen: secureInputSeen,
            truncated: truncated,
            targetWindow: targetWindow
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
            append(time, location, kind, modifiers: held)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isInsideOwnWindow(location) { return }
            noteTargetApp()
            let count = max(1, Int(event.getIntegerValueField(.mouseEventClickState)))
            append(time, location, .mouseDown(button(for: type), clickCount: count), modifiers: held)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if isInsideOwnWindow(location) { return }
            let count = max(1, Int(event.getIntegerValueField(.mouseEventClickState)))
            append(time, location, .mouseUp(button(for: type), clickCount: count), modifiers: held)

        case .scrollWheel:
            guard options.recordScroll else { return }
            if isInsideOwnWindow(location) { return }
            let dy = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            if dx == 0 && dy == 0 { return }
            append(time, location, .scroll(dx: dx, dy: dy), modifiers: held)

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
            noteTargetApp()
            let characters = NSEvent(cgEvent: event)?.characters ?? ""
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            append(time, location, .keyDown(keyCode: code, modifiers: modifiers, characters: characters, isRepeat: isRepeat))

        default:
            break
        }
    }

    private func append(_ time: Double, _ location: CGPoint, _ kind: RawEventKind, modifiers: KeyModifiers = []) {
        events.append(RawEvent(time: time, x: Double(location.x), y: Double(location.y), kind: kind, modifiers: modifiers))
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
        if options.preciseTiming, let stamp = NSEvent(cgEvent: event)?.timestamp,
           stamp > 0, abs(stamp - arrival) < 0.5 {
            time = stamp
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

    private func noteTargetApp() {
        guard targetApp == nil else { return }
        if let front = Platform.frontmost(), !Platform.isThisApp(front) {
            targetApp = front
            // Remember where its window is, so playback can follow it if it moves.
            if let app = Platform.runningApplication(bundleID: front.bundleID) {
                targetWindow = Platform.frontWindow(pid: app.processIdentifier).frame
            }
        }
    }

    /// True when the event at `point` goes to one of this app's own windows (for example the Stop
    /// button). Being inside the area of one of our windows is not enough: another app's window may
    /// be in front of it there, and then the click belongs to that app and must be recorded.
    private func isInsideOwnWindow(_ point: CGPoint) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - framesCachedAt > 0.25 {
            cachedFrames = Platform.ownWindowFrames()
            framesCachedAt = now
        }
        guard cachedFrames.contains(where: { $0.contains(point) }) else { return false }
        // Which window is really in front at this point (Cocoa coordinates, origin bottom-left)?
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        let number = NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number) != nil
    }
}
