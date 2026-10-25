import AppKit
import CoreGraphics
import MacActionRecorderCore

enum EventMarker {
    /// Stamped on every event this app posts, so our own event taps can recognise and ignore them.
    static let userData: Int64 = 0x4D41_5243
}

enum EventTapSupport {
    static func mask(for types: [CGEventType]) -> CGEventMask {
        var mask: CGEventMask = 0
        for type in types {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }
        return mask
    }

    static func modifiers(from flags: CGEventFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    static func flags(from modifiers: KeyModifiers) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers.contains(.shift) { result.insert(.maskShift) }
        if modifiers.contains(.control) { result.insert(.maskControl) }
        if modifiers.contains(.option) { result.insert(.maskAlternate) }
        if modifiers.contains(.command) { result.insert(.maskCommand) }
        return result
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    /// Installs a listen-only tap (it can observe events but never alter or block them)
    /// on the main run loop. Returns nil if macOS refuses, which normally means the
    /// Input Monitoring permission has not been granted.
    static func install(
        mask: CGEventMask,
        callback: @escaping CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer
    ) -> (tap: CFMachPort, source: CFRunLoopSource)? {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            return nil
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return (tap, source)
    }

    static func remove(tap: CFMachPort, source: CFRunLoopSource) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }
}
