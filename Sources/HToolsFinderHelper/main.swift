import AppKit
import FinderMenuKit

/// 右键菜单的后台助手：无界面（LSUIElement），只负责执行 htools:// 请求，执行完立即退出。
/// 放在 HTools.app/Contents/Library 中，不会打开主窗口。
final class FinderHelperDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let group = DispatchGroup()
        for url in urls {
            guard let request = FinderMenuRequest(url: url) else { continue }
            group.enter()
            request.perform { group.leave() }
        }
        group.notify(queue: .main) {
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = FinderHelperDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
