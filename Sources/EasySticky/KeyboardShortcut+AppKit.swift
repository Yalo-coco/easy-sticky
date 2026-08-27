import AppKit
import Carbon.HIToolbox
import EasyStickyCore

extension KeyboardShortcut {
    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    static func from(event: NSEvent) -> KeyboardShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        let requiredModifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
        guard modifiers & requiredModifiers != 0 else { return nil }
        return KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: eventKeyLabel(for: event)
        )
    }
}

private func eventKeyLabel(for event: NSEvent) -> String {
    switch event.keyCode {
    case 36: return "↩"
    case 48: return "⇥"
    case 49: return "Space"
    case 51: return "⌫"
    case 53: return "Esc"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default:
        let label = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return label?.isEmpty == false ? label! : "Key (event.keyCode)"
    }
}
