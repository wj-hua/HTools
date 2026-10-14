import AppKit
import Combine
import Foundation
import Security
import LocalAuthentication
import ImageIO
import UniformTypeIdentifiers

struct CloudClip: Codable, Identifiable {
    let id: String
    let kind: String
    let createdAt: Int64
    let byteCount: Int
    let text: String?
    var date: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }
}

struct CloudDevice: Codable, Identifiable {
    let id: String
    let name: String
    let createdAt: Int64
    let lastSeen: Int64?
    let token: String?
    var lastSeenDate: Date? { lastSeen.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

@MainActor
final class CloudClipboardStore: ObservableObject {
    @Published private(set) var endpoint: String = UserDefaults.standard.string(forKey: "cloudClipboardEndpoint") ?? "https://www.gtcode.xyz/clipboard-api"
    @Published private(set) var token: String = ""
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "cloudClipboardEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cloudClipboardEnabled")
            changeCount = NSPasteboard.general.changeCount
        }
    }
    @Published private(set) var items: [CloudClip] = []
    @Published private(set) var devices: [CloudDevice] = []
    @Published private(set) var status = "同步已暂停"
    @Published private(set) var isRefreshing = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var retentionDays = 0
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var uploading = false
    private var nextRetry = Date.distantPast
    private var pending: [PendingClip] = []
    private var issuedTokens: Set<String> = []
    private let queueURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.mino.HTools/cloud-clipboard-queue.json")
    private let session = URLSession(configuration: .ephemeral)
    private static let keychainService = "com.mino.HTools.CloudClipboard"

    private struct PendingClip: Codable {
        let id: String
        let kind: String
    }
    private struct ListResponse: Decodable {
        let items: [CloudClip]
        let retentionDays: Int
    }
    private struct DeviceList: Decodable {
        let devices: [CloudDevice]
    }

    init() {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: "token",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            token = String(data: data, encoding: .utf8) ?? ""
        }
        do {
            if FileManager.default.fileExists(atPath: queueURL.path) {
                pending = try JSONDecoder().decode([PendingClip].self, from: Data(contentsOf: queueURL))
                pendingCount = pending.count
            }
        } catch { errorMessage = "无法读取待同步记录：\(error.localizedDescription)" }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if token.isEmpty {
            let configURL = queueURL.deletingLastPathComponent().appendingPathComponent("cloud-clipboard-connection.json")
            if let data = try? Data(contentsOf: configURL),
               let config = try? JSONDecoder().decode([String: String].self, from: data),
               let address = config["url"], let key = config["token"] {
                saveConnection(address: address, key: key, restoring: true)
            }
        }
        updateStatus()
        if !token.isEmpty { Task { await refresh() } }
    }

    func saveConnection(address: String, key: String, restoring: Bool = false) {
        do {
            guard pending.isEmpty || restoring else { throw failure("请先完成待同步记录，或暂停后清空待同步记录，再修改连接。") }
            _ = try baseURL(address: address)
            guard key.count >= 32 else { throw failure("请输入有效的连接密钥。") }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: "token"]
            let data = Data(key.utf8)
            var result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if result == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                result = SecItemAdd(attributes as CFDictionary, nil)
            }
            guard result == errSecSuccess else { throw failure("无法将连接密钥保存到钥匙串（\(result)）。") }
            endpoint = address
            token = key
            UserDefaults.standard.set(endpoint, forKey: "cloudClipboardEndpoint")
            items = []
            devices = []
            nextRetry = .distantPast
            Task { await refresh(); await refreshDevices() }
            toastMessage = "连接已保存"
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshDevices() async {
        do {
            devices = try JSONDecoder().decode(DeviceList.self, from: await request("devices")).devices
        } catch { errorMessage = "无法读取设备列表：\(error.localizedDescription)" }
    }

    /// Issues a token for one Android device and copies its pairing info; the server only returns the token once.
    func addDevice(name: String) async {
        do {
            let body = try JSONEncoder().encode(["name": name])
            let device = try JSONDecoder().decode(CloudDevice.self, from: await request("devices", method: "POST", body: body, mime: "application/json"))
            guard let deviceToken = device.token, let data = try? JSONEncoder().encode(["url": endpoint, "token": deviceToken]),
                  let text = String(data: data, encoding: .utf8) else { throw failure("服务器未返回设备密钥。") }
            issuedTokens.insert(deviceToken)
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            changeCount = board.changeCount
            toastMessage = "已复制“\(device.name)”的配对信息，请在该 Android 设备的连接设置中粘贴"
            await refreshDevices()
        } catch { errorMessage = error.localizedDescription }
    }

    func revoke(_ device: CloudDevice) async {
        do {
            _ = try await request("devices/\(device.id)", method: "DELETE")
            toastMessage = "已撤销“\(device.name)”"
            await refreshDevices()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let data = try await request("items")
            let response = try JSONDecoder().decode(ListResponse.self, from: data)
            items = response.items
            retentionDays = response.retentionDays
            updateStatus()
        } catch { status = "连接失败：\(error.localizedDescription)" }
    }

    func copy(_ item: CloudClip) async {
        do {
            let board = NSPasteboard.general
            if let text = item.text {
                guard Pasteboard.copy(text) else { throw failure("复制失败，请重试。") }
            } else {
                let data = try await request("items/\(item.id)/content")
                board.clearContents()
                guard board.setData(data, forType: .png) else { throw failure("复制图片失败，请重试。") }
            }
            changeCount = board.changeCount
            toastMessage = "已复制"
        } catch { errorMessage = error.localizedDescription }
    }

    func imageData(_ item: CloudClip) async throws -> Data {
        try await request("items/\(item.id)/content")
    }

    func delete(_ item: CloudClip) async {
        do {
            _ = try await request("items/\(item.id)", method: "DELETE")
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func clearPending() {
        guard !enabled, !uploading else { return }
        pending = []
        persistQueue()
        updateStatus()
    }

    private func tick() {
        if enabled, !token.isEmpty {
            capture()
            if !uploading, !pending.isEmpty, Date() >= nextRetry {
                uploading = true
                Task { await uploadPending() }
            }
        }
        if !enabled { updateStatus() }
    }

    private func capture() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !excluded.contains(where: { board.types?.contains(NSPasteboard.PasteboardType($0)) == true }) else { return }
        do {
            let clip: PendingClip
            let payload: Data
            if let png = try clipboardImage(board) {
                clip = PendingClip(id: UUID().uuidString.lowercased(), kind: "image")
                payload = png
            } else if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let data = Data(text.utf8)
                guard data.count <= 1024 * 1024 else { throw failure("文本超过 1 MB，已跳过同步。") }
                clip = PendingClip(id: UUID().uuidString.lowercased(), kind: "text")
                payload = data
            } else { return }
            // Pairing credentials should never be uploaded even if another app drops their concealed marker.
            if clip.kind == "text", let text = String(data: payload, encoding: .utf8),
               ([token] + issuedTokens).contains(where: { text.contains($0) }) { return }
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: payloadURL(clip.id), options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payloadURL(clip.id).path)
            pending.append(clip)
            pending = Array(pending.suffix(50))
            persistQueue()
            updateStatus()
        } catch { status = error.localizedDescription }
    }

    private func clipboardImage(_ board: NSPasteboard) throws -> Data? {
        let source: CGImageSource
        let originalPNG = board.data(forType: .png)
        if let data = originalPNG ?? board.data(forType: .tiff) {
            guard let decoded = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            source = decoded
        } else if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  let url = urls.first, (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true,
                  let decoded = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            source = decoded
        } else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, Double(width) * Double(height) <= 40_000_000 else {
            throw failure("图片过大，已跳过同步（最多 4000 万像素）。")
        }
        let png: Data
        if let originalPNG { png = originalPNG }
        else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let encoded = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw failure("无法读取剪贴板图片。")
            }
            png = encoded
        }
        guard png.count <= 20 * 1024 * 1024 else { throw failure("图片超过 20 MB，已跳过同步。") }
        return png
    }

    private func uploadPending() async {
        defer { uploading = false }
        while enabled, let clip = pending.first {
            do {
                _ = try await request("items/\(clip.id)", method: "PUT", body: Data(contentsOf: payloadURL(clip.id), options: .mappedIfSafe),
                                      mime: clip.kind == "image" ? "image/png" : "text/plain; charset=utf-8")
                pending.removeAll { $0.id == clip.id }
                persistQueue()
                updateStatus()
            } catch {
                nextRetry = Date().addingTimeInterval(10)
                status = "待重试 \(pending.count) 条：\(error.localizedDescription)"
                return
            }
        }
        await refresh()
    }

    private func persistQueue() {
        pendingCount = pending.count
        do {
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pending).write(to: queueURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: queueURL.path)
            let retained = Set(pending.map { $0.id + ".payload" })
            for url in try FileManager.default.contentsOfDirectory(at: queueURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                where url.pathExtension == "payload" && !retained.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        } catch { errorMessage = "无法保存待同步记录：\(error.localizedDescription)" }
    }

    private func payloadURL(_ id: String) -> URL {
        queueURL.deletingLastPathComponent().appendingPathComponent(id + ".payload")
    }

    private func updateStatus() {
        if token.isEmpty { status = "请先设置服务器连接" }
        else if !enabled { status = "同步已暂停" }
        else if pending.isEmpty { status = "正在监听 Mac 复制内容" }
        else { status = "待同步 \(pending.count) 条" }
    }

    private func baseURL(address: String? = nil) throws -> URL {
        guard let url = URL(string: address ?? endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw failure("服务器地址必须是有效的 HTTPS 地址。")
        }
        return url
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, mime: String? = nil) async throws -> Data {
        var request = URLRequest(url: try baseURL().appendingPathComponent(path), timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let mime { request.setValue(mime, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw failure(message ?? "服务器请求失败，请检查连接。")
        }
        return data
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "CloudClipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
