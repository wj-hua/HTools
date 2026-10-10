import AppKit
import SwiftUI

/// 全局共享的视觉与动效规范。
///
/// - 动效默认使用临界阻尼弹簧（无回弹），只有真正带动量的交互才允许轻微回弹；
/// - 颜色全部来自系统语义色，自动适配浅色/深色与“增强对比度”；
/// - 卡片使用系统控件背景 + 0.5pt 分隔线描边，层级靠明暗而不是厚重阴影。
enum Motion {
    /// 默认 UI 弹簧：damping 1.0，response ≈ 0.35s。
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// 选中态、分段切换等需要更跟手的场景。
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 1.0)
    /// 按压反馈：按下即响应。
    static let press = Animation.spring(response: 0.18, dampingFraction: 1.0)
}

extension View {
    /// 在开启“减弱动态效果”时退化为短促的淡入淡出。
    func adaptiveAnimation<V: Equatable>(_ animation: Animation, value: V, reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? .easeInOut(duration: 0.15) : animation, value: value)
    }
}

/// 标准卡片容器。
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// 卡片内的小标题：字重区分层级，而不是一味放大字号。
struct CardHeader<Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, systemImage: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            accessory
        }
    }
}

/// 带图标底板的应用/工具标识。
struct IconTile: View {
    let image: Image
    let tint: Color
    var size: CGFloat = 30
    var isActive = true
    /// SF Symbol 按字号绘制；位图/矢量 Logo 需要按尺寸缩放。
    private var isSymbol = false

    init(image: Image, tint: Color, size: CGFloat = 30, isActive: Bool = true) {
        self.image = image
        self.tint = tint
        self.size = size
        self.isActive = isActive
    }

    init(systemImage: String, tint: Color, size: CGFloat = 30, isActive: Bool = true) {
        self.init(image: Image(systemName: systemImage), tint: tint, size: size, isActive: isActive)
        isSymbol = true
    }

    var body: some View {
        Group {
            if isSymbol {
                image.font(.system(size: size * 0.45, weight: .semibold))
            } else {
                image
                    .scaledToFit()
                    .frame(width: size * 0.5, height: size * 0.5)
            }
        }
        .foregroundStyle(isActive ? tint : .secondary)
        .frame(width: size, height: size)
        .background {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill((isActive ? tint : Color.secondary).opacity(0.14))
        }
    }
}

/// 大号数字：圆体 + 等宽数字 + 收紧字距，变化时逐位滚动。
struct BigNumber: View {
    let text: String
    var unit: String?
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .tracking(-0.02 * size)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: max(11, size * 0.36), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 一组小指标中的一格。
struct MetricCell: View {
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 多段比例条：各段宽度按数值占比分配。
struct ProportionBar: View {
    struct Segment: Identifiable {
        let id: String
        let color: Color
        let value: Double
    }

    let segments: [Segment]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let active = segments.filter { $0.value > 0 }
            let total = active.reduce(0) { $0 + $1.value }
            let spacing: CGFloat = 2
            let available = max(0, proxy.size.width - spacing * CGFloat(max(0, active.count - 1)))

            HStack(spacing: spacing) {
                ForEach(active) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: total > 0 ? max(3, available * segment.value / total) : 0)
                }
            }
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }
}

/// 按下即缩放的按钮样式：反馈发生在 mouse-down，而不是松开之后。
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// 页面底部短暂出现的状态提示（复制成功等），自动消失。
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.bottom, 18)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    .id(message)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: message)
        .onChange(of: message) { _, newValue in
            dismissTask?.cancel()
            guard newValue != nil else { return }
            dismissTask = Task {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                message = nil
            }
        }
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

enum Pasteboard {
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
