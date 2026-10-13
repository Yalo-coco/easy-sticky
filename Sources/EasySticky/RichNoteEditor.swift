import AppKit
import UniformTypeIdentifiers

/// The document stays native RTFD; images are embedded, never uploaded or referenced remotely.
final class RichNoteEditor: NSTextView {
    static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor
    ]

    var documentData: Data? {
        attributedString().rtfd(from: NSRange(location: 0, length: textStorage?.length ?? 0), documentAttributes: [:])
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { updateImageLayout() }
    }

    override func didChangeText() {
        updateImageLayout()
        super.didChangeText()
    }

    /// Only attachment cells change size. The original file wrapper is never rewritten.
    func updateImageLayout() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let available = max(1, bounds.width - 2 * textContainerInset.width - 2 * padding)
        var changed = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let cell: OriginalImageCell
            if let existing = attachment.attachmentCell as? OriginalImageCell {
                cell = existing
            } else {
                let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
                guard let image = data.flatMap({ NSImage(data: $0) }) else { return }
                cell = OriginalImageCell(imageCell: image)
                attachment.attachmentCell = cell
                changed = true
            }
            let paragraph = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let head = max(paragraph?.headIndent ?? 0, paragraph?.firstLineHeadIndent ?? 0)
            let tail = paragraph?.tailIndent ?? 0
            let width = max(1, (tail > 0 ? min(available, tail) : available + tail) - head)
            if cell.fit(to: width) { changed = true }
        }
        if changed {
            let range = NSRange(location: 0, length: storage.length)
            layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager?.invalidateDisplay(forCharacterRange: range)
            needsDisplay = true
        }
    }

    override func paste(_ sender: Any?) {
        if !pasteRichContent(from: .general) { super.paste(sender) }
    }

    @discardableResult
    func pasteRichContent(from pasteboard: NSPasteboard) -> Bool {
        guard let selection = CapturedSelection.read(from: pasteboard) else { return false }
        replaceDocument(in: selectedRange(), with: selection.document)
        return true
    }

    func load(text: String, data: Data?) {
        isRichText = true
        importsGraphics = true
        isEditable = true
        allowsUndo = true
        if let data, let document = NSAttributedString(rtfd: data, documentAttributes: nil) {
            textStorage?.setAttributedString(document)
        } else {
            textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.defaultAttributes))
        }
        typingAttributes = Self.defaultAttributes
        updateImageLayout()
        setSelectedRange(NSRange(location: 0, length: 0))
        undoManager?.removeAllActions()
    }

    func format(_ command: String) {
        switch command {
        case "bold": toggleFont(.boldFontMask)
        case "italic": toggleFont(.italicFontMask)
        case "underline": toggleAttribute(.underlineStyle)
        case "strike": toggleAttribute(.strikethroughStyle)
        case "body", "h1", "h2", "h3":
            let size: CGFloat = ["h1": 28, "h2": 23, "h3": 19][command] ?? 16
            transform(paragraph: true) { document in
                document.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: command == "body" ? .regular : .bold), range: NSRange(location: 0, length: document.length))
            }
        case "bullet": list(prefix: "• ")
        case "number": list(prefix: "1. ")
        case "todo": list(prefix: "☐ ")
        case "inlineCode", "codeBlock":
            transform(paragraph: command == "codeBlock") { document in
                let range = NSRange(location: 0, length: document.length)
                document.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor], range: range)
            }
        case "clear": transform { $0.setAttributes(Self.defaultAttributes, range: NSRange(location: 0, length: $0.length)) }
        case "rule": insertText("\n────────────────────\n", replacementRange: selectedRange())
        case "link": editLink()
        case "image": insertImage()
        case "undo": undoManager?.undo()
        case "redo": undoManager?.redo()
        default:
            if command.hasPrefix("size:"), let value = Double(command.dropFirst(5)) {
                transform { document in
                    document.enumerateAttribute(.font, in: NSRange(location: 0, length: document.length)) { font, range, _ in
                        let original = font as? NSFont ?? NSFont.systemFont(ofSize: 16)
                        document.addAttribute(.font, value: NSFontManager.shared.convert(original, toSize: value), range: range)
                    }
                }
            } else if command.hasPrefix("color:") {
                let colors: [String: NSColor] = ["默认": .textColor, "红": .systemRed, "橙": .systemOrange, "绿": .systemGreen, "蓝": .systemBlue, "紫": .systemPurple, "灰": .systemGray]
                if let color = colors[String(command.dropFirst(6))] {
                    transform { $0.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: $0.length)) }
                }
            }
        }
        window?.makeFirstResponder(self)
    }

    private func toggleFont(_ trait: NSFontTraitMask) {
        let range = selectedRange()
        let font = (range.length > 0 ? textStorage?.attribute(.font, at: range.location, effectiveRange: nil) : typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: 16)
        let removing = NSFontManager.shared.traits(of: font).contains(trait)
        transform { document in
            document.enumerateAttribute(.font, in: NSRange(location: 0, length: document.length)) { value, range, _ in
                let original = value as? NSFont ?? .systemFont(ofSize: 16)
                let converted = removing ? NSFontManager.shared.convert(original, toNotHaveTrait: trait) : NSFontManager.shared.convert(original, toHaveTrait: trait)
                document.addAttribute(.font, value: converted, range: range)
            }
        }
    }

    private func toggleAttribute(_ key: NSAttributedString.Key) {
        let range = selectedRange()
        let value = (range.length > 0 ? textStorage?.attribute(key, at: range.location, effectiveRange: nil) : typingAttributes[key]) as? Int ?? 0
        transform { $0.addAttribute(key, value: value == 0 ? NSUnderlineStyle.single.rawValue : 0, range: NSRange(location: 0, length: $0.length)) }
    }

    private func transform(paragraph: Bool = false, _ update: (NSMutableAttributedString) -> Void) {
        let selection = selectedRange()
        let range = paragraph ? (string as NSString).paragraphRange(for: selection) : selection
        if range.length == 0 {
            let sample = NSMutableAttributedString(string: " ", attributes: typingAttributes)
            update(sample)
            typingAttributes = sample.attributes(at: 0, effectiveRange: nil)
            return
        }
        let document = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
        update(document)
        replaceDocument(in: range, with: document)
        setSelectedRange(selection)
    }

    /// NSTextInputClient.insertText normalizes attributes to the current typing style.
    /// Formatting must replace the attributed storage directly, with an explicit undo pair.
    private func replaceDocument(in range: NSRange, with document: NSAttributedString) {
        guard let storage = textStorage else { return }
        let previous = storage.attributedSubstring(from: range)
        let selection = selectedRange()
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.replaceDocument(in: NSRange(location: range.location, length: document.length), with: previous)
            editor.setSelectedRange(selection)
        }
        storage.replaceCharacters(in: range, with: document)
        setSelectedRange(NSRange(location: range.location + document.length, length: 0))
        didChangeText()
    }

    static func prefix(in line: String) -> String? {
        guard let range = line.range(of: "^(?:[•☐☑] |[0-9]+\\. )", options: .regularExpression) else { return nil }
        return String(line[range])
    }

    private func list(prefix: String) {
        let selection = selectedRange()
        let range = (string as NSString).paragraphRange(for: selection)
        let selected = (string as NSString).substring(with: range)
        let lines = selected.components(separatedBy: "\n")
        let result = NSMutableAttributedString(string: "")
        var offset = range.location
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 && line.isEmpty && index > 0 { break }
            let oldPrefix = Self.prefix(in: line) ?? ""
            let newPrefix = prefix == "1. " ? "\(index + 1). " : prefix
            let attributes = offset < (textStorage?.length ?? 0) ? attributedString().attributes(at: offset, effectiveRange: nil) : typingAttributes
            result.append(NSAttributedString(string: newPrefix, attributes: attributes))
            let bodyRange = NSRange(location: offset + (oldPrefix as NSString).length, length: (line as NSString).length - (oldPrefix as NSString).length)
            result.append(attributedString().attributedSubstring(from: bodyRange))
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            offset += (line as NSString).length + 1
        }
        replaceDocument(in: range, with: result)
    }

    override func insertNewline(_ sender: Any?) {
        let position = selectedRange().location
        let range = (string as NSString).paragraphRange(for: NSRange(location: position, length: 0))
        let line = (string as NSString).substring(with: range)
        guard let prefix = Self.prefix(in: line) else { super.insertNewline(sender); return }
        if line.trimmingCharacters(in: .whitespacesAndNewlines) == prefix.trimmingCharacters(in: .whitespacesAndNewlines) {
            insertText("", replacementRange: NSRange(location: range.location, length: (prefix as NSString).length))
            return
        }
        var next = prefix == "☑ " ? "☐ " : prefix
        if let number = Int(prefix.dropLast(2)) { next = "\(number + 1). " }
        insertText("\n" + next, replacementRange: selectedRange())
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index < (string as NSString).length {
            let range = (string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
            let line = (string as NSString).substring(with: range)
            if (line.hasPrefix("☐ ") || line.hasPrefix("☑ ")), index <= range.location + 1 {
                toggleTask(at: range.location)
                return
            }
        }
        super.mouseDown(with: event)
    }

    func toggleTask(at position: Int) {
        let range = NSRange(location: position, length: 1)
        let old = (string as NSString).substring(with: range)
        guard old == "☐" || old == "☑" else { return }
        let attributes = attributedString().attributes(at: position, effectiveRange: nil)
        replaceDocument(in: range, with: NSAttributedString(string: old == "☐" ? "☑" : "☐", attributes: attributes))
    }

    private func editLink() {
        let selection = selectedRange()
        let alert = NSAlert()
        alert.messageText = "插入链接"
        alert.informativeText = "选中的文字将成为链接；未选中文字时显示网址。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "插入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { NSSound.beep(); return }
        let title = selection.length > 0 ? (string as NSString).substring(with: selection) : raw
        var attributes = typingAttributes
        attributes[.link] = url
        replaceDocument(in: selection, with: NSAttributedString(string: title, attributes: attributes))
    }

    private func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        insertImageData(data, filename: url.lastPathComponent)
    }

    func insertLocalImage(_ image: NSImage) {
        guard let data = image.tiffRepresentation else { return }
        insertImageData(data, filename: "image.tiff")
    }

    func insertImageData(_ data: Data, filename: String) {
        guard let document = Self.imageDocument(data: data, filename: filename) else { return }
        replaceDocument(in: selectedRange(), with: document)
    }

    static func imageDocument(data: Data, filename: String) -> NSAttributedString? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.attachmentCell = OriginalImageCell(imageCell: image)
        return NSAttributedString(attachment: attachment)
    }
}

