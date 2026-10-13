import AppKit
import EasyStickyCore

final class StickyNoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private(set) var note: StickyNote
    private let onChange: (StickyNote) -> Void
    private let onFocus: (UUID) -> Void
    private let onAction: (UUID, String) -> Void
    private let textView = RichNoteEditor()
    private let rootView = NotePaperView()
    private let scrollView = NSScrollView()
    private let headerTitle = NSTextField(labelWithString: "随手记")
    private let saveLabel = NSTextField(labelWithString: "已保存")
    private let reminderLabel = NSTextField(labelWithString: "")
    private let pinButton = NoteIconButton(symbol: "pin", label: "置顶")
    private let themeButton = NoteIconButton(symbol: "circle.fill", label: "便签颜色")
    private let reminderButton = NoteIconButton(symbol: "bell", label: "提醒")
    private let formatButton = NSButton(title: "Aa", target: nil, action: nil)
    private var editorToolbar: EditorToolbar!
    private var editorBottom: NSLayoutConstraint!
    private var reminderEditor: ReminderEditorView?
    private var colorPopover: NSPopover?
    private var isApplyingFrame = false
    private var isFormattingVisible = false
    private var documentDirty = false

    init(note: StickyNote, visibleFrames: [CGRect], fallbackFrame: CGRect,
         onChange: @escaping (StickyNote) -> Void, onFocus: @escaping (UUID) -> Void,
         onAction: @escaping (UUID, String) -> Void) {
        self.note = note
        self.onChange = onChange
        self.onFocus = onFocus
        self.onAction = onAction
        let frame = (note.frame ?? WindowFrame(fallbackFrame))
            .normalized(to: visibleFrames, minimumSize: CGSize(width: 380, height: 300), fallback: fallbackFrame).rect
        let window = StickyPanel(contentRect: frame,
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.onNoteShortcut = { [weak self] command in
            guard let self else { return }
            if command == "hide" { self.hide() }
            else { self.onAction(self.note.id, command) }
        }
        window.delegate = self
        window.title = "Easy Sticky"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 300)
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setAccessibilityTitle("Easy Sticky 便签")
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        configureContent(window)
        applyAppearance()
        self.note.frame = WindowFrame(frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(focus: Bool) {
        note.setWindowState(isHidden: false)
        onChange(note)
        if focus {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(textView)
        } else { window?.orderFront(nil) }
    }

    func hide() {
        guard window?.isVisible == true else { return }
        note.setWindowState(isHidden: true)
        onChange(note)
        window?.orderOut(nil)
    }

    func toggleAlwaysOnTop() {
        note.setWindowState(isAlwaysOnTop: !note.isAlwaysOnTop)
        applyWindowBehavior()
        onChange(note)
    }

    func toggleDisplayMode() {
        note.setWindowState(displayMode: note.displayMode == .allSpaces ? .currentSpace : .allSpaces)
        applyWindowBehavior()
        onChange(note)
    }

    func setTheme(_ theme: NoteTheme) {
        note.setWindowState(theme: theme)
        applyAppearance()
        onChange(note)
    }

    func format(_ command: String) { textView.format(command) }
    func setSaveStatus(_ text: String) { saveLabel.stringValue = text }

    func setReminder(_ date: Date?) {
        note.reminderDate = date
        note.updatedAt = Date()
        updateReminderDisplay()
        onChange(note)
    }

    func showReminderEditor(onSave: @escaping (Date, @escaping (Error?) -> Void) -> Void,
                            onCancel: @escaping () -> Void) {
        if reminderEditor != nil { dismissReminderEditor(); return }
        let editor = ReminderEditorView(date: note.reminderDate, onSave: onSave,
                                        onCancel: onCancel, onClose: { [weak self] in self?.dismissReminderEditor() })
        editor.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(editor)
        reminderEditor = editor
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 54),
            editor.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            editor.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            editor.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18)
        ])
        scrollView.isHidden = true
        editorToolbar.isHidden = true
        formatButton.isHidden = true
        saveLabel.isHidden = true
        reminderLabel.isHidden = true
        headerTitle.stringValue = "提醒"
        reminderButton.isHighlightedState = true
    }

    private func dismissReminderEditor() {
        reminderEditor?.removeFromSuperview()
        reminderEditor = nil
        scrollView.isHidden = false
        editorToolbar.isHidden = !isFormattingVisible
        formatButton.isHidden = false
        saveLabel.isHidden = false
        reminderLabel.isHidden = false
        headerTitle.stringValue = "随手记"
        updateReminderDisplay()
        window?.makeFirstResponder(textView)
    }

    func normalizeFrame(to visibleFrames: [CGRect]) {
        guard let window else { return }
        let frame = WindowFrame(window.frame).normalized(to: visibleFrames, minimumSize: CGSize(width: 380, height: 300)).rect
        guard frame != window.frame else { return }
        isApplyingFrame = true
        window.setFrame(frame, display: true, animate: true)
        isApplyingFrame = false
        note.setWindowState(frame: WindowFrame(frame))
        onChange(note)
    }

    func textDidChange(_ notification: Notification) {
        // Keep typing cheap; capture attachments once after the application's save debounce.
        note.content = textView.string
        note.updatedAt = Date()
        documentDirty = true
        onChange(note)
    }

    func flushDocument() throws -> StickyNote {
        if documentDirty {
            guard let data = textView.documentData else { throw NoteStoreError.damagedData }
            note.richContent = data
            documentDirty = false
        }
        return note
    }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidBecomeKey(_ notification: Notification) { onFocus(note.id) }
    func windowDidResignKey(_ notification: Notification) {
        if !note.isAlwaysOnTop { window?.orderBack(nil) }
    }
    func windowWillClose(_ notification: Notification) {
        note.setWindowState(isHidden: true)
        onChange(note)
    }

    private func configureContent(_ window: NSWindow) {
        window.contentView = rootView
        rootView.wantsLayer = true
        rootView.onAppearanceChange = { [weak self] in self?.applyAppearance() }

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 3
        let add = NoteIconButton(symbol: "plus", label: "新建便签")
        let complete = NoteIconButton(symbol: "checkmark", label: "完成并归档")
        let more = NoteIconButton(symbol: "ellipsis", label: "更多操作")
        for (button, action) in [(add, "new"), (pinButton, "pin"), (reminderButton, "reminder"), (complete, "archive"), (more, "more")] {
            button.identifier = NSUserInterfaceItemIdentifier(action)
            button.target = self
            button.action = #selector(headerPressed(_:))
            header.addArrangedSubview(button)
        }
        themeButton.target = self
        themeButton.action = #selector(themePressed(_:))
        themeButton.imageScaling = .scaleProportionallyDown
        headerTitle.font = .systemFont(ofSize: 12, weight: .medium)
        headerTitle.textColor = .secondaryLabelColor

        textView.load(text: note.content, data: note.richContent)
        textView.delegate = self
        textView.isSelectable = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("便签正文")
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        editorToolbar = EditorToolbar(editor: textView)
        editorToolbar.isHidden = true
        formatButton.target = self
        formatButton.action = #selector(toggleFormat(_:))
        formatButton.font = .systemFont(ofSize: 14, weight: .medium)
        formatButton.isBordered = false
        formatButton.refusesFirstResponder = true
        formatButton.toolTip = "显示或收起格式工具"
        formatButton.setAccessibilityLabel("格式工具")
        saveLabel.font = .systemFont(ofSize: 10)
        saveLabel.textColor = .tertiaryLabelColor
        reminderLabel.font = .systemFont(ofSize: 10)
        reminderLabel.textColor = .secondaryLabelColor
        reminderLabel.lineBreakMode = .byTruncatingTail
        for view in [themeButton, headerTitle, header, scrollView, editorToolbar!, formatButton, saveLabel, reminderLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        editorBottom = scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -40)
        NSLayoutConstraint.activate([
            themeButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            themeButton.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 10),
            headerTitle.leadingAnchor.constraint(equalTo: themeButton.trailingAnchor, constant: 2),
            headerTitle.centerYAnchor.constraint(equalTo: themeButton.centerYAnchor),
            header.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            header.centerYAnchor.constraint(equalTo: themeButton.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 50),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -10),
            editorBottom,
            formatButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            formatButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -10),
            formatButton.widthAnchor.constraint(equalToConstant: 28),
            saveLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            saveLabel.centerYAnchor.constraint(equalTo: formatButton.centerYAnchor),
            reminderLabel.leadingAnchor.constraint(equalTo: formatButton.trailingAnchor, constant: 12),
            reminderLabel.trailingAnchor.constraint(lessThanOrEqualTo: saveLabel.leadingAnchor, constant: -12),
            reminderLabel.centerYAnchor.constraint(equalTo: formatButton.centerYAnchor),
            editorToolbar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 14),
            editorToolbar.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -10),
            editorToolbar.bottomAnchor.constraint(equalTo: formatButton.topAnchor, constant: -8)
        ])
    }

    @objc private func headerPressed(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "pin": toggleAlwaysOnTop()
        case "more":
            let menu = NSMenu()
            for (title, command) in [
                ("关闭便签（保留内容）", "hide"),
                (note.displayMode == .allSpaces ? "仅在当前桌面显示" : "在所有桌面显示", "spaces"),
                ("便签库…", "library"), ("偏好设置…", "preferences"),
                ("删除便签…", "delete")
            ] {
                if command == "delete" { menu.addItem(.separator()) }
                let item = NSMenuItem(title: title, action: #selector(moreChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command
                if command == "hide" { item.keyEquivalent = "w"; item.keyEquivalentModifierMask = .command }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 5), in: sender)
        default: onAction(note.id, sender.identifier?.rawValue ?? "")
        }
    }

    @objc private func moreChosen(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        if command == "spaces" { toggleDisplayMode() }
        else { onAction(note.id, command) }
    }

    @objc private func toggleFormat(_ sender: Any?) {
        isFormattingVisible.toggle()
        editorToolbar.isHidden = !isFormattingVisible
        editorBottom.constant = isFormattingVisible ? -78 : -40
        formatButton.contentTintColor = isFormattingVisible ? note.theme.accentColor(for: rootView.effectiveAppearance) : .secondaryLabelColor
        window?.makeFirstResponder(textView)
    }

    @objc private func themePressed(_ sender: Any?) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ColorPaletteViewController(selectedTheme: note.theme) { [weak self, weak popover] theme in
            self?.setTheme(theme)
            popover?.performClose(nil)
        }
        colorPopover = popover
        popover.show(relativeTo: themeButton.bounds, of: themeButton, preferredEdge: .maxY)
    }

    private func applyWindowBehavior() {
        guard let window else { return }
        window.level = note.isAlwaysOnTop ? .floating : .normal
        // Joining desktop Spaces alone does not opt into other apps' full-screen Spaces.
        window.collectionBehavior = note.displayMode == .allSpaces
            ? [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary]
            : [.managed, .fullScreenAuxiliary]
        pinButton.image = NSImage(systemSymbolName: note.isAlwaysOnTop ? "pin.fill" : "pin", accessibilityDescription: "置顶")
        pinButton.isHighlightedState = note.isAlwaysOnTop
        pinButton.setAccessibilityValue(note.isAlwaysOnTop ? "已置顶" : "未置顶")
    }

    private func updateReminderDisplay() {
        reminderButton.isHighlightedState = note.reminderDate != nil || reminderEditor != nil
        reminderButton.image = NSImage(systemSymbolName: note.reminderDate == nil ? "bell" : "bell.badge", accessibilityDescription: "提醒")
        if let date = note.reminderDate {
            reminderLabel.stringValue = "◷ " + date.formatted(date: .abbreviated, time: .shortened)
            reminderButton.toolTip = "提醒：" + date.formatted(date: .abbreviated, time: .shortened)
        } else {
            reminderLabel.stringValue = ""
            reminderButton.toolTip = "设置提醒"
        }
    }

    private func applyAppearance() {
        let appearance = rootView.effectiveAppearance
        rootView.layer?.backgroundColor = note.theme.backgroundColor(for: appearance).cgColor
        rootView.layer?.cornerRadius = 16
        rootView.layer?.borderWidth = 0.5
        rootView.layer?.borderColor = note.theme.accentColor(for: appearance).withAlphaComponent(0.13).cgColor
        rootView.layer?.masksToBounds = true
        themeButton.contentTintColor = note.theme.accentColor(for: appearance)
        textView.insertionPointColor = note.theme.accentColor(for: appearance)
        applyWindowBehavior()
        updateReminderDisplay()
    }

    private func saveFrame() {
        guard !isApplyingFrame, let window else { return }
        note.setWindowState(frame: WindowFrame(window.frame))
        onChange(note)
    }
}

/// Nonactivating panels cannot rely on the foreground application's menu shortcuts.
final class StickyPanel: NSPanel {
    var onNoteShortcut: ((String) -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased(),
           let command = ["w": "hide", "n": "new"][key] {
            onNoteShortcut?(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class NotePaperView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

final class NoteIconButton: NSButton {
    var isHighlightedState = false { didSet { needsDisplay = true } }
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        title = ""
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        toolTip = label
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlightedState {
            NSColor.labelColor.withAlphaComponent(isHovered ? 0.09 : 0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}
