import CryptoKit
import Foundation

public enum NoteLoadSource: Equatable, Sendable { case empty, primary, backup }

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
    case damagedData
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "不支持的便签数据版本：\(version)"
        case .damagedData: return "便签文件或附件校验失败，已停止保存。"
        }
    }
}

private struct LegacySnapshot: Codable {
    let schemaVersion: Int
    let notes: [StickyNote]
}

private struct NoteIndex: Codable {
    var schemaVersion = 2
    var notes: [String: String] = [:]
}

private struct NoteRecord: Codable {
    var note: StickyNote
    var document: String?
}

/// Directory structure stays in JSON; original file bytes live in immutable assets.
private struct DocumentRecord: Codable {
    var filename: String?
    var preferredFilename: String?
    var children: [String: DocumentRecord]?
    var asset: String?
    var opaque: Bool?
}

/// Confine one instance to one serial queue. The index is the only commit point.
public final class NoteStore {
    /// Legacy files remain untouched for migration and manual rollback.
    public let fileURL: URL
    public let backupURL: URL
    public let directoryURL: URL
    public var indexURL: URL { directoryURL.appendingPathComponent("index.json") }
    public var backupIndexURL: URL { directoryURL.appendingPathComponent("index.backup.json") }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var initialized = false
    private var index: NoteIndex?
    private var cachedNotes: [UUID: StickyNote] = [:]
    private var records: [UUID: NoteRecord] = [:]

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        backupURL = fileURL.deletingPathExtension().appendingPathExtension("backup.json")
        directoryURL = fileURL.deletingLastPathComponent().appendingPathComponent("Store-v2", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() throws -> NoteLoadResult {
        initialized = false
        if exists(indexURL) || exists(backupIndexURL) {
            let (data, source) = try recover(primary: indexURL, backup: backupIndexURL) { _ = try self.readIndex($0) }
            let (loadedIndex, loadedRecords, notes) = try readIndex(data)
            // Recover a complete transaction, never mix revisions or revert to stale v1.
            if source == .backup { try data.write(to: indexURL, options: .atomic) }
            index = loadedIndex
            records = loadedRecords
            cachedNotes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
            initialized = true
            return NoteLoadResult(notes: sorted(notes), source: source)
        }
        index = nil
        records = [:]
        cachedNotes = [:]
        guard exists(fileURL) || exists(backupURL) else {
            initialized = true
            return NoteLoadResult(notes: [], source: .empty)
        }
        let (data, source) = try recover(primary: fileURL, backup: backupURL) { _ = try self.decodeLegacy($0) }
        let notes = try decodeLegacy(data)
        initialized = true
        do { try save(notes) }
        catch { initialized = false; throw error }
        return NoteLoadResult(notes: sorted(notes), source: source)
    }

    public func save(_ notes: [StickyNote]) throws {
        if !initialized { _ = try load() }
        guard Set(notes.map(\.id)).count == notes.count else { throw NoteStoreError.damagedData }
        let incoming = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        if index != nil && incoming == cachedNotes { return }
        for folder in ["notes", "documents", "assets"] {
            try fileManager.createDirectory(at: directoryURL.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        var next = NoteIndex()
        var nextRecords: [UUID: NoteRecord] = [:]
        for note in notes {
            if cachedNotes[note.id] == note, let hash = index?.notes[note.id.uuidString] {
                next.notes[note.id.uuidString] = hash
                nextRecords[note.id] = records[note.id]
                continue
            }
            var record = NoteRecord(note: note)
            record.note.richContent = nil
            if let rich = note.richContent {
                if cachedNotes[note.id]?.richContent == rich, let previous = records[note.id] {
                    record.document = previous.document
                } else {
                    let document: DocumentRecord
                    if let wrapper = FileWrapper(serializedRepresentation: rich) {
                        document = try storeWrapper(wrapper)
                    } else {
                        // Do not discard undecodable documents from older versions.
                        document = DocumentRecord(asset: try put(rich, in: "assets"), opaque: true)
                    }
                    record.document = try put(encoder.encode(document), in: "documents")
                }
            }
            next.notes[note.id.uuidString] = try put(encoder.encode(record), in: "notes")
            nextRecords[note.id] = record
        }
        let data = try encoder.encode(next)
        // Verify the entire migration before switching. Normal writes verify changed objects in put().
        if index == nil { _ = try readIndex(data) }
        let previous = try index.map { try encoder.encode($0) } ?? data
        try previous.write(to: backupIndexURL, options: .atomic)
        try data.write(to: indexURL, options: .atomic)
        index = next
        records = nextRecords
        cachedNotes = incoming
        // Retain current + previous transaction; cleanup failure cannot invalidate a committed save.
        try? collectUnusedFiles()
    }

    private func decodeLegacy(_ data: Data) throws -> [StickyNote] {
        let snapshot = try decoder.decode(LegacySnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw NoteStoreError.unsupportedSchema(snapshot.schemaVersion) }
        guard Set(snapshot.notes.map(\.id)).count == snapshot.notes.count else { throw NoteStoreError.damagedData }
        return snapshot.notes
    }

    private func recover(primary: URL, backup: URL, validate: (Data) throws -> Void) throws -> (Data, NoteLoadSource) {
        do {
            let data = try Data(contentsOf: primary)
            try validate(data)
            return (data, .primary)
        } catch NoteStoreError.unsupportedSchema(let version) {
            throw NoteStoreError.unsupportedSchema(version)
        } catch let original {
            guard exists(backup) else { throw original }
            let data = try Data(contentsOf: backup)
            try validate(data)
            return (data, .backup)
        }
    }

    private func readIndex(_ data: Data) throws -> (NoteIndex, [UUID: NoteRecord], [StickyNote]) {
        let value = try decoder.decode(NoteIndex.self, from: data)
        guard value.schemaVersion == 2 else { throw NoteStoreError.unsupportedSchema(value.schemaVersion) }
        var result: [StickyNote] = []
        var loaded: [UUID: NoteRecord] = [:]
        for (id, hash) in value.notes {
            let record = try decoder.decode(NoteRecord.self, from: get(hash, in: "notes"))
            guard record.note.id.uuidString == id, record.note.richContent == nil else { throw NoteStoreError.damagedData }
            var note = record.note
            if let hash = record.document {
                let document = try decoder.decode(DocumentRecord.self, from: get(hash, in: "documents"))
                if document.opaque == true, let asset = document.asset {
                    note.richContent = try get(asset, in: "assets")
                } else {
                    guard let rich = try restoreWrapper(document).serializedRepresentation else { throw NoteStoreError.damagedData }
                    note.richContent = rich
                }
            }
            loaded[note.id] = record
            result.append(note)
        }
        return (value, loaded, result)
    }

    private func storeWrapper(_ wrapper: FileWrapper) throws -> DocumentRecord {
        var record = DocumentRecord(filename: wrapper.filename, preferredFilename: wrapper.preferredFilename)
        if wrapper.isRegularFile, let bytes = wrapper.regularFileContents {
            record.asset = try put(bytes, in: "assets")
        } else if wrapper.isDirectory, let children = wrapper.fileWrappers {
            record.children = try children.mapValues { try storeWrapper($0) }
        } else { throw NoteStoreError.damagedData }
        return record
    }

    private func restoreWrapper(_ record: DocumentRecord) throws -> FileWrapper {
        let wrapper: FileWrapper
        if let children = record.children {
            var restored: [String: FileWrapper] = [:]
            for (name, child) in children {
                let file = try restoreWrapper(child)
                // RTF references these unique directory keys. Duplicate preferred names otherwise
                // get reassigned in dictionary iteration order, silently swapping same-named images.
                file.preferredFilename = name
                file.filename = name
                restored[name] = file
            }
            wrapper = FileWrapper(directoryWithFileWrappers: restored)
        } else if let asset = record.asset {
            wrapper = FileWrapper(regularFileWithContents: try get(asset, in: "assets"))
        } else { throw NoteStoreError.damagedData }
        if let filename = record.filename { wrapper.filename = filename }
        if let filename = record.preferredFilename { wrapper.preferredFilename = filename }
        return wrapper
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func objectURL(_ hash: String, in folder: String) throws -> URL {
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw NoteStoreError.damagedData }
        return directoryURL.appendingPathComponent(folder).appendingPathComponent(hash)
    }
    private func get(_ hash: String, in folder: String) throws -> Data {
        let bytes = try Data(contentsOf: objectURL(hash, in: folder))
        guard digest(bytes) == hash else { throw NoteStoreError.damagedData }
        return bytes
    }
    private func put(_ bytes: Data, in folder: String) throws -> String {
        let hash = digest(bytes)
        let url = try objectURL(hash, in: folder)
        if !exists(url) { try bytes.write(to: url, options: .atomic) }
        guard try get(hash, in: folder) == bytes else { throw NoteStoreError.damagedData }
        return hash
    }
    private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }
    private func sorted(_ notes: [StickyNote]) -> [StickyNote] {
        notes.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    private func collectUnusedFiles() throws {
        var keep: [String: Set<String>] = ["notes": [], "documents": [], "assets": []]
        func visit(_ document: DocumentRecord) {
            if let asset = document.asset { keep["assets"]!.insert(asset) }
            document.children?.values.forEach(visit)
        }
        for url in [indexURL, backupIndexURL] {
            let snapshot = try decoder.decode(NoteIndex.self, from: Data(contentsOf: url))
            for hash in snapshot.notes.values {
                keep["notes"]!.insert(hash)
                let record = try decoder.decode(NoteRecord.self, from: get(hash, in: "notes"))
                if let document = record.document {
                    keep["documents"]!.insert(document)
                    visit(try decoder.decode(DocumentRecord.self, from: get(document, in: "documents")))
                }
            }
        }
        // Only app-generated hash objects in these exact folders are eligible.
        for (folder, hashes) in keep {
            for url in try fileManager.contentsOfDirectory(at: directoryURL.appendingPathComponent(folder), includingPropertiesForKeys: nil) {
                let hash = url.lastPathComponent
                guard !hashes.contains(hash), (try? objectURL(hash, in: folder)) != nil else { continue }
                try fileManager.removeItem(at: url)
            }
        }
    }
}
