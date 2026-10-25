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

    // MARK: ActionPerformer

    func perform(_ action: MacroAction) throws {
        switch action.kind {
        case .move:
            try moveCursor(to: point(of: action))

        case .drag:
            let button = action.button ?? .left
            try post(mouseEvent(dragType(for: button), at: point(of: action), button: button))

        case .mouseDown:
            let button = action.button ?? .left
            let location = point(of: action)
            try moveCursor(to: location)
            try post(mouseEvent(downType(for: button), at: location, button: button, clickState: 1))
            lock.lock()
            heldButtons[button] = location
            lock.unlock()

        case .mouseUp:
            let button = action.button ?? .left
            let location = point(of: action)
            try post(mouseEvent(upType(for: button), at: location, button: button, clickState: 1))
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

        try moveCursor(to: location)
        Thread.sleep(forTimeInterval: 0.012) // let hover state settle before the press

        for index in 1...count {
            try post(mouseEvent(downType(for: button), at: location, button: button, clickState: index))
            Thread.sleep(forTimeInterval: 0.010)
            try post(mouseEvent(upType(for: button), at: location, button: button, clickState: index))
            if index < count {
                Thread.sleep(forTimeInterval: 0.030)
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
        clickState: Int? = nil
    ) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: cgButton(button)
        )
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
        Thread.sleep(forTimeInterval: 0.008)

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
    }
}
