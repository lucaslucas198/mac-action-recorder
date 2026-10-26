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

/// Where updates come from. The app only ever contacts these fixed GitHub addresses, and only to read.
public enum UpdateConfig {
    public static let repository = "lucaslucas198/mac-action-recorder"

    /// GitHub's description of the newest published release (version number and file list).
    public static var latestReleaseAPIURL: URL {
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// The name of the release file that holds the finished app (a zip of "Mac Action Recorder.app").
    public static let releaseAssetName = "MacActionRecorder-macOS.zip"

    /// The only address prefix a downloadable release file may have.
    public static var releaseDownloadPrefix: String {
        return "https://github.com/\(repository)/releases/download/"
    }
}

/// The parts of GitHub's "latest release" answer that the updater uses.
public struct ReleaseInfo: Equatable {
    public let version: AppVersion
    public let assetURL: URL

    public init(version: AppVersion, assetURL: URL) {
        self.version = version
        self.assetURL = assetURL
    }

    /// Reads GitHub's JSON. Returns nil unless it names a parseable version AND a file called
    /// `UpdateConfig.releaseAssetName` hosted under this repository's release downloads. Anything
    /// else (an error message, a draft, a file from somewhere else) is ignored.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard data.count < 2_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = AppVersion(tag) else {
            return nil
        }
        if (object["draft"] as? Bool) == true || (object["prerelease"] as? Bool) == true {
            return nil
        }
        let assets = object["assets"] as? [[String: Any]] ?? []
        for asset in assets {
            guard (asset["name"] as? String) == UpdateConfig.releaseAssetName,
                  let address = asset["browser_download_url"] as? String,
                  address.hasPrefix(UpdateConfig.releaseDownloadPrefix),
                  let url = URL(string: address) else {
                continue
            }
            return ReleaseInfo(version: version, assetURL: url)
        }
        return nil
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
