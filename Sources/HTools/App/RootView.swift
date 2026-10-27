import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case tokens
    case processes
    case snippets
    case cloudClipboard
    case snip
    case translate
    case tasks
    case finderMenu
    case devices
    case cooler
    case distribution
    case sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: return "Token 用量"
        case .processes: return "进程与内存"
        case .snippets: return "常用文本"
        case .cloudClipboard: return "跨设备粘贴板"
        case .snip: return "截图"
        case .translate: return "翻译"
        case .tasks: return "任务清单"
        case .finderMenu: return "右键菜单"
        case .devices: return "手机调试"
        case .cooler: return "散热背夹"
        case .distribution: return "蒲公英分发"
        case .sleep: return "防止休眠"
        }
    }

    var systemImage: String {
        switch self {
        case .tokens: return "chart.bar.xaxis"
        case .processes: return "memorychip"
        case .snippets: return "text.quote"
        case .cloudClipboard: return "doc.on.clipboard"
        case .snip: return "camera.viewfinder"
        case .translate: return "translate"
        case .tasks: return "checklist"
        case .finderMenu: return "cursorarrow.click.2"
        case .devices: return "iphone.gen3"
        case .cooler: return "fan"
        case .distribution: return "paperplane"
        case .sleep: return "moon.zzz"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("selectedSection") private var selection: AppSection = .tokens
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selection,
                processMonitor: model.processMonitor,
                taskStore: model.taskStore,
                snip: model.snip,
                devices: model.devices
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 480)
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
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
        case .cloudClipboard:
            CloudClipboardView(store: model.cloudClipboard)
        case .snip:
            SnipView(snip: model.snip)
        case .translate:
            TranslateView(translator: model.translator, snip: model.snip)
        case .tasks:
            TasksView(store: model.taskStore)
        case .finderMenu:
            FinderMenuView()
        case .devices:
            DevicesView()
        case .cooler:
            CoolerView(cooler: model.cooler)
        case .distribution:
            DistributionView(uploader: model.pgyerUploader)
        case .sleep:
            SleepView()
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: AppSection
    @ObservedObject var processMonitor: ProcessMonitor
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var snip: SnipController
    @ObservedObject var devices: DeviceController

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            Section("AI 编码") {
                row(.tokens)
                row(.processes, badge: processMonitor.totalProcessCount)
            }
            Section("效率") {
                row(.snippets)
                row(.cloudClipboard)
                row(.snip, badge: snip.pins.count)
                row(.translate)
                row(.tasks, badge: taskStore.pendingCount)
                row(.finderMenu)
                row(.sleep)
            }
            Section("移动设备") {
                row(.devices, badge: devices.connectedCount)
                row(.cooler)
                row(.distribution)
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
