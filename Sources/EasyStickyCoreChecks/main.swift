import CoreGraphics
import Darwin
import EasyStickyCore
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private var passedCount = 0
private var failedCount = 0

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(description: message) }
}

private func run(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passedCount += 1
        print("PASS \(name)")
    } catch {
        failedCount += 1
        print("FAIL \(name): \(error)")
    }
}

run("content change updates timestamp") {
    let createdAt = Date(timeIntervalSince1970: 100)
    let updatedAt = Date(timeIntervalSince1970: 200)
    var note = StickyNote(content: "before", createdAt: createdAt)

    note.setContent("after", at: updatedAt)

    try check(note.content == "after", "content was not updated")
    try check(note.updatedAt == updatedAt, "timestamp was not updated")
}

run("same content keeps timestamp") {
    let createdAt = Date(timeIntervalSince1970: 100)
    var note = StickyNote(content: "same", createdAt: createdAt)

    note.setContent("same", at: Date(timeIntervalSince1970: 200))

    try check(note.updatedAt == createdAt, "unchanged content modified the timestamp")
}

run("default behavior matches product plan") {
    let note = StickyNote()

    try check(note.displayMode == .allSpaces, "new notes must appear on all Spaces")
    try check(note.isAlwaysOnTop, "new notes must be pinned by default")
    try check(!note.isHidden, "new notes must be visible")
    try check(note.theme == .yellow, "new notes must use the yellow theme")
}

run("palette themes are complete and stable") {
    let expectedRawValues = [
        "yellow", "orange", "rose", "lavender", "blue", "mint", "sage", "graphite"
    ]

    try check(NoteTheme.allCases.map(\.rawValue) == expectedRawValues, "palette order or storage keys changed")
    try check(Set(expectedRawValues).count == expectedRawValues.count, "palette contains duplicate storage keys")
}

run("each note preserves its independent color") {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for theme in NoteTheme.allCases {
        let original = StickyNote(content: theme.rawValue, theme: theme)
        let restored = try decoder.decode(StickyNote.self, from: encoder.encode(original))
        try check(restored.theme == theme, "failed to preserve \(theme.rawValue)")
    }
}

run("selected text shortcut round-trip is stable") {
    let original = KeyboardShortcut.selectedTextDefault
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(KeyboardShortcut.self, from: data)

    try check(restored == original, "shortcut changed after persistence")
    try check(restored.keyLabel == "Y", "default shortcut label is incorrect")
}

run("offscreen frame moves into visible area") {
    let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let original = WindowFrame(x: 3000, y: -500, width: 320, height: 260)

    let normalized = original.normalized(to: [visibleFrame]).rect

    try check(visibleFrame.contains(normalized), "normalized frame is still offscreen")
    try check(normalized.size == CGSize(width: 320, height: 260), "normalization changed a valid size")
}

run("oversized frame is clamped to screen") {
    let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let original = WindowFrame(x: -100, y: -100, width: 1600, height: 1200)

    let normalized = original.normalized(to: [visibleFrame]).rect

    try check(normalized == visibleFrame, "oversized frame did not match visible frame")
}

run("frame stays on intersecting secondary display") {
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let original = WindowFrame(x: 2000, y: 300, width: 320, height: 260)

    let normalized = original.normalized(to: [primary, secondary]).rect

    try check(secondary.contains(normalized), "frame moved away from the secondary display")
    try check(normalized.origin == original.rect.origin, "valid origin changed unexpectedly")
}

run("invalid frame falls back to usable size") {
    let visibleFrame = CGRect(x: 0, y: 0, width: 1280, height: 720)
    let invalid = WindowFrame(x: .nan, y: 0, width: -1, height: 0)

    let normalized = invalid.normalized(to: [visibleFrame]).rect

    try check(visibleFrame.contains(normalized), "fallback frame is not visible")
    try check(normalized.size == CGSize(width: 320, height: 260), "fallback size is incorrect")
}

run("empty store loads cleanly") {
    try withTemporaryStore { store in
        let result = try store.load()
        try check(result.source == .empty, "empty store returned a non-empty source")
        try check(result.notes.isEmpty, "empty store returned notes")
    }
}

run("store round-trip preserves and sorts notes") {
    try withTemporaryStore { store in
        let later = StickyNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            content: "later",
            createdAt: Date(timeIntervalSince1970: 200),
            theme: .blue
        )
        let earlier = StickyNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            content: "earlier",
            createdAt: Date(timeIntervalSince1970: 100),
            displayMode: .currentSpace,
            isAlwaysOnTop: false
        )

        try store.save([later, earlier])
        let result = try store.load()

        try check(result.source == .primary, "round-trip did not load from primary storage")
        try check(result.notes == [earlier, later], "round-trip changed or failed to sort notes")
    }
}

