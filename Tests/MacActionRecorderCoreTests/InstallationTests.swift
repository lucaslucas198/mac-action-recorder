import XCTest
@testable import MacActionRecorderCore

final class InstallationTests: XCTestCase {
    private let home = "/Users/lucas"

    func testLocations() {
        XCTAssertEqual(Installation.location(ofAppAt: "/Applications/Mac Action Recorder.app", home: home), .applications)
        XCTAssertEqual(Installation.location(ofAppAt: "/Users/lucas/Applications/Mac Action Recorder.app", home: home), .applications)
        XCTAssertEqual(Installation.location(ofAppAt: "/Volumes/Mac Action Recorder 2/Mac Action Recorder.app", home: home), .volume)
        XCTAssertEqual(
            Installation.location(ofAppAt: "/private/var/folders/x/AppTranslocation/ABC/d/Mac Action Recorder.app", home: home),
            .translocated
        )
        XCTAssertEqual(Installation.location(ofAppAt: "/Users/lucas/Downloads/Mac Action Recorder.app", home: home), .elsewhere)
        XCTAssertEqual(Installation.location(ofAppAt: "/Applications/../Users/x.app", home: home), .elsewhere)
        XCTAssertTrue(Installation.Location.applications.isInstalled)
        XCTAssertFalse(Installation.Location.volume.isInstalled)
    }

    func testSignatureKinds() {
        XCTAssertEqual(Installation.signatureKind(ofRequirement: "cdhash H\"0123abcd\""), .adHoc)
        XCTAssertEqual(
            Installation.signatureKind(ofRequirement: "identifier \"io.github.macactionrecorder.app\" and certificate leaf = H\"ab\""),
            .certificate
        )
        XCTAssertEqual(
            Installation.signatureKind(ofRequirement: "identifier \"io.github.macactionrecorder.app\" and certificate root = H\"ab\""),
            .certificate
        )
        XCTAssertEqual(Installation.signatureKind(ofRequirement: "unavailable"), .unknown)
    }

    func testPermissionResetOnlyWhenSignatureChangedAndNotWorking() {
        XCTAssertTrue(Installation.shouldResetPermissionEntries(
            previousRequirement: "cdhash H\"aa\"", currentRequirement: "cdhash H\"bb\"",
            accessibilityGranted: false, inputMonitoringGranted: true))
        XCTAssertFalse(Installation.shouldResetPermissionEntries(
            previousRequirement: "cdhash H\"aa\"", currentRequirement: "cdhash H\"bb\"",
            accessibilityGranted: true, inputMonitoringGranted: true), "never undo working permissions")
        XCTAssertFalse(Installation.shouldResetPermissionEntries(
            previousRequirement: "same", currentRequirement: "same",
            accessibilityGranted: false, inputMonitoringGranted: false), "same signature: the user simply has not switched it on")
        XCTAssertFalse(Installation.shouldResetPermissionEntries(
            previousRequirement: nil, currentRequirement: "x",
            accessibilityGranted: false, inputMonitoringGranted: false))
    }

    func testNewerVersionWinsThenInstalledThenOlderProcess() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let installedOld = Installation.RunningCopy(path: "/Applications/Mac Action Recorder.app", version: "0.5.0", launchDate: early)
        let diskNew = Installation.RunningCopy(path: "/Volumes/Mac Action Recorder/Mac Action Recorder.app", version: "0.6.0", launchDate: late)
        XCTAssertTrue(Installation.shouldKeepSelf(diskNew, over: installedOld, home: home))
        XCTAssertFalse(Installation.shouldKeepSelf(installedOld, over: diskNew, home: home))

        let diskSame = Installation.RunningCopy(path: "/Volumes/Mac Action Recorder/Mac Action Recorder.app", version: "0.5.0", launchDate: early)
        let installedSame = Installation.RunningCopy(path: "/Applications/Mac Action Recorder.app", version: "0.5.0", launchDate: late)
        XCTAssertTrue(Installation.shouldKeepSelf(installedSame, over: diskSame, home: home))
        XCTAssertFalse(Installation.shouldKeepSelf(diskSame, over: installedSame, home: home))

