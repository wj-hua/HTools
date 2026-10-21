import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ClipboardTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ClipboardNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.compositionStateDidChange = { [weak coordinator = context.coordinator] isComposing in
            DispatchQueue.main.async {
                coordinator?.updateCompositionState(isComposing)
            }
        }
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClipboardNSTextView,
              !textView.isComposing,
              textView.string != text else {
            return
        }

        let selectedRange = textView.selectedRange()
        textView.string = text
        let safeLocation = min(selectedRange.location, (text as NSString).length)
        textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ClipboardTextEditor

        init(parent: ClipboardTextEditor) {
            self.parent = parent
        }

        func updateCompositionState(_ isComposing: Bool) {
            guard parent.isComposing != isComposing else { return }

            parent.isComposing = isComposing
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  parent.text != textView.string else {
                return
            }

            parent.text = textView.string
        }
    }
}

final class ClipboardNSTextView: NSTextView {
    var compositionStateDidChange: ((Bool) -> Void)?
    var onSubmit: (() -> Void)?
    private(set) var isComposing = false

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        isComposing = hasMarkedTextContent(string)
        compositionStateDidChange?(isComposing)
    }

    override func unmarkText() {
        super.unmarkText()
        isComposing = false
        compositionStateDidChange?(false)
    }

    private func hasMarkedTextContent(_ text: Any) -> Bool {
        if let text = text as? String {
            return !text.isEmpty
        }

        if let text = text as? NSAttributedString {
            return text.length > 0
        }

        if let text = text as? NSString {
            return text.length > 0
        }

        return true
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return
        }

        insertText(text, replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == UInt16(kVK_Return)
            || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        guard isReturnKey else {
            super.keyDown(with: event)
            return
        }

        // Let the input method commit its marked text before handling Return.
        guard !isComposing else {
            super.keyDown(with: event)
            return
        }

        let textInputModifiers = event.modifierFlags.intersection([
            .shift,
            .control,
            .option,
            .command
        ])
        if textInputModifiers.isEmpty {
            onSubmit?()
        } else if textInputModifiers.contains(.shift) || textInputModifiers.contains(.command) {
            insertText("\n", replacementRange: selectedRange())
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturnKey = event.keyCode == UInt16(kVK_Return)
            || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        let textInputModifiers = event.modifierFlags.intersection([
            .shift,
            .control,
            .option,
            .command
        ])
        if isReturnKey, !isComposing {
            if textInputModifiers.isEmpty {
                onSubmit?()
                return true
            }

            if textInputModifiers.contains(.shift) || textInputModifiers.contains(.command) {
                insertText("\n", replacementRange: selectedRange())
                return true
            }
        }

        guard event.modifierFlags.contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch characters {
        case "c":
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
