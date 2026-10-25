import Foundation

public enum RecordingError: Error, LocalizedError, Equatable {
    case notFound(String)
    case tooLarge(Int)
    case invalidJSON(String)
    case missingVersion
    case unsupportedVersion(Int)
    case newerVersion(Int)
    case invalid([String])
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "Recording not found: \(name)"
        case .tooLarge(let bytes):
            return "The file is too large to be a recording (\(bytes) bytes)."
        case .invalidJSON(let detail):
            return "The file is not a valid recording: \(detail)"
        case .missingVersion:
            return "The file has no formatVersion, so it is not a recording."
        case .unsupportedVersion(let version):
            return "Unsupported recording format version \(version)."
        case .newerVersion(let version):
            return "This recording uses format version \(version), which is newer than this app supports (\(RecordingFormat.currentVersion)). Update Mac Action Recorder."
        case .invalid(let messages):
            let first = messages.prefix(3).joined(separator: " ")
            return "The recording failed validation. \(first)"
        case .io(let detail):
            return "File error: \(detail)"
        }
    }
}

/// Reads and writes the versioned JSON recording format.
public enum RecordingCodec {
    /// Files larger than this are rejected before parsing (50 MB).
    public static let defaultMaxFileSize = 50 * 1024 * 1024

    private struct VersionHeader: Decodable {
        let formatVersion: Int?
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ recording: Recording) throws -> Data {
        do {
            return try makeEncoder().encode(recording)
        } catch {
            throw RecordingError.io("Could not encode recording: \(error.localizedDescription)")
        }
    }

    /// Decodes, migrates and validates a recording. Never traps on malformed input.
    public static func decode(_ data: Data, maxBytes: Int = defaultMaxFileSize) throws -> Recording {
        if data.count > maxBytes {
            throw RecordingError.tooLarge(data.count)
        }

        let decoder = makeDecoder()

        let header: VersionHeader
        do {
            header = try decoder.decode(VersionHeader.self, from: data)
        } catch {
            throw RecordingError.invalidJSON(describe(error))
        }

        guard let version = header.formatVersion else {
            throw RecordingError.missingVersion
        }
        if version < 1 {
            throw RecordingError.unsupportedVersion(version)
        }
        if version > RecordingFormat.currentVersion {
            throw RecordingError.newerVersion(version)
        }

        var recording: Recording
        do {
            recording = try decoder.decode(Recording.self, from: data)
        } catch {
            throw RecordingError.invalidJSON(describe(error))
        }

        recording = migrate(recording, from: version)

        let errors = RecordingValidator.errors(in: RecordingValidator.validate(recording))
        if !errors.isEmpty {
            throw RecordingError.invalid(errors.map { $0.description })
        }
        return recording
    }

    /// Upgrades older versions to the current model. Version 1 is current, so this is the
    /// hook where future versions add their steps (v1 -> v2, v2 -> v3, ...).
    static func migrate(_ recording: Recording, from version: Int) -> Recording {
        var result = recording
        // if version < 2 { ... upgrade ... }
        result.formatVersion = RecordingFormat.currentVersion
        return result
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, _):
                return "missing field '\(key.stringValue)'"
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            @unknown default:
                return "unreadable data"
            }
        }
        return error.localizedDescription
    }
}
