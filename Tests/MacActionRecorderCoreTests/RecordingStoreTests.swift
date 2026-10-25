import XCTest
@testable import MacActionRecorderCore

final class RecordingStoreTests: XCTestCase {
    private var root: URL!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacActionRecorderTests-\(UUID().uuidString)", isDirectory: true)
        store = try RecordingStore(directory: root.appendingPathComponent("Recordings", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRecording(name: String, createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Recording {
        return Recording(
            name: name,
            createdAt: createdAt,
            modifiedAt: createdAt,
            actions: [.click(x: 1, y: 2), .text("hello", delay: 0.5), .key(KeyCodes.returnKey, delay: 0.1)]
        )
    }

    func testSaveAndLoad() throws {
        let recording = makeRecording(name: "First")
        try store.save(recording)
        XCTAssertTrue(store.exists(id: recording.id))
        XCTAssertEqual(try store.load(id: recording.id), recording)
    }

    func testSaveOverwritesExistingFileWithEdits() throws {
        var recording = makeRecording(name: "Editable")
        try store.save(recording)
        recording.name = "Renamed"
        recording.actions[1].text = "changed"
        try store.save(recording)

        let loaded = try store.load(id: recording.id)
        XCTAssertEqual(loaded.name, "Renamed")
        XCTAssertEqual(loaded.actions[1].text, "changed")
        XCTAssertEqual(store.loadAll().recordings.count, 1)
    }

    func testLoadAllReturnsNewestFirst() throws {
        let older = makeRecording(name: "older", createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        let newer = makeRecording(name: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(older)
        try store.save(newer)
        XCTAssertEqual(store.loadAll().recordings.map { $0.name }, ["newer", "older"])
    }

    func testCorruptFilesAreSkippedAndReportedWithoutAbortingTheListing() throws {
        try store.save(makeRecording(name: "good"))
        let junk = store.directory.appendingPathComponent("junk.\(RecordingFormat.fileExtension)")
        try Data("this is not json".utf8).write(to: junk)
        let alsoNotARecording = store.directory.appendingPathComponent("notes.txt")
        try Data("ignored".utf8).write(to: alsoNotARecording)

        let result = store.loadAll()
        XCTAssertEqual(result.recordings.map { $0.name }, ["good"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.url.lastPathComponent, junk.lastPathComponent)
    }

    func testDelete() throws {
        let recording = makeRecording(name: "doomed")
        try store.save(recording)
        try store.delete(id: recording.id)
        XCTAssertFalse(store.exists(id: recording.id))
        XCTAssertTrue(store.loadAll().recordings.isEmpty)
    }

    func testDeletingAMissingRecordingThrows() {
        XCTAssertThrowsError(try store.delete(id: UUID())) { error in
            guard let recordingError = error as? RecordingError, case .notFound = recordingError else {
                return XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    func testLoadingAMissingRecordingThrows() {
        XCTAssertThrowsError(try store.load(id: UUID()))
    }

    func testDuplicateGetsNewIdsAndCopySuffix() throws {
        let original = makeRecording(name: "Original")
        try store.save(original)
        let copy = try store.duplicate(original)

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Original copy")
        XCTAssertEqual(copy.actions.count, original.actions.count)
        XCTAssertEqual(copy.actions.map { $0.kind }, original.actions.map { $0.kind })
        XCTAssertTrue(Set(copy.actions.map { $0.id }).isDisjoint(with: Set(original.actions.map { $0.id })))
        XCTAssertEqual(store.loadAll().recordings.count, 2)
    }

    func testExportThenImportIntoAnotherStoreKeepsEverything() throws {
        var original = makeRecording(name: "Portable")
        original.targetApp = TargetApp(bundleID: "com.example.chat", name: "Chat")
        original.playbackDefaults = PlaybackDefaults(speed: 1.5, repeatCount: 4, loopDelay: 2)
        try store.save(original)

        let exportURL = root.appendingPathComponent("portable.\(RecordingFormat.fileExtension)")
        try store.export(original, to: exportURL)

        let otherStore = try RecordingStore(directory: root.appendingPathComponent("OtherMac", isDirectory: true))
        let imported = try otherStore.importFile(at: exportURL)

        XCTAssertEqual(imported, original, "id, actions, target app and playback settings all survive the transfer")
        XCTAssertEqual(try otherStore.load(id: original.id), original)
    }

    func testImportingAnExistingIdNeverOverwrites() throws {
        let original = makeRecording(name: "Original")
        try store.save(original)
        let exportURL = root.appendingPathComponent("again.\(RecordingFormat.fileExtension)")
        try store.export(original, to: exportURL)

        let imported = try store.importFile(at: exportURL)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertEqual(store.loadAll().recordings.count, 2)
        XCTAssertEqual(try store.load(id: original.id), original)
    }

    func testImportingAnInvalidFileFailsAndLeavesTheStoreUntouched() throws {
        let bad = root.appendingPathComponent("bad.\(RecordingFormat.fileExtension)")
        try Data("{\"formatVersion\":1,\"oops\":true}".utf8).write(to: bad)

        XCTAssertThrowsError(try store.importFile(at: bad))
        XCTAssertTrue(store.loadAll().recordings.isEmpty)
    }

    func testImportingAMissingFileThrows() {
        let missing = root.appendingPathComponent("nope.\(RecordingFormat.fileExtension)")
        XCTAssertThrowsError(try store.importFile(at: missing))
    }

    func testBackupCopiesFilesAndPrunesOldBackups() throws {
        for index in 0..<3 {
            try store.save(makeRecording(name: "r\(index)"))
        }
        let backupRoot = root.appendingPathComponent("Backups", isDirectory: true)

        var created: [URL] = []
        for step in 0..<4 {
            let now = Date(timeIntervalSince1970: 1_800_000_000 + Double(step) * 10)
            created.append(try store.createBackup(into: backupRoot, keep: 2, now: now))
        }

        let remaining = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
            .map { $0.lastPathComponent }
            .sorted()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining), Set(created.suffix(2).map { $0.lastPathComponent }), "the newest two are kept")

        let files = try FileManager.default.contentsOfDirectory(at: created[3], includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
    }

    func testStoreCreatesItsDirectory() throws {
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        _ = try RecordingStore(directory: nested)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