run("corrupt primary recovers from backup") {
    try withTemporaryStore { store in
        let first = StickyNote(content: "safe copy")
        var second = first
        second.setContent("new copy")

        try store.save([first])
        try store.save([second])
        try Data("not-json".utf8).write(to: store.indexURL, options: .atomic)

        let recovered = try store.load()
        try check(recovered.source == .backup, "store did not report backup recovery")
        try check(recovered.notes == [first], "store recovered the wrong snapshot")

        let restored = try store.load()
        try check(restored.source == .primary, "backup was not restored to primary storage")
        try check(restored.notes == [first], "restored primary data changed")
    }
}

run("old v1 note without new fields remains readable") {
    let original = StickyNote(content: "已有便签", theme: .mint)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
    for key in ["richContent", "archivedAt", "reminderDate"] { object.removeValue(forKey: key) }
    let restored = try JSONDecoder().decode(StickyNote.self, from: JSONSerialization.data(withJSONObject: object))
    try check(restored == original, "old note changed during migration")
    try check(!restored.isArchived && restored.reminderDate == nil && restored.richContent == nil, "new optional fields did not default safely")
}

run("archive cancels reminder but preserves content and appearance") {
    var note = StickyNote(content: "待办", theme: .rose)
    note.richContent = Data([1, 2, 3])
    note.reminderDate = Date().addingTimeInterval(600)
    note.archive(at: Date(timeIntervalSince1970: 500))
    try check(note.isArchived && note.isHidden && note.reminderDate == nil, "archive did not clear active state")
    try check(note.content == "待办" && note.theme == .rose && note.richContent == Data([1, 2, 3]), "archive lost document")
    note.restore()
    try check(!note.isArchived && !note.isHidden, "restore did not make note active")
    try check(note.reminderDate == nil, "restore resurrected old reminder")
}

run("rich document and reminder survive storage") {
    try withTemporaryStore { store in
        var note = StickyNote(content: "图片与文字")
        note.setDocument(text: "图片与文字", richContent: Data([1, 2, 3, 4]))
        note.reminderDate = Date(timeIntervalSince1970: 2_000_000_000)
        var archive = StickyNote(content: "已完成")
        archive.archive()
        try store.save([note, archive])
        let restored = try store.load().notes
        try check(restored.first(where: { $0.id == note.id }) == note, "rich reminder note changed")
        try check(restored.first(where: { $0.id == archive.id }) == archive, "archived state lost")
    }
}

run("v1 migration preserves every field and leaves both original files untouched") {
    try withTemporaryStore { store in
        var first = StickyNote(content: "迁移测试", theme: .rose)
        first.richContent = fixtureDocument()
        first.reminderDate = Date(timeIntervalSince1970: 2_000_000_000)
        first.frame = WindowFrame(x: 1, y: 2, width: 380, height: 400)
        var archive = StickyNote(content: "归档", displayMode: .currentSpace, isAlwaysOnTop: false)
        archive.archive()
        let bytes = try legacyData([first, archive])
        try bytes.write(to: store.fileURL)
        let backup = try legacyData([archive])
        try backup.write(to: store.backupURL)
        let result = try store.load()
        try check(result.notes == [first, archive], "migration changed model fields")
        try check(Data(contentsOf: store.fileURL) == bytes, "migration rewrote legacy primary")
        try check(Data(contentsOf: store.backupURL) == backup, "migration rewrote legacy backup")
        let restarted = try NoteStore(fileURL: store.fileURL).load()
        try check(restarted.notes == result.notes, "restart after migration changed data")
        let before = try inventory(store.directoryURL)
        _ = try store.load()
        try store.save(result.notes)
        try check(inventory(store.directoryURL) == before, "repeated startup/save rewrote unchanged files")
    }
}

run("migration uses valid legacy backup without rewriting corrupt primary") {
    try withTemporaryStore { store in
        let note = StickyNote(content: "backup only")
        let broken = Data("broken".utf8)
        try broken.write(to: store.fileURL)
        try legacyData([note]).write(to: store.backupURL)
        let result = try store.load()
        try check(result.source == .backup && result.notes == [note], "valid backup was not migrated")
        try check(Data(contentsOf: store.fileURL) == broken, "corrupt legacy file was overwritten")
    }
}

