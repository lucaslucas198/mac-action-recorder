import XCTest
@testable import MacActionRecorderCore

final class RecordingCodecTests: XCTestCase {
    static let validJSON = """
    {"formatVersion":1,"id":"11111111-1111-1111-1111-111111111111","name":"x",
     "createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z",
     "actions":[{"kind":"click","x":1,"y":2,"button":"left","clickCount":1}]}
    """

    private func sampleRecording() -> Recording {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        return Recording(
            name: "Round trip",
            createdAt: created,
            modifiedAt: created,
            targetApp: TargetApp(bundleID: "com.example.app", name: "Example"),
            recordedScreen: ScreenSize(width: 1512, height: 982),
            playbackDefaults: PlaybackDefaults(speed: 2, repeatCount: 3, loopDelay: 1.5),
            notes: "some notes",
            actions: [
                .move(x: 10.5, y: 20.25),
                .click(x: 100, y: 200, button: .right, count: 2, delay: 0.4),
                .scroll(dx: 0, dy: -120, x: 100, y: 200, delay: 0.1),
                .key(KeyCodes.ansiK, modifiers: [.command, .shift], delay: 0.2),
                .text("héllo 👋", delay: 0.05),
                .wait(1.5),
                .mouseDown(x: 1, y: 2),
                .drag(x: 3, y: 4),
                .mouseUp(x: 3, y: 4)
            ]
        )
    }

    private func recordingError(from block: () throws -> Void) -> RecordingError? {
        do {
            try block()
            return nil
        } catch {
            return error as? RecordingError
        }
    }

    // MARK: Serialization

    func testRoundTripPreservesEveryField() throws {
        let original = sampleRecording()
        let data = try RecordingCodec.encode(original)
        let decoded = try RecordingCodec.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripPreservesActionOrder() throws {
        let original = sampleRecording()
        let decoded = try RecordingCodec.decode(try RecordingCodec.encode(original))
        XCTAssertEqual(decoded.actions.map { $0.kind }, original.actions.map { $0.kind })
        XCTAssertEqual(decoded.actions.map { $0.id }, original.actions.map { $0.id })
    }

    func testEncodedFileContainsVersionAndReadableModifiers() throws {
        let data = try RecordingCodec.encode(sampleRecording())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("formatVersion"))
        XCTAssertTrue(text.contains("\"command\""))
        XCTAssertTrue(text.contains("\"shift\""))
    }

    func testMinimalFileDecodesWithDefaults() throws {
        let recording = try RecordingCodec.decode(Data(Self.validJSON.utf8))
        XCTAssertEqual(recording.actions.count, 1)
        XCTAssertEqual(recording.actions[0].delay, 0)
        XCTAssertEqual(recording.actions[0].kind, .click)
        XCTAssertEqual(recording.formatVersion, RecordingFormat.currentVersion)
    }

    func testUnknownExtraFieldsAreIgnored() throws {
        let json = Self.validJSON.replacingOccurrences(of: "\"name\":\"x\"", with: "\"name\":\"x\",\"futureField\":{\"a\":1}")
        XCTAssertNoThrow(try RecordingCodec.decode(Data(json.utf8)))
    }

    // MARK: Invalid files

    func testGarbageIsRejectedWithoutCrashing() {
        let error = recordingError { _ = try RecordingCodec.decode(Data("not json at all".utf8)) }
        guard case .invalidJSON? = error else { return XCTFail("Expected invalidJSON, got \(String(describing: error))") }
    }

    func testEmptyDataIsRejected() {
        let error = recordingError { _ = try RecordingCodec.decode(Data()) }
        guard case .invalidJSON? = error else { return XCTFail("Expected invalidJSON, got \(String(describing: error))") }
    }

    func testTruncatedFileIsRejected() {
        let truncated = String(Self.validJSON.prefix(80))
        let error = recordingError { _ = try RecordingCodec.decode(Data(truncated.utf8)) }
        guard case .invalidJSON? = error else { return XCTFail("Expected invalidJSON, got \(String(describing: error))") }
    }

    func testJSONArrayIsRejected() {
        let error = recordingError { _ = try RecordingCodec.decode(Data("[1,2,3]".utf8)) }
        guard case .invalidJSON? = error else { return XCTFail("Expected invalidJSON, got \(String(describing: error))") }
    }

    func testMissingVersionIsRejected() {
        let error = recordingError { _ = try RecordingCodec.decode(Data("{\"name\":\"x\"}".utf8)) }
        XCTAssertEqual(error, .missingVersion)
    }

    func testNewerVersionIsRejectedWithClearError() {
        let error = recordingError { _ = try RecordingCodec.decode(Data("{\"formatVersion\":99}".utf8)) }
        XCTAssertEqual(error, .newerVersion(99))
    }

    func testVersionZeroIsRejected() {
        let error = recordingError { _ = try RecordingCodec.decode(Data("{\"formatVersion\":0}".utf8)) }
        XCTAssertEqual(error, .unsupportedVersion(0))
    }

    func testUnknownActionKindIsRejected() {
        let json = Self.validJSON.replacingOccurrences(of: "\"click\"", with: "\"teleport\"")
        let error = recordingError { _ = try RecordingCodec.decode(Data(json.utf8)) }
        guard case .invalidJSON? = error else { return XCTFail("Expected invalidJSON, got \(String(describing: error))") }
    }

    func testUnknownModifierIsRejected() {
        let json = Self.validJSON.replacingOccurrences(
            of: "\"clickCount\":1",
            with: "\"clickCount\":1,\"modifiers\":[\"hyper\"]"
        )
        let error = recordingError { _ = try RecordingCodec.decode(Data(json.utf8)) }
        guard case .invalidJSON? = error else { return XCTFail("Expected invalidJSON, got \(String(describing: error))") }
    }

    func testValidationFailuresAreReportedAsInvalid() {
        let json = Self.validJSON.replacingOccurrences(of: "\"button\":\"left\",", with: "")
        let error = recordingError { _ = try RecordingCodec.decode(Data(json.utf8)) }
        guard case .invalid(let messages)? = error else { return XCTFail("Expected invalid, got \(String(describing: error))") }
        XCTAssertFalse(messages.isEmpty)
    }

    func testOversizedFileIsRejectedBeforeParsing() {
        let data = Data(Self.validJSON.utf8)
        let error = recordingError { _ = try RecordingCodec.decode(data, maxBytes: 10) }
        XCTAssertEqual(error, .tooLarge(data.count))
    }
}
