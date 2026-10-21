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
    let cloudClipboard = CloudClipboardStore()

    // 设备
    let devices = DeviceController()
    let pgyerUploader = PgyerUploader()
    let cooler = CoolerController()

    // 截图与贴图
    let snip = SnipController()

    // 翻译
    let translator = TranslateController()

    /// 由主窗口注入；关闭主窗口后仍可用来重新打开它。
    var openMainWindow: (() -> Void)?

    init() {
        clipboardViewModel = ClipboardViewModel(store: pasteStore, pasteService: pasteService)
        snip.onTranslate = { [weak self] image in self?.translate(image) }
    }

    /// 截图翻译：切到翻译页并带到前台，识别结果和译文直接显示在页面上。
    func translate(_ image: CGImage) {
        UserDefaults.standard.set(AppSection.translate.rawValue, forKey: "selectedSection")
        NSApp.unhide(nil)
        openMainWindow?()
        NSApp.activate()
        translator.recognize(image)
    }

    func start() {
        panelController = PanelController(viewModel: clipboardViewModel)

        let hotKey = GlobalHotKeyController()
        hotKey.onHotKey = { [weak self] in
            self?.panelController?.toggle()
        }
        isHotKeyRegistered = hotKey.register()
        hotKeyController = hotKey

        snip.start()

        refreshAccessibilityStatus()
        cloudClipboard.start()
        usageStore.refresh()
        processMonitor.startMonitoring(interval: ProcessMonitor.backgroundInterval)
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