run("unreadable legacy data fails closed") {
    try withTemporaryStore { store in
        let bytes = Data("broken".utf8)
        try bytes.write(to: store.fileURL)
        try bytes.write(to: store.backupURL)
        try expectFailure { _ = try store.load() }
        try expectFailure { try store.save([]) }
        try check(!FileManager.default.fileExists(atPath: store.indexURL.path), "failed migration published an index")
        try check(Data(contentsOf: store.fileURL) == bytes, "failed migration damaged source")
    }
}

run("future legacy schema cannot silently roll back to backup") {
    try withTemporaryStore { store in
        let future = Data("{\"schemaVersion\":99,\"notes\":[]}".utf8)
        try future.write(to: store.fileURL)
        try legacyData([StickyNote(content: "old")]).write(to: store.backupURL)
        try expectFailure { _ = try store.load() }
        try check(!FileManager.default.fileExists(atPath: store.indexURL.path), "unsupported schema was overwritten")
    }
}

run("interrupted migration retries safely with original data") {
    try withTemporaryStore { store in
        var note = StickyNote(content: "retry")
        note.richContent = fixtureDocument()
        let source = try legacyData([note])
        try source.write(to: store.fileURL)
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        let blocked = store.directoryURL.appendingPathComponent("assets")
        try Data("blocks directory creation".utf8).write(to: blocked)
        try expectFailure { _ = try store.load() }
        try check(!FileManager.default.fileExists(atPath: store.indexURL.path), "partial migration became visible")
        try check(Data(contentsOf: store.fileURL) == source, "failed migration changed source")
        try FileManager.default.removeItem(at: blocked)
        try check(store.load().notes == [note], "retry did not recover all fields")
    }
}

run("incremental metadata save leaves other note, document, and original asset unchanged") {
    try withTemporaryStore { store in
        var first = StickyNote(content: "first")
        first.richContent = fixtureDocument()
        let other = StickyNote(content: "other")
        try store.save([first, other])
        let before = try inventory(store.directoryURL)
        let firstIndex = try indexEntries(store)
        first.setWindowState(frame: WindowFrame(x: 10, y: 20, width: 600, height: 400), theme: .mint)
        try store.save([first, other])
        let secondIndex = try indexEntries(store)
        try check(firstIndex[other.id.uuidString] == secondIndex[other.id.uuidString], "unchanged note received a new revision")
        try check(firstIndex[first.id.uuidString] != secondIndex[first.id.uuidString], "changed note did not receive a revision")
        let after = try inventory(store.directoryURL)
        for (path, value) in before where path.hasPrefix("assets/") || path.hasPrefix("documents/") || path.hasPrefix("notes/") {
            try check(after[path] == value, "existing object rewritten: \(path)")
        }
        try check(NoteStore(fileURL: store.fileURL).load().notes == [first, other], "incremental save failed reload")
    }
}

