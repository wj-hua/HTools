import SwiftUI

enum CaptureAction {
    case copy, save, pin, translate, cancel
}

/// 选区下方的工具栏：标注工具 | 撤销重做 | 退出、翻译、贴图、保存、复制。
/// ↩ / 双击执行的主操作（复制，或截图翻译时的翻译）用强调色标出。
/// 选中工具后在下面展开第二行，调粗细和颜色。
struct CaptureToolbar: View {
    @ObservedObject var editor: CaptureEditor
    let primaryAction: CaptureAction
    let onAction: (CaptureAction) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(CaptureTool.allCases) { tool in
                    ToolbarIconButton(
                        systemImage: tool.systemImage,
                        help: "\(tool.title)  \(tool.shortcut.uppercased())",
                        isSelected: editor.tool == tool
                    ) {
                        editor.tool = editor.tool == tool ? nil : tool
                    }
                }

                separator

                ToolbarIconButton(systemImage: "arrow.uturn.backward", help: "撤销  ⌘Z") { editor.undo() }
                    .disabled(!editor.canUndo)
                ToolbarIconButton(systemImage: "arrow.uturn.forward", help: "重做  ⇧⌘Z") { editor.redo() }
                    .disabled(!editor.canRedo)

                separator

                ToolbarIconButton(systemImage: "xmark", help: "退出  Esc") { onAction(.cancel) }
                ToolbarIconButton(
                    systemImage: "translate",
                    help: primaryAction == .translate ? "识别并翻译  ↩ 或双击选区" : "识别并翻译  ⌘E",
                    tint: primaryAction == .translate ? .accentColor : .primary
                ) { onAction(.translate) }
                ToolbarIconButton(systemImage: "pin", help: "贴到屏幕  ⌘T") { onAction(.pin) }
                ToolbarIconButton(systemImage: "square.and.arrow.down", help: "保存  ⌘S") { onAction(.save) }
                ToolbarIconButton(
                    systemImage: "checkmark",
                    help: primaryAction == .copy ? "复制  ↩ 或双击选区" : "复制  ⌘C",
                    tint: primaryAction == .copy ? .accentColor : .primary
                ) { onAction(.copy) }
            }
            .padding(4)
            .toolbarSurface()

            if let tool = editor.tool {
                propertyBar(for: tool)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .toolbarSurface()
            }
        }
        .fixedSize()
    }

    private var separator: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 4)
    }

    private func propertyBar(for tool: CaptureTool) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Button {
                    editor.sizeIndex = index
                } label: {
                    Circle()
                        .fill(Color.primary.opacity(editor.sizeIndex == index ? 0.85 : 0.35))
                        .frame(width: CGFloat(4 + index * 4), height: CGFloat(4 + index * 4))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.88))
                .help(tool == .mosaic ? ["小色块", "中色块", "大色块"][index] : ["细", "中", "粗"][index])
            }

            if tool.usesColor {
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 4)

                ForEach(CaptureEditor.palette.indices, id: \.self) { index in
                    Button {
                        editor.colorIndex = index
                    } label: {
                        Circle()
                            .fill(Color(nsColor: CaptureEditor.palette[index]))
                            .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                            .frame(width: 16, height: 16)
                            .padding(3)
                            .overlay {
                                if editor.colorIndex == index {
                                    Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.88))
                }
            }
        }
    }
}

private struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    var isSelected = false
    var tint: Color = .primary
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : tint)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(isHovered && isEnabled ? 0.1 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .help(help)
        .onHover { isHovered = $0 }
        .animation(Motion.snappy, value: isSelected)
    }
}

private extension View {
    func toolbarSurface() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}
