import SwiftUI

/// GUI 和由客户端启动的 MCP 进程使用同一个固定的偏好设置域。
enum MCPSettings {
    private static let defaults = UserDefaults(suiteName: "com.mino.HTools.MCP")!
    private static let prefix = "disabled."

    static func isEnabled(_ name: String) -> Bool {
        defaults.synchronize()
        return !defaults.bool(forKey: prefix + name)
    }

    static func setEnabled(_ enabled: Bool, for name: String) {
        defaults.set(!enabled, forKey: prefix + name)
        defaults.synchronize()
    }
}

/// 工具元数据，包含分类、图标、视觉色系与参数提示。
private struct ToolMeta {
    let name: String
    let displayName: String
    let category: String
    let icon: String
    let tint: Color
    let returnType: String
    let paramSummary: String?

    static func meta(for name: String) -> ToolMeta {
        switch name {
        case "get_token_usage":
            return ToolMeta(
                name: name,
                displayName: "Token 用量查询",
                category: "AI 与统计",
                icon: "chart.bar.xaxis",
                tint: .blue,
                returnType: "JSON 统计",
                paramSummary: "period: today | week | month | total (默认 today)"
            )
        case "list_ai_processes":
            return ToolMeta(
                name: name,
                displayName: "AI 进程监控",
                category: "AI 与统计",
                icon: "memorychip",
                tint: .purple,
                returnType: "JSON 列表",
                paramSummary: "无参数 (返回当前用户各 AI 进程及内存)"
            )
        case "list_tasks":
            return ToolMeta(
                name: name,
                displayName: "任务清单查询",
                category: "任务协同",
                icon: "checklist",
                tint: .green,
                returnType: "JSON 数组",
                paramSummary: "status: all | pending | completed (默认 all)"
            )
        case "list_devices":
            return ToolMeta(
                name: name,
                displayName: "调试设备列表",
                category: "手机调试",
                icon: "iphone.gen3",
                tint: .teal,
                returnType: "JSON 列表",
                paramSummary: "无参数 (列出 ADB 和 HDC 在线设备)"
            )
        case "get_device_info":
            return ToolMeta(
                name: name,
                displayName: "设备硬件信息",
                category: "手机调试",
                icon: "info.circle",
                tint: .cyan,
                returnType: "JSON 详情",
                paramSummary: "deviceId: 设备 ID (多设备时必填)"
            )
        case "get_foreground_app":
            return ToolMeta(
                name: name,
                displayName: "当前前台应用",
                category: "手机调试",
                icon: "app.badge",
                tint: .indigo,
                returnType: "JSON 包名",
                paramSummary: "deviceId: 设备 ID (多设备时必填)"
            )
        case "capture_device_screen":
            return ToolMeta(
                name: name,
                displayName: "手机屏幕截图",
                category: "手机调试",
                icon: "camera.viewfinder",
                tint: .pink,
                returnType: "图片 (PNG/JPEG)",
                paramSummary: "deviceId: 设备 ID (多设备时必填)"
            )
        case "upload_to_pgyer":
            return ToolMeta(
                name: name,
                displayName: "蒲公英安装包上传",
                category: "应用分发",
                icon: "arrow.up.circle",
                tint: .orange,
                returnType: "JSON 构建信息",
                paramSummary: "filePath (必填), updateDescription, installType, password, apiKey"
            )
        case "list_stetho_targets":
            return ToolMeta(
                name: name,
                displayName: "Stetho 应用列表",
                category: "网络抓包",
                icon: "network",
                tint: .blue,
                returnType: "JSON 列表",
                paramSummary: "deviceId: 设备 ID (多设备时必填)"
            )
        case "capture_stetho_requests":
            return ToolMeta(
                name: name,
                displayName: "即时抓包",
                category: "网络抓包",
                icon: "record.circle",
                tint: .teal,
                returnType: "JSON 请求与正文",
                paramSummary: "processName, duration (默认 10s), includeBody, urlFilter"
            )
        case "start_stetho_capture":
            return ToolMeta(
                name: name,
                displayName: "启动后台抓包",
                category: "网络抓包",
                icon: "play.circle",
                tint: .green,
                returnType: "JSON 会话状态",
                paramSummary: "processName, autoStopSeconds (默认 120s), deviceId"
            )
        case "get_stetho_requests":
            return ToolMeta(
                name: name,
                displayName: "查询抓包请求",
                category: "网络抓包",
                icon: "magnifyingglass.circle",
                tint: .indigo,
                returnType: "JSON 摘要或详情",
                paramSummary: "requestId, urlFilter, statusFilter, includeBody, limit, clear"
            )
        case "stop_stetho_capture":
            return ToolMeta(
                name: name,
                displayName: "停止后台抓包",
                category: "网络抓包",
                icon: "stop.circle",
                tint: .red,
                returnType: "JSON 统计",
                paramSummary: "无参数 (停止会话并释放资源)"
            )
        default:
            return ToolMeta(
                name: name,
                displayName: name,
                category: "常规工具",
                icon: "wrench.and.screwdriver",
                tint: .secondary,
                returnType: "JSON",
                paramSummary: nil
            )
        }
    }
}

