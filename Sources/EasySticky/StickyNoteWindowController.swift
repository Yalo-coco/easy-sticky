import AppKit
import EasyStickyCore

final class StickyNoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private(set) var note: StickyNote

    private let onChange: (StickyNote) -> Void
    private let onFocus: (UUID) -> Void
    private let textView = NSTextView()
    private let rootView = NSView()
    private let pinButton = NSButton()
    private let spacesButton = NSButton()
    private let themeButton = NSButton()
    private var isApplyingFrame = false

    init(
        note: StickyNote,
        visibleFrames: [CGRect],
        fallbackFrame: CGRect,
        onChange: @escaping (StickyNote) -> Void,
        onFocus: @escaping (UUID) -> Void
    ) {
        self.note = note
        self.onChange = onChange
        self.onFocus = onFocus

        let initialFrame = (note.frame ?? WindowFrame(fallbackFrame))
            .normalized(to: visibleFrames, fallback: fallbackFrame)
            .rect
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        configureWindow(window)
        configureContent()
        applyAppearance()
        self.note.frame = WindowFrame(initialFrame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(focus: Bool) {
        note.setWindowState(isHidden: false)
        onChange(note)

        if focus {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(textView)
        } else {
            window?.orderFront(nil)
        }
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
        let nextMode: NoteDisplayMode = note.displayMode == .allSpaces ? .currentSpace : .allSpaces
        note.setWindowState(displayMode: nextMode)
        applyWindowBehavior()
        onChange(note)
    }

    func setTheme(_ theme: NoteTheme) {
        note.setWindowState(theme: theme)
        applyAppearance()
        onChange(note)
    }

    func normalizeFrame(to visibleFrames: [CGRect]) {
        guard let window else { return }
        let normalized = WindowFrame(window.frame).normalized(to: visibleFrames).rect
        guard normalized != window.frame else { return }

        isApplyingFrame = true
        window.setFrame(normalized, display: true, animate: true)
        isApplyingFrame = false
        note.setWindowState(frame: WindowFrame(normalized))
        onChange(note)
    }

    func textDidChange(_ notification: Notification) {
        note.setContent(textView.string)
        onChange(note)
    }

    func windowDidMove(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onFocus(note.id)
    }

    func windowWillClose(_ notification: Notification) {
        note.setWindowState(isHidden: true)
        onChange(note)
    }

    @objc private func pinButtonPressed(_ sender: Any?) {
        toggleAlwaysOnTop()
    }

    @objc private func spacesButtonPressed(_ sender: Any?) {
        toggleDisplayMode()
    }

    @objc private func themeButtonPressed(_ sender: Any?) {
        guard let index = NoteTheme.allCases.firstIndex(of: note.theme) else { return }
        let nextIndex = NoteTheme.allCases.index(after: index)
        let nextTheme = nextIndex == NoteTheme.allCases.endIndex ? NoteTheme.allCases[0] : NoteTheme.allCases[nextIndex]
        setTheme(nextTheme)
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.title = "Easy Sticky"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 220, height: 140)
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setAccessibilityTitle("Easy Sticky 便签")
    }

    private func configureContent() {
        guard let window else { return }

        rootView.wantsLayer = true
        window.contentView = rootView

        let titleLabel = NSTextField(labelWithString: "Easy Sticky")
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityLabel("Easy Sticky")

        configureHeaderButton(
            pinButton,
            symbolName: "pin.fill",
            fallbackTitle: "置顶",
            toolTip: "切换置顶显示",
            action: #selector(pinButtonPressed(_:))
        )
        configureHeaderButton(
            spacesButton,
            symbolName: "square.on.square",
            fallbackTitle: "桌面",
            toolTip: "切换所有桌面/当前桌面",
            action: #selector(spacesButtonPressed(_:))
        )
        configureHeaderButton(
            themeButton,
            symbolName: "paintpalette.fill",
            fallbackTitle: "主题",
            toolTip: "切换便签颜色",
            action: #selector(themeButtonPressed(_:))
        )

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        textView.string = note.content
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("便签正文")
        scrollView.documentView = textView

        [titleLabel, pinButton, spacesButton, themeButton, scrollView].forEach(rootView.addSubview)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 72),
            titleLabel.centerYAnchor.constraint(equalTo: pinButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -4),

            themeButton.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 6),
            themeButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
            themeButton.widthAnchor.constraint(equalToConstant: 26),
            themeButton.heightAnchor.constraint(equalToConstant: 24),

            spacesButton.centerYAnchor.constraint(equalTo: themeButton.centerYAnchor),
            spacesButton.trailingAnchor.constraint(equalTo: themeButton.leadingAnchor, constant: -2),
            spacesButton.widthAnchor.constraint(equalToConstant: 26),
            spacesButton.heightAnchor.constraint(equalToConstant: 24),

            pinButton.centerYAnchor.constraint(equalTo: themeButton.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: spacesButton.leadingAnchor, constant: -2),
            pinButton.widthAnchor.constraint(equalToConstant: 26),
            pinButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 36),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -4)
        ])
    }

    private func configureHeaderButton(
        _ button: NSButton,
        symbolName: String,
        fallbackTitle: String,
        toolTip: String,
        action: Selector
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .inline
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        if button.image == nil {
            button.title = fallbackTitle
        }
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.contentTintColor = .secondaryLabelColor
    }

    private func applyWindowBehavior() {
        guard let window else { return }
        window.level = note.isAlwaysOnTop ? .floating : .normal
        window.collectionBehavior = note.displayMode == .allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed, .fullScreenAuxiliary]

        pinButton.contentTintColor = note.isAlwaysOnTop ? .controlAccentColor : .secondaryLabelColor
        spacesButton.contentTintColor = note.displayMode == .allSpaces ? .controlAccentColor : .secondaryLabelColor
    }

    private func applyAppearance() {
        rootView.layer?.backgroundColor = note.theme.backgroundColor.cgColor
        rootView.layer?.cornerRadius = 12
        rootView.layer?.masksToBounds = true
        applyWindowBehavior()
    }

    private func saveCurrentFrame() {
        guard !isApplyingFrame, let window else { return }
        note.setWindowState(frame: WindowFrame(window.frame))
        onChange(note)
    }
}

private extension NoteTheme {
    var backgroundColor: NSColor {
        switch self {
        case .yellow:
            return NSColor(red: 1.00, green: 0.95, blue: 0.70, alpha: 0.97)
        case .mint:
            return NSColor(red: 0.78, green: 0.96, blue: 0.84, alpha: 0.97)
        case .blue:
            return NSColor(red: 0.78, green: 0.90, blue: 1.00, alpha: 0.97)
        case .rose:
            return NSColor(red: 1.00, green: 0.82, blue: 0.84, alpha: 0.97)
        }
    }
}
