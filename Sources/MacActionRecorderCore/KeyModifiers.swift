import Foundation

/// Keyboard modifiers, independent of any platform API so the model stays portable.
/// Only the four modifiers that matter for shortcuts are tracked.
public struct KeyModifiers: OptionSet, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// Stable names used in the recording file, in display order.
    static let named: [(String, KeyModifiers)] = [
        ("control", .control),
        ("option", .option),
        ("shift", .shift),
        ("command", .command)
    ]

    /// Display string such as "⌃⌥⇧⌘" (in the standard macOS order).
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

extension KeyModifiers: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let names = try container.decode([String].self)
        var result = KeyModifiers()
        for name in names {
            guard let match = KeyModifiers.named.first(where: { $0.0 == name }) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown modifier '\(name)'"
                )
            }
            result.insert(match.1)
        }
        self = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let names = KeyModifiers.named.filter { self.contains($0.1) }.map { $0.0 }
        try container.encode(names)
    }
}
