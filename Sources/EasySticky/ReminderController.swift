import AppKit
import EasyStickyCore
import UserNotifications

final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var isRequestingAuthorization = false
    var onOpenNote: ((UUID) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func schedule(_ note: StickyNote, at date: Date, completion: @escaping (Error?) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.add(note, at: date, completion: completion)
                case .notDetermined:
                    if !self.isRequestingAuthorization {
                        self.isRequestingAuthorization = true
                        // Only the explicit permission action activates the app, never normal note display.
                        NSApp.activate(ignoringOtherApps: true)
                        self.center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
                            DispatchQueue.main.async { self?.isRequestingAuthorization = false }
                            if let error { NSLog("Notification authorization: \(error.localizedDescription)") }
                        }
                    }
                    // A system prompt may be suppressed while sharing the screen. Do not leave the
                    // save operation pending, or schedule an obsolete reminder after closing this panel.
                    completion(ReminderError.permissionPending)
                default:
                    completion(ReminderError.permission)
                }
            }
        }
    }

    private func add(_ note: StickyNote, at date: Date, completion: @escaping (Error?) -> Void) {
        guard date > Date() else { DispatchQueue.main.async { completion(ReminderError.past) }; return }
        let content = UNMutableNotificationContent()
        content.title = "Easy Sticky · 便签提醒"
        content.body = String(note.content.prefix(180))
        if content.body.isEmpty { content.body = "你设置的便签提醒到时间了。" }
        content.sound = .default
        content.userInfo = ["noteID": note.id.uuidString]
        let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
        center.add(UNNotificationRequest(identifier: note.id.uuidString, content: content, trigger: trigger)) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func restore(_ notes: [StickyNote]) {
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let active = Dictionary(uniqueKeysWithValues: notes.filter { !$0.isArchived && $0.reminderDate != nil }.map { ($0.id.uuidString, $0) })
            let inactive = Set(notes.filter { $0.isArchived || $0.reminderDate == nil }.map { $0.id.uuidString })
            let stale = requests.filter { inactive.contains($0.identifier) }.map(\.identifier)
            self.center.removePendingNotificationRequests(withIdentifiers: stale)
            let pending = Set(requests.map(\.identifier))
            for note in active.values where !pending.contains(note.id.uuidString) {
                if let date = note.reminderDate, date > Date() {
                    self.add(note, at: date) { error in
                        if let error { NSLog("Reminder restore: \(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    func cancel(_ id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["noteID"] as? String, let id = UUID(uuidString: raw) {
            DispatchQueue.main.async { [weak self] in self?.onOpenNote?(id) }
        }
        completionHandler()
    }
}

private enum ReminderError: LocalizedError {
    case permission, permissionPending, past
    var errorDescription: String? {
        switch self {
        case .permission: return "尚未获得通知权限。请在系统设置 → 通知 → Easy Sticky 中允许通知后重试。"
        case .permissionPending: return "已申请通知权限，提醒尚未保存。请允许通知后再次点击“设置提醒”；未见弹窗时可打开下方通知设置。"
        case .past: return "请选择未来的时间。"
        }
    }
}

final class ReminderEditorView: NSView {
    private let picker: ReminderWheelPicker
    private let status = NSTextField(wrappingLabelWithString: "")
    private let onSave: (Date, @escaping (Error?) -> Void) -> Void
    private let onCancelReminder: () -> Void
    private let onClose: () -> Void
    private let saveButton = ReminderPillButton(title: "完成", primary: true)
    private let settingsButton = NSButton(title: "通知设置", target: nil, action: nil)

    init(date: Date?, onSave: @escaping (Date, @escaping (Error?) -> Void) -> Void, onCancel: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancelReminder = onCancel
        self.onClose = onClose
        picker = ReminderWheelPicker(date: date.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(900))
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "设置提醒")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let shortcuts = NSStackView()
        shortcuts.spacing = 8
        for (index, title) in ["15 分钟后", "1 小时后", "明早 9 点"].enumerated() {
            let button = ReminderPillButton(title: title)
            button.target = self
            button.action = #selector(quickTime(_:))
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.tag = index
            button.setAccessibilityLabel(title)
            shortcuts.addArrangedSubview(button)
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(openNotificationSettings(_:))
        settingsButton.isBordered = false
        settingsButton.font = .systemFont(ofSize: 11)
        settingsButton.isHidden = true
        let back = NSButton(title: "取消", target: self, action: #selector(closeEditor(_:)))
        back.bezelStyle = .rounded
        back.isBordered = false
        back.keyEquivalent = "\u{1b}"
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.contentTintColor = .white
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "移除提醒", target: self, action: #selector(cancelReminder(_:)))
        cancel.isBordered = false
        cancel.contentTintColor = .systemRed
        cancel.isHidden = date == nil
        let actions = NSStackView(views: [back, cancel, NSView(), saveButton])
        actions.spacing = 6

        let stack = NSStackView(views: [title, shortcuts, picker, status, settingsButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        [scroll, actions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            picker.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor),
            actions.heightAnchor.constraint(equalToConstant: 32),
            saveButton.widthAnchor.constraint(equalToConstant: 76)
        ])
        picker.onChange = { [weak self] in self?.updateSummary() }
        updateSummary()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateSummary() {
        settingsButton.isHidden = true
        guard let date = picker.dateValue else {
            status.stringValue = "这个当地时间不存在，请调整时间。"
            saveButton.isEnabled = false
            return
        }
        saveButton.isEnabled = date > Date()
        status.stringValue = date > Date()
            ? date.formatted(.dateTime.year().month().day().hour().minute()) + " 提醒"
            : "这个时间已过去，请向后滚动日期或时间。"
    }

    @objc private func quickTime(_ sender: NSButton) {
        if sender.tag == 2 {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            picker.setDate(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!)
        } else {
            picker.setDate(Date().addingTimeInterval(sender.tag == 0 ? 900 : 3600))
        }
        updateSummary()
    }

    @objc private func save(_ sender: Any?) {
        guard let date = picker.dateValue, date > Date() else { updateSummary(); return }
        saveButton.isEnabled = false
        status.stringValue = "正在设置…"
        onSave(date) { [weak self] error in
            guard let self else { return }
            self.saveButton.isEnabled = true
            if let error {
                self.status.stringValue = error.localizedDescription
                self.settingsButton.isHidden = true
                if let error = error as? ReminderError, error != .past { self.settingsButton.isHidden = false }
            } else { self.onClose() }
        }
    }

    @objc private func cancelReminder(_ sender: Any?) { onCancelReminder(); onClose() }
    @objc private func closeEditor(_ sender: Any?) { onClose() }
    @objc private func openNotificationSettings(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}

/// Custom fill stays legible even while the nonactivating note is not the foreground app.
private final class ReminderPillButton: NSButton {
    private let primary: Bool
    init(title: String, primary: Bool = false) {
        self.primary = primary
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        return NSSize(width: text.width + 24, height: primary ? 30 : 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        let fill = primary ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.07)
        fill.withAlphaComponent(isEnabled ? (isHighlighted ? 0.6 : primary ? 1 : 0.07) : 0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: primary ? 9 : 12, yRadius: primary ? 9 : 12).fill()
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: primary ? 13 : 12, weight: .medium),
            .foregroundColor: primary ? NSColor.white : NSColor.labelColor.withAlphaComponent(isEnabled ? 0.8 : 0.3)
        ])
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: (bounds.height - text.size().height) / 2))
    }
}

/// A compact three-column clock picker. Dates are calendar days, never 86400-second offsets.
final class ReminderWheelPicker: NSView {
    let dayWheel: ReminderWheel
    let hourWheel: ReminderWheel
    let minuteWheel: ReminderWheel
    private let calendar: Calendar
    private let baseDay: Date
    var onChange: (() -> Void)?

    init(date: Date, calendar: Calendar = .current, today: Date = Date()) {
        self.calendar = calendar
        baseDay = calendar.startOfDay(for: today)
        let base = baseDay
        dayWheel = ReminderWheel(label: "日期", value: 0) { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: base) else { return "" }
            let prefix = offset == 0 ? "今天" : offset == 1 ? "明天" : ""
            let parts = calendar.dateComponents([.month, .day], from: day)
            return prefix.isEmpty ? "\(parts.month!)/\(parts.day!) " + day.formatted(.dateTime.weekday(.abbreviated)) : prefix
        }
        hourWheel = ReminderWheel(label: "小时", value: 0, range: 0...23) { String(format: "%02d", $0) }
        minuteWheel = ReminderWheel(label: "分钟", value: 0, range: 0...59) { String(format: "%02d", $0) }
        super.init(frame: .zero)
        let wheels = NSStackView(views: [dayWheel, hourWheel, minuteWheel])
        wheels.spacing = 8
        wheels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wheels)
        NSLayoutConstraint.activate([
            wheels.leadingAnchor.constraint(equalTo: leadingAnchor),
            wheels.trailingAnchor.constraint(equalTo: trailingAnchor),
            wheels.topAnchor.constraint(equalTo: topAnchor),
            wheels.bottomAnchor.constraint(equalTo: bottomAnchor),
            hourWheel.widthAnchor.constraint(equalTo: minuteWheel.widthAnchor),
            dayWheel.widthAnchor.constraint(equalTo: hourWheel.widthAnchor, multiplier: 1.9),
            heightAnchor.constraint(equalToConstant: 126)
        ])
        for wheel in [dayWheel, hourWheel, minuteWheel] {
            wheel.onChange = { [weak self] in self?.onChange?() }
        }
        setDate(date)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var dateValue: Date? {
        guard let day = calendar.date(byAdding: .day, value: dayWheel.value, to: baseDay),
              let result = calendar.date(bySettingHour: hourWheel.value, minute: minuteWheel.value, second: 0, of: day, matchingPolicy: .strict),
              calendar.isDate(result, inSameDayAs: day),
              calendar.component(.hour, from: result) == hourWheel.value,
              calendar.component(.minute, from: result) == minuteWheel.value else { return nil }
        return result
    }

    func setDate(_ date: Date) {
        dayWheel.value = calendar.dateComponents([.day], from: baseDay, to: calendar.startOfDay(for: date)).day ?? 0
        hourWheel.value = calendar.component(.hour, from: date)
        minuteWheel.value = calendar.component(.minute, from: date)
    }
}

/// Native AppKit control: wheel scrolling, dragging, clicking adjacent rows and arrow keys.
final class ReminderWheel: NSControl {
    var value: Int { didSet { needsDisplay = true; setAccessibilityValue(labelForValue(value)) } }
    var onChange: (() -> Void)?
    private let label: String
    private let range: ClosedRange<Int>?
    private let labelForValue: (Int) -> String
    private var scrollRemainder: CGFloat = 0
    private var dragY: CGFloat?
    private var didDrag = false
    private let rowHeight: CGFloat = 28
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(label: String, value: Int, range: ClosedRange<Int>? = nil, labelForValue: @escaping (Int) -> String) {
        self.label = label
        self.value = value
        self.range = range
        self.labelForValue = labelForValue
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.incrementor)
        setAccessibilityLabel(label)
        setAccessibilityValue(labelForValue(value))
        setAccessibilityHelp("滚动、拖动或按上下方向键选择" + label)
        toolTip = "滚动、拖动或按 ↑ ↓ 选择" + label
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func wrapped(_ proposed: Int) -> Int {
        guard let range else { return proposed }
        let count = range.upperBound - range.lowerBound + 1
        return ((proposed - range.lowerBound) % count + count) % count + range.lowerBound
    }
    func step(_ delta: Int) {
        value = wrapped(value + delta)
        onChange?()
    }
    override func accessibilityPerformIncrement() -> Bool { step(1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-1); return true }

    override func draw(_ dirtyRect: NSRect) {
        let centerY = (bounds.height + 16) / 2
        let band = NSRect(x: 0, y: centerY - rowHeight / 2, width: bounds.width, height: rowHeight)
        NSColor.labelColor.withAlphaComponent(0.065).setFill()
        NSBezierPath(roundedRect: band, xRadius: 7, yRadius: 7).fill()
        let heading = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        heading.draw(at: NSPoint(x: (bounds.width - heading.size().width) / 2, y: 0))
        for offset in -2...2 {
            let text = NSAttributedString(string: labelForValue(wrapped(value + offset)), attributes: [
                .font: range == nil ? NSFont.systemFont(ofSize: offset == 0 ? 15 : 13, weight: offset == 0 ? .semibold : .regular) : NSFont.monospacedDigitSystemFont(ofSize: offset == 0 ? 23 : 18, weight: offset == 0 ? .medium : .regular),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(offset == 0 ? 1 : abs(offset) == 1 ? 0.35 : 0.12)
            ])
            let y = centerY + CGFloat(offset) * rowHeight - text.size().height / 2
            if y >= 14 && y + text.size().height <= bounds.height {
                text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: y))
            }
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.6).setStroke()
            NSBezierPath(roundedRect: band.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).stroke()
        }
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 126 { step(-1) }
        else if event.keyCode == 125 { step(1) }
        else { super.keyDown(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
        let steps = Int(scrollRemainder / rowHeight)
        if steps != 0 { step(-steps); scrollRemainder -= CGFloat(steps) * rowHeight }
        if event.phase == .ended || event.momentumPhase == .ended { scrollRemainder = 0 }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragY = convert(event.locationInWindow, from: nil).y
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        guard let previous = dragY else { return }
        let steps = Int((y - previous) / rowHeight)
        if steps != 0 { step(-steps); dragY = previous + CGFloat(steps) * rowHeight; didDrag = true }
    }
    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            let y = convert(event.locationInWindow, from: nil).y
            step(Int(((y - (bounds.height + 16) / 2) / rowHeight).rounded()))
        }
        dragY = nil
    }
}