        // Same copy opened twice: the one already running stays.
        let first = Installation.RunningCopy(path: "/Applications/Mac Action Recorder.app", version: "0.5.0", launchDate: early)
        let second = Installation.RunningCopy(path: "/Applications/Mac Action Recorder.app", version: "0.5.0", launchDate: late)
        XCTAssertFalse(Installation.shouldKeepSelf(second, over: first, home: home))
        XCTAssertTrue(Installation.shouldKeepSelf(first, over: second, home: home))
        // Unknown launch dates: never close the other one.
        let unknown = Installation.RunningCopy(path: "/Applications/Mac Action Recorder.app", version: "0.5.0", launchDate: nil)
        XCTAssertFalse(Installation.shouldKeepSelf(unknown, over: first, home: home))
    }

    func testCopiesToRemove() {
        let found = [
            "/Applications/Mac Action Recorder.app",
            "/Applications/Mac Action Recorder 2.app",
            "/Users/lucas/Downloads/Mac Action Recorder.app",
            "/Users/lucas/Downloads/Mac Action Recorder.app",
            "/Users/lucas/.Trash/Mac Action Recorder.app",
            "/Volumes/Mac Action Recorder/Mac Action Recorder.app",
            "/Users/lucas/Library/Application Support/Mac Action Recorder/Updates/Mac Action Recorder.app",
            "/Applications/Installer.app/Contents/Resources/Mac Action Recorder.app",
            "/Users/lucas/Downloads/notes.txt"
        ]
        let remove = Installation.copiesToRemove(
            found: found,
            keeping: "/Applications/Mac Action Recorder.app/",
            home: home,
            supportFolder: "/Users/lucas/Library/Application Support/Mac Action Recorder"
        )
        XCTAssertEqual(remove, [
            "/Applications/Mac Action Recorder 2.app",
            "/Users/lucas/Downloads/Mac Action Recorder.app"
        ])
    }

    func testHdiutilMountPoints() throws {
        let info: [String: Any] = [
            "images": [
                ["image-path": "/Users/lucas/Downloads/MacActionRecorder-macOS.dmg",
                 "system-entities": [["dev-entry": "/dev/disk4"], ["dev-entry": "/dev/disk4s1", "mount-point": "/Volumes/Mac Action Recorder"]]],
                ["image-path": "/x.dmg", "system-entities": [["dev-entry": "/dev/disk5s1", "mount-point": "/Volumes/Mac Action Recorder 1"]]],
                ["image-path": "/y.dmg"]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        XCTAssertEqual(Installation.diskImageMountPoints(fromHdiutilInfo: data), ["/Volumes/Mac Action Recorder", "/Volumes/Mac Action Recorder 1"])
        XCTAssertEqual(Installation.diskImageMountPoints(fromHdiutilInfo: Data("garbage".utf8)), [])
    }

    func testStepsAreOrderedAndTheBarNeverFillsBeforeTheEnd() {
        var previous = 0.0
        for step in SetupStep.allCases {
            XCTAssertGreaterThanOrEqual(step.range.lowerBound, previous)
            XCTAssertLessThan(step.range.lowerBound, step.range.upperBound)
            XCTAssertLessThan(step.range.upperBound, 1.0)
            previous = step.range.upperBound
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.detail.isEmpty)
            // Moves while running, never past the step's end on its own.
            XCTAssertEqual(step.fraction(afterSeconds: 0), step.range.lowerBound, accuracy: 0.0001)
            XCTAssertGreaterThan(step.fraction(afterSeconds: 1), step.range.lowerBound)
            XCTAssertLessThan(step.fraction(afterSeconds: 10_000), step.range.upperBound)
            XCTAssertLessThanOrEqual(step.fraction(afterSeconds: 1), step.fraction(afterSeconds: 2))
        }
        XCTAssertNotNil(SetupStep.signing.slowHint)
    }

    func testScriptsUsePositionalArgumentsOnly() {
        // Paths are passed as $1.. so a folder name can never become code.
        XCTAssertTrue(Installation.reopenScript.contains("\"$2\""))
        XCTAssertTrue(Installation.swapScript.contains("dest=\"$3\""))
        XCTAssertFalse(Installation.swapScript.contains("Mac Action Recorder"))
    }

    func testReopenOpensTheInstalledCopyUnlessItIsOlder() {
        let me = "/Volumes/Mac Action Recorder/Mac Action Recorder.app"
        let installed = "/Applications/Mac Action Recorder.app"
        XCTAssertEqual(Installation.reopenTarget(selfPath: me, selfVersion: "0.6.0", installedPath: installed, installedVersion: "0.6.0"), installed)
        XCTAssertEqual(Installation.reopenTarget(selfPath: me, selfVersion: "0.6.0", installedPath: installed, installedVersion: "0.7.0"), installed)
        XCTAssertEqual(Installation.reopenTarget(selfPath: me, selfVersion: "0.6.0", installedPath: installed, installedVersion: "0.5.0"), me)
        XCTAssertEqual(Installation.reopenTarget(selfPath: me, selfVersion: "0.6.0", installedPath: nil, installedVersion: nil), me)
        XCTAssertEqual(Installation.reopenTarget(selfPath: installed, selfVersion: "0.6.0", installedPath: installed, installedVersion: "0.6.0"), installed)
    }
}
