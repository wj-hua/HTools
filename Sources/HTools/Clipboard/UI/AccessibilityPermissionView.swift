import SwiftUI

struct AccessibilityPermissionView: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(spacing: 16) {
            IconTile(systemImage: "hand.raised.fill", tint: .orange, size: 56)

            VStack(spacing: 6) {
                Text("需要辅助功能权限")
                    .font(.system(size: 16, weight: .bold))

                Text("为了把常用文本自动粘贴到当前应用，请在系统设置的“隐私与安全性 > 辅助功能”中允许当前版本的常用粘贴板控制电脑。")
                    .font(.system(size: 12.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("稍后") {
                    viewModel.dismissPermissionNotice()
                }

                Button("我已授权，重新检查") {
                    viewModel.refreshAccessibilityPermission()
                }

                Button("打开系统设置") {
                    viewModel.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
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
