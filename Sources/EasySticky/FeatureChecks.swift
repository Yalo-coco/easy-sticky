import AppKit
import EasyStickyCore

/// Runs without loading user notes, registering hotkeys, or requesting permissions.
func runFeatureChecks() -> Int32 {
    var failures = 0
    var total = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        total += 1
        if condition() { print("PASS \(name)") }
        else { failures += 1; print("FAIL \(name)") }
    }
    let editor = RichNoteEditor(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    editor.isRichText = true
    editor.allowsUndo = true
    editor.isEditable = true
    let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = editor
    window.makeFirstResponder(editor)
    editor.load(text: "Alpha 中文\nBeta", data: nil)
    editor.setSelectedRange(NSRange(location: 0, length: 5))
    editor.format("bold")
    let font = editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    check(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "bold applies to selection")
    editor.format("italic")
    editor.format("underline")
    editor.format("strike")
    editor.format("size:24")
    editor.format("color:红")
    let restored = RichNoteEditor()
    restored.load(text: "fallback", data: editor.documentData)
    let attributes = restored.attributedString().attributes(at: 0, effectiveRange: nil)
    check(restored.string == editor.string, "RTFD preserves multilingual text")
    check((attributes[.font] as? NSFont)?.pointSize == 24, "RTFD preserves font size")
    check((attributes[.underlineStyle] as? Int) == 1, "RTFD preserves underline")
    check((attributes[.strikethroughStyle] as? Int) == 1, "RTFD preserves strike")
    check((attributes[.foregroundColor] as? NSColor) != NSColor.textColor, "RTFD preserves custom color")
    editor.format("clear")
    check(editor.attributedString().attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil, "clear format removes strike")
    editor.load(text: "one\ntwo", data: nil)
    editor.setSelectedRange(NSRange(location: 0, length: 7))
    editor.format("todo")
    check(editor.string == "☐ one\n☐ two", "multiple lines become tasks")
    editor.toggleTask(at: 0)
    check(editor.string.hasPrefix("☑ one"), "task toggles completed")
    restored.load(text: "", data: editor.documentData)
    check(restored.string == editor.string, "task completion persists")
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    editor.insertNewline(nil)
    check(editor.string.hasSuffix("\n☐ "), "return continues checklist")
    editor.insertNewline(nil)
    check(editor.string.hasSuffix("\n") && !editor.string.hasSuffix("☐ "), "empty checklist return exits list")
    editor.load(text: "one\ntwo", data: nil)
    editor.setSelectedRange(NSRange(location: 0, length: 7))
    editor.format("number")
    check(editor.string == "1. one\n2. two", "numbered list numbers each line")
    editor.insertNewline(nil)
    check(editor.string.hasSuffix("3. "), "return increments list number")
    editor.load(text: "Heading", data: nil)
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    editor.format("h1")
    check((editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 28, "heading applies to paragraph")
    editor.format("codeBlock")
    check(editor.attributedString().attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil, "code block has background")
    editor.load(text: "image: ", data: nil)
    editor.setSelectedRange(NSRange(location: 7, length: 0))
    let image = NSImage(size: NSSize(width: 800, height: 300))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 800, height: 300).fill()
    image.unlockFocus()
    editor.insertLocalImage(image)
    restored.load(text: "", data: editor.documentData)
    let attachment = restored.attributedString().length > 7 ? restored.attributedString().attribute(.attachment, at: 7, effectiveRange: nil) as? NSTextAttachment : nil
    check(attachment != nil, "RTFD embeds and restores image")
    check((attachment?.attachmentCell?.cellSize().width ?? 0) <= 360, "image fits note width")
    editor.undoManager?.endUndoGrouping()
    editor.undoManager?.undo()
    check(!editor.string.contains("\u{FFFC}"), "image insertion supports undo")
    editor.undoManager?.redo()
    check(editor.string.contains("\u{FFFC}"), "image insertion supports redo")
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!
    let imageEditor = RichNoteEditor(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    imageEditor.textContainerInset = NSSize(width: 12, height: 8)
    func imageAttachment(_ editor: RichNoteEditor, at index: Int = 0) -> NSTextAttachment {
        editor.attributedString().attribute(.attachment, at: index, effectiveRange: nil) as! NSTextAttachment
    }
    for (name, bytes) in [("original.png", png), ("original.jpg", jpeg), ("original.tiff", image.tiffRepresentation!)] {
        imageEditor.load(text: "", data: nil)
        imageEditor.insertImageData(bytes, filename: name)
        let original = imageAttachment(imageEditor)
        check(original.fileWrapper?.regularFileContents == bytes, "\(name) inserts byte-for-byte original")
        let size = original.attachmentCell!.cellSize()
        check(size.width <= 366 && abs(size.width / size.height - 800.0 / 300.0) < 0.001, "\(name) fits content width without distortion")
        imageEditor.setFrameSize(NSSize(width: 200, height: 300))
        let narrow = original.attachmentCell!.cellSize()
        check(narrow.width <= 166 && narrow.width < size.width, "\(name) shrinks when note narrows")
        imageEditor.setFrameSize(NSSize(width: 700, height: 300))
        check(original.attachmentCell!.cellSize().width > narrow.width, "\(name) grows again using original image")
        check(original.fileWrapper?.regularFileContents == bytes, "\(name) resize never rewrites original bytes")
        let reloaded = RichNoteEditor(frame: NSRect(x: 0, y: 0, width: 280, height: 300))
        reloaded.load(text: "", data: imageEditor.documentData)
        check(imageAttachment(reloaded).fileWrapper?.regularFileContents == bytes, "\(name) RTFD reload preserves exact bytes")
        check(imageAttachment(reloaded).attachmentCell!.cellSize().width <= 270, "\(name) reload adapts to new note width")
        imageEditor.setFrameSize(NSSize(width: 400, height: 300))
    }
    imageEditor.load(text: "", data: nil)
    imageEditor.insertImageData(png, filename: "same.png")
    imageEditor.insertText("\n", replacementRange: imageEditor.selectedRange())
    imageEditor.insertImageData(jpeg, filename: "same.png")
    let multi = RichNoteEditor(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
    multi.load(text: "", data: imageEditor.documentData)
    check(imageAttachment(multi).fileWrapper?.regularFileContents == png && imageAttachment(multi, at: 2).fileWrapper?.regularFileContents == jpeg, "multiple same-named images keep independent original data")
    multi.setFrameSize(NSSize(width: 180, height: 300))
    check(imageAttachment(multi).attachmentCell!.cellSize().width <= 170 && imageAttachment(multi, at: 2).attachmentCell!.cellSize().width <= 170, "all images reflow on width change")
    let longImage = NSImage(size: NSSize(width: 120, height: 1200))
    longImage.lockFocus()
    NSColor.systemGreen.setFill()
    NSRect(x: 0, y: 0, width: 120, height: 1200).fill()
    longImage.unlockFocus()
    imageEditor.load(text: "", data: nil)
    imageEditor.insertLocalImage(longImage)
    let longSize = imageAttachment(imageEditor).attachmentCell!.cellSize()
    check(longSize.width == 120 && longSize.height == 1200, "small and tall images are not enlarged or cropped")
    imageEditor.setFrameSize(NSSize(width: 400, height: 150))
    check(imageAttachment(imageEditor).attachmentCell!.cellSize() == longSize, "height-only resize preserves image proportions and size")
    imageEditor.layoutManager?.ensureLayout(for: imageEditor.textContainer!)
    check((imageEditor.layoutManager?.usedRect(for: imageEditor.textContainer!).height ?? 0) >= 1200, "long image participates in vertically scrollable text layout")
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    clipboard.setData(png, forType: .png)
    check(CapturedSelection.read(from: clipboard)?.document.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment, "raw PNG clipboard becomes an image attachment")
    imageEditor.load(text: "", data: nil)
    _ = imageEditor.pasteRichContent(from: clipboard)
    check(imageAttachment(imageEditor).fileWrapper?.regularFileContents == png, "image paste preserves original PNG bytes")
    clipboard.clearContents()
    clipboard.setData(editor.documentData!, forType: .rtfd)
    clipboard.setString("plain fallback", forType: .string)
    let richCopy = CapturedSelection.read(from: clipboard)!
    check(richCopy.document.attribute(.attachment, at: 7, effectiveRange: nil) is NSTextAttachment, "capture prefers RTFD with embedded image over plain text")
    clipboard.clearContents()
    let html = "<meta charset='utf-8'><p>普通 <b>按协议拆 provider</b></p><p><code style='background-color:#eeeeee'>azure_openai</code> <a href='https://example.com'>链接</a></p>"
    clipboard.setData(Data(html.utf8), forType: .html)
    clipboard.setString("flattened text", forType: .string)
    let copied = CapturedSelection.read(from: clipboard)!
    let boldRange = (copied.text as NSString).range(of: "按协议拆")
    let codeRange = (copied.text as NSString).range(of: "azure_openai")
    let linkRange = (copied.text as NSString).range(of: "链接")
    check(copied.text.contains("\n") && copied.text.contains("普通"), "HTML capture preserves Chinese paragraphs instead of flattened fallback")
    check(NSFontManager.shared.traits(of: copied.document.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont).contains(.boldFontMask), "HTML capture preserves bold")
    check((copied.document.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)?.isFixedPitch == true, "HTML capture preserves code font")
    check(copied.document.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) != nil, "HTML capture preserves code background")
    check(copied.document.attribute(.link, at: linkRange.location, effectiveRange: nil) != nil, "HTML capture preserves links")
    restored.load(text: copied.text, data: copied.richContent)
    check(restored.attributedString().attribute(.link, at: linkRange.location, effectiveRange: nil) != nil, "captured formatting survives RTFD reload")
    editor.load(text: "", data: nil)
    check(editor.pasteRichContent(from: clipboard) && editor.string == copied.text, "ordinary paste uses rich content")
    check(editor.attributedString().attribute(.link, at: linkRange.location, effectiveRange: nil) != nil, "ordinary paste preserves link attributes")
    editor.undoManager?.endUndoGrouping()
    editor.undoManager?.undo()
    check(editor.string.isEmpty, "rich paste supports undo")
    clipboard.clearContents()
    clipboard.setData(Data("broken rtf".utf8), forType: .rtf)
    clipboard.setString("plain\ntext", forType: .string)
    check(CapturedSelection.read(from: clipboard)?.text == "plain\ntext", "unsupported rich content falls back to intact plain text")
    clipboard.clearContents()
    check(CapturedSelection.read(from: clipboard) == nil, "empty clipboard does not create a note")

    var panelAction: String?
    let controller = StickyNoteWindowController(note: StickyNote(), visibleFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)], fallbackFrame: CGRect(x: 50, y: 50, width: 420, height: 340), onChange: { _ in }, onFocus: { _ in }, onAction: { _, action in panelAction = action })
    check(controller.window is NSPanel, "sticky remains a panel")
    check(controller.window!.styleMask.contains(.nonactivatingPanel), "panel does not activate other Space")
    check(controller.window!.collectionBehavior.contains(.canJoinAllApplications), "panel opts into other app Spaces")
    check(controller.window!.collectionBehavior.contains(.fullScreenAuxiliary), "panel opts into fullscreen")
    check(controller.window!.level == .floating, "pinned panel floats")
    let noteScroll = controller.window!.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
    let noteEditor = noteScroll.documentView as! RichNoteEditor
    noteEditor.load(text: "", data: nil)
    noteEditor.insertImageData(png, filename: "window-test.png")
    controller.window!.setContentSize(NSSize(width: 380, height: 340))
    controller.window!.contentView!.layoutSubtreeIfNeeded()
    let compactImage = imageAttachment(noteEditor).attachmentCell!.cellSize()
    check(compactImage.width <= noteScroll.contentSize.width - 34, "real note layout fits image within editor padding")
    controller.window!.setContentSize(NSSize(width: 700, height: 340))
    controller.window!.contentView!.layoutSubtreeIfNeeded()
    let expandedImage = imageAttachment(noteEditor).attachmentCell!.cellSize()
    check(expandedImage.width > compactImage.width, "resizing real note width automatically expands image")
    controller.window!.setContentSize(NSSize(width: 380, height: 340))
    controller.window!.contentView!.layoutSubtreeIfNeeded()
    check(imageAttachment(noteEditor).attachmentCell!.cellSize() == compactImage, "repeated window shrink restores exact image layout")
    controller.window!.setContentSize(NSSize(width: 380, height: 500))
    controller.window!.contentView!.layoutSubtreeIfNeeded()
    check(imageAttachment(noteEditor).attachmentCell!.cellSize() == compactImage, "real window height resize does not distort image")
    check(imageAttachment(noteEditor).fileWrapper?.regularFileContents == png, "window resize preserves original image file")
    controller.toggleAlwaysOnTop()
    check(controller.window!.level == .normal, "unpin restores normal level")
    controller.toggleDisplayMode()
    check(!controller.window!.collectionBehavior.contains(.canJoinAllSpaces), "current Space mode removes all-Spaces behavior")
    controller.setReminder(Date(timeIntervalSince1970: 2_000_000_000))
    check(controller.note.reminderDate != nil, "reminder updates note")
    controller.setReminder(nil)
    check(controller.note.reminderDate == nil, "reminder can be removed")
    let windowCount = NSApp.windows.count
    controller.showReminderEditor(onSave: { _, done in done(nil) }, onCancel: {})
    check(NSApp.windows.count == windowCount, "reminder editor does not create another window")
    check(controller.window!.contentView!.subviews.contains { $0 is ReminderEditorView }, "reminder editor is embedded in note")
    controller.showReminderEditor(onSave: { _, done in done(nil) }, onCancel: {})
    check(!controller.window!.contentView!.subviews.contains { $0 is ReminderEditorView }, "reminder toggle returns to note")
    let newEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
    check(controller.window!.performKeyEquivalent(with: newEvent) && panelAction == "new", "panel directly handles command N")
    controller.show(focus: false)
    let closeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
    check(controller.window!.performKeyEquivalent(with: closeEvent) && controller.note.isHidden && !controller.window!.isVisible, "command W hides only this note")
    check(!controller.note.isArchived, "closing does not archive or delete")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let today = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
    let wheel = ReminderWheelPicker(date: today, calendar: calendar, today: today)
    wheel.hourWheel.value = 23
    wheel.hourWheel.step(1)
    check(wheel.hourWheel.value == 0, "hour wheel wraps 23 to 00")
    wheel.minuteWheel.value = 0
    wheel.minuteWheel.step(-1)
    check(wheel.minuteWheel.value == 59, "minute wheel wraps backwards")
    wheel.dayWheel.step(1)
    wheel.hourWheel.value = 9
    wheel.minuteWheel.value = 30
    check(calendar.component(.day, from: wheel.dateValue!) == 8 && calendar.component(.hour, from: wheel.dateValue!) == 9, "calendar wheel preserves day and time across DST")
    wheel.hourWheel.value = 2
    check(wheel.dateValue == nil, "nonexistent DST time is rejected without silent date change")
    let future = calendar.date(from: DateComponents(year: 2027, month: 12, day: 31, hour: 23, minute: 58))!
    wheel.setDate(future)
    check(wheel.dateValue == future, "wheel restores future date across year boundary")
    print("\(total - failures) passed, \(failures) failed")
    return failures == 0 ? 0 : 1
}
