import AppKit
import EasyStickyCore

final class ShortcutPreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let recorder: ShortcutRecorderButton
    private let onRequestAccessibility: () -> Void

    init(
        shortcut: KeyboardShortcut,
        onShortcutChange: @escaping (KeyboardShortcut) -> Bool,
        onRecordingChange: @escaping (Bool) -> Void,
        onRequestAccessibility: @escaping () -> Void
    ) {
        recorder = ShortcutRecorderButton(
            shortcut: shortcut,
            onChange: onShortcutChange,
            onRecordingChange: onRecordingChange
        )
        self.onRequestAccessibility = onRequestAccessibility

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Easy Sticky 快捷键"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView()
        window.contentView = contentView

        let title = NSTextField(labelWithString: "从选中文本新建便签")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: "在任意应用中选中文本后按下此快捷键，Easy Sticky 会读取选区并创建一张置顶、跨桌面的便签。")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3

        let shortcutLabel = NSTextField(labelWithString: "快捷键")
        shortcutLabel.font = .systemFont(ofSize: 13, weight: .medium)

        recorder.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "恢复默认", target: recorder, action: #selector(ShortcutRecorderButton.restoreDefault(_:)))
        resetButton.bezelStyle = .rounded

        let permissionButton = NSButton(
            title: "授权辅助功能…",
            target: self,
            action: #selector(requestAccessibility(_:))
        )
        permissionButton.bezelStyle = .rounded

        [title, detail, shortcutLabel, recorder, resetButton, permissionButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            shortcutLabel.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 20),
            shortcutLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),

            recorder.leadingAnchor.constraint(equalTo: shortcutLabel.trailingAnchor, constant: 16),
            recorder.widthAnchor.constraint(equalToConstant: 146),
            recorder.heightAnchor.constraint(equalToConstant: 30),

            resetButton.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 8),
            resetButton.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),

            permissionButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            permissionButton.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func requestAccessibility(_ sender: Any?) {
        onRequestAccessibility()
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stopRecording()
    }
}

final class ShortcutRecorderButton: NSButton {
    private var shortcut: KeyboardShortcut
    private let onChange: (KeyboardShortcut) -> Bool
    private let onRecordingChange: (Bool) -> Void
    private var isRecording = false
    private var eventMonitor: Any?

    init(
        shortcut: KeyboardShortcut,
        onChange: @escaping (KeyboardShortcut) -> Bool,
        onRecordingChange: @escaping (Bool) -> Void
    ) {
        self.shortcut = shortcut
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording(_:))
        updateTitle()
        setAccessibilityLabel("从选中文本新建便签的快捷键")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    deinit {
        removeEventMonitor()
    }

    @objc func beginRecording(_ sender: Any?) {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChange(true)
        title = "请按新快捷键…"
        window?.makeFirstResponder(self)
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isRecording else { return event }
                self.handleRecordedKey(event)
                return nil
            }
        }
    }

    @objc func restoreDefault(_ sender: Any?) {
        apply(.selectedTextDefault)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleRecordedKey(event)
    }

    func stopRecording() {
        let wasRecording = isRecording
        isRecording = false
        removeEventMonitor()
        updateTitle()
        if wasRecording {
            onRecordingChange(false)
        }
    }

    private func handleRecordedKey(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        guard let candidate = KeyboardShortcut.from(event: event) else {
            NSSound.beep()
            title = "需包含 ⌃、⌥ 或 ⌘"
            return
        }
        apply(candidate)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    private func apply(_ candidate: KeyboardShortcut) {
        if onChange(candidate) {
            shortcut = candidate
            stopRecording()
            window?.makeFirstResponder(nil)
        } else {
            NSSound.beep()
            title = "快捷键冲突，请重试"
            isRecording = true
        }
    }

    private func updateTitle() {
        title = shortcut.displayName
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
