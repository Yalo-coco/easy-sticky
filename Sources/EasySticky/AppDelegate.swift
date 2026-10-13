import AppKit
import Carbon.HIToolbox
import EasyStickyCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let selectedTextHotKeyID: UInt32 = 3
    private static let selectedTextShortcutDefaultsKey = "selectedTextShortcut"

    private let store: NoteStore
    private let hotKeyManager = GlobalHotKeyManager()
    private let selectedTextCapture = SelectedTextCapture()

    private var notes: [UUID: StickyNote] = [:]
    private var controllers: [UUID: StickyNoteWindowController] = [:]
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "EasySticky.persistence", qos: .utility)
    private var saveRevision = 0
    private var lastActiveNoteID: UUID?
    private var statusItem: NSStatusItem?
    private var dynamicPinItems: [NSMenuItem] = []
    private var dynamicSpaceItems: [NSMenuItem] = []
    private var dynamicThemeItems: [NSMenuItem] = []
    private var selectedTextMenuItems: [NSMenuItem] = []
    private var selectedTextShortcut = KeyboardShortcut.selectedTextDefault
    private var isRecordingSelectedTextShortcut = false
    private var preferencesWindowController: ShortcutPreferencesWindowController?
    private var libraryWindowController: NoteLibraryWindowController?
    private lazy var reminderService = ReminderService()
    private var storageAvailable = true
    private var actionShortcuts: [String: KeyboardShortcut] = [:]
    private static let actionIDs: [String: UInt32] = ["new": 1, "show": 4, "hide": 5]
    private static let defaultShortcuts: [String: KeyboardShortcut] = [
        "new": KeyboardShortcut(keyCode: 0x2D, modifiers: 0x0900, keyLabel: "N"),
        "show": KeyboardShortcut(keyCode: 0x13, modifiers: 0x0800, keyLabel: "2"),
        "hide": KeyboardShortcut(keyCode: 0x14, modifiers: 0x0800, keyLabel: "3")
    ]

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let dataDirectory: URL
        let arguments = CommandLine.arguments
        let argumentDataPath = arguments.firstIndex(of: "--data-dir").flatMap { index -> String? in
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { return nil }
            return arguments[valueIndex]
        }
        if let overridePath = argumentDataPath, !overridePath.isEmpty {
            dataDirectory = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else if let overridePath = environment["EASY_STICKY_DATA_DIR"], !overridePath.isEmpty {
            dataDirectory = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            dataDirectory = applicationSupport.appendingPathComponent("EasySticky", isDirectory: true)
        }
        store = NoteStore(fileURL: dataDirectory.appendingPathComponent("notes.json"))
        selectedTextShortcut = Self.loadSelectedTextShortcut()
        for (key, fallback) in Self.defaultShortcuts {
            actionShortcuts[key] = UserDefaults.standard.data(forKey: "shortcut.\(key)").flatMap { try? JSONDecoder().decode(KeyboardShortcut.self, from: $0) } ?? fallback
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        configureStatusItem()
        registerGlobalHotKeys()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        loadNotes()
        guard storageAvailable else { return }
        reminderService.onOpenNote = { [weak self] id in self?.openNote(id) }
        reminderService.restore(Array(notes.values))
        restoreWindows()
        refreshMenuStates()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        pendingSave?.cancel()
        guard storageAvailable else { return .terminateNow }
        do {
            let snapshot = try captureNotes()
            // Drain earlier writes before the final snapshot; no callback waits on the main queue.
            try saveQueue.sync { try store.save(snapshot) }
            return .terminateNow
        } catch {
            presentAlert(message: "便签尚未保存", detail: "已取消退出，请保留应用并检查磁盘空间。\n\(error.localizedDescription)")
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showAllNotes(nil)
        }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStates()
    }

    @objc private func newNote(_ sender: Any?) {
        createNote(content: "")
    }

    private func createNote(content: String, richContent: Data? = nil) {
        var note = StickyNote(content: content, frame: WindowFrame(nextDefaultFrame()))
        note.richContent = richContent
        notes[note.id] = note
        let controller = makeController(for: note)
        controllers[note.id] = controller
        lastActiveNoteID = note.id
        controller.show(focus: true)
        scheduleSave()
        refreshMenuStates()
    }

    @objc private func newNoteFromSelectedText(_ sender: Any?) {
        selectedTextCapture.capture { [weak self] result in
            switch result {
            case .success(let selection):
                self?.createNote(content: selection.text, richContent: selection.richContent)
            case .failure(let error):
                self?.presentCaptureError(error)
            }
        }
    }

    @objc private func showShortcutPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = ShortcutPreferencesWindowController(
                shortcut: selectedTextShortcut,
                onShortcutChange: { [weak self] shortcut in
                    self?.updateSelectedTextShortcut(shortcut) ?? false
                },
                onRecordingChange: { [weak self] isRecording in
                    self?.setSelectedTextShortcutRecording(isRecording)
                },
                onRequestAccessibility: { [weak self] in
                    self?.requestAccessibilityPermission()
                },
                actionShortcuts: actionShortcuts,
                defaultShortcuts: Self.defaultShortcuts,
                onActionShortcutChange: { [weak self] key, shortcut in self?.updateActionShortcut(key, shortcut) ?? false },
                onActionRecordingChange: { [weak self] key, recording in
                    guard let self, let id = Self.actionIDs[key], let shortcut = self.actionShortcuts[key] else { return }
                    if recording { self.hotKeyManager.unregister(id: id) }
                    else { _ = self.registerActionShortcut(key, shortcut) }
                },
                dataDirectory: store.fileURL.deletingLastPathComponent()
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAllNotes(_ sender: Any?) {
        if controllers.isEmpty {
            if notes.isEmpty { newNote(sender) }
            else { presentLibrary(archived: true) }
            return
        }

        let sortedControllers = controllers.values.sorted {
            $0.note.createdAt < $1.note.createdAt
        }
        for controller in sortedControllers.dropLast() {
            controller.show(focus: false)
        }
        sortedControllers.last?.show(focus: true)
        refreshMenuStates()
    }

    @objc private func hideAllNotes(_ sender: Any?) {
        controllers.values.forEach { $0.hide() }
        refreshMenuStates()
    }

    @objc private func closeCurrentNote(_ sender: Any?) {
        activeController?.hide()
        refreshMenuStates()
    }

    @objc private func deleteCurrentNote(_ sender: Any?) {
        guard let controller = activeController else {
            NSSound.beep()
            return
        }

        deleteNote(controller.note.id)
    }

    private func deleteNote(_ id: UUID) {
        guard notes[id] != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这张便签？"
        alert.informativeText = "删除后无法恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        controllers[id]?.window?.orderOut(nil)
        reminderService.cancel(id)
        controllers[id] = nil
        notes[id] = nil
        if lastActiveNoteID == id {
            lastActiveNoteID = nil
        }

        scheduleSave()
        libraryWindowController?.update(Array(notes.values))
        refreshMenuStates()
    }

    @objc private func toggleCurrentPin(_ sender: Any?) {
        guard let controller = activeController else {
            NSSound.beep()
            return
        }
        controller.toggleAlwaysOnTop()
        refreshMenuStates()
    }

    @objc private func toggleCurrentSpaceMode(_ sender: Any?) {
        guard let controller = activeController else {
            NSSound.beep()
            return
        }
        controller.toggleDisplayMode()
        refreshMenuStates()
    }

    @objc private func setCurrentTheme(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let theme = NoteTheme(rawValue: rawValue),
            let controller = activeController
        else {
            NSSound.beep()
            return
        }
        controller.setTheme(theme)
        refreshMenuStates()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        let frames = visibleScreenFrames
        controllers.values.forEach { $0.normalizeFrame(to: frames) }
    }

    private func loadNotes() {
        do {
            let result = try store.load()
            notes = Dictionary(uniqueKeysWithValues: result.notes.map { ($0.id, $0) })
            if result.source == .backup {
                NSLog("Easy Sticky recovered notes from backup")
            }
        } catch {
            storageAvailable = false
            presentAlert(message: "便签数据无法读取", detail: "为避免覆盖现有数据，已停止保存。请保留数据目录并检查备份。\n\(error.localizedDescription)")
            NSLog("Easy Sticky could not load notes: \(error.localizedDescription)")
        }
    }

    private func restoreWindows() {
        if notes.isEmpty {
            newNote(nil)
            return
        }

        let sortedNotes = notes.values.filter { !$0.isArchived }.sorted { $0.createdAt < $1.createdAt }
        for note in sortedNotes {
            controllers[note.id] = makeController(for: note)
        }

        let visibleNotes = sortedNotes.filter { !$0.isHidden }
        if !visibleNotes.isEmpty {
            for note in visibleNotes.dropLast() {
                controllers[note.id]?.show(focus: false)
            }
            if let last = visibleNotes.last {
                controllers[last.id]?.show(focus: true)
            }
        }
    }

    private func makeController(for note: StickyNote) -> StickyNoteWindowController {
        StickyNoteWindowController(
            note: note,
            visibleFrames: visibleScreenFrames,
            fallbackFrame: nextDefaultFrame(),
            onChange: { [weak self] updatedNote in
                self?.notes[updatedNote.id] = updatedNote
                self?.scheduleSave()
                self?.refreshMenuStates()
            },
            onFocus: { [weak self] id in
                self?.lastActiveNoteID = id
                self?.refreshMenuStates()
            },
            onAction: { [weak self] id, action in
                self?.handleAction(id, action)
            }
        )
    }

    private var activeController: StickyNoteWindowController? {
        if let keyWindow = NSApp.keyWindow,
           let controller = controllers.values.first(where: { $0.window === keyWindow }) {
            return controller
        }
        if let lastActiveNoteID, let controller = controllers[lastActiveNoteID] {
            return controller
        }
        return controllers.values.first(where: { $0.window?.isVisible == true }) ?? controllers.values.first
    }

    private var visibleScreenFrames: [CGRect] {
        let frames = NSScreen.screens.map(\.visibleFrame)
        return frames.isEmpty ? [CGRect(x: 0, y: 0, width: 1440, height: 900)] : frames
    }

    private func nextDefaultFrame() -> CGRect {
        let screen = NSScreen.main?.visibleFrame ?? visibleScreenFrames[0]
        let offset = CGFloat(controllers.count % 7) * 24
        let width: CGFloat = 420
        let height: CGFloat = 340
        return CGRect(
            x: max(screen.minX, screen.maxX - width - 40 - offset),
            y: max(screen.minY, screen.maxY - height - 40 - offset),
            width: width,
            height: height
        )
    }

    private func scheduleSave() {
        saveRevision += 1
        controllers.values.forEach { $0.setSaveStatus("保存中…") }
        pendingSave?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistImmediately()
        }
        pendingSave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func persistImmediately() {
        guard storageAvailable else { return }
        do {
            let snapshot = try captureNotes()
            let revision = saveRevision
            saveQueue.async { [self] in
                let result = Result { try store.save(snapshot) }
                DispatchQueue.main.async { [self] in
                    guard revision == saveRevision else { return }
                    switch result {
                    case .success:
                        controllers.values.forEach { $0.setSaveStatus("已保存") }
                        libraryWindowController?.update(Array(notes.values))
                    case .failure(let error): reportSaveFailure(error)
                    }
                }
            }
        } catch {
            reportSaveFailure(error)
        }
    }

    private func captureNotes() throws -> [StickyNote] {
        for (id, controller) in controllers { notes[id] = try controller.flushDocument() }
        return Array(notes.values)
    }

    private func reportSaveFailure(_ error: Error) {
        controllers.values.forEach { $0.setSaveStatus("保存失败") }
        NSLog("Easy Sticky could not save notes: \(error.localizedDescription)")
    }

    private func registerGlobalHotKeys() {
        let modifiers = UInt32(cmdKey | optionKey)
        let registered = actionShortcuts.map { registerActionShortcut($0.key, $0.value) }
        let newNoteRegistered = registered.allSatisfy { $0 }
        let visibilityRegistered = hotKeyManager.register(
            id: 2,
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: modifiers
        ) { [weak self] in
            guard let self else { return }
            let hasVisibleWindow = self.controllers.values.contains { $0.window?.isVisible == true }
            hasVisibleWindow ? self.hideAllNotes(nil) : self.showAllNotes(nil)
        }
        let selectedTextRegistered = registerSelectedTextHotKey(selectedTextShortcut)

        if !newNoteRegistered || !visibilityRegistered || !selectedTextRegistered {
            NSLog("Easy Sticky could not register one or more global hotkeys")
        }
    }

    private func registerSelectedTextHotKey(_ shortcut: KeyboardShortcut) -> Bool {
        hotKeyManager.register(
            id: Self.selectedTextHotKeyID,
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        ) { [weak self] in
            self?.newNoteFromSelectedText(nil)
        }
    }

    private func updateSelectedTextShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        guard !actionShortcuts.values.contains(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers }), !(shortcut.keyCode == UInt32(kVK_ANSI_S) && shortcut.modifiers == UInt32(cmdKey | optionKey)) else { return false }
        let previousShortcut = selectedTextShortcut
        guard registerSelectedTextHotKey(shortcut) else {
            if !isRecordingSelectedTextShortcut {
                _ = registerSelectedTextHotKey(previousShortcut)
            }
            return false
        }

        selectedTextShortcut = shortcut
        if let encoded = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(encoded, forKey: Self.selectedTextShortcutDefaultsKey)
        }
        refreshSelectedTextMenuTitles()
        return true
    }

    private func setSelectedTextShortcutRecording(_ isRecording: Bool) {
        isRecordingSelectedTextShortcut = isRecording
        if isRecording {
            hotKeyManager.unregister(id: Self.selectedTextHotKeyID)
        } else {
            _ = registerSelectedTextHotKey(selectedTextShortcut)
        }
    }

    private static func loadSelectedTextShortcut() -> KeyboardShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: selectedTextShortcutDefaultsKey),
            let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
        else {
            return .selectedTextDefault
        }
        return shortcut
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "note.text",
            accessibilityDescription: "Easy Sticky"
        )
        item.button?.toolTip = "Easy Sticky"

        let menu = NSMenu(title: "Easy Sticky")
        menu.delegate = self
        menu.addItem(makeItem("偏好设置…", action: #selector(showShortcutPreferences(_:))))
        menu.addItem(makeItem("新建便签", action: #selector(newNote(_:))))
        menu.addItem(makeSelectedTextMenuItem())
        menu.addItem(makeItem("显示全部便签", action: #selector(showAllNotes(_:))))
        menu.addItem(makeItem("隐藏全部便签", action: #selector(hideAllNotes(_:))))
        menu.addItem(makeItem("便签库…", action: #selector(showLibrary(_:))))
        menu.addItem(makeItem("已归档的便签…", action: #selector(showArchive(_:))))
        menu.addItem(.separator())

        let pinItem = makeItem("置顶显示", action: #selector(toggleCurrentPin(_:)))
        dynamicPinItems.append(pinItem)
        menu.addItem(pinItem)

        let spaceItem = makeItem("固定到所有桌面", action: #selector(toggleCurrentSpaceMode(_:)))
        dynamicSpaceItems.append(spaceItem)
        menu.addItem(spaceItem)
        menu.addItem(makeThemeRootItem())
        menu.addItem(.separator())
        menu.addItem(makeItem("使用帮助与反馈", action: #selector(showHelp(_:))))
        menu.addItem(makeItem("关于 Easy Sticky", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        menu.addItem(makeItem("退出 Easy Sticky", action: #selector(NSApplication.terminate(_:)), target: NSApp))

        item.menu = menu
        statusItem = item
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: "Main")

        let appRoot = NSMenuItem()
        let appMenu = NSMenu(title: "Easy Sticky")
        appMenu.addItem(makeItem("关于 Easy Sticky", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem("偏好设置…", action: #selector(showShortcutPreferences(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem("隐藏 Easy Sticky", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        appMenu.addItem(makeItem("退出 Easy Sticky", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        appRoot.submenu = appMenu
        mainMenu.addItem(appRoot)

        let fileRoot = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(makeItem("新建便签", action: #selector(newNote(_:)), key: "n"))
        fileMenu.addItem(makeSelectedTextMenuItem())
        fileMenu.addItem(makeItem("关闭便签", action: #selector(closeCurrentNote(_:)), key: "w"))
        fileMenu.addItem(makeItem("完成并归档", action: #selector(archiveCurrentNote(_:)), key: "d", modifiers: [.command, .shift]))
        fileMenu.addItem(makeItem("设置提醒…", action: #selector(remindCurrentNote(_:))))
        fileMenu.addItem(makeItem("便签库…", action: #selector(showLibrary(_:)), key: "l", modifiers: [.command, .shift]))
        fileMenu.addItem(makeItem("已归档的便签…", action: #selector(showArchive(_:))))
        fileMenu.addItem(.separator())
        let deleteItem = makeItem("删除便签…", action: #selector(deleteCurrentNote(_:)), key: "\u{8}")
        deleteItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(deleteItem)
        fileRoot.submenu = fileMenu
        mainMenu.addItem(fileRoot)

        let editRoot = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(makeResponderItem("撤销", action: Selector(("undo:")), key: "z"))
        let redo = makeResponderItem("重做", action: Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(makeResponderItem("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(makeResponderItem("复制", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(makeResponderItem("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(makeResponderItem("全选", action: #selector(NSText.selectAll(_:)), key: "a"))
        editRoot.submenu = editMenu
        mainMenu.addItem(editRoot)

        let formatRoot = NSMenuItem()
        let formatMenu = NSMenu(title: "格式")
        for (title, command, key) in [("加粗", "bold", "b"), ("斜体", "italic", "i"), ("下划线", "underline", "u"), ("删除线", "strike", ""), ("待办项", "todo", ""), ("插入图片…", "image", ""), ("插入链接…", "link", "k"), ("清除格式", "clear", "")] {
            let item = makeItem(title, action: #selector(formatCurrentNote(_:)), key: key)
            item.representedObject = command
            formatMenu.addItem(item)
        }
        formatRoot.submenu = formatMenu
        mainMenu.addItem(formatRoot)

        let viewRoot = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.delegate = self
        viewMenu.addItem(makeItem("显示全部便签", action: #selector(showAllNotes(_:))))
        viewMenu.addItem(makeItem("隐藏全部便签", action: #selector(hideAllNotes(_:)), key: "s", modifiers: [.command, .option]))
        viewMenu.addItem(.separator())

        let pinItem = makeItem("置顶显示", action: #selector(toggleCurrentPin(_:)))
        dynamicPinItems.append(pinItem)
        viewMenu.addItem(pinItem)

        let spaceItem = makeItem("固定到所有桌面", action: #selector(toggleCurrentSpaceMode(_:)))
        dynamicSpaceItems.append(spaceItem)
        viewMenu.addItem(spaceItem)
        viewMenu.addItem(makeThemeRootItem())
        viewRoot.submenu = viewMenu
        mainMenu.addItem(viewRoot)

        NSApp.mainMenu = mainMenu
    }

    private func handleAction(_ id: UUID, _ action: String) {
        lastActiveNoteID = id
        switch action {
        case "new": newNote(nil)
        case "hide": controllers[id]?.hide()
        case "archive": archiveNote(id)
        case "delete": deleteNote(id)
        case "reminder": showReminder(id)
        case "library": presentLibrary(archived: false)
        case "preferences": showShortcutPreferences(nil)
        default: break
        }
    }

    @objc private func formatCurrentNote(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String { activeController?.format(command) }
    }

    private func archiveNote(_ id: UUID) {
        do {
            if let controller = controllers[id] { notes[id] = try controller.flushDocument() }
        } catch { reportSaveFailure(error); return }
        guard var note = notes[id] else { return }
        note.archive()
        reminderService.cancel(id)
        controllers[id]?.window?.orderOut(nil)
        controllers[id] = nil
        notes[id] = note
        if lastActiveNoteID == id { lastActiveNoteID = nil }
        scheduleSave()
        refreshMenuStates()
    }

    private func openNote(_ id: UUID) {
        guard var note = notes[id] else { return }
        if note.isArchived { note.restore(); notes[id] = note }
        if controllers[id] == nil { controllers[id] = makeController(for: note) }
        controllers[id]?.show(focus: true)
        lastActiveNoteID = id
        scheduleSave()
    }

    @objc private func archiveCurrentNote(_ sender: Any?) { if let id = activeController?.note.id { archiveNote(id) } }
    @objc private func remindCurrentNote(_ sender: Any?) { if let id = activeController?.note.id { showReminder(id) } }
    @objc private func showLibrary(_ sender: Any?) { presentLibrary(archived: false) }
    @objc private func showArchive(_ sender: Any?) { presentLibrary(archived: true) }

    private func presentLibrary(archived: Bool) {
        if libraryWindowController == nil {
            libraryWindowController = NoteLibraryWindowController(onOpen: { [weak self] in self?.openNote($0) }, onDelete: { [weak self] in self?.deleteNote($0) })
        }
        libraryWindowController?.update(Array(notes.values), archived: archived)
        NSApp.activate(ignoringOtherApps: true)
        libraryWindowController?.showWindow(nil)
        libraryWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func showReminder(_ id: UUID) {
        guard let note = notes[id], !note.isArchived else { return }
        controllers[id]?.showReminderEditor(onSave: { [weak self] date, done in
            guard let self, let current = self.notes[id], !current.isArchived else { return }
            self.reminderService.schedule(current, at: date) { [weak self] error in
                if error == nil {
                    if let controller = self?.controllers[id] { controller.setReminder(date) }
                    else { self?.reminderService.cancel(id) }
                }
                done(error)
            }
        }, onCancel: { [weak self] in
            self?.reminderService.cancel(id)
            self?.controllers[id]?.setReminder(nil)
        })
    }

    private func registerActionShortcut(_ key: String, _ shortcut: KeyboardShortcut) -> Bool {
        guard let id = Self.actionIDs[key] else { return false }
        return hotKeyManager.register(id: id, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            switch key {
            case "new": self?.newNote(nil)
            case "show": self?.showAllNotes(nil)
            case "hide": self?.hideAllNotes(nil)
            default: break
            }
        }
    }

    private func updateActionShortcut(_ key: String, _ shortcut: KeyboardShortcut) -> Bool {
        let others = actionShortcuts.filter { $0.key != key }.map(\.value) + [selectedTextShortcut, KeyboardShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey), keyLabel: "S")]
        guard !others.contains(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers }) else { return false }
        guard registerActionShortcut(key, shortcut) else {
            if let previous = actionShortcuts[key] { _ = registerActionShortcut(key, previous) }
            return false
        }
        actionShortcuts[key] = shortcut
        if let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: "shortcut.\(key)") }
        return true
    }

    @objc private func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/Yalo-coco/easy-sticky")!)
    }

    private func makeThemeRootItem() -> NSMenuItem {
        let root = NSMenuItem(title: "便签颜色", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "便签颜色")
        for theme in NoteTheme.allCases {
            let item = makeItem(theme.displayName, action: #selector(setCurrentTheme(_:)))
            item.representedObject = theme.rawValue
            item.image = theme.menuImage
            dynamicThemeItems.append(item)
            menu.addItem(item)
        }
        root.submenu = menu
        return root
    }

    private func makeSelectedTextMenuItem() -> NSMenuItem {
        let item = makeItem(
            "从选中文本新建便签（\(selectedTextShortcut.displayName)）",
            action: #selector(newNoteFromSelectedText(_:))
        )
        selectedTextMenuItems.append(item)
        return item
    }

    private func refreshSelectedTextMenuTitles() {
        selectedTextMenuItems.forEach {
            $0.title = "从选中文本新建便签（\(selectedTextShortcut.displayName)）"
        }
    }

    private func makeItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    private func makeResponderItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        return item
    }

    private func refreshMenuStates() {
        guard let note = activeController?.note else {
            dynamicPinItems.forEach { $0.state = .off; $0.isEnabled = false }
            dynamicSpaceItems.forEach { $0.state = .off; $0.isEnabled = false }
            dynamicThemeItems.forEach { $0.state = .off; $0.isEnabled = false }
            return
        }

        dynamicPinItems.forEach {
            $0.isEnabled = true
            $0.state = note.isAlwaysOnTop ? .on : .off
        }
        dynamicSpaceItems.forEach {
            $0.isEnabled = true
            $0.state = note.displayMode == .allSpaces ? .on : .off
        }
        dynamicThemeItems.forEach {
            $0.isEnabled = true
            $0.state = ($0.representedObject as? String) == note.theme.rawValue ? .on : .off
        }
    }

    private func requestAccessibilityPermission() {
        let trusted = selectedTextCapture.requestAccessibilityPermission()
        guard !trusted else {
            presentAlert(
                message: "辅助功能权限已开启",
                detail: "现在可以在其他应用中选中文本并使用 \(selectedTextShortcut.displayName) 创建便签。"
            )
            return
        }
        presentAlert(
            message: "请允许 Easy Sticky 控制电脑",
            detail: "在“系统设置 > 隐私与安全性 > 辅助功能”中开启 Easy Sticky，然后重新使用快捷键。"
        )
    }

    private func presentCaptureError(_ error: SelectedTextCaptureError) {
        if error == .accessibilityPermissionRequired {
            requestAccessibilityPermission()
            return
        }
        presentAlert(message: "无法创建便签", detail: error.localizedDescription)
    }

    private func presentAlert(message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
