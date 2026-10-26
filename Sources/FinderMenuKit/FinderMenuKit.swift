import AppKit

/// 右键菜单的配置。主 App 在设置页写入，Finder 扩展在每次弹出菜单时读取。
public struct FinderMenuConfig: Codable, Equatable {
    public struct Template: Codable, Equatable, Identifiable {
        public var id = UUID()
        public var name: String
        public var ext: String

        public init(name: String, ext: String) {
            self.name = name
            self.ext = ext
        }

        public var fileName: String { ext.isEmpty ? name : "\(name).\(ext)" }
    }

    public var showNewFile = true
    public var showCopyPath = true
    /// 勾选的“在 X 打开”应用，存 bundle ID。
    public var openApps: Set<String> = ["com.apple.Terminal", "com.sublimetext.4", "abnerworks.Typora"]
    public var templates: [Template] = [Template(name: "未命名", ext: "txt"), Template(name: "未命名", ext: "md")]

    public init() {}
}

/// 配置的读写。主 App 写入 `~/Library/Application Support/HTools/finder-menu.json`，
/// 沙盒中的扩展通过只读的 home-relative 例外读取同一个文件（见 HToolsFinder.entitlements）。
/// 不用 UserDefaults：非沙盒进程写入的偏好域与沙盒扩展的容器偏好不是同一份。
public enum FinderMenuConfigStore {
    /// 用 getpwuid 取真实主目录：沙盒进程里 NSHomeDirectory() 指向容器。
    private static var fileURL: URL {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        return URL(fileURLWithPath: home).appending(path: "Library/Application Support/HTools/finder-menu.json")
    }

    public static func load() -> FinderMenuConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(FinderMenuConfig.self, from: data)
        else { return FinderMenuConfig() }
        return config
    }

    /// 仅主 App 调用。
    public static func save(_ config: FinderMenuConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 可以作为“在 X 打开”目标的应用。
public struct OpenWithApp: Equatable {
    public let bundleID: String
    public let name: String
    /// 终端类应用只接受文件夹，所以选中文件时改为打开其所在目录。
    public let opensFolderOnly: Bool

    public static let all: [OpenWithApp] = [
        OpenWithApp(bundleID: "com.apple.Terminal", name: "Terminal", opensFolderOnly: true),
        OpenWithApp(bundleID: "com.googlecode.iterm2", name: "iTerm2", opensFolderOnly: true),
        OpenWithApp(bundleID: "com.microsoft.VSCode", name: "VSCode", opensFolderOnly: false),
        OpenWithApp(bundleID: "com.sublimetext.4", name: "Sublime", opensFolderOnly: false),
        OpenWithApp(bundleID: "abnerworks.Typora", name: "Typora", opensFolderOnly: false),
    ]

    /// 本机已安装的应用；未安装的不显示在设置页和右键菜单中。
    public static var installed: [OpenWithApp] {
        all.filter { url(of: $0) != nil }
    }

    public static func url(of app: OpenWithApp) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
    }
}
