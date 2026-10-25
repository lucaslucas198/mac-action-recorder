import Foundation

/// macOS virtual key codes (ANSI layout names) used for display and presets.
/// Key codes identify physical key positions; on other layouts the printed key may differ.
public enum KeyCodes {
    public static let returnKey = 36
    public static let tab = 48
    public static let space = 49
    public static let delete = 51
    public static let escape = 53
    public static let keypadEnter = 76
    public static let leftArrow = 123
    public static let rightArrow = 124
    public static let downArrow = 125
    public static let upArrow = 126
    public static let ansiK = 40
    public static let ansiS = 1
}

public enum KeyNames {
    private static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Escape", 55: "Command", 56: "Shift", 57: "Caps Lock",
        58: "Option", 59: "Control", 76: "Enter (keypad)",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End",
        120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    public static func name(for keyCode: Int) -> String {
        return names[keyCode] ?? "Key \(keyCode)"
    }

    /// Example: "⌘K", "⌃⌥⌘S", "Return".
    public static func display(keyCode: Int, modifiers: KeyModifiers) -> String {
        let key = name(for: keyCode)
        if modifiers.isEmpty {
            return key
        }
        return modifiers.symbols + key
    }
}

/// A global keyboard shortcut (used for the emergency stop).
public struct HotKey: Codable, Equatable {
    public var keyCode: Int
    public var modifiers: KeyModifiers

    public init(keyCode: Int, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌃⌥⌘S. Chosen because it is unlikely to collide with Discord or system shortcuts.
    public static let defaultEmergencyStop = HotKey(
        keyCode: KeyCodes.ansiS,
        modifiers: [.control, .option, .command]
    )

    public func matches(keyCode: Int, modifiers: KeyModifiers) -> Bool {
        return self.keyCode == keyCode && self.modifiers == modifiers
    }

    public var displayString: String {
        return KeyNames.display(keyCode: keyCode, modifiers: modifiers)
    }
}
