import AppKit
import CoreGraphics
import MacActionRecorderCore

/// Plays actions back by posting synthetic CGEvents (the normal macOS mechanism, which requires
/// the Accessibility permission). Nothing here runs shell commands or scripts.
///
/// Called from the playback thread. Held mouse buttons are tracked so `cleanup()` can release
/// them if playback stops between a press and its release.
final class MacEventPerformer: ActionPerformer {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private var heldButtons: [MouseButton: CGPoint] = [:]
    private var inputTiming = InputTiming()
    private var adjuster: ((MacroAction) -> MacroAction)?
    private var lastPoint: CGPoint?
    private var lastPostTime = 0.0

    /// Sets how long clicks and key presses take. Call before a run starts.
    func configure(timing: InputTiming, adjuster: ((MacroAction) -> MacroAction)?) {
        lock.lock()
        inputTiming = timing
        self.adjuster = adjuster
        lastPoint = nil
        lastPostTime = 0
        lock.unlock()
    }

    private var timing: InputTiming {
        lock.lock()
        defer { lock.unlock() }
        return inputTiming
    }

    /// Distance in points between where this performer last put the pointer and where the pointer
    /// is now. Returns nil unless that can be said reliably: the last move must be a moment ago
    /// (the system may not have applied it yet) and must have been on a display.
    func pointerDrift() -> Double? {
        lock.lock()
        let expected = lastPoint
        let postedAt = lastPostTime
        lock.unlock()
        guard let target = expected,
              ProcessInfo.processInfo.systemUptime - postedAt > 0.08,
              Platform.isOnAnyDisplay(target),
              let now = Platform.pointerLocation() else { return nil }
        return Double(hypot(now.x - target.x, now.y - target.y))
    }

    // MARK: ActionPerformer

    func perform(_ original: MacroAction) throws {
        lock.lock()
        let adjust = adjuster
        lock.unlock()
        // Follows the target window if it has moved since the macro was recorded.
        let action = adjust?(original) ?? original
        switch action.kind {
        case .move:
            try moveCursor(to: point(of: action))

        case .drag:
            let button = action.button ?? .left
            try post(mouseEvent(dragType(for: button), at: point(of: action), button: button, modifiers: action.modifiers ?? []))

        case .mouseDown:
            let button = action.button ?? .left
            let location = point(of: action)
            try moveCursor(to: location)
            try post(mouseEvent(downType(for: button), at: location, button: button, clickState: 1, modifiers: action.modifiers ?? []))
            lock.lock()
            heldButtons[button] = location
            lock.unlock()

        case .mouseUp:
            let button = action.button ?? .left
            let location = point(of: action)
            try post(mouseEvent(upType(for: button), at: location, button: button, clickState: 1, modifiers: action.modifiers ?? []))
            lock.lock()
            heldButtons[button] = nil
            lock.unlock()

        case .click:
            try click(action)

        case .scroll:
            try scroll(action)

        case .key:
            try pressKey(
                code: action.keyCode ?? 0,
                modifiers: action.modifiers ?? []
            )

        case .text:
            for character in (action.text ?? "") {
                if character == "\n" || character == "\r" {
                    // A line break inside text is typed as Shift+Return, which inserts a new line
                    // in Discord and most chat apps instead of sending the message.
                    try pressKey(code: KeyCodes.returnKey, modifiers: [.shift])
                } else {
                    try typeUnicode(String(character))
                }
            }

        case .wait:
            break // handled by the engine's scheduling
        }
    }

    func cleanup() {
        lock.lock()
        let held = heldButtons
        heldButtons.removeAll()
        lock.unlock()
        for (button, location) in held {
            try? post(mouseEvent(upType(for: button), at: location, button: button, clickState: 1))
        }
    }

    // MARK: Mouse

    private func click(_ action: MacroAction) throws {
        let button = action.button ?? .left
        let count = max(1, min(3, action.clickCount ?? 1))
        let location = point(of: action)

        let modifiers = action.modifiers ?? []
        let t = timing

        try moveCursor(to: location)
        Thread.sleep(forTimeInterval: t.settleBeforeClick) // let hover state settle before the press

        for index in 1...count {
            try post(mouseEvent(downType(for: button), at: location, button: button, clickState: index, modifiers: modifiers))
            Thread.sleep(forTimeInterval: t.clickHold)
            try post(mouseEvent(upType(for: button), at: location, button: button, clickState: index, modifiers: modifiers))
            if index < count {
                Thread.sleep(forTimeInterval: t.doubleClickGap)
            }
        }
    }

    private func scroll(_ action: MacroAction) throws {
        if let x = action.x, let y = action.y {
            try moveCursor(to: CGPoint(x: x, y: y))
        }
        let dy = Int32(clamping: action.scrollY ?? 0)
        let dx = Int32(clamping: action.scrollX ?? 0)
        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        )
        if let modifiers = action.modifiers, !modifiers.isEmpty {
            event?.flags = EventTapSupport.flags(from: modifiers)
        }
        try post(event)
    }

    private func moveCursor(to location: CGPoint) throws {
        lock.lock()
        let heldButton = heldButtons.keys.first
        lock.unlock()

        if let button = heldButton {
            try post(mouseEvent(dragType(for: button), at: location, button: button))
        } else {
            try post(mouseEvent(.mouseMoved, at: location, button: .left))
        }
    }

    private func mouseEvent(
        _ type: CGEventType,
        at location: CGPoint,
        button: MouseButton,
        clickState: Int? = nil,
        modifiers: KeyModifiers = []
    ) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: cgButton(button)
        )
        if !modifiers.isEmpty {
            event?.flags = EventTapSupport.flags(from: modifiers)
        }
        if let clickState = clickState {
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        if button == .other {
            event?.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
        return event
    }

    private func cgButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .other: return .center
        }
    }

    private func downType(for button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .other: return .otherMouseDown
        }
    }

    private func upType(for button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .other: return .otherMouseUp
        }
    }

    private func dragType(for button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .other: return .otherMouseDragged
        }
    }

    private func point(of action: MacroAction) -> CGPoint {
        return CGPoint(x: action.x ?? 0, y: action.y ?? 0)
    }

    // MARK: Keyboard

    private func pressKey(code: Int, modifiers: KeyModifiers) throws {
        let keyCode = CGKeyCode(max(0, min(255, code)))
        let flags = EventTapSupport.flags(from: modifiers)

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        try post(down)
        Thread.sleep(forTimeInterval: timing.keyHold)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        try post(up)
    }

    /// Types one character independent of the keyboard layout by attaching the Unicode
    /// string directly to the key event.
    private func typeUnicode(_ string: String) throws {
        let units = Array(string.utf16)
        guard !units.isEmpty else { return }

        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.flags = []
        up?.flags = []
        units.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        try post(down)
        try post(up)
    }

    // MARK: Posting

    private func post(_ event: CGEvent?) throws {
        guard let event = event else {
            throw PlaybackError("macOS refused to create an input event.")
        }
        event.setIntegerValueField(.eventSourceUserData, value: EventMarker.userData)
        event.post(tap: .cghidEventTap)
        noteIfMouse(event)
    }

    /// Remembers where the pointer was sent, so `pointerDrift` can tell whether someone else moved it.
    private func noteIfMouse(_ event: CGEvent) {
        switch event.type {
        case .mouseMoved,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            lock.lock()
            lastPoint = event.location
            lastPostTime = ProcessInfo.processInfo.systemUptime
            lock.unlock()
        default:
            break
        }
    }
}
