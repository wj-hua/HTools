import AppKit
import SwiftUI

struct ClipboardRow: View {
    let item: PasteItem
    let index: Int
    let isSelected: Bool
    let preview: String
    let tagName: String?
    let showsDragHandle: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: showsDragHandle ? "line.3.horizontal" : "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : PanelStyle.tertiaryText)
                .frame(width: 12)

            // 行首快捷键：前 9 项显示 ⌥1 ~ ⌥9，提示可以一键直达。
            Text(index < 9 ? "⌥\(index + 1)" : String(format: "%02d", index + 1))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 22)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )

            Text(preview)
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tagName {
                Text(tagName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(.quinary, in: Capsule())
            }

            if isSelected {
                Text("↵ 粘贴")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: ClipboardPanelView.listRowHeight)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .animation(PanelStyle.animation(Motion.snappy, reduceMotion: reduceMotion), value: isSelected)
    }
}

struct ClipboardDropDelegate: DropDelegate {
    let itemID: UUID
    @Binding var draggedItemID: UUID?
    let items: [PasteItem]
    let moveItems: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedItemID,
              draggedItemID != itemID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedItemID }),
              let targetIndex = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        // 拖过目标行时放到目标行后面；从下往上拖时则放到目标行前面。
        let destination = targetIndex > fromIndex ? targetIndex + 1 : targetIndex
        moveItems(IndexSet(integer: fromIndex), destination)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}