/// The display size is transient; drawing always samples the original image.
final class OriginalImageCell: NSTextAttachmentCell {
    private var displaySize = NSSize.zero

    @discardableResult
    func fit(to width: CGFloat) -> Bool {
        guard let image, image.size.width > 0, image.size.height > 0 else { return false }
        let scale = min(1, max(1, width) / image.size.width)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard size != displaySize else { return false }
        displaySize = size
        return true
    }

    override func cellSize() -> NSSize { displaySize == .zero ? (image?.size ?? .zero) : displaySize }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

final class EditorToolbar: NSStackView {
    private weak var editor: RichNoteEditor?

    init(editor: RichNoteEditor) {
        self.editor = editor
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 2
        addMenu("正文", choices: [("正文", "body"), ("标题 1", "h1"), ("标题 2", "h2"), ("标题 3", "h3")])
        addAction("B", label: "加粗", command: "bold")
        addAction("I", label: "斜体", command: "italic")
        addMenu("列表", choices: [("无序列表", "bullet"), ("有序列表", "number"), ("待办项", "todo")])
        addMenu("字号", choices: [12,14,16,18,20,24,28,32].map { ("\($0)", "size:\($0)") })
        addMenu("字色", choices: ["默认","红","橙","绿","蓝","紫","灰"].map { ($0, "color:\($0)") })
        addMenu("更多", choices: [("下划线", "underline"), ("删除线", "strike"), ("行内代码", "inlineCode"), ("代码块", "codeBlock"), ("链接…", "link"), ("插入图片…", "image"), ("分隔线", "rule"), ("清除格式", "clear"), ("撤销", "undo"), ("重做", "redo")])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addAction(_ title: String, label: String, command: String) {
        let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(command)
        button.bezelStyle = .inline
        button.isBordered = false
        button.refusesFirstResponder = true
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 25).isActive = true
        addArrangedSubview(button)
    }

    private func addMenu(_ title: String, choices: [(String, String)]) {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.bezelStyle = .inline
        popup.isBordered = false
        popup.refusesFirstResponder = true
        popup.addItem(withTitle: title)
        popup.setAccessibilityLabel(title)
        for (label, command) in choices {
            let item = NSMenuItem(title: label, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            popup.menu?.addItem(item)
        }
        addArrangedSubview(popup)
    }

    @objc private func pressed(_ sender: NSButton) { editor?.format(sender.identifier?.rawValue ?? "") }
    @objc private func chosen(_ sender: NSMenuItem) { editor?.format(sender.representedObject as? String ?? "") }
}
