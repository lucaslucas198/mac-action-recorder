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
        XCTAssertEqual(UpdateConfig.latestReleaseAPIURL.scheme, "https")
        XCTAssertEqual(UpdateConfig.latestReleaseAPIURL.host, "api.github.com")
        XCTAssertTrue(UpdateConfig.releaseDownloadPrefix.hasPrefix("https://github.com/"))
        XCTAssertTrue(UpdateConfig.releaseAssetName.hasSuffix(".zip"))
    }

    private func releaseJSON(
        tag: String = "v0.3.0",
        assetName: String = "MacActionRecorder-macOS.zip",
        assetURL: String? = nil,
        extra: String = ""
    ) -> Data {
        let url = assetURL ?? (UpdateConfig.releaseDownloadPrefix + "\(tag)/\(assetName)")
        let json = """
        {"tag_name": "\(tag)"\(extra), "assets": [
          {"name": "README.txt", "browser_download_url": "\(UpdateConfig.releaseDownloadPrefix)\(tag)/README.txt"},
          {"name": "\(assetName)", "browser_download_url": "\(url)"}
        ]}
        """
        return Data(json.utf8)
    }

    func testReleaseInfoReadsVersionAndAsset() throws {
        let info = try XCTUnwrap(ReleaseInfo.parse(releaseJSON()))
        XCTAssertEqual(info.version, AppVersion("0.3.0"))
        XCTAssertEqual(info.assetURL.lastPathComponent, "MacActionRecorder-macOS.zip")
        XCTAssertTrue(info.assetURL.absoluteString.hasPrefix(UpdateConfig.releaseDownloadPrefix))
    }

    func testReleaseInfoRejectsBadAnswers() {
        XCTAssertNil(ReleaseInfo.parse(Data("not json".utf8)))
        XCTAssertNil(ReleaseInfo.parse(Data("{\"message\": \"Not Found\"}".utf8)))
        XCTAssertNil(ReleaseInfo.parse(Data("[]".utf8)))
        // right version, but the app file is missing
        XCTAssertNil(ReleaseInfo.parse(releaseJSON(assetName: "other.zip")))
        // right name, but hosted somewhere else
        XCTAssertNil(ReleaseInfo.parse(releaseJSON(assetURL: "https://example.com/MacActionRecorder-macOS.zip")))
        XCTAssertNil(ReleaseInfo.parse(releaseJSON(assetURL: "http://github.com/x/MacActionRecorder-macOS.zip")))
        // unparseable tag, draft, prerelease
        XCTAssertNil(ReleaseInfo.parse(releaseJSON(tag: "nightly")))
        XCTAssertNil(ReleaseInfo.parse(releaseJSON(extra: ", \"draft\": true")))
        XCTAssertNil(ReleaseInfo.parse(releaseJSON(extra: ", \"prerelease\": true")))
    }

    func testWelcomeFlagDefaultsToFalseAndPersists() throws {
        XCTAssertFalse(AppSettings().hasCompletedWelcome)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{\"defaultSpeed\": 2}".utf8))
        XCTAssertFalse(old.hasCompletedWelcome)
        var settings = AppSettings()
        settings.hasCompletedWelcome = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: data).hasCompletedWelcome)
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

final class SetupStageTests: XCTestCase {
    func testStagesAreOrderedAndFractionsIncreaseWithoutReachingOne() {
        let stages = SetupStage.allCases
        XCTAssertEqual(stages.count, 3)
        XCTAssertEqual(SetupStage.count, 3)
        var previous = 0.0
        for stage in stages {
            XCTAssertGreaterThan(stage.fraction, previous)
            XCTAssertLessThan(stage.fraction, 1.0)
            previous = stage.fraction
        }
    }

    func testTextsAreFilledInAndStepsCountFromOne() {
        XCTAssertEqual(SetupStage.copying.stepText, "Step 1 of 3")
        XCTAssertEqual(SetupStage.installing.stepText, "Step 3 of 3")
        for stage in SetupStage.allCases {
            XCTAssertFalse(stage.title.isEmpty)
        }
        XCTAssertNotNil(SetupStage.signing.hint)
        XCTAssertNil(SetupStage.copying.hint)
    }
}
