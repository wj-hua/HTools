import SwiftUI

struct UsageHelpBubble: View {
    let doubleClickAction: ClipboardViewModel.DoubleClickAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ClipboardTheme.accent)
                Text("快捷键与使用技巧")
                    .font(.system(size: 12.5, weight: .bold, design: .default))
                    .foregroundStyle(ClipboardTheme.ink)
            }

            VStack(alignment: .leading, spacing: 6) {
                KeycapRow(keys: ["⌥", "空格"], desc: "快速显示 / 隐藏面板")
                KeycapRow(keys: ["直接输入"], desc: "快速搜索常用文本")
                KeycapRow(keys: ["⌘", "F"], desc: "聚焦搜索输入框")
                KeycapRow(keys: ["单击"], desc: "选择目标常用文本")
                KeycapRow(keys: ["⌘", "C"], desc: "仅复制所选文本")
                KeycapRow(
                    keys: ["双击"],
                    desc: doubleClickAction == .paste ? "粘贴所选文本" : "仅复制所选文本"
                )
                KeycapRow(keys: ["↩"], desc: "粘贴所选文本")
                KeycapRow(keys: ["⌥", "1-9"], desc: "一键直达粘贴对应项")
                KeycapRow(keys: ["拖拽"], desc: "自由调整文本或标签顺序")
                KeycapRow(keys: ["右键标签"], desc: "重命名或删除标签分类")
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.96))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white, Color.black.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: Color.black.opacity(0.14), radius: 18, y: 8)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.96))
                .offset(x: -48, y: 8)
        }
    }
}

struct KeycapRow: View {
    let keys: [String]
    let desc: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 2.5) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(ClipboardTheme.ink)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(Color.black.opacity(0.12), lineWidth: 0.8)
                                }
                                .shadow(color: Color.black.opacity(0.08), radius: 1, y: 1)
                        }
                }
            }
            .frame(width: 72, alignment: .leading)

            Text(desc)
                .font(.system(size: 11.5, weight: .medium, design: .default))
                .foregroundStyle(ClipboardTheme.inkSecondary)
        }
    }
}
