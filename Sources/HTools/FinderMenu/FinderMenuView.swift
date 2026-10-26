import AppKit
import FinderMenuKit
import SwiftUI

/// 右键菜单页：配置访达右键菜单里的“新建文件”“拷贝路径”和“在 X 打开”。
/// 配置即时写入扩展偏好域，下一次右键即生效，无需重启 Finder。
struct FinderMenuView: View {
    @State private var config = FinderMenuConfigStore.load()
    @State private var newName = ""
    @State private var newExt = ""
    private let installedApps = OpenWithApp.installed

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader("右键菜单", systemImage: "cursorarrow.click.2")
                        Toggle("新建文件", isOn: $config.showNewFile)
                        Toggle("拷贝路径", isOn: $config.showCopyPath)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader("在应用中打开", systemImage: "arrow.up.forward.app")
                        if installedApps.isEmpty {
                            Text("未检测到支持的应用")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(installedApps, id: \.bundleID) { app in
                            Toggle(isOn: binding(for: app)) {
                                Label {
                                    Text("在 \(app.name) 打开")
                                } icon: {
                                    Image(nsImage: nsImage(for: app))
                                }
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader("新建文件模板", systemImage: "doc.badge.plus")
                        ForEach(config.templates) { template in
                            HStack {
                                Text(template.fileName)
                                    .monospacedDigit()
                                Spacer()
                                Button {
                                    config.templates.removeAll { $0.id == template.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("删除模板")
                            }
                        }
                        HStack {
                            TextField("名称", text: $newName)
                            TextField("扩展名（如 txt）", text: $newExt)
                            Button("添加") {
                                config.templates.append(.init(name: newName.trimmingCharacters(in: .whitespaces),
                                                              ext: newExt.trimmingCharacters(in: .whitespaces)))
                                newName = ""
                                newExt = ""
                            }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader("启用扩展")
                        Text("首次使用需在“系统设置 → 通用 → 登录项与扩展 → 访达扩展”中勾选 HTools 右键菜单。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("打开扩展设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: config) {
            FinderMenuConfigStore.save(config)
        }
    }

    private func binding(for app: OpenWithApp) -> Binding<Bool> {
        Binding(
            get: { config.openApps.contains(app.bundleID) },
            set: { isOn in
                if isOn {
                    config.openApps.insert(app.bundleID)
                } else {
                    config.openApps.remove(app.bundleID)
                }
            }
        )
    }

    private func nsImage(for app: OpenWithApp) -> NSImage {
        let image = OpenWithApp.url(of: app).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
