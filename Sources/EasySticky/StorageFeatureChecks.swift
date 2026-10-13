import AppKit
import EasyStickyCore

/// Uses generated images and an isolated directory, never the user's live notes.
func runStorageFeatureChecks() -> (total: Int, failures: Int) {
    var total = 0
    var failures = 0
    func check(_ value: Bool, _ name: String) {
        total += 1
        if value { print("PASS \(name)") }
        else { failures += 1; print("FAIL \(name)") }
    }
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp/261013-storage-checks/\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 1600, height: 900))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 1600, height: 900).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let originals = [
            ("same.png", bitmap.representation(using: .png, properties: [:])!),
            ("same.png", bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!),
            ("photo.tiff", image.tiffRepresentation!)
        ]
        let editor = RichNoteEditor(frame: NSRect(x: 0, y: 0, width: 420, height: 340))
        editor.isRichText = true
        editor.load(text: "加粗与链接\n", data: nil)
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        editor.format("bold")
        editor.textStorage?.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 3, length: 2))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        for (name, bytes) in originals { editor.insertImageData(bytes, filename: name) }
        var note = StickyNote(content: editor.string, theme: .blue)
        note.richContent = editor.documentData
        let beforeMigration = NSAttributedString(rtfd: note.richContent!, documentAttributes: nil)!
        func attachmentData(_ value: NSAttributedString) -> [Data] {
            var result: [Data] = []
            value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, _, _ in
                if let attachment = attachment as? NSTextAttachment, let bytes = attachment.fileWrapper?.regularFileContents { result.append(bytes) }
            }
            return result
        }
        check(attachmentData(beforeMigration) == originals.map(\.1), "native source fixture preserves same-named images before migration")
        note.reminderDate = Date(timeIntervalSince1970: 2_000_000_000)
        var archived = StickyNote(content: "已归档")
        archived.archive()
        struct Legacy: Encodable { let schemaVersion = 1; let notes: [StickyNote] }
        let originalJSON = try JSONEncoder().encode(Legacy(notes: [note, archived]))
        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        try originalJSON.write(to: store.fileURL)
        _ = try store.load()
        let reloaded = try NoteStore(fileURL: store.fileURL).load().notes
        check(reloaded.count == 2 && reloaded.contains(archived), "migration preserves archived notes alongside images")
        let restored = reloaded.first { $0.id == note.id }!
        check(restored.content == note.content && restored.reminderDate == note.reminderDate && restored.theme == note.theme, "migration preserves text, reminder, and theme")
        let document = NSAttributedString(rtfd: restored.richContent!, documentAttributes: nil)!
        check(document.string == editor.string, "split document reconstructs complete native rich text")
        let font = document.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        check(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "migration retains bold formatting")
        check(document.attribute(.link, at: 3, effectiveRange: nil) != nil, "migration retains hyperlink")
        var attachments: [Data] = []
        document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment, let bytes = attachment.fileWrapper?.regularFileContents { attachments.append(bytes) }
        }
        check(attachments == originals.map(\.1), "PNG JPEG TIFF originals remain byte-identical after real migration and restart")
        let assetURLs = try FileManager.default.contentsOfDirectory(at: store.directoryURL.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
        let assetBytes = try assetURLs.map { try Data(contentsOf: $0) }
        check(originals.allSatisfy { assetBytes.contains($0.1) }, "all three originals exist as independent raw files")
        check(try Data(contentsOf: store.fileURL) == originalJSON, "native migration leaves original JSON untouched")

        var changes: [StickyNote] = []
        let controller = StickyNoteWindowController(note: restored,
            visibleFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)],
            fallbackFrame: CGRect(x: 50, y: 50, width: 420, height: 340),
            onChange: { changes.append($0) }, onFocus: { _ in }, onAction: { _, _ in })
        let scroll = controller.window!.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
        let live = scroll.documentView as! RichNoteEditor
        let oldRich = controller.note.richContent
        live.setSelectedRange(NSRange(location: 0, length: 0))
        live.insertText("连续输入", replacementRange: live.selectedRange())
        live.insertText("末次编辑", replacementRange: live.selectedRange())
        check(controller.note.content.hasPrefix("连续输入末次编辑") && controller.note.richContent == oldRich,
              "typing updates text without serializing rich attachments on every keystroke")
        let snapshot = try controller.flushDocument()
        check(NSAttributedString(rtfd: snapshot.richContent!, documentAttributes: nil)?.string == live.string,
              "immediate flush captures last edit before close archive or quit")
        let secondFlush = try controller.flushDocument()
        check(snapshot == secondFlush, "unchanged editor flush reuses serialized document")
        controller.hide()
        check(try controller.flushDocument().content == live.string, "hide cannot discard pending document")
        let queue = DispatchQueue(label: "EasySticky.storage-test")
        queue.async { try! store.save([restored, archived]) }
        try queue.sync { try store.save([snapshot, archived]) }
        var finalNote = try NoteStore(fileURL: store.fileURL).load().notes.first { $0.id == snapshot.id }!
        let finalDocument = NSAttributedString(rtfd: finalNote.richContent!, documentAttributes: nil)!
        let snapshotDocument = NSAttributedString(rtfd: snapshot.richContent!, documentAttributes: nil)!
        // Flat RTFD directory entry order is not stable; compare metadata and document semantics.
        finalNote.richContent = snapshot.richContent
        check(finalNote == snapshot && finalDocument.string == snapshotDocument.string && attachmentData(finalDocument) == attachmentData(snapshotDocument), "serial final flush wins over older queued save")
        controller.window?.setContentSize(NSSize(width: 380, height: 400))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        var fits = true
        live.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: live.attributedString().length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                fits = fits && (attachment.attachmentCell?.cellSize().width ?? .infinity) <= scroll.contentSize.width - 34
            }
        }
        check(fits, "migrated images still adapt to narrow note width")
    } catch {
        total += 1
        failures += 1
        print("FAIL storage feature checks: \(error)")
    }
    return (total, failures)
}
