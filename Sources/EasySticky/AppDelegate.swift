import AppKit
import Carbon.HIToolbox
import EasyStickyCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: NoteStore
    private let hotKeyManager = GlobalHotKeyManager()

    private var notes: [UUID: StickyNote] = [:]
    private var controllers: [UUID: StickyNoteWindowController] = [:]
    private var pendingSave: DispatchWorkItem?
    private var lastActiveNoteID: UUID?
    private var statusItem: NSStatusItem?
    private var dynamicPinItems: [NSMenuItem] = []
    private var dynamicSpaceItems: [NSMenuItem] = []
    private var dynamicThemeItems: [NSMenuItem] = []

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
        restoreWindows()
        refreshMenuStates()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingSave?.cancel()
        persistImmediately()
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
        let note = StickyNote(frame: WindowFrame(nextDefaultFrame()))
        notes[note.id] = note
        let controller = makeController(for: note)
        controllers[note.id] = controller
        lastActiveNoteID = note.id
        controller.show(focus: true)
        scheduleSave()
        refreshMenuStates()
    }

    @objc private func showAllNotes(_ sender: Any?) {
        if controllers.isEmpty {
            newNote(sender)
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
        activeController?.close()
        refreshMenuStates()
    }

    @objc private func deleteCurrentNote(_ sender: Any?) {
        guard let controller = activeController else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这张便签？"
        alert.informativeText = "删除后无法恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let id = controller.note.id
        controller.window?.orderOut(nil)
        controllers[id] = nil
        notes[id] = nil
        if lastActiveNoteID == id {
            lastActiveNoteID = nil
        }

        if notes.isEmpty {
            newNote(nil)
        } else {
            scheduleSave()
        }
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
            notes = [:]
            NSLog("Easy Sticky could not load notes: \(error.localizedDescription)")
        }
    }

    private func restoreWindows() {
        if notes.isEmpty {
            newNote(nil)
            return
        }

        let sortedNotes = notes.values.sorted { $0.createdAt < $1.createdAt }
        for note in sortedNotes {
            controllers[note.id] = makeController(for: note)
        }

        let visibleNotes = sortedNotes.filter { !$0.isHidden }
        if visibleNotes.isEmpty, let mostRecent = sortedNotes.max(by: { $0.updatedAt < $1.updatedAt }) {
            controllers[mostRecent.id]?.show(focus: true)
        } else {
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
        let width: CGFloat = 320
        let height: CGFloat = 260
        return CGRect(
            x: max(screen.minX, screen.maxX - width - 40 - offset),
            y: max(screen.minY, screen.maxY - height - 40 - offset),
            width: width,
            height: height
        )
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistImmediately()
        }
        pendingSave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func persistImmediately() {
        do {
            try store.save(Array(notes.values))
        } catch {
            NSLog("Easy Sticky could not save notes: \(error.localizedDescription)")
        }
    }

    private func registerGlobalHotKeys() {
        let modifiers = UInt32(cmdKey | optionKey)
        let newNoteRegistered = hotKeyManager.register(
            id: 1,
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: modifiers
        ) { [weak self] in
            self?.newNote(nil)
        }
        let visibilityRegistered = hotKeyManager.register(
            id: 2,
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: modifiers
        ) { [weak self] in
            guard let self else { return }
            let hasVisibleWindow = self.controllers.values.contains { $0.window?.isVisible == true }
            hasVisibleWindow ? self.hideAllNotes(nil) : self.showAllNotes(nil)
        }

        if !newNoteRegistered || !visibilityRegistered {
            NSLog("Easy Sticky could not register one or more global hotkeys")
        }
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
        menu.addItem(makeItem("新建便签", action: #selector(newNote(_:))))
        menu.addItem(makeItem("显示全部便签", action: #selector(showAllNotes(_:))))
        menu.addItem(makeItem("隐藏全部便签", action: #selector(hideAllNotes(_:))))
        menu.addItem(.separator())

        let pinItem = makeItem("置顶显示", action: #selector(toggleCurrentPin(_:)))
        dynamicPinItems.append(pinItem)
        menu.addItem(pinItem)

        let spaceItem = makeItem("固定到所有桌面", action: #selector(toggleCurrentSpaceMode(_:)))
        dynamicSpaceItems.append(spaceItem)
        menu.addItem(spaceItem)
        menu.addItem(makeThemeRootItem())
        menu.addItem(.separator())
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
        appMenu.addItem(makeItem("隐藏 Easy Sticky", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        appMenu.addItem(makeItem("退出 Easy Sticky", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        appRoot.submenu = appMenu
        mainMenu.addItem(appRoot)

        let fileRoot = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(makeItem("新建便签", action: #selector(newNote(_:)), key: "n"))
        fileMenu.addItem(makeItem("关闭便签", action: #selector(closeCurrentNote(_:)), key: "w"))
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

    private func makeThemeRootItem() -> NSMenuItem {
        let root = NSMenuItem(title: "便签颜色", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "便签颜色")
        let titles: [NoteTheme: String] = [
            .yellow: "暖黄",
            .mint: "薄荷绿",
            .blue: "天空蓝",
            .rose: "玫瑰粉"
        ]
        for theme in NoteTheme.allCases {
            let item = makeItem(titles[theme] ?? theme.rawValue, action: #selector(setCurrentTheme(_:)))
            item.representedObject = theme.rawValue
            dynamicThemeItems.append(item)
            menu.addItem(item)
        }
        root.submenu = menu
        return root
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
}
