import Foundation

/// One line in the activity log: a repetition that finished, failed or was stopped.
///
/// The log stores which message number and channel a run used, not the message text, so it does
/// not copy what was typed out of the macro.
public struct ActivityEntry: Codable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Equatable {
        /// Every step of the repetition ran.
        case sent
        /// The run stopped with an error (a safety stop, a missing permission...).
        case failed
        /// Stopped by the user part-way through the repetition.
        case stopped
    }

    public var id: UUID
    public var date: Date
    public var recordingID: UUID
    public var recordingName: String
    public var outcome: Outcome
    /// The repetition number within that playback (1-based).
    public var run: Int?
    /// 1-based message number from the campaign, if it had messages.
    public var messageNumber: Int?
    public var channel: String?
    /// The error, for failed runs.
    public var detail: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        recordingID: UUID,
        recordingName: String,
        outcome: Outcome,
        run: Int? = nil,
        messageNumber: Int? = nil,
        channel: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.date = date
        self.recordingID = recordingID
        self.recordingName = recordingName
        self.outcome = outcome
        self.run = run
        self.messageNumber = messageNumber
        self.channel = channel
        self.detail = detail
    }
}

/// The activity log, kept as one JSON file on this Mac. Newest entries last; the oldest are
/// dropped past `limit`. Not thread-safe: use it from one thread (the app uses the main thread).
public final class ActivityLogStore {
    public let fileURL: URL
    public let limit: Int
    public private(set) var entries: [ActivityEntry] = []

    public init(fileURL: URL, limit: Int = 2_000) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
        load()
    }

    /// Reads the file. A missing or unreadable file gives an empty log rather than an error.
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = Array(((try? decoder.decode([ActivityEntry].self, from: data)) ?? []).suffix(limit))
    }

    public func append(_ entry: ActivityEntry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    /// Finished runs of this macro since `since`.
    public func sentCount(recordingID: UUID, since: Date) -> Int {
        return entries.filter { $0.recordingID == recordingID && $0.outcome == .sent && $0.date >= since }.count
    }

    /// Finished runs of this macro since local midnight.
    public func sentToday(recordingID: UUID, now: Date = Date(), calendar: Calendar = .current) -> Int {
        return sentCount(recordingID: recordingID, since: calendar.startOfDay(for: now))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
