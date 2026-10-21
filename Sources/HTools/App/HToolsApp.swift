import AppKit
import SwiftUI

@main
struct HToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("HTools", id: "main") {
            RootView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.devices)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {}
            CommandMenu("工具") {
                Button("快速粘贴面板") {
                    appDelegate.model.showQuickPastePanel()
                }
                // 全局快捷键由 Carbon 注册，这里只作为菜单提示，不重复绑定。
                Text("全局快捷键：⌥ Space")

                Divider()

                Button("截图") {
                    appDelegate.model.snip.captureHidingApp()
                }
                Button("贴出剪贴板") {
                    appDelegate.model.snip.pinClipboard()
                }
                Button("截图翻译") {
                    appDelegate.model.snip.captureHidingApp(primaryAction: .translate)
                }
                Text("截图 / 贴图 / 截图翻译快捷键在“截图”页设置")
            }
        }

        MenuBarExtra("HTools", systemImage: "wrench.and.screwdriver") {
            MenuBarView()
                .environmentObject(appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.start()
    }

    /// 关闭主窗口后仍保留进程，⌥Space 快速粘贴面板和录屏不受影响。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshAccessibilityStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.pasteStore.flushPendingSave()
        model.taskStore.flushPendingSave()
        model.devices.stopMirroring()
        model.cooler.shutdown()
    }
}
