import SwiftUI

struct AccessibilityPermissionView: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.14))
                    .frame(width: 58, height: 58)
                    .overlay {
                        Circle()
                            .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                    }

                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 6) {
                Text("需要辅助功能权限")
                    .font(.system(size: 16, weight: .bold, design: .default))
                    .foregroundStyle(ClipboardTheme.ink)

                Text("为了把常用文本自动粘贴到当前应用，请在系统设置的“隐私与安全性 > 辅助功能”中允许当前版本的常用粘贴板控制电脑。")
                    .font(.system(size: 12.5, weight: .regular, design: .default))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ClipboardTheme.inkSecondary)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.dismissPermissionNotice()
                } label: {
                    Text("稍后")
                        .font(.system(size: 13, weight: .medium, design: .default))
                        .foregroundStyle(ClipboardTheme.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.60))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                                }
                        }
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.refreshAccessibilityPermission()
                } label: {
                    Text("我已授权，重新检查")
                        .font(.system(size: 13, weight: .medium, design: .default))
                        .foregroundStyle(ClipboardTheme.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.60))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                                }
                        }
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.openAccessibilitySettings()
                } label: {
                    Text("打开系统设置")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ClipboardTheme.accentGradient)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                                }
                                .shadow(color: ClipboardTheme.accent.opacity(0.30), radius: 4, y: 2)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(26)
        .background(.regularMaterial)
        .task {
            // 用户通常会先点“打开系统设置”，授权后再回到这里。
            // 轮询可以在授权生效后自动关闭弹窗，不需要额外点击“重新检查”。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                viewModel.refreshAccessibilityPermission()
            }
        }
    }
}
