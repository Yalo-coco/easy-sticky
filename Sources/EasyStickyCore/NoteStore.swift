import Foundation

public enum NoteLoadSource: Equatable, Sendable {
    case empty
    case primary
    case backup
}

public struct NoteLoadResult: Equatable, Sendable {
    public let notes: [StickyNote]
    public let source: NoteLoadSource

    public init(notes: [StickyNote], source: NoteLoadSource) {
        self.notes = notes
        self.source = source
    }
}

public enum NoteStoreError: LocalizedError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "不支持的便签数据版本：\(version)"
        }
    }
}

private struct NoteSnapshot: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let notes: [StickyNote]

    init(notes: [StickyNote]) {
        schemaVersion = Self.currentSchemaVersion
        self.notes = notes
    }
}

public final class NoteStore {
    public let fileURL: URL
    public let backupURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        backupURL = fileURL.deletingPathExtension().appendingPathExtension("backup.json")
        self.fileManager = fileManager

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
    }

    public func load() throws -> NoteLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            if fileManager.fileExists(atPath: backupURL.path) {
                let backupData = try Data(contentsOf: backupURL)
                let notes = try decode(backupData)
                try? backupData.write(to: fileURL, options: .atomic)
                return NoteLoadResult(notes: notes, source: .backup)
            }
            return NoteLoadResult(notes: [], source: .empty)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return NoteLoadResult(notes: try decode(data), source: .primary)
        } catch let primaryError {
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw primaryError
            }

            do {
                let backupData = try Data(contentsOf: backupURL)
                let notes = try decode(backupData)
                try? backupData.write(to: fileURL, options: .atomic)
                return NoteLoadResult(notes: notes, source: .backup)
            } catch {
                throw primaryError
            }
        }
    }

    public func save(_ notes: [StickyNote]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: fileURL.path),
           let currentData = try? Data(contentsOf: fileURL),
           (try? decode(currentData)) != nil {
            try currentData.write(to: backupURL, options: .atomic)
        }

        let sortedNotes = notes.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        let data = try encoder.encode(NoteSnapshot(notes: sortedNotes))
        try data.write(to: fileURL, options: .atomic)
    }

    private func decode(_ data: Data) throws -> [StickyNote] {
        let snapshot = try decoder.decode(NoteSnapshot.self, from: data)
        guard snapshot.schemaVersion == NoteSnapshot.currentSchemaVersion else {
            throw NoteStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot.notes
    }
}
