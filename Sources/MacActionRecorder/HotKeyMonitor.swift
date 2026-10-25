import AppKit
import CoreGraphics
import MacActionRecorderCore

/// Watches key presses for one global shortcut (the emergency stop).
///
/// It only runs while a recording countdown, a recording or a playback is active, never in
/// the background while the app is idle. It is a listen-only tap: it cannot block or alter
/// any key press, and it ignores everything except an exact match of the shortcut.
final class HotKeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hotKey = HotKey.defaultEmergencyStop

    /// Called on the main thread when the shortcut is pressed.
    var onTrigger: (() -> Void)?

    var isRunning: Bool {
        return tap != nil
    }

    /// Starts watching. Returns false if macOS refused to create the tap (permission missing).
    @discardableResult
    func start(hotKey: HotKey) -> Bool {
        stop()
        self.hotKey = hotKey

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon = refcon {
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        let mask = EventTapSupport.mask(for: [.keyDown])
        guard let installed = EventTapSupport.install(
            mask: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        tap = installed.tap
        source = installed.source
        return true
    }

    func stop() {
        if let tap = tap, let source = source {
            EventTapSupport.remove(tap: tap, source: source)
        }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == EventMarker.userData {
                return
            }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = EventTapSupport.modifiers(from: event.flags)
            if hotKey.matches(keyCode: code, modifiers: modifiers) {
                DispatchQueue.main.async { [weak self] in
                    self?.onTrigger?()
                }
            }
        default:
            break
        }
    }
}
