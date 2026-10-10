import AppKit
import SwiftUI

struct ClipboardRow: View {
    let item: PasteItem
    let index: Int
    let isSelected: Bool
    let preview: String
    let tagName: String?
    let showsDragHandle: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: showsDragHandle ? "line.3.horizontal" : "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    isSelected ? ClipboardTheme.accent : ClipboardTheme.inkTertiary.opacity(0.65)
                )
                .frame(width: 12)

            // 行首快捷键勋章：前 9 项显示 ⌥1 ~ ⌥9，直观引导快捷键直达
            HStack(spacing: 1) {
                if index < 9 {
                    Text("⌥")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? ClipboardTheme.accentDeep : ClipboardTheme.inkTertiary)
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? ClipboardTheme.accentDeep : ClipboardTheme.inkSecondary)
                } else {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? ClipboardTheme.accentDeep : ClipboardTheme.inkTertiary)
                }
            }
            .frame(width: 28, height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isSelected
                            ? ClipboardTheme.accent.opacity(0.16)
                            : Color.black.opacity(0.04)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(
                                isSelected
                                    ? ClipboardTheme.accent.opacity(0.25)
                                    : Color.black.opacity(0.03),
                                lineWidth: 0.5
                            )
                    }
            }

            Text(preview)
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium, design: .default))
                .foregroundStyle(isSelected ? ClipboardTheme.ink : ClipboardTheme.ink.opacity(0.88))
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tagName {
                Text(tagName)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(isSelected ? ClipboardTheme.accentDeep : ClipboardTheme.inkSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background {
                        Capsule()
                            .fill(
                                isSelected
                                    ? ClipboardTheme.accent.opacity(0.14)
                                    : Color.black.opacity(0.04)
                            )
                    }
            }

            if isSelected {
                HStack(spacing: 3) {
                    Text("↵")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Text("粘贴")
                        .font(.system(size: 10, weight: .medium, design: .default))
                }
                .foregroundStyle(ClipboardTheme.accentDeep.opacity(0.85))
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background {
                    Capsule()
                        .fill(ClipboardTheme.accent.opacity(0.10))
                        .overlay {
                            Capsule().stroke(ClipboardTheme.accent.opacity(0.20), lineWidth: 0.5)
                        }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: ClipboardPanelView.listRowHeight)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color.white.opacity(0.82)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.38))
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white,
                                ClipboardTheme.accent.opacity(0.40),
                                Color.white.opacity(0.60)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            } else {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.6), Color.black.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(ClipboardTheme.accentGradient)
                    .frame(width: 3.5, height: 18)
                    .padding(.leading, 3.5)
            }
        }
        .shadow(
            color: isSelected ? Color.black.opacity(0.06) : .clear,
            radius: isSelected ? 6 : 0,
            y: isSelected ? 2 : 0
        )
        .shadow(
            color: isSelected ? ClipboardTheme.accent.opacity(0.10) : .clear,
            radius: isSelected ? 3 : 0,
            y: isSelected ? 1 : 0
        )
        .animation(.snappy(duration: 0.22), value: isSelected)
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
