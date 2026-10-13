import AppKit
import EasyStickyCore

final class ShortcutPreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let recorder: ShortcutRecorderButton
    private let onRequestAccessibility: () -> Void
    private let dataDirectory: URL
    private var actionRecorders: [ShortcutRecorderButton] = []

    init(
        shortcut: KeyboardShortcut,
        onShortcutChange: @escaping (KeyboardShortcut) -> Bool,
        onRecordingChange: @escaping (Bool) -> Void,
        onRequestAccessibility: @escaping () -> Void,
        actionShortcuts: [String: KeyboardShortcut],
        defaultShortcuts: [String: KeyboardShortcut],
        onActionShortcutChange: @escaping (String, KeyboardShortcut) -> Bool,
        onActionRecordingChange: @escaping (String, Bool) -> Void,
        dataDirectory: URL
    ) {
        recorder = ShortcutRecorderButton(
            shortcut: shortcut,
            onChange: onShortcutChange,
            onRecordingChange: onRecordingChange
        )
        self.onRequestAccessibility = onRequestAccessibility
        self.dataDirectory = dataDirectory

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Easy Sticky 偏好设置"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView()
        let tabs = NSTabView(frame: window.contentView!.bounds.insetBy(dx: 12, dy: 12))
        tabs.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(tabs)
        let shortcutTab = NSTabViewItem(identifier: "shortcuts")
        shortcutTab.label = "快捷键"
        shortcutTab.view = contentView
        tabs.addTabViewItem(shortcutTab)
        let dataTab = NSTabViewItem(identifier: "data")
        dataTab.label = "数据"
        let dataView = NSStackView()
        dataView.orientation = .vertical
        dataView.alignment = .leading
        dataView.spacing = 20
        dataView.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let localInfo = NSTextField(wrappingLabelWithString: "便签仅保存在这台 Mac，无需账号，不上传到服务器。\n\n包含内容、图片、位置、归档和提醒时间。复制整个目录可备份。删除应用不会自动删除便签数据。")
        let path = NSTextField(wrappingLabelWithString: dataDirectory.path)
        path.isSelectable = true
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let reveal = NSButton(title: "在 Finder 中显示数据目录", target: self, action: #selector(revealData(_:)))
        [localInfo, path, reveal].forEach(dataView.addArrangedSubview)
        dataTab.view = dataView
        tabs.addTabViewItem(dataTab)

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

        var previous: NSView = permissionButton
        for (key, name) in [("new", "新建便签"), ("show", "显示全部便签"), ("hide", "隐藏全部便签")] {
            guard let shortcut = actionShortcuts[key], let fallback = defaultShortcuts[key] else { continue }
            let label = NSTextField(labelWithString: name)
            let button = ShortcutRecorderButton(shortcut: shortcut, onChange: { onActionShortcutChange(key, $0) }, onRecordingChange: { onActionRecordingChange(key, $0) }, defaultShortcut: fallback, accessibilityLabel: name + "快捷键")
            actionRecorders.append(button)
            let reset = NSButton(title: "恢复默认", target: button, action: #selector(ShortcutRecorderButton.restoreDefault(_:)))
            for view in [label, button, reset] { view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view) }
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 18),
                label.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 180),
                button.widthAnchor.constraint(equalToConstant: 146),
                reset.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 10),
                reset.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            previous = label
        }
        let conflictHint = NSTextField(wrappingLabelWithString: "便签内：⌘W 关闭当前便签（保留内容），⌘N 新建。\n全局快捷键冲突时请更换组合；Esc 取消录制。⌥⌘S 切换全部便签显示。")
        conflictHint.font = .systemFont(ofSize: 11)
        conflictHint.textColor = .secondaryLabelColor
        conflictHint.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(conflictHint)
        NSLayoutConstraint.activate([
            conflictHint.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 18),
            conflictHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            conflictHint.trailingAnchor.constraint(equalTo: title.trailingAnchor)
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
        actionRecorders.forEach { $0.stopRecording() }
    }

    @objc private func revealData(_ sender: Any?) { NSWorkspace.shared.open(dataDirectory) }
}

final class ShortcutRecorderButton: NSButton {
    private var shortcut: KeyboardShortcut
    private let onChange: (KeyboardShortcut) -> Bool
    private let onRecordingChange: (Bool) -> Void
    private var isRecording = false
    private var eventMonitor: Any?
    private let defaultShortcut: KeyboardShortcut

    init(
        shortcut: KeyboardShortcut,
        onChange: @escaping (KeyboardShortcut) -> Bool,
        onRecordingChange: @escaping (Bool) -> Void,
        defaultShortcut: KeyboardShortcut = .selectedTextDefault,
        accessibilityLabel: String = "从选中文本新建便签的快捷键"
    ) {
        self.shortcut = shortcut
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
        self.defaultShortcut = defaultShortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording(_:))
        updateTitle()
        setAccessibilityLabel(accessibilityLabel)
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
        apply(defaultShortcut)
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
