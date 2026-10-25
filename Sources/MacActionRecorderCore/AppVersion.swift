import Foundation

/// A dotted version number such as "0.2.0". Missing trailing parts count as zero, so "1.2" equals "1.2.0".
public struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    public let components: [Int]

    /// Accepts "1.2.3", "v1.2.3", " 1.2.3\n" and "1.2.3-beta" (the suffix is ignored).
    /// Returns nil for anything else, such as an HTML error page.
    public init?(_ text: String) {
        var line = String(text.split(whereSeparator: { $0.isNewline }).first ?? "")
        line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("v") || line.hasPrefix("V") {
            line.removeFirst()
        }
        let numeric = line.prefix(while: { $0.isNumber || $0 == "." })
        guard !numeric.isEmpty, numeric.count <= 32 else { return nil }
        // After the number only nothing, a space, or a "-" / "+" suffix may follow ("1.2.3-beta").
        // This keeps text such as "404: Not Found" from being read as version 404.
        if let next = line.dropFirst(numeric.count).first, next != "-", next != "+", next != " " {
            return nil
        }

        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 4 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, let value = Int(part) else { return nil }
            values.append(value)
        }
        components = values
    }

    public var description: String {
        return components.map { String($0) }.joined(separator: ".")
    }

    private func padded(to count: Int) -> [Int] {
        return components + Array(repeating: 0, count: max(0, count - components.count))
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        let a = lhs.padded(to: count)
        let b = rhs.padded(to: count)
        for index in 0..<count where a[index] != b[index] {
            return a[index] < b[index]
        }
        return false
    }
}

/// Where updates come from. The app only ever contacts these two addresses, and only to read.
public enum UpdateConfig {
    public static let repository = "lucaslucas198/mac-action-recorder"
    public static let branch = "main"

    /// A one-line text file in the repository that holds the newest version number.
    public static var versionFileURL: URL {
        return URL(string: "https://raw.githubusercontent.com/\(repository)/\(branch)/VERSION")!
    }

    /// The source of the newest version, as a zip.
    public static var sourceZipURL: URL {
        return URL(string: "https://github.com/\(repository)/archive/refs/heads/\(branch).zip")!
    }
}

public enum UpdateCheck {
    /// True only when both texts parse as versions and the remote one is strictly newer.
    public static func isNewer(remote: String, installed: String) -> Bool {
        guard let remoteVersion = AppVersion(remote), let installedVersion = AppVersion(installed) else {
            return false
        }
        return remoteVersion > installedVersion
    }
}
