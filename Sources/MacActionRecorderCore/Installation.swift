import Foundation

/// Rules used when installing the app and keeping exactly one copy of it. Everything here is pure
/// logic on paths and strings, so it can be unit-tested; the app target does the file work.
public enum Installation {
    public static let bundleID = "io.github.macactionrecorder.app"
    public static let appName = "Mac Action Recorder.app"

    // MARK: Where a copy lives

    public enum Location: Equatable {
        /// /Applications or ~/Applications.
        case applications
        /// Inside a mounted disk image or another volume (/Volumes/...).
        case volume
        /// A temporary, read-only copy macOS made because the app was opened from a download.
        case translocated
        /// Anywhere else (Downloads, Desktop, a build folder...).
        case elsewhere

        public var isInstalled: Bool { return self == .applications }
    }

    public static func location(ofAppAt path: String, home: String) -> Location {
        let clean = normalized(path)
        if clean.contains("/AppTranslocation/") { return .translocated }
        if clean.hasPrefix("/Applications/") || clean.hasPrefix(normalized(home) + "/Applications/") {
            return .applications
        }
        if clean.hasPrefix("/Volumes/") { return .volume }
        return .elsewhere
    }

    /// The path the installed app should have.
    public static var installedPath: String {
        return "/Applications/" + appName
    }

    // MARK: Signatures

    public enum SignatureKind: Equatable {
        /// Ad hoc ("cdhash ..."): changes with every build, so macOS forgets permissions.
        case adHoc
        /// Signed with a certificate: the requirement stays the same across builds.
        case certificate
        case unknown
    }

    /// Reads the designated requirement text that `SecRequirementCopyString` returns.
    public static func signatureKind(ofRequirement requirement: String) -> SignatureKind {
        if requirement.contains("cdhash") { return .adHoc }
        if requirement.contains("certificate") { return .certificate }
        return .unknown
    }

    /// True when the app's signature changed since the permissions were last granted and they are
    /// not working now. The old entries in System Settings then belong to a different signature:
    /// they look switched on but do nothing, and get in the way of adding the app again.
    public static func shouldResetPermissionEntries(
        previousRequirement: String?,
        currentRequirement: String,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
    ) -> Bool {
        guard let previous = previousRequirement, !previous.isEmpty else { return false }
        guard previous != currentRequirement else { return false }
        return !(accessibilityGranted && inputMonitoringGranted)
    }

    // MARK: Choosing between running copies

    public struct RunningCopy: Equatable {
        public var path: String
        public var version: String?
        public var launchDate: Date?

        public init(path: String, version: String?, launchDate: Date?) {
            self.path = path
            self.version = version
            self.launchDate = launchDate
        }
    }

    /// When two copies run at once, which one should stay? The newer version wins; with equal
    /// versions an installed copy wins; otherwise the one that was already running stays, so
    /// opening the app twice never closes the window you were using.
    public static func shouldKeepSelf(_ me: RunningCopy, over other: RunningCopy, home: String) -> Bool {
        if let mine = me.version.flatMap(AppVersion.init), let theirs = other.version.flatMap(AppVersion.init), mine != theirs {
            return mine > theirs
        }
        let meInstalled = location(ofAppAt: me.path, home: home).isInstalled
        let otherInstalled = location(ofAppAt: other.path, home: home).isInstalled
        if meInstalled != otherInstalled { return meInstalled }
        switch (me.launchDate, other.launchDate) {
        case let (mine?, theirs?): return mine < theirs
        default: return false
        }
    }

    /// Which copy "Quit and Reopen" should open: the installed one, unless it is older than the
    /// copy that is running (for example a new download opened before setup), in which case the
    /// running copy is opened again so the user never ends up in an older version.
    public static func reopenTarget(selfPath: String, selfVersion: String?, installedPath: String?, installedVersion: String?) -> String {
        guard let installed = installedPath else { return selfPath }
        if let mine = selfVersion.flatMap(AppVersion.init), let theirs = installedVersion.flatMap(AppVersion.init), theirs < mine {
            return selfPath
        }
        return installed
    }

    // MARK: Other copies

    /// From the paths Spotlight reports for this app's bundle ID, the ones to move to the Trash.
    ///
    /// Kept: the copy that is running, anything already in the Trash, anything on another volume
    /// (disk images are ejected instead, and other drives are left alone), the app's own staging
    /// folders (a downloaded update waiting to be installed), and copies inside another app.
    public static func copiesToRemove(found: [String], keeping keep: String, home: String, supportFolder: String) -> [String] {
        let keepPath = normalized(keep)
        let trash = normalized(home) + "/.Trash/"
        let support = normalized(supportFolder) + "/"
        var seen = Set<String>()
        var result: [String] = []
        for raw in found {
            let path = normalized(raw)
            guard path.hasSuffix(".app"), !seen.contains(path) else { continue }
            seen.insert(path)
            if path == keepPath { continue }
            if path.hasPrefix(trash) || path.contains("/.Trash/") || path.contains("/.Trashes/") { continue }
            if path.hasPrefix("/Volumes/") { continue }
            if path.hasPrefix(support) { continue }
            if path.contains("/AppTranslocation/") { continue }
            // A copy nested inside some other bundle (for example an installer) is not ours to delete.
            let parent = (path as NSString).deletingLastPathComponent
            if parent.contains(".app/") || parent.hasSuffix(".app") { continue }
            result.append(path)
        }
        return result.sorted()
    }

