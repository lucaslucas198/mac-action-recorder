import Foundation

/// Optional, keyboard-only building blocks for common Discord tasks.
///
/// None of these contain screen coordinates. They rely on Discord's own keyboard shortcuts
/// (the Quick Switcher, ⌘K), which are more robust than clicking at fixed positions.
/// Discord can change its shortcuts at any time; insert a preset, then check it behaves as
/// expected in your version.
public enum Presets {
    public struct Info: Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        /// Label for the text field the user must fill in, if any.
        public let inputLabel: String?
        public let secondInputLabel: String?
    }

    public static let all: [Info] = [
        Info(
            id: "open-channel",
            title: "Open channel with Quick Switcher",
            detail: "⌘K, type the channel or person, Return.",
            inputLabel: "Channel or person",
            secondInputLabel: nil
        ),
        Info(
            id: "send-message",
            title: "Type message and send",
            detail: "Types your text, then presses Return.",
            inputLabel: "Message",
            secondInputLabel: nil
        ),
        Info(
            id: "open-and-send",
            title: "Open channel, then send message",
            detail: "Quick Switcher to the channel, wait, type the message, Return.",
            inputLabel: "Channel or person",
            secondInputLabel: "Message"
        )
    ]

    public static func actions(for id: String, input: String, secondInput: String = "") -> [MacroAction] {
        switch id {
        case "open-channel":
            return openChannel(input)
        case "send-message":
            return sendMessage(input)
        case "open-and-send":
            return openChannel(input) + [MacroAction.wait(0.5)] + sendMessage(secondInput)
        default:
            return []
        }
    }

    public static func openChannel(_ name: String) -> [MacroAction] {
        return [
            .key(KeyCodes.ansiK, modifiers: [.command], delay: 0.2),
            .wait(0.4),
            .text(name),
            .wait(0.6),
            .key(KeyCodes.returnKey)
        ]
    }

    public static func sendMessage(_ message: String) -> [MacroAction] {
        return [
            .text(message, delay: 0.2),
            .key(KeyCodes.returnKey, delay: 0.15)
        ]
    }
}