private enum ConfigFormat: String, CaseIterable, Identifiable {
    case fields = "参数字段"
    case json = "JSON 配置"

    var id: String { rawValue }
}

struct MCPManagementView: View {
    @State private var enabled: [String: Bool] = [:]
    @State private var toastMessage: String?
    @State private var configFormat: ConfigFormat = .fields
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    private var enabledCount: Int {
        HToolsMCP.definitions.filter { def in
            guard let name = def["name"] as? String else { return false }
            return enabled[name] ?? MCPSettings.isEnabled(name)
        }.count
    }

    private var jsonConfig: String {
        let escapedPath = executablePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "htools": {
              "command": "\(escapedPath)",
              "args": [
                "--mcp"
              ]
            }
          }
        }
        """
    }

    private var groupedDefinitions: [(category: String, tools: [[String: Any]])] {
        var groups: [String: [[String: Any]]] = [:]
        var order: [String] = []

        for def in HToolsMCP.definitions {
            guard let name = def["name"] as? String else { continue }
            let cat = ToolMeta.meta(for: name).category
            if groups[cat] == nil {
                groups[cat] = []
                order.append(cat)
            }
            groups[cat]?.append(def)
        }

        return order.compactMap { cat in
            guard let list = groups[cat] else { return nil }
            return (category: cat, tools: list)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metricsOverview

                connectionCard

                toolsCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("MCP 管理")
        .navigationSubtitle("已开放 \(enabledCount) / \(HToolsMCP.definitions.count) 项工具 · stdio 本机服务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        if Pasteboard.copy(jsonConfig) { toastMessage = "已复制 JSON 配置" }
                    } label: {
                        Label("复制完整 JSON 配置", systemImage: "doc.on.doc")
                    }
                    Button {
                        let cmd = "\"\(executablePath)\" --mcp"
                        if Pasteboard.copy(cmd) { toastMessage = "已复制完整命令行" }
                    } label: {
                        Label("复制完整命令行", systemImage: "terminal")
                    }
                    Divider()
                    Button {
                        if Pasteboard.copy(executablePath) { toastMessage = "已复制可执行文件路径" }
                    } label: {
                        Label("复制可执行文件路径", systemImage: "folder")
                    }
                } label: {
                    Label("复制配置", systemImage: "square.and.arrow.up")
                }
                .help("复制 MCP 客户端配置")
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .toast($toastMessage)
    }

    // MARK: - 概览指标

    private var metricsOverview: some View {
        Card {
            HStack(spacing: 0) {
                MetricCell(label: "通讯协议", value: "JSON-RPC 2.0", tint: .blue)
                Divider().frame(height: 30).padding(.horizontal, 14)
                MetricCell(label: "传输通道", value: "stdio 进程", tint: .indigo)
                Divider().frame(height: 30).padding(.horizontal, 14)
                MetricCell(label: "安全权限", value: "严格只读", tint: .green)
                Divider().frame(height: 30).padding(.horizontal, 14)
                MetricCell(
                    label: "开放工具",
                    value: "\(enabledCount) / \(HToolsMCP.definitions.count)",
                    tint: enabledCount > 0 ? .green : .secondary
                )
            }
        }
    }

    // MARK: - 连接配置卡片

    private var connectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("接入客户端", systemImage: "link") {
                    Picker("格式", selection: $configFormat) {
                        ForEach(ConfigFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                Text("在 HCode、Claude Desktop 或 Cursor 等 MCP 客户端中配置服务。客户端在需要时自动启动进程，无需保持 HTools 窗口运行。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if configFormat == .fields {
                    VStack(alignment: .leading, spacing: 10) {
                        connectionRow(title: "服务名称", value: "htools")
                        connectionRow(title: "执行命令", value: executablePath)
                        connectionRow(title: "启动参数", value: "--mcp")
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("可直接粘贴到 claude_desktop_config.json 或客户端 MCP 配置中：")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                if Pasteboard.copy(jsonConfig) {
                                    toastMessage = "已复制 JSON 配置"
                                }
                            } label: {
                                Label("复制 JSON", systemImage: "doc.on.doc")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(PressableButtonStyle())
                        }

                        Text(jsonConfig)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                            )
                    }
                    .padding(.vertical, 2)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.top, 1)
                    Text("首次配置后需新建或重启 AI 会话。若重新构建或清理目录导致路径变动，请更新路径并重启会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func connectionRow(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            Text(value)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                )

            Spacer(minLength: 8)

            Button {
                if Pasteboard.copy(value) {
                    toastMessage = "已复制\(title)"
                }
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressableButtonStyle())
            .help("复制\(title)")
        }
    }

    // MARK: - 工具管理卡片

    private var toolsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("开放的工具", systemImage: "wrench.and.screwdriver") {
                    HStack(spacing: 8) {
                        Button("全部开启") {
                            setAllTools(enabled: true)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(enabledCount == HToolsMCP.definitions.count ? Color.secondary : Color.accentColor)
                        .disabled(enabledCount == HToolsMCP.definitions.count)

                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Button("全部关闭") {
                            setAllTools(enabled: false)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(enabledCount == 0 ? Color.secondary : Color.red)
                        .disabled(enabledCount == 0)
                    }
                }

                Text("关闭后对应工具将被隐藏并拒绝调用；重新连接客户端可刷新工具列表。所有开放工具均为只读设计。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(groupedDefinitions.enumerated()), id: \.offset) { catIndex, group in
                        if catIndex > 0 {
                            Divider()
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.category)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, catIndex > 0 ? 2 : 0)

                            VStack(spacing: 8) {
                                ForEach(Array(group.tools.enumerated()), id: \.offset) { _, def in
                                    toolRow(def)
                                }
                            }
                        }
                    }
                }

                Divider()
                    .padding(.top, 2)

                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("安全保障：MCP 服务运行于本机且仅暴露只读查询接口，不修改系统设置或文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ definition: [String: Any]) -> some View {
        if let name = definition["name"] as? String,
           let description = definition["description"] as? String {
            let meta = ToolMeta.meta(for: name)
            let isToolOn = enabled[name] ?? MCPSettings.isEnabled(name)
            let anim = reduceMotion ? .easeInOut(duration: 0.15) : Motion.snappy

            HStack(alignment: .top, spacing: 12) {
                IconTile(
                    systemImage: meta.icon,
                    tint: meta.tint,
                    size: 32,
                    isActive: isToolOn
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(meta.displayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(isToolOn ? .primary : .secondary)

                        Text(name)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.secondary.opacity(0.1))
                            )

                        Text(meta.returnType)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isToolOn ? meta.tint : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill((isToolOn ? meta.tint : Color.secondary).opacity(0.12))
                            )
                    }

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let params = meta.paramSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 9))
                            Text(params)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 12)

                Toggle("", isOn: Binding(
                    get: { enabled[name] ?? MCPSettings.isEnabled(name) },
                    set: { value in
                        withAnimation(anim) {
                            enabled[name] = value
                            MCPSettings.setEnabled(value, for: name)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 操作

    private func setAllTools(enabled isEnabled: Bool) {
        let anim = reduceMotion ? .easeInOut(duration: 0.15) : Motion.snappy
        withAnimation(anim) {
            for definition in HToolsMCP.definitions {
                if let name = definition["name"] as? String {
                    enabled[name] = isEnabled
                    MCPSettings.setEnabled(isEnabled, for: name)
                }
            }
        }
        toastMessage = isEnabled ? "已全部开启" : "已全部关闭"
    }

    private func refresh() {
        for definition in HToolsMCP.definitions {
            if let name = definition["name"] as? String {
                enabled[name] = MCPSettings.isEnabled(name)
            }
        }
    }
}
