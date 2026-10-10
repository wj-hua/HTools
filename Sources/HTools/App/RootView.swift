import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case tokens
    case processes
    case snippets
    case devices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: return "Token 用量"
        case .processes: return "进程与内存"
        case .snippets: return "常用文本"
        case .devices: return "手机调试"
        }
    }

    var systemImage: String {
        switch self {
        case .tokens: return "chart.bar.xaxis"
        case .processes: return "memorychip"
        case .snippets: return "text.quote"
        case .devices: return "iphone.gen3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("selectedSection") private var selection: AppSection = .tokens

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selection,
                processMonitor: model.processMonitor,
                devices: model.devices
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 480)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .tokens:
            TokenUsageView(store: model.usageStore)
        case .processes:
            ProcessesView(monitor: model.processMonitor)
        case .snippets:
            SnippetsView(store: model.pasteStore)
        case .devices:
            DevicesView()
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: AppSection
    @ObservedObject var processMonitor: ProcessMonitor
    @ObservedObject var devices: DeviceController

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            Section("AI 编码") {
                row(.tokens)
                row(.processes, badge: processMonitor.totalProcessCount)
            }
            Section("效率") {
                row(.snippets)
            }
            Section("移动设备") {
                row(.devices, badge: devices.connectedCount)
            }
        }
    }

    /// `.tag` 必须是行视图最外层的修饰符：若在它外面再套 `.badge`，
    /// List 找不到选中值，点击该行不会切换页面。
    private func row(_ section: AppSection, badge: Int = 0) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(badge)
            .tag(section)
    }
}