run("identical originals are shared across notes and retain exact bytes") {
    try withTemporaryStore { store in
        let original = Data(repeating: 0xA5, count: 1024 * 1024)
        var a = StickyNote(content: "a")
        a.richContent = fixtureDocument(image: original)
        var b = StickyNote(content: "b")
        b.richContent = a.richContent
        try store.save([a, b])
        let assets = try FileManager.default.contentsOfDirectory(at: store.directoryURL.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
        try check(assets.count == 2, "duplicate image/text assets were written")
        let matches = try assets.filter { try Data(contentsOf: $0) == original }
        try check(matches.count == 1, "original file is not independently readable byte-for-byte")
        for file in try FileManager.default.contentsOfDirectory(at: store.directoryURL.appendingPathComponent("notes"), includingPropertiesForKeys: nil) {
            let metadata = try Data(contentsOf: file)
            try check(metadata.count < 2048 && !String(decoding: metadata, as: UTF8.self).contains("richContent"), "note metadata embeds attachment data")
        }
    }
}

run("failed index commit leaves previous transaction recoverable and allows retry") {
    try withTemporaryStore { store in
        var note = StickyNote(content: "before")
        try store.save([note])
        let old = note
        try FileManager.default.removeItem(at: store.indexURL)
        try FileManager.default.createDirectory(at: store.indexURL, withIntermediateDirectories: false)
        note.setContent("after")
        try expectFailure { try store.save([note]) }
        try FileManager.default.removeItem(at: store.indexURL)
        try check(NoteStore(fileURL: store.fileURL).load().notes == [old], "failed write lost committed state")
        try store.save([note])
        try check(NoteStore(fileURL: store.fileURL).load().notes == [note], "retry did not commit latest state")
    }
}

run("corrupt newest note rolls back the complete transaction") {
    try withTemporaryStore { store in
        var note = StickyNote(content: "before")
        try store.save([note])
        let old = note
        note.setContent("after")
        try store.save([note])
        let hash = try indexEntries(store)[note.id.uuidString]!
        try Data("damaged".utf8).write(to: store.directoryURL.appendingPathComponent("notes/\(hash)"))
        let result = try NoteStore(fileURL: store.fileURL).load()
        try check(result.source == .backup && result.notes == [old], "damaged revision did not recover previous transaction")
    }
}

run("missing shared original fails closed and never resurrects stale legacy data") {
    try withTemporaryStore { store in
        var note = StickyNote(content: "original")
        note.richContent = fixtureDocument()
        try legacyData([note]).write(to: store.fileURL)
        _ = try store.load()
        note.content = "newer"
        try store.save([note])
        let asset = try FileManager.default.contentsOfDirectory(at: store.directoryURL.appendingPathComponent("assets"), includingPropertiesForKeys: nil).first!
        try FileManager.default.removeItem(at: asset)
        try expectFailure { _ = try NoteStore(fileURL: store.fileURL).load() }
    }
}

run("deletion keeps one recovery generation and then collects unreferenced originals") {
    try withTemporaryStore { store in
        var a = StickyNote(content: "delete")
        a.richContent = fixtureDocument()
        var b = StickyNote(content: "keep")
        try store.save([a, b])
        try store.save([b])
        try check(NoteStore(fileURL: store.fileURL).load().notes == [b], "deleted note resurrected")
        let assets = store.directoryURL.appendingPathComponent("assets")
        try check(!FileManager.default.contentsOfDirectory(atPath: assets.path).isEmpty, "backup original removed too soon")
        b.setContent("keep changed")
        try store.save([b])
        try check(FileManager.default.contentsOfDirectory(atPath: assets.path).isEmpty, "unreferenced original leaked")
        try store.save([])
        try check(NoteStore(fileURL: store.fileURL).load().notes.isEmpty, "empty index resurrected deleted notes")
    }
}

run("many incremental revisions stay bounded and no-op saves write nothing") {
    try withTemporaryStore { store in
        var note = StickyNote(content: "0")
        for i in 0..<30 { note.setContent(String(i)); try store.save([note]) }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.appendingPathComponent("notes").path)
        try check(files.count == 2, "revision history grew without bound")
        let before = try inventory(store.directoryURL)
        try store.save([note])
        try check(inventory(store.directoryURL) == before, "no-op save wrote files")
    }
}

run("future v2 schema and duplicate identifiers fail without overwriting data") {
    try withTemporaryStore { store in
        let note = StickyNote(content: "safe")
        try store.save([note])
        let before = try Data(contentsOf: store.indexURL)
        try expectFailure { try store.save([note, note]) }
        try check(Data(contentsOf: store.indexURL) == before, "duplicate input overwrote index")
        try Data("{\"schemaVersion\":99,\"notes\":{}}".utf8).write(to: store.indexURL)
        try expectFailure { _ = try NoteStore(fileURL: store.fileURL).load() }
    }
}

print("\n\(passedCount) passed, \(failedCount) failed")
if failedCount > 0 {
    exit(EXIT_FAILURE)
}

private func withTemporaryStore(_ body: (NoteStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("EasyStickyChecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try body(NoteStore(fileURL: directory.appendingPathComponent("notes.json")))
}

private func legacyData(_ notes: [StickyNote]) throws -> Data {
    struct Snapshot: Encodable { let schemaVersion = 1; let notes: [StickyNote] }
    return try JSONEncoder().encode(Snapshot(notes: notes))
}

private func fixtureDocument(image: Data = Data([0, 1, 2, 3, 4])) -> Data {
    let text = FileWrapper(regularFileWithContents: Data("{\\rtf1 fixture}".utf8))
    text.preferredFilename = "TXT.rtf"
    let original = FileWrapper(regularFileWithContents: image)
    original.preferredFilename = "original.png"
    return FileWrapper(directoryWithFileWrappers: ["TXT.rtf": text, "original.png": original]).serializedRepresentation!
}

private func expectFailure(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw CheckFailure(description: "operation unexpectedly succeeded")
}

private func indexEntries(_ store: NoteStore) throws -> [String: String] {
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL)) as! [String: Any]
    return json["notes"] as! [String: String]
}

private struct FileState: Equatable { let bytes: Data; let modified: Date }
private func inventory(_ directory: URL) throws -> [String: FileState] {
    var result: [String: FileState] = [:]
    let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])!
    for case let url as URL in files {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        if values.isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count + 1))] = FileState(bytes: try Data(contentsOf: url), modified: values.contentModificationDate!)
        }
    }
    return result
}
