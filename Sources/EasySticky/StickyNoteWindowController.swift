import AppKit
import EasyStickyCore

final class StickyNoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private(set) var note: StickyNote

    private let onChange: (StickyNote) -> Void
    private let onFocus: (UUID) -> Void
    private let textView = NSTextView()
    private let rootView = HoverTrackingView()
    private let controlsBackground = NSVisualEffectView()
    private let pinButton = NSButton()
    private let spacesButton = NSButton()
    private let themeButton = NSButton()
    private var colorPopover: NSPopover?
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
        updateControlsVisibility(animated: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        updateControlsVisibility(animated: true)
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
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = ColorPaletteViewController(
            selectedTheme: note.theme,
            onSelect: { [weak self, weak popover] theme in
                self?.setTheme(theme)
                popover?.performClose(nil)
            }
        )
        colorPopover = popover
        popover.show(relativeTo: themeButton.bounds, of: themeButton, preferredEdge: .maxY)
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.title = "Easy Sticky"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
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
        rootView.onHoverChange = { [weak self] _ in
            self?.updateControlsVisibility(animated: true)
        }
        rootView.onAppearanceChange = { [weak self] in
            self?.applyAppearance()
        }
        window.contentView = rootView

        controlsBackground.translatesAutoresizingMaskIntoConstraints = false
        controlsBackground.material = .popover
        controlsBackground.blendingMode = .withinWindow
        controlsBackground.state = .active
        controlsBackground.wantsLayer = true
        controlsBackground.layer?.cornerRadius = 12

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
            toolTip: "选择这张便签的颜色",
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
        textView.font = .systemFont(ofSize: 15.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 15, height: 13)
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

        rootView.addSubview(controlsBackground)
        [pinButton, spacesButton, themeButton].forEach(controlsBackground.addSubview)
        rootView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            controlsBackground.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 6),
            controlsBackground.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
            controlsBackground.heightAnchor.constraint(equalToConstant: 25),

            themeButton.topAnchor.constraint(equalTo: controlsBackground.topAnchor),
            themeButton.trailingAnchor.constraint(equalTo: controlsBackground.trailingAnchor, constant: -3),
            themeButton.widthAnchor.constraint(equalToConstant: 27),
            themeButton.heightAnchor.constraint(equalTo: controlsBackground.heightAnchor),

            spacesButton.centerYAnchor.constraint(equalTo: themeButton.centerYAnchor),
            spacesButton.trailingAnchor.constraint(equalTo: themeButton.leadingAnchor, constant: -2),
            spacesButton.widthAnchor.constraint(equalToConstant: 27),
            spacesButton.heightAnchor.constraint(equalTo: controlsBackground.heightAnchor),

            pinButton.centerYAnchor.constraint(equalTo: themeButton.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: spacesButton.leadingAnchor, constant: -2),
            pinButton.leadingAnchor.constraint(equalTo: controlsBackground.leadingAnchor, constant: 3),
            pinButton.widthAnchor.constraint(equalToConstant: 27),
            pinButton.heightAnchor.constraint(equalTo: controlsBackground.heightAnchor),

            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 36),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -4)
        ])
        updateControlsVisibility(animated: false)
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
        button.focusRingType = .none
    }

    private func applyWindowBehavior() {
        guard let window else { return }
        window.level = note.isAlwaysOnTop ? .floating : .normal
        window.collectionBehavior = note.displayMode == .allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed, .fullScreenAuxiliary]

        let appearance = rootView.effectiveAppearance
        let activeColor = note.theme.accentColor(for: appearance)
        let inactiveColor = note.theme.foregroundColor(for: appearance).withAlphaComponent(0.52)
        pinButton.image = NSImage(
            systemSymbolName: note.isAlwaysOnTop ? "pin.fill" : "pin",
            accessibilityDescription: "切换置顶显示"
        )
        spacesButton.image = NSImage(
            systemSymbolName: note.displayMode == .allSpaces ? "square.on.square.fill" : "square.on.square",
            accessibilityDescription: "切换所有桌面/当前桌面"
        )
        pinButton.contentTintColor = note.isAlwaysOnTop ? activeColor : inactiveColor
        spacesButton.contentTintColor = note.displayMode == .allSpaces ? activeColor : inactiveColor
        themeButton.contentTintColor = activeColor
        pinButton.setAccessibilityValue(note.isAlwaysOnTop ? "已置顶" : "未置顶")
        spacesButton.setAccessibilityValue(note.displayMode == .allSpaces ? "所有桌面" : "当前桌面")
    }

    private func applyAppearance() {
        let appearance = rootView.effectiveAppearance
        rootView.layer?.backgroundColor = note.theme.backgroundColor(for: appearance).cgColor
        rootView.layer?.cornerRadius = 12
        rootView.layer?.masksToBounds = true
        textView.textColor = note.theme.foregroundColor(for: appearance)
        textView.insertionPointColor = note.theme.accentColor(for: appearance)
        applyWindowBehavior()
    }

    private func updateControlsVisibility(animated: Bool) {
        let alpha: CGFloat = rootView.isMouseInside || window?.isKeyWindow == true ? 1 : 0
        if alpha > 0 {
            controlsBackground.isHidden = false
        }
        guard animated else {
            controlsBackground.alphaValue = alpha
            controlsBackground.isHidden = alpha == 0
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            controlsBackground.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.rootView.isMouseInside, self.window?.isKeyWindow != true {
                self.controlsBackground.isHidden = true
            }
        })
    }

    private func saveCurrentFrame() {
        guard !isApplyingFrame, let window else { return }
        note.setWindowState(frame: WindowFrame(window.frame))
        onChange(note)
    }
}

private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onAppearanceChange: (() -> Void)?
    private(set) var isMouseInside = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        onHoverChange?(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
