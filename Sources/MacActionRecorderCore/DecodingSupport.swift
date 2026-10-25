import Foundation

extension KeyedDecodingContainer {
    /// Decodes a value, returning `fallback` when the key is missing or unreadable.
    /// Used for settings so that files written by older/newer versions still load.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        if let decoded = try? decodeIfPresent(T.self, forKey: key) {
            return decoded
        }
        return fallback
    }

    /// Same as `value` for optional properties (nil stays nil).
    func optionalValue<T: Decodable>(_ key: Key, _ fallback: T?) -> T? {
        if let decoded = try? decodeIfPresent(T.self, forKey: key) {
            return decoded
        }
        return fallback
    }
}

enum Num {
    /// Clamps to a range; NaN becomes the lower bound.
    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        if value.isNaN { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
