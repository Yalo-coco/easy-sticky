import AppKit
import EasyStickyCore

final class NoteLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["当前便签", "已归档"], trackingMode: .selectOne, target: nil, action: nil)
    private let actionButton = NSButton(title: "打开便签", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private var notes: [StickyNote] = []
    private var rows: [StickyNote] = []
    private let onOpen: (UUID) -> Void
    private let onDelete: (UUID) -> Void

    init(onOpen: @escaping (UUID) -> Void, onDelete: @escaping (UUID) -> Void) {
        self.onOpen = onOpen
        self.onDelete = onDelete
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "便签库"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        window.center()
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged(_:))
        search.placeholderString = "搜索便签内容"
        search.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("note")))
        table.headerView = nil
        table.rowHeight = 62
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        actionButton.target = self
        actionButton.action = #selector(openSelected(_:))
        let delete = NSButton(title: "永久删除…", target: self, action: #selector(deleteSelected(_:)))
        let buttons = NSStackView(views: [actionButton, delete, summary])
        buttons.spacing = 16
        let content = window.contentView!
        for view in [filter, search, scroll, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            filter.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            search.centerYAnchor.constraint(equalTo: filter.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: filter.trailingAnchor, constant: 20),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ notes: [StickyNote], archived: Bool? = nil) {
        self.notes = notes
        if let archived { filter.selectedSegment = archived ? 1 : 0 }
        reload()
    }

    private func reload() {
        let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        rows = notes.filter { $0.isArchived == (filter.selectedSegment == 1) && (search.stringValue.isEmpty || $0.content.localizedCaseInsensitiveContains(search.stringValue)) }.sorted { $0.updatedAt > $1.updatedAt }
        actionButton.title = filter.selectedSegment == 1 ? "恢复便签" : "打开便签"
        summary.stringValue = rows.isEmpty ? "没有匹配的便签" : "\(rows.count) 张便签"
        table.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = rows[row]
        let title = note.content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        let label = NSTextField(wrappingLabelWithString: "\(title.isEmpty ? "空白便签" : String(title.prefix(80)))\n\(note.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(note.isArchived ? "已归档" : note.isHidden ? "已收起" : "桌面上")")
        label.font = .systemFont(ofSize: 13)
        label.maximumNumberOfLines = 3
        return label
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func filterChanged(_ sender: Any?) { reload() }
    @objc private func openSelected(_ sender: Any?) {
        guard rows.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        onOpen(rows[table.selectedRow].id)
    }
    @objc private func deleteSelected(_ sender: Any?) {
        guard rows.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        onDelete(rows[table.selectedRow].id)
    }
}
