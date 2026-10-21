import AppKit
import Foundation

/// 标签栏中的一格：标签胶囊，或行尾的「新建标签」按钮。
enum TagBarEntry: Identifiable {
    case tag(PasteTag)
    case addButton

    var id: String {
        switch self {
        case .tag(let tag):
            return tag.id.uuidString
        case .addButton:
            return "add-tag-button"
        }
    }
}

/// 标签栏的排版尺寸。视图与 `ClipboardPanelView.panelHeight` 共用这里的换行结果，
/// 面板高度才能和实际行数保持一致。
enum TagBarMetrics {
    static let chipHeight: CGFloat = 30
    static let chipIconSize: CGFloat = 10
    static let chipTextSize: CGFloat = 12
    static let chipIconSpacing: CGFloat = 5
    static let chipLeadingPadding: CGFloat = 10
    static let chipTrailingPadding: CGFloat = 7
    static let chipDividerWidth: CGFloat = 1
    static let chipDeleteButtonWidth: CGFloat = 25

    static let addButtonSize: CGFloat = 30
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 6
    static let itemSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 9

    static func symbolName(for tag: PasteTag) -> String {
        tag.isDefault ? "tray.fill" : "tag.fill"
    }

    /// 一行可用的宽度。
    static var contentWidth: CGFloat {
        ClipboardPanelView.panelWidth - horizontalPadding * 2
    }

    /// 估算胶囊宽度。这里只能偏大不能偏小：算窄了标签就会被挤出面板宽度，
    /// 算宽了最多是行尾多留一点空白。
    static func chipWidth(for tag: PasteTag) -> CGFloat {
        let textWidth = (tag.name as NSString).size(withAttributes: [.font: chipFont]).width
        var width = chipLeadingPadding
            + symbolWidth(for: tag)
            + chipIconSpacing
            + textWidth
            + (tag.isDefault ? chipLeadingPadding : chipTrailingPadding)

        if !tag.isDefault {
            width += chipDividerWidth + chipDeleteButtonWidth
        }

        return ceil(width) + 2
    }

    /// 按可用宽度把标签铺成若干行，「新建标签」按钮永远跟在最后一个标签后面。
    static func rows(for tags: [PasteTag]) -> [[TagBarEntry]] {
        let available = contentWidth
        var rows: [[TagBarEntry]] = []
        var currentRow: [TagBarEntry] = []
        var currentWidth: CGFloat = 0

        func append(_ entry: TagBarEntry, width: CGFloat) {
            if currentRow.isEmpty {
                currentRow = [entry]
                currentWidth = width
                return
            }

            let widthWithEntry = currentWidth + itemSpacing + width
            if widthWithEntry > available {
                rows.append(currentRow)
                currentRow = [entry]
                currentWidth = width
            } else {
                currentRow.append(entry)
                currentWidth = widthWithEntry
            }
        }

        for tag in tags {
            // 单个标签比整行还宽时只能截断，但仍要占满一行，不能溢出面板。
            append(.tag(tag), width: min(chipWidth(for: tag), available))
        }
        append(.addButton, width: addButtonSize)

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }

    static func barHeight(for tags: [PasteTag]) -> CGFloat {
        let rowCount = max(rows(for: tags).count, 1)
        return CGFloat(rowCount) * rowHeight
            + CGFloat(rowCount - 1) * rowSpacing
            + verticalPadding * 2
    }

    private static let chipFont: NSFont = {
        let base = NSFont.systemFont(ofSize: chipTextSize, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: chipTextSize) else {
            return base
        }
        return rounded
    }()

    private static let defaultSymbolWidth = measuredSymbolWidth(named: "tray.fill")
    private static let tagSymbolWidth = measuredSymbolWidth(named: "tag.fill")

    private static func symbolWidth(for tag: PasteTag) -> CGFloat {
        tag.isDefault ? defaultSymbolWidth : tagSymbolWidth
    }

    private static func measuredSymbolWidth(named name: String) -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(pointSize: chipIconSize, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return chipIconSize + 4
        }
        return ceil(image.size.width)
    }
}
