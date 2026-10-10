import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation

protocol PasteService: AnyObject {
    func isAccessibilityTrusted() -> Bool
    func requestAccessibilityPermission()
    func openAccessibilitySettings()
    @discardableResult
    func copy(text: String) -> Bool
    func paste(text: String, into application: NSRunningApplication)
}

struct ClipboardSnapshot {
    private struct ItemSnapshot {
        private enum Representation {
            case data(type: NSPasteboard.PasteboardType, value: Data)
            case propertyList(type: NSPasteboard.PasteboardType, value: Any)
            case string(type: NSPasteboard.PasteboardType, value: String)
        }

        private let representations: [Representation]

        init(item: NSPasteboardItem) {
            representations = item.types.compactMap { type in
                if type == .string, let value = item.string(forType: type) {
                    return .string(type: type, value: value)
                }

                if let value = item.data(forType: type) {
                    return .data(type: type, value: value)
                }

                if let value = item.propertyList(forType: type) {
                    return .propertyList(type: type, value: value)
                }

                if let value = item.string(forType: type) {
                    return .string(type: type, value: value)
                }

                return nil
            }
        }

        func makePasteboardItem() -> NSPasteboardItem {
            let item = NSPasteboardItem()

            for representation in representations {
                switch representation {
                case let .data(type, value):
                    _ = item.setData(value, forType: type)
                case let .propertyList(type, value):
                    _ = item.setPropertyList(value, forType: type)
                case let .string(type, value):
                    _ = item.setString(value, forType: type)
                }
            }

            return item
        }
    }

    let changeCount: Int
    private let items: [ItemSnapshot]

    init(pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        items = (pasteboard.pasteboardItems ?? []).map(ItemSnapshot.init)
    }

    @discardableResult
    func restoreIfUnchanged(
        on pasteboard: NSPasteboard,
        expectedChangeCount: Int,
        expectedString: String? = nil
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else {
            return false
        }

        if let expectedString,
           pasteboard.string(forType: .string) != expectedString {
            return false
        }

        pasteboard.clearContents()
        let pasteboardItems = items.map { $0.makePasteboardItem() }
        guard !pasteboardItems.isEmpty else { return true }

        return pasteboard.writeObjects(pasteboardItems)
    }
}

final class SystemPasteService: PasteService {
    private let activationDelay: TimeInterval = 0.20
    private let pasteSettlingDelay: TimeInterval = 0.75
    private let pasteboard: NSPasteboard
    private let accessibilityTrustCheck: () -> Bool

    init(
        pasteboard: NSPasteboard = .general,
        accessibilityTrustCheck: (() -> Bool)? = nil
    ) {
        self.pasteboard = pasteboard
        self.accessibilityTrustCheck = accessibilityTrustCheck ?? {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
            ] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    }

    func isAccessibilityTrusted() -> Bool {
        accessibilityTrustCheck()
    }

    func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func copy(text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func paste(text: String, into application: NSRunningApplication) {
        guard isAccessibilityTrusted() else { return }

        let pasteboard = self.pasteboard
        let savedClipboard = ClipboardSnapshot(pasteboard: pasteboard)

        // If the clipboard changed while its contents were being captured, the
        // snapshot may already be stale. Do not replace it or restore stale data.
        guard pasteboard.changeCount == savedClipboard.changeCount else { return }

        let injectedChangeCount = pasteboard.clearContents()
        guard injectedChangeCount == savedClipboard.changeCount + 1,
              pasteboard.changeCount == injectedChangeCount else {
            return
        }

        guard pasteboard.setString(text, forType: .string) else {
            _ = savedClipboard.restoreIfUnchanged(
                on: pasteboard,
                expectedChangeCount: injectedChangeCount
            )
            return
        }

        application.activate(options: [.activateAllWindows])

        // Give the target application a moment to become active before sending Command+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            guard !application.isTerminated,
                  let eventSource = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(
                    keyboardEventSource: eventSource,
                    virtualKey: CGKeyCode(kVK_ANSI_V),
                    keyDown: true
                  ),
                  let keyUp = CGEvent(
                    keyboardEventSource: eventSource,
                    virtualKey: CGKeyCode(kVK_ANSI_V),
                    keyDown: false
                  ) else {
                self.restoreClipboard(
                    savedClipboard,
                    pasteboard: pasteboard,
                    expectedChangeCount: injectedChangeCount,
                    expectedString: text
                )
                return
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.postToPid(application.processIdentifier)
            keyUp.postToPid(application.processIdentifier)

            // CGEvent posting has no acknowledgement. Leave the injected text
            // available briefly so the target can consume it before restoring
            // the saved contents.
            DispatchQueue.main.asyncAfter(deadline: .now() + self.pasteSettlingDelay) {
                self.restoreClipboard(
                    savedClipboard,
                    pasteboard: pasteboard,
                    expectedChangeCount: injectedChangeCount,
                    expectedString: text
                )
            }
        }
    }

    private func restoreClipboard(
        _ savedClipboard: ClipboardSnapshot,
        pasteboard: NSPasteboard,
        expectedChangeCount: Int,
        expectedString: String
    ) {
        _ = savedClipboard.restoreIfUnchanged(
            on: pasteboard,
            expectedChangeCount: expectedChangeCount,
            expectedString: expectedString
        )
    }
}
