import CoreGraphics
import Foundation

public enum NoteDisplayMode: String, Codable, CaseIterable, Sendable {
    case allSpaces
    case currentSpace
}

public enum NoteTheme: String, Codable, CaseIterable, Sendable {
    case yellow
    case orange
    case rose
    case lavender
    case blue
    case mint
    case sage
    case graphite
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    // Carbon key code for Y with Command + Option.
    public static let selectedTextDefault = KeyboardShortcut(
        keyCode: 0x10,
        modifiers: 0x0900,
        keyLabel: "Y"
    )
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public func normalized(
        to visibleFrames: [CGRect],
        minimumSize: CGSize = CGSize(width: 220, height: 140),
        fallback: CGRect = CGRect(x: 80, y: 80, width: 320, height: 260)
    ) -> WindowFrame {
        guard !visibleFrames.isEmpty else {
            return hasFinitePositiveSize ? self : WindowFrame(fallback)
        }

        var candidate = hasFinitePositiveSize ? rect : fallback
        let targetScreen = Self.bestScreen(for: candidate, among: visibleFrames)

        let minimumWidth = min(minimumSize.width, targetScreen.width)
        let minimumHeight = min(minimumSize.height, targetScreen.height)
        candidate.size.width = min(max(candidate.width, minimumWidth), targetScreen.width)
        candidate.size.height = min(max(candidate.height, minimumHeight), targetScreen.height)

        let maximumX = targetScreen.maxX - candidate.width
        let maximumY = targetScreen.maxY - candidate.height
        candidate.origin.x = min(max(candidate.minX, targetScreen.minX), maximumX)
        candidate.origin.y = min(max(candidate.minY, targetScreen.minY), maximumY)

        return WindowFrame(candidate)
    }

    private var hasFinitePositiveSize: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    private static func bestScreen(for frame: CGRect, among screens: [CGRect]) -> CGRect {
        let intersections = screens.map { screen -> (screen: CGRect, area: CGFloat) in
            let intersection = screen.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            return (screen, area)
        }

        if let bestIntersection = intersections.max(by: { $0.area < $1.area }), bestIntersection.area > 0 {
            return bestIntersection.screen
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min { lhs, rhs in
            squaredDistance(from: center, to: lhs) < squaredDistance(from: center, to: rhs)
        } ?? screens[0]
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}

public struct StickyNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var content: String
    public let createdAt: Date
    public var updatedAt: Date
    public var frame: WindowFrame?
    public var displayMode: NoteDisplayMode
    public var isAlwaysOnTop: Bool
    public var isHidden: Bool
    public var theme: NoteTheme

    public init(
        id: UUID = UUID(),
        content: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        frame: WindowFrame? = nil,
        displayMode: NoteDisplayMode = .allSpaces,
        isAlwaysOnTop: Bool = true,
        isHidden: Bool = false,
        theme: NoteTheme = .yellow
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.frame = frame
        self.displayMode = displayMode
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isHidden = isHidden
        self.theme = theme
    }

    public mutating func setContent(_ newContent: String, at date: Date = Date()) {
        guard content != newContent else { return }
        content = newContent
        updatedAt = date
    }

    public mutating func setWindowState(
        frame: WindowFrame? = nil,
        displayMode: NoteDisplayMode? = nil,
        isAlwaysOnTop: Bool? = nil,
        isHidden: Bool? = nil,
        theme: NoteTheme? = nil,
        at date: Date = Date()
    ) {
        if let frame {
            self.frame = frame
        }
        if let displayMode {
            self.displayMode = displayMode
        }
        if let isAlwaysOnTop {
            self.isAlwaysOnTop = isAlwaysOnTop
        }
        if let isHidden {
            self.isHidden = isHidden
        }
        if let theme {
            self.theme = theme
        }
        updatedAt = date
    }
}
