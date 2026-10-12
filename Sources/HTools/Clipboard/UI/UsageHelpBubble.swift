import SwiftUI

struct UsageHelpBubble: View {
    let doubleClickAction: ClipboardViewModel.DoubleClickAction

    /// 气泡浮在面板材质之上，用不透明的控件背景，避免两层半透明叠在一起看不清。
    private let surface = Color(nsColor: .controlBackgroundColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("快捷键与使用技巧", systemImage: "keyboard")
                .font(.system(size: 12.5, weight: .semibold))

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
        .background(surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        // 小三角指向右下角的“使用说明”按钮。
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 12))
                .foregroundStyle(surface)
                .offset(x: -8, y: 8)
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
                    Keycap(key)
                }
            }
            .frame(width: 72, alignment: .leading)

            Text(desc)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
