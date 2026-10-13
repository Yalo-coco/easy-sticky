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

/// Copy and ordinary paste share the same format precedence and RTFD persistence.
struct CapturedSelection {
    let document: NSAttributedString
    var text: String { document.string }
    var richContent: Data? {
        document.rtfd(from: NSRange(location: 0, length: document.length), documentAttributes: [:])
    }

    static func read(from pasteboard: NSPasteboard) -> CapturedSelection? {
        for (type, format) in [
            (NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd),
            (.rtf, .rtf), (.html, .html)
        ] {
            if let data = pasteboard.data(forType: type),
               let document = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil),
               document.length > 0 {
                return CapturedSelection(document: document)
            }
        }
        if let raw = pasteboard.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL,
           let data = try? Data(contentsOf: url),
           let document = RichNoteEditor.imageDocument(data: data, filename: url.lastPathComponent) {
            return CapturedSelection(document: document)
        }
        for (type, filename) in [(NSPasteboard.PasteboardType.png, "image.png"), (.tiff, "image.tiff")] {
            if let data = pasteboard.data(forType: type),
               let document = RichNoteEditor.imageDocument(data: data, filename: filename) {
                return CapturedSelection(document: document)
            }
        }
        guard let text = pasteboard.string(forType: .string), !text.isBlank else { return nil }
        return CapturedSelection(document: NSAttributedString(string: text, attributes: RichNoteEditor.defaultAttributes))
    }
}

final class SelectedTextCapture {
    private var isCapturing = false
    func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func capture(completion: @escaping (Result<CapturedSelection, SelectedTextCaptureError>) -> Void) {
        guard !isCapturing else { return }
        guard AXIsProcessTrusted() else {
            _ = requestAccessibilityPermission()
            completion(.failure(.accessibilityPermissionRequired))
            return
        }

        let fallback = selectedTextFromAccessibility()
        isCapturing = true
        captureByCopying { [weak self] result in
            self?.isCapturing = false
            if case .failure = result, let fallback, !fallback.isBlank {
                completion(.success(CapturedSelection(document: NSAttributedString(string: fallback, attributes: RichNoteEditor.defaultAttributes))))
            } else { completion(result) }
        }
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
        completion: @escaping (Result<CapturedSelection, SelectedTextCaptureError>) -> Void
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
        completion: @escaping (Result<CapturedSelection, SelectedTextCaptureError>) -> Void
    ) {
        if pasteboard.changeCount != baselineChangeCount {
            // Restore the user's clipboard before HTML import can run the main run loop.
            let copied = NSPasteboard.withUniqueName()
            PasteboardSnapshot(pasteboard: pasteboard).restore(to: copied)
            snapshot.restore(to: pasteboard)
            let selection = CapturedSelection.read(from: copied)
            copied.releaseGlobally()
            guard let selection else {
                completion(.failure(.noSelection))
                return
            }
            completion(.success(selection))
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
