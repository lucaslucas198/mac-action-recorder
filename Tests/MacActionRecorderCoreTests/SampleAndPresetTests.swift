import XCTest
@testable import MacActionRecorderCore

final class SampleAndPresetTests: XCTestCase {
    private var repoRoot: URL {
        // <repo>/Tests/MacActionRecorderCoreTests/<this file>
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBundledSampleRecordingLoadsAndIsFreeOfCoordinates() throws {
        let url = repoRoot.appendingPathComponent("Samples/discord-send-message.macro.json")
        let data = try Data(contentsOf: url)
        let recording = try RecordingCodec.decode(data)

        XCTAssertEqual(recording.actions.count, 8)
        XCTAssertEqual(recording.actions.first?.kind, .key)
        XCTAssertEqual(recording.actions.first?.keyCode, KeyCodes.ansiK)
        XCTAssertEqual(recording.actions.first?.modifiers, [.command])
        XCTAssertTrue(recording.actions.allSatisfy { $0.x == nil && $0.y == nil }, "no screen coordinates in the sample")
        XCTAssertNil(recording.targetApp)
        XCTAssertTrue(RecordingValidator.errors(in: RecordingValidator.validate(recording)).isEmpty)
    }

    func testSampleRecordingSurvivesAReEncodeRoundTrip() throws {
        let url = repoRoot.appendingPathComponent("Samples/discord-send-message.macro.json")
        let recording = try RecordingCodec.decode(try Data(contentsOf: url))
        let again = try RecordingCodec.decode(try RecordingCodec.encode(recording))
        XCTAssertEqual(again, recording)
    }

    func testEveryPresetProducesValidActions() {
        XCTAssertEqual(Presets.all.count, 3)
        for preset in Presets.all {
            let actions = Presets.actions(for: preset.id, input: "general", secondInput: "hello")
            XCTAssertFalse(actions.isEmpty, preset.title)
            let recording = Recording(name: preset.title, actions: actions)
            let errors = RecordingValidator.errors(in: RecordingValidator.validate(recording))
            XCTAssertTrue(errors.isEmpty, "\(preset.title): \(errors)")
            XCTAssertTrue(actions.allSatisfy { $0.x == nil && $0.y == nil }, "presets never contain coordinates")
        }
    }

    func testOpenChannelPresetUsesTheQuickSwitcherShortcut() {
        let actions = Presets.openChannel("general")
        XCTAssertEqual(actions.first?.kind, .key)
        XCTAssertEqual(actions.first?.keyCode, KeyCodes.ansiK)
        XCTAssertEqual(actions.first?.modifiers, [.command])
        XCTAssertEqual(actions.last?.keyCode, KeyCodes.returnKey)
        XCTAssertTrue(actions.contains { $0.text == "general" })
    }

    func testUnknownPresetIsEmpty() {
        XCTAssertTrue(Presets.actions(for: "nope", input: "x").isEmpty)
    }

    func testActionDescriptions() {
        XCTAssertEqual(ActionDescriber.describe(.move(x: 420, y: 310)), "Move mouse to (420, 310)")
        XCTAssertEqual(ActionDescriber.describe(.click(x: 1, y: 2)), "Left click at (1, 2)")
        XCTAssertEqual(ActionDescriber.describe(.click(x: 1, y: 2, button: .right)), "Right click at (1, 2)")
        XCTAssertEqual(ActionDescriber.describe(.click(x: 1, y: 2, count: 2)), "Left double-click at (1, 2)")
        XCTAssertEqual(ActionDescriber.describe(.key(KeyCodes.ansiK, modifiers: [.command])), "Press ⌘K")
        XCTAssertEqual(ActionDescriber.describe(.key(KeyCodes.returnKey)), "Press Return")
        XCTAssertEqual(ActionDescriber.describe(.text("hi")), "Type “hi”")
        XCTAssertEqual(ActionDescriber.describe(.wait(1)), "Wait 1.00 s")
    }

    func testKeyNames() {
        XCTAssertEqual(KeyNames.name(for: 36), "Return")
        XCTAssertEqual(KeyNames.name(for: 123), "←")
        XCTAssertEqual(KeyNames.name(for: 250), "Key 250")
        XCTAssertEqual(KeyNames.display(keyCode: 1, modifiers: [.control, .option, .command]), "⌃⌥⌘S")
        XCTAssertEqual(KeyNames.display(keyCode: 40, modifiers: [.shift, .command]), "⇧⌘K")
    }
}
