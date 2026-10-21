import SwiftUI

/// 快速粘贴面板共用的小部件。颜色全部来自系统语义色与强调色，
/// 跟随系统浅色 / 深色与“增强对比度”，不写死 RGB。
enum PanelStyle {
    /// 第三级文字色。`.tertiary` 是 ShapeStyle，三元表达式里需要和 `Color` 同类型时用它。
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)

    /// 带“减弱动态效果”回退的面板动画。
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}

extension View {
    /// 面板里的圆形图标按钮（关闭、返回、设置、说明）。搭配 `PressableButtonStyle`，按下即有反馈。
    func panelCircleIcon() -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(.quaternary, in: Circle())
            .contentShape(Circle())
    }
}

/// 键帽样式的快捷键提示，例如 ⌘F、⌥ 空格。
struct Keycap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}
