import AppKit
import EasyStickyCore

final class ColorPaletteViewController: NSViewController {
    private let selectedTheme: NoteTheme
    private let onSelect: (NoteTheme) -> Void

    init(selectedTheme: NoteTheme, onSelect: @escaping (NoteTheme) -> Void) {
        self.selectedTheme = selectedTheme
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 210, height: 108)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: "便签颜色")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: makeRows())
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 9
        grid.xPlacement = .center
        grid.yPlacement = .center

        container.addSubview(titleLabel)
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            grid.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ])
        view = container
    }

    @objc private func selectTheme(_ sender: ColorSwatchButton) {
        onSelect(sender.theme)
    }

    private func makeRows() -> [[NSView]] {
        let buttons = NoteTheme.allCases.map { theme -> NSView in
            let button = ColorSwatchButton(theme: theme, isSelected: theme == selectedTheme)
            button.target = self
            button.action = #selector(selectTheme(_:))
            return button
        }
        return [Array(buttons.prefix(4)), Array(buttons.dropFirst(4))]
    }
}

private final class ColorSwatchButton: NSButton {
    let theme: NoteTheme
    private let selected: Bool

    init(theme: NoteTheme, isSelected: Bool) {
        self.theme = theme
        selected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        toolTip = theme.displayName
        setAccessibilityLabel(theme.displayName)
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(isSelected ? "已选择" : "未选择")
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = bounds.insetBy(dx: 4, dy: 1)
        let circle = NSBezierPath(ovalIn: circleRect)
        theme.backgroundColor(for: effectiveAppearance)
            .withAlphaComponent(isHighlighted ? 0.72 : 1)
            .setFill()
        circle.fill()

        (selected ? theme.accentColor(for: effectiveAppearance) : NSColor.separatorColor).setStroke()
        circle.lineWidth = selected ? 2.5 : 0.8
        circle.stroke()

        guard selected else { return }
        let checkmark = NSBezierPath()
        checkmark.move(to: NSPoint(x: circleRect.midX - 5, y: circleRect.midY))
        checkmark.line(to: NSPoint(x: circleRect.midX - 1.5, y: circleRect.midY - 3.5))
        checkmark.line(to: NSPoint(x: circleRect.midX + 5.5, y: circleRect.midY + 4))
        checkmark.lineWidth = 2
        checkmark.lineCapStyle = .round
        checkmark.lineJoinStyle = .round
        theme.accentColor(for: effectiveAppearance).setStroke()
        checkmark.stroke()
    }
}