    /// Mount points of disk images that the `hdiutil info -plist` output lists.
    public static func diskImageMountPoints(fromHdiutilInfo data: Data) -> [String] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else {
            return []
        }
        var points: [String] = []
        for image in images {
            guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let point = entity["mount-point"] as? String, !point.isEmpty {
                    points.append(point)
                }
            }
        }
        return points
    }

    private static func normalized(_ path: String) -> String {
        var clean = (path as NSString).standardizingPath
        while clean.count > 1 && clean.hasSuffix("/") { clean.removeLast() }
        return clean
    }

    // MARK: Helper scripts

    /// A small `/bin/sh` script that waits until the process `pid` has quit (at most `timeout`
    /// seconds) and then opens `app` (unless `$4` is `--no-open`, used by the CI self-test). Used for "Quit and Reopen", so the new copy never starts
    /// while the old one is still running. Arguments are passed separately, never pasted into code.
    public static let reopenScript = """
    pid="$1"; app="$2"; limit="$3"
    i=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt $((limit * 10)) ]; then break; fi
        /bin/sleep 0.1
    done
    [ "$4" = "--no-open" ] || /usr/bin/open "$app"
    """

    /// Waits for `pid` to quit, replaces the app at `$3` with the prepared copy at `$2`, removes the
    /// download flag, re-registers it with Launch Services, and opens it. If copying fails the old
    /// app is kept and opened again.
    public static let swapScript = """
    pid="$1"; staged="$2"; dest="$3"
    i=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 150 ]; then break; fi
        /bin/sleep 0.1
    done
    if /usr/bin/ditto "$staged" "$dest.new"; then
        /bin/rm -rf "$dest"
        /bin/mv "$dest.new" "$dest"
        /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        /bin/rm -rf "$staged"
    else
        /bin/rm -rf "$dest.new"
    fi
    lsreg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    [ -x "$lsreg" ] && "$lsreg" -f "$dest" 2>/dev/null
    [ "$4" = "--no-open" ] || /usr/bin/open "$dest"
    """
}

/// The steps of setting the app up, for the progress screen. The bar moves through each step's
/// share while the step is really running and jumps to its end when the step finishes.
public enum SetupStep: Int, CaseIterable, Equatable, Identifiable {
    case checking
    case closingOthers
    case copying
    case signing
    case installing
    case reopening
    case ejecting
    case removingCopies
    case permissions

    public var id: Int { return rawValue }

    /// Share of the bar at the start and end of this step (0...1, increasing, never full).
    public var range: ClosedRange<Double> {
        switch self {
        case .checking: return 0.00...0.05
        case .closingOthers: return 0.05...0.10
        case .copying: return 0.10...0.25
        case .signing: return 0.25...0.55
        case .installing: return 0.55...0.70
        case .reopening: return 0.70...0.78
        case .ejecting: return 0.78...0.86
        case .removingCopies: return 0.86...0.93
        case .permissions: return 0.93...0.98
        }
    }

    public var title: String {
        switch self {
        case .checking: return "Checking this Mac"
        case .closingOthers: return "Closing other copies of the app"
        case .copying: return "Copying the app"
        case .signing: return "Signing it for this Mac"
        case .installing: return "Moving it into Applications"
        case .reopening: return "Reopening from Applications"
        case .ejecting: return "Ejecting old installer disks"
        case .removingCopies: return "Moving old copies to the Trash"
        case .permissions: return "Clearing old permission entries"
        }
    }

    /// What is happening right now, in plain words.
    public var detail: String {
        switch self {
        case .checking: return "Looking at where the app is and how it is signed."
        case .closingOthers: return "Only one copy of the app should run at a time."
        case .copying: return "Making a working copy so the original is never changed half-way."
        case .signing: return "Creating a certificate that exists only on this Mac and signing the app with it, so macOS keeps your permissions after updates."
        case .installing: return "Replacing the app in Applications with the prepared copy."
        case .reopening: return "The app closes and opens again from Applications. This takes a few seconds."
        case .ejecting: return "Old Mac Action Recorder disk images are still open. They are ejected so macOS cannot open an old copy by mistake."
        case .removingCopies: return "Other copies of the app (in Applications, Downloads, on the Desktop, or anywhere Spotlight finds one) are moved to the Trash, where you can put them back. macOS may ask once whether the app may look in Downloads or Desktop: click Allow."
        case .permissions: return "Entries from older versions are removed so the switches in System Settings work for this copy."
        }
    }

    /// Shown when the step takes longer than expected.
    public var slowHint: String? {
        switch self {
        case .signing:
            return "Still signing. If macOS shows a window asking whether “codesign” may use a key, click Always Allow (you may need your Mac password)."
        case .reopening:
            return "If the app does not reopen by itself, open it from your Applications folder."
        case .copying, .installing:
            return "Still copying. This can take a little longer on a busy Mac."
        case .removingCopies:
            return "If macOS asks whether Mac Action Recorder may access files in Downloads or on the Desktop, click Allow (Don't Allow skips those folders)."
        default:
            return nil
        }
    }

    /// How long the step normally takes, in seconds. Used only to pace the moving bar inside a step.
    public var typicalSeconds: Double {
        switch self {
        case .signing: return 6
        case .copying, .installing: return 2
        case .reopening: return 3
        default: return 1
        }
    }

    /// Where the bar should be after `elapsed` seconds of this step. It moves quickly at first and
    /// then ever more slowly, so it keeps moving but never reaches the end of the step by itself.
    public func fraction(afterSeconds elapsed: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        let t = max(0, elapsed) / max(0.1, typicalSeconds)
        let eased = 1 - exp(-t)
        return range.lowerBound + span * 0.9 * eased
    }
}
