import XCTest
@testable import MacActionRecorderCore

final class UpdateTests: XCTestCase {
    func testParsesCommonForms() {
        XCTAssertEqual(AppVersion("0.2.0")?.components, [0, 2, 0])
        XCTAssertEqual(AppVersion("v1.10.3")?.components, [1, 10, 3])
        XCTAssertEqual(AppVersion(" 2.0 \n")?.components, [2, 0])
        XCTAssertEqual(AppVersion("1.2.3-beta.1")?.components, [1, 2, 3])
        XCTAssertEqual(AppVersion("3")?.components, [3])
        XCTAssertEqual(AppVersion("1.0.0\nsecond line ignored")?.components, [1, 0, 0])
    }

    func testRejectsJunk() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("<html>404: Not Found</html>"))
        XCTAssertNil(AppVersion("404: Not Found"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("1.2.3.4.5"))
        XCTAssertNil(AppVersion(".1"))
        XCTAssertNil(AppVersion("99999999999.1"))
        XCTAssertNil(AppVersion("latest"))
    }

    func testOrderingIsNumericNotAlphabetical() {
        XCTAssertTrue(AppVersion("0.10.0")! > AppVersion("0.9.0")!)
        XCTAssertTrue(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        XCTAssertTrue(AppVersion("0.2.0")! < AppVersion("0.2.1")!)
    }

    func testMissingPartsCountAsZero() {
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("1.2.0")!)
        XCTAssertFalse(AppVersion("1.2")! < AppVersion("1.2.0")!)
        XCTAssertTrue(AppVersion("1.2")! < AppVersion("1.2.1")!)
    }

    func testIsNewerNeedsBothVersionsToParseAndBeStrictlyGreater() {
        XCTAssertTrue(UpdateCheck.isNewer(remote: "0.3.0", installed: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.2.0", installed: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.1.0", installed: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "<html>", installed: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "0.3.0", installed: "unknown"))
    }

    func testUpdateAddressesAreFixedHttpsGitHubURLs() {
        XCTAssertEqual(UpdateConfig.versionFileURL.scheme, "https")
        XCTAssertEqual(UpdateConfig.versionFileURL.host, "raw.githubusercontent.com")
        XCTAssertEqual(UpdateConfig.sourceZipURL.scheme, "https")
        XCTAssertEqual(UpdateConfig.sourceZipURL.host, "github.com")
        XCTAssertTrue(UpdateConfig.sourceZipURL.path.hasSuffix(".zip"))
    }

    func testRepositoryVersionFileParses() throws {
        // VERSION at the repository root is what the update check reads, so it must parse.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        XCTAssertNotNil(AppVersion(text))
    }

    func testUpdateSettingsDefaultOnAndOldFilesStillLoad() throws {
        XCTAssertTrue(AppSettings().checkForUpdates)
        XCTAssertTrue(AppSettings().autoBuildUpdates)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{\"defaultSpeed\": 2}".utf8))
        XCTAssertTrue(old.checkForUpdates)
        XCTAssertTrue(old.autoBuildUpdates)
        let off = try JSONDecoder().decode(
            AppSettings.self,
            from: Data("{\"checkForUpdates\": false, \"autoBuildUpdates\": false}".utf8)
        )
        XCTAssertFalse(off.checkForUpdates)
        XCTAssertFalse(off.autoBuildUpdates)
    }
}
