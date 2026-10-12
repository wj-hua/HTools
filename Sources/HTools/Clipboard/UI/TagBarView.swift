import AppKit
import SwiftUI

struct TagBarView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @Binding var draggedTagID: UUID?
    @Binding var draggedItemID: UUID?
    let onAddTag: () -> Void
    let onRenameTag: (PasteTag) -> Void
    let onDeleteTag: (PasteTag) -> Void
    @State private var targetedTagID: UUID?

    var body: some View {
        // 单行横向滚动会把标签裁掉，而列表模式下横向滚动已被面板用于切换标签，
        // 那条 ScrollView 实际滚不动，所以这里改为按行铺开、全部展示。
        VStack(alignment: .leading, spacing: TagBarMetrics.rowSpacing) {
            ForEach(Array(TagBarMetrics.rows(for: viewModel.tags).enumerated()), id: \.offset) { _, row in
                HStack(spacing: TagBarMetrics.itemSpacing) {
                    ForEach(row) { entry in
                        switch entry {
                        case .tag(let tag):
                            TagChipView(
                                tag: tag,
                                isSelected: viewModel.selectedTagID == tag.id,
                                isDropTarget: targetedTagID == tag.id,
                                onSelect: {
                                    viewModel.selectTag(withID: tag.id)
                                },
                                onRename: {
                                    onRenameTag(tag)
                                },
                                onDelete: {
                                    onDeleteTag(tag)
                                },
                                draggedTagID: $draggedTagID
                            )
                            .onDrop(
                                of: [.text],
                                delegate: TagDropDelegate(
                                    tagID: tag.id,
                                    draggedTagID: $draggedTagID,
                                    draggedItemID: $draggedItemID,
                                    targetedTagID: $targetedTagID,
                                    tags: viewModel.tags,
                                    moveTags: viewModel.moveTags,
                                    moveItemToTag: { itemID, tagID in
                                        viewModel.moveItem(withID: itemID, toTagID: tagID)
                                    }
                                )
                            )
                        case .addButton:
                            addTagButton
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(height: TagBarMetrics.rowHeight)
            }
        }
        .frame(height: TagBarMetrics.barHeight(for: viewModel.tags))
        .padding(.horizontal, TagBarMetrics.horizontalPadding)
        // 整条标签栏都让给标签自己的长按拖动排序，窗口拖动不在这里接管。
        .excludedFromWindowDrag()
    }

    private var addTagButton: some View {
        Button {
            onAddTag()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: TagBarMetrics.addButtonSize, height: TagBarMetrics.addButtonSize)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .help("添加标签")
    }
}

struct TagChipView: View {
    let tag: PasteTag
    let isSelected: Bool
    var isDropTarget: Bool = false
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @Binding var draggedTagID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHighlighted: Bool { isSelected || isDropTarget }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onSelect()
            } label: {
                HStack(spacing: TagBarMetrics.chipIconSpacing) {
                    Image(systemName: isDropTarget ? "arrow.down.circle.fill" : TagBarMetrics.symbolName(for: tag))
                        .font(.system(size: TagBarMetrics.chipIconSize, weight: .semibold))

                    Text(tag.name)
                        .font(.system(size: TagBarMetrics.chipTextSize, weight: .semibold, design: .default))
                        .lineLimit(1)
                }
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
                .padding(.leading, TagBarMetrics.chipLeadingPadding)
                .padding(.trailing, tag.isDefault ? TagBarMetrics.chipLeadingPadding : TagBarMetrics.chipTrailingPadding)
                .frame(height: TagBarMetrics.chipHeight)
                // 让整块胶囊区域可点，而不是只有图标和文字的实际像素。
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag {
                draggedTagID = tag.id
                return NSItemProvider(object: tag.id.uuidString as NSString)
            }

            if !tag.isDefault {
                Rectangle()
                    .fill(isHighlighted ? Color.accentColor.opacity(0.3) : Color(nsColor: .separatorColor))
                    .frame(width: TagBarMetrics.chipDividerWidth, height: 14)

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: TagBarMetrics.chipDeleteButtonWidth, height: TagBarMetrics.chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isHighlighted ? Color.accentColor : PanelStyle.tertiaryText)
                .help("删除标签")
            }
        }
        .background(
            isDropTarget
                ? AnyShapeStyle(Color.accentColor.opacity(0.26))
                : (isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.quaternary)),
            in: Capsule()
        )
        .overlay {
            if isDropTarget {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        // 拖入文本时轻微放大，提示可以松手；减弱动态效果时只保留颜色变化。
        .scaleEffect(isDropTarget && !reduceMotion ? 1.05 : 1.0)
        .animation(PanelStyle.animation(Motion.snappy, reduceMotion: reduceMotion), value: isDropTarget)
        .contentShape(Capsule())
        .contextMenu {
            Button("重命名标签") {
                onRename()
            }

            if tag.isDefault {
                Button("默认标签不可删除") {}
                    .disabled(true)
            } else {
                Button("删除标签", role: .destructive) {
                    onDelete()
                }
            }
        }
    }
}

struct TagDropDelegate: DropDelegate {
    let tagID: UUID
    @Binding var draggedTagID: UUID?
    @Binding var draggedItemID: UUID?
    @Binding var targetedTagID: UUID?
    let tags: [PasteTag]
    let moveTags: (IndexSet, Int) -> Void
    let moveItemToTag: (UUID, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedItemID != nil || draggedTagID != nil || info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        if draggedItemID != nil {
            targetedTagID = tagID
            return
        }

        guard let draggedTagID,
              draggedTagID != tagID,
              let fromIndex = tags.firstIndex(where: { $0.id == draggedTagID }),
              let targetIndex = tags.firstIndex(where: { $0.id == tagID }) else {
            return
        }

        let destination = targetIndex > fromIndex ? targetIndex + 1 : targetIndex
        moveTags(IndexSet(integer: fromIndex), destination)
    }

    func dropExited(info: DropInfo) {
        if targetedTagID == tagID {
            targetedTagID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let itemID = draggedItemID {
            moveItemToTag(itemID, tagID)
            draggedItemID = nil
            targetedTagID = nil
            return true
        }

        targetedTagID = nil
        if draggedTagID != nil {
            draggedTagID = nil
            return true
        }

        let providers = info.itemProviders(for: [.text])
        if let provider = providers.first {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let str = string as? String, let uuid = UUID(uuidString: str) {
                    DispatchQueue.main.async {
                        self.moveItemToTag(uuid, self.tagID)
                    }
                }
            }
            return true
        }

        return false
    }
}
