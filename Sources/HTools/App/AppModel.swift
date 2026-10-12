import AppKit
import Combine

/// 整个 App 共享的服务实例。三个工具原本各自是独立的菜单栏 App，
/// 现在由这里统一创建，主窗口和 ⌥Space 快速粘贴面板共用同一份数据。
@MainActor
final class AppModel: ObservableObject {
    // Token 用量 / 进程
    let usageStore = UsageStore()
    let processMonitor = ProcessMonitor()

    // 常用文本
    let pasteStore = PasteItemStore()
    let pasteService = SystemPasteService()
    let clipboardViewModel: ClipboardViewModel
    private var panelController: PanelController?
    private var hotKeyController: GlobalHotKeyController?
    @Published private(set) var isHotKeyRegistered = false
    @Published private(set) var isAccessibilityTrusted = false

    // 任务清单
    let taskStore = TaskStore()

    // 设备
    let devices = DeviceController()

    init() {
        clipboardViewModel = ClipboardViewModel(store: pasteStore, pasteService: pasteService)
    }

    func start() {
        panelController = PanelController(viewModel: clipboardViewModel)

        let hotKey = GlobalHotKeyController()
        hotKey.onHotKey = { [weak self] in
            self?.panelController?.toggle()
        }
        isHotKeyRegistered = hotKey.register()
        hotKeyController = hotKey

        refreshAccessibilityStatus()
        usageStore.refresh()
        processMonitor.refresh()
    }

    func showQuickPastePanel() {
        panelController?.show()
    }

    func refreshAccessibilityStatus() {
        isAccessibilityTrusted = pasteService.isAccessibilityTrusted()
    }

    func requestAccessibilityPermission() {
        pasteService.requestAccessibilityPermission()
        pasteService.openAccessibilitySettings()
    }
}
