import AppKit
import EasyStickyCore

extension NoteTheme {
    var displayName: String {
        switch self {
        case .yellow: return "暖黄"
        case .orange: return "杏橙"
        case .rose: return "玫瑰粉"
        case .lavender: return "薰衣草紫"
        case .blue: return "天空蓝"
        case .mint: return "薄荷绿"
        case .sage: return "鼠尾草绿"
        case .graphite: return "雾灰"
        }
    }

    func backgroundColor(for appearance: NSAppearance) -> NSColor {
        let colors: (light: NSColor, dark: NSColor)
        switch self {
        case .yellow: colors = (rgb(0xFCF5DA), rgb(0x4B432A))
        case .orange: colors = (rgb(0xFBE8D5), rgb(0x4C382A))
        case .rose: colors = (rgb(0xFBE4E8), rgb(0x4A3239))
        case .lavender: colors = (rgb(0xEEE7FA), rgb(0x3C3549))
        case .blue: colors = (rgb(0xE2EFF9), rgb(0x2C3D4C))
        case .mint: colors = (rgb(0xE3F3EB), rgb(0x2C423A))
        case .sage: colors = (rgb(0xEBF0E0), rgb(0x374232))
        case .graphite: colors = (rgb(0xF0F1F3), rgb(0x36383B))
        }
        return appearance.isDark ? colors.dark : colors.light
    }

    func foregroundColor(for appearance: NSAppearance) -> NSColor {
        appearance.isDark ? NSColor(white: 0.94, alpha: 1) : rgb(0x2F2D29)
    }

    func accentColor(for appearance: NSAppearance) -> NSColor {
        if appearance.isDark {
            return foregroundColor(for: appearance).withAlphaComponent(0.90)
        }

        switch self {
        case .yellow: return rgb(0x856A13)
        case .orange: return rgb(0x99531F)
        case .rose: return rgb(0x95485C)
        case .lavender: return rgb(0x695293)
        case .blue: return rgb(0x356A92)
        case .mint: return rgb(0x33745E)
        case .sage: return rgb(0x58704D)
        case .graphite: return rgb(0x5C6066)
        }
    }

    var menuImage: NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            backgroundColor(for: NSApp.effectiveAppearance).setFill()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            circle.fill()
            NSColor.separatorColor.setStroke()
            circle.lineWidth = 0.75
            circle.stroke()
            return true
        }
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private func rgb(_ value: UInt32) -> NSColor {
    NSColor(
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}
