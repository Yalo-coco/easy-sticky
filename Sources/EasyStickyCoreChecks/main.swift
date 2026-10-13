import CoreGraphics
import Darwin
import EasyStickyCore
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private var passedCount = 0
private var failedCount = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
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
        try Data("not-json".utf8).write(to: store.fileURL, options: .atomic)

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
