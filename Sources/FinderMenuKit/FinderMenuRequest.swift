import AppKit

/// Finder 右键菜单的文件操作请求。
///
/// 沙盒中的 Finder 扩展无法访问“文稿”等目录，所以扩展只把请求编码成 `htools://finder/...` URL，
/// 由非沙盒的主 App 解析并执行。
public enum FinderMenuRequest: Equatable {
    case newFile(directory: URL, template: FinderMenuConfig.Template)
    case openApp(bundleID: String, urls: [URL])

    private static let scheme = "htools"
    private static let host = "finder"

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch components.path {
        case "/new-file":
            guard let dir = value("dir"), let name = value("name"), let ext = value("ext") else { return nil }
            self = .newFile(directory: URL(fileURLWithPath: dir), template: .init(name: name, ext: ext))
        case "/open":
            guard let bundleID = value("app") else { return nil }
            let urls = items.filter { $0.name == "path" }.compactMap(\.value).map { URL(fileURLWithPath: $0) }
            self = .openApp(bundleID: bundleID, urls: urls)
        default:
            return nil
        }
    }

    /// 扩展端调用：编码成 URL，交给 LaunchServices 打开主 App。
    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        switch self {
        case let .newFile(directory, template):
            components.path = "/new-file"
            components.queryItems = [
                URLQueryItem(name: "dir", value: directory.path),
                URLQueryItem(name: "name", value: template.name),
                URLQueryItem(name: "ext", value: template.ext),
            ]
        case let .openApp(bundleID, urls):
            components.path = "/open"
            components.queryItems = [URLQueryItem(name: "app", value: bundleID)]
                + urls.map { URLQueryItem(name: "path", value: $0.path) }
        }
        return components.url
    }

    /// 助手 App 调用：真正执行文件操作，完成后回调（用于决定何时退出）。
    public func perform(completion: @escaping () -> Void) {
        switch self {
        case let .newFile(directory, template):
            let url = Self.availableURL(in: directory, template: template)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            completion()

        case let .openApp(bundleID, urls):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                completion()
                return
            }
            let opensFolderOnly = OpenWithApp.all.first { $0.bundleID == bundleID }?.opensFolderOnly ?? false
            let targets = opensFolderOnly ? Array(Set(urls.map(Self.folder(containing:)))) : urls
            NSWorkspace.shared.open(targets, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                completion()
            }
        }
    }

    /// 终端类应用只接受文件夹，选中文件时改为打开其所在目录。
    private static func folder(containing url: URL) -> URL {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }

    /// 同名文件已存在时按访达的习惯追加序号：未命名 2.txt、未命名 3.txt …
    private static func availableURL(in directory: URL, template: FinderMenuConfig.Template) -> URL {
        var url = directory.appendingPathComponent(template.fileName)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let name = template.ext.isEmpty ? "\(template.name) \(index)" : "\(template.name) \(index).\(template.ext)"
            url = directory.appendingPathComponent(name)
            index += 1
        }
        return url
    }
}
