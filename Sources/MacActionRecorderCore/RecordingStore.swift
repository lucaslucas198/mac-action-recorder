import Foundation

/// Stores each recording as `<uuid>.macro.json` inside one folder.
public final class RecordingStore {
    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) throws {
        self.directory = directory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordingError.io("Could not create \(directory.path): \(error.localizedDescription)")
        }
    }

    public func fileURL(for id: UUID) -> URL {
        return directory.appendingPathComponent("\(id.uuidString).\(RecordingFormat.fileExtension)")
    }

    public func exists(id: UUID) -> Bool {
        return fileManager.fileExists(atPath: fileURL(for: id).path)
    }

    /// Writes the recording atomically (a crash mid-write cannot leave a half-written file).
    public func save(_ recording: Recording) throws {
        let data = try RecordingCodec.encode(recording)
        do {
            try data.write(to: fileURL(for: recording.id), options: .atomic)
        } catch {
            throw RecordingError.io(error.localizedDescription)
        }
    }

    public func load(id: UUID) throws -> Recording {
        return try load(from: fileURL(for: id))
    }

    public func load(from url: URL) throws -> Recording {
        let data = try readFile(url)
        return try RecordingCodec.decode(data)
    }

    /// Loads every readable recording, newest first. Files that fail to load are reported
    /// in `failures` instead of aborting the whole listing.
    public func loadAll() -> (recordings: [Recording], failures: [(url: URL, error: Error)]) {
        var recordings: [Recording] = []
        var failures: [(url: URL, error: Error)] = []
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasSuffix("." + RecordingFormat.fileExtension) {
            do {
                recordings.append(try load(from: url))
            } catch {
                failures.append((url, error))
            }
        }
        recordings.sort { $0.createdAt > $1.createdAt }
        return (recordings, failures)
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RecordingError.notFound(url.lastPathComponent)
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw RecordingError.io(error.localizedDescription)
        }
    }

    /// Saves a copy under a new id and name ("<name> copy").
    @discardableResult
    public func duplicate(_ recording: Recording, now: Date = Date()) throws -> Recording {
        var copy = recording
        copy.id = UUID()
        copy.name = recording.name + " copy"
        copy.createdAt = now
        copy.modifiedAt = now
        copy.actions = recording.actions.map { action in
            var fresh = action
            fresh.id = UUID()
            return fresh
        }
        try save(copy)
        return copy
    }

    /// Imports a recording file into the store. The file is fully validated first; if its id
    /// already exists in the store, the import gets a new id so nothing is overwritten.
    @discardableResult
    public func importFile(at url: URL) throws -> Recording {
        var recording = try load(from: url)
        if exists(id: recording.id) {
            recording.id = UUID()
        }
        try save(recording)
        return recording
    }

    /// Writes a standalone copy of the recording to `url` for sharing or moving to another Mac.
    public func export(_ recording: Recording, to url: URL) throws {
        let data = try RecordingCodec.encode(recording)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw RecordingError.io(error.localizedDescription)
        }
    }

    /// Copies every recording into a new timestamped folder under `backupRoot` and keeps only
    /// the newest `keep` backup folders. Returns the new backup folder.
    @discardableResult
    public func createBackup(into backupRoot: URL, keep: Int, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let folder = backupRoot.appendingPathComponent("backup-" + formatter.string(from: now), isDirectory: true)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in urls where url.lastPathComponent.hasSuffix("." + RecordingFormat.fileExtension) {
                try fileManager.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            }
        } catch {
            throw RecordingError.io("Backup failed: \(error.localizedDescription)")
        }

        pruneBackups(in: backupRoot, keep: max(1, keep))
        return folder
    }

    private func pruneBackups(in root: URL, keep: Int) {
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix("backup-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if backups.count > keep {
            for old in backups[keep...] {
                try? fileManager.removeItem(at: old)
            }
        }
    }

    private func readFile(_ url: URL) throws -> Data {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber, size.intValue > RecordingCodec.defaultMaxFileSize {
            throw RecordingError.tooLarge(size.intValue)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw RecordingError.io("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
