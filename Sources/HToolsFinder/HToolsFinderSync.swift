import AppKit
import FinderMenuKit
import FinderSync

/// Finder 右键菜单扩展：新建文件、拷贝路径、在指定应用中打开。
/// 菜单内容由主 App 的“右键菜单”页配置，每次右键时重新读取。
///
/// 注意：菜单项的 representedObject 不会跨进程保留（Finder 持有菜单副本），
/// 所以点击时重新获取选中项，并用 tag（菜单项的索引）识别应用和模板。
/// 文件操作交给主 App 执行（见 FinderMenuRequest）。
@objc(HToolsFinderSync)
final class HToolsFinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let config = FinderMenuConfigStore.load()
        guard !Self.selectedTargets.isEmpty else { return nil }

        let menu = NSMenu(title: "")

        if menuKind == .contextualMenuForContainer, config.showNewFile, !config.templates.isEmpty {
            let submenu = NSMenu(title: "新建文件")
            for (index, template) in config.templates.enumerated() {
                submenu.addItem(makeItem(template.fileName, action: #selector(newFile(_:)), tag: index))
            }
            let parent = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            parent.submenu = submenu
            menu.addItem(parent)
        }

        if config.showCopyPath {
            let item = makeItem("拷贝路径", action: #selector(copyPath(_:)))
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(item)
        }

        for (index, app) in OpenWithApp.all.enumerated() where config.openApps.contains(app.bundleID) {
            guard let appURL = OpenWithApp.url(of: app) else { continue }
            let item = makeItem("在 \(app.name) 打开", action: #selector(openInApp(_:)), tag: index)
            item.image = NSWorkspace.shared.icon(forFile: appURL.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }

        return menu.items.isEmpty ? nil : menu
    }

    private func makeItem(_ title: String, action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    /// 当前选中的项目；没有选中时为右键所在的文件夹。
    private static var selectedTargets: [URL] {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        return selected.isEmpty ? [controller.targetedURL()].compactMap { $0 } : selected
    }

    /// 扩展位于 HTools.app/Contents/PlugIns，助手位于 HTools.app/Contents/Library。
    /// 直接指定助手打开请求，助手无界面，不会拉起主窗口。
    private static let helperURL = Bundle.main.bundleURL
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Library/HToolsFinderHelper.app")

    private func send(_ request: FinderMenuRequest) {
        guard let url = request.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: Self.helperURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        let paths = Self.selectedTargets.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func openInApp(_ sender: NSMenuItem) {
        let apps = OpenWithApp.all
        guard apps.indices.contains(sender.tag) else { return }
        send(.openApp(bundleID: apps[sender.tag].bundleID, urls: Self.selectedTargets))
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        let templates = FinderMenuConfigStore.load().templates
        guard templates.indices.contains(sender.tag),
              let directory = FIFinderSyncController.default().targetedURL()
        else { return }
        send(.newFile(directory: directory, template: templates[sender.tag]))
    }
}
