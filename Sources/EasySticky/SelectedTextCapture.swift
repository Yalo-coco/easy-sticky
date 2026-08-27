import AppKit
import ApplicationServices

enum SelectedTextCaptureError: LocalizedError, Equatable {
    case accessibilityPermissionRequired
    case noSelection
    case copyUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "需要辅助功能权限，才能读取其他应用中的选中文本。"
        case .noSelection:
            return "没有读取到选中的文本。请先在其他应用中选中文本，再按快捷键。"
        case .copyUnavailable:
            return "当前应用没有提供可复制的选中文本。"
        }
    }
}

final class SelectedTextCapture {
    func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func capture(completion: @escaping (Result<String, SelectedTextCaptureError>) -> Void) {
        guard AXIsProcessTrusted() else {
            _ = requestAccessibilityPermission()
            completion(.failure(.accessibilityPermissionRequired))
            return
        }

        if let selectedText = selectedTextFromAccessibility(), !selectedText.isBlank {
            completion(.success(selectedText))
            return
        }
        captureByCopying(completion: completion)
    }

    private func selectedTextFromAccessibility() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return nil
        }

        let focusedElement = focusedValue as! AXUIElement
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectionValue
        ) == .success else {
            return nil
        }
        return selectionValue as? String
    }

    private func captureByCopying(
        completion: @escaping (Result<String, SelectedTextCaptureError>) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        let baselineChangeCount = pasteboard.changeCount

        guard postCopyShortcut() else {
            snapshot.restore(to: pasteboard)
            completion(.failure(.copyUnavailable))
            return
        }
        pollPasteboard(
            pasteboard,
            baselineChangeCount: baselineChangeCount,
            attemptsRemaining: 12,
            snapshot: snapshot,
            completion: completion
        )
    }

    private func pollPasteboard(
        _ pasteboard: NSPasteboard,
        baselineChangeCount: Int,
        attemptsRemaining: Int,
        snapshot: PasteboardSnapshot,
        completion: @escaping (Result<String, SelectedTextCaptureError>) -> Void
    ) {
        if pasteboard.changeCount != baselineChangeCount {
            let selectedText = pasteboard.string(forType: .string)
            snapshot.restore(to: pasteboard)
            guard let selectedText, !selectedText.isBlank else {
                completion(.failure(.noSelection))
                return
            }
            completion(.success(selectedText))
            return
        }
        guard attemptsRemaining > 0 else {
            snapshot.restore(to: pasteboard)
            completion(.failure(.noSelection))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pollPasteboard(
                pasteboard,
                baselineChangeCount: baselineChangeCount,
                attemptsRemaining: attemptsRemaining - 1,
                snapshot: snapshot,
                completion: completion
            )
        }
    }

    private func postCopyShortcut() -> Bool {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

private struct PasteboardSnapshot {
    private let itemData: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        itemData = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = itemData.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            values.forEach { item.setData($0.value, forType: $0.key) }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
