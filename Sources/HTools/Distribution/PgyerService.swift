import AppKit
import Foundation
import Security
import SwiftUI

/// 上传进度信息，包含精确已发送字节数与总字节数。
struct PgyerUploadProgress: Equatable, Sendable {
    var fraction: Double
    var bytesSent: Int64
    var totalBytes: Int64

    var formattedSent: String {
        ByteCountFormatter.string(fromByteCount: bytesSent, countStyle: .file)
    }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// 支持的移动平台类型。
enum AppPlatform: String, Codable, Sendable, CaseIterable {
    case android = "Android"
    case ios = "iOS"
    case harmonyOS = "HarmonyOS"
    case unknown = "其他"

    var title: String { rawValue }

    var badgeColor: Color {
        switch self {
        case .android: return .green
        case .ios: return .blue
        case .harmonyOS: return .orange
        case .unknown: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .android: return "candybarphone"
        case .ios: return "iphone"
        case .harmonyOS: return "circle.hexagongrid.fill"
        case .unknown: return "shippingbox.fill"
        }
    }

    static func from(pathExtension: String) -> AppPlatform {
        switch pathExtension.lowercased() {
        case "apk": return .android
        case "ipa": return .ios
        case "hap": return .harmonyOS
        default: return .unknown
        }
    }

    static func from(buildType: String?) -> AppPlatform {
        guard let buildType else { return .unknown }
        switch buildType.lowercased() {
        case "1", "ipa", "ios": return .ios
        case "2", "apk", "android": return .android
        case "hap", "harmony", "harmonyos": return .harmonyOS
        default: return .unknown
        }
    }
}

/// 发布成功后蒲公英返回的版本信息（`buildInfo` 接口）。
struct PgyerBuild: Codable, Sendable, Equatable, Identifiable {
    var id: String {
        buildKey ?? (buildShortcutUrl.isEmpty ? UUID().uuidString : buildShortcutUrl)
    }

    var buildKey: String?
    let buildType: String?
    let buildName: String?
    let buildVersion: String?
    let buildVersionNo: String?
    let buildShortcutUrl: String
    let buildQRCodeURL: String?
    let buildIcon: String?
    let buildDescription: String?
    let buildUpdateDescription: String?
    let buildFileSize: String?
    let buildCreated: String?

    // 本地持久化补充字段
    var uploadedAt: Date?
    var localInstallType: Int?
    var localPassword: String?
    var localUpdateDescription: String?
    var localFileName: String?
    var localFileSizeBytes: Int64?

    /// 固定的长链接：以 32 位 buildKey 为路径，永久唯一对应当前上传的构建版本。
    var fixedURL: URL? {
        guard let buildKey, !buildKey.isEmpty else { return nil }
        return URL(string: "https://www.pgyer.com/\(buildKey)")
    }

    /// 应用短链接：以 buildShortcutUrl 为路径。
    var shortcutURL: URL? {
        guard !buildShortcutUrl.isEmpty else { return nil }
        return URL(string: "https://www.pgyer.com/\(buildShortcutUrl)")
    }

    /// 复制链接、分享文案与浏览器打开的首选链接：优先使用固定的长链接（https://www.pgyer.com/{buildKey}），若无则回退到短链接。
    var downloadURL: URL? {
        fixedURL ?? shortcutURL
    }

    var qrCodeURL: URL? {
        buildQRCodeURL.flatMap(URL.init(string:))
    }

    var iconURL: URL? {
        buildIcon.flatMap(URL.init(string:))
    }

    var platform: AppPlatform {
        if let localFileName, let ext = localFileName.split(separator: ".").last {
            let plat = AppPlatform.from(pathExtension: String(ext))
            if plat != .unknown { return plat }
        }
        return AppPlatform.from(buildType: buildType)
    }

    var displayVersion: String {
        var parts: [String] = []
        if let v = buildVersion, !v.isEmpty { parts.append("v\(v)") }
        if let b = buildVersionNo, !b.isEmpty { parts.append("(\(b))") }
        return parts.isEmpty ? "未知版本" : parts.joined(separator: " ")
    }

    var installTypeDescription: String {
        guard let localInstallType, let type = PgyerInstallType(rawValue: localInstallType) else {
            return "公开"
        }
        return type.title
    }

    var formattedFileSize: String {
        if let localFileSizeBytes, localFileSizeBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: localFileSizeBytes, countStyle: .file)
        }
        if let buildFileSize, let bytes = Int64(buildFileSize), bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return "未知大小"
    }

    enum CodingKeys: String, CodingKey {
        case buildKey, buildType, buildName, buildVersion, buildVersionNo
        case buildShortcutUrl, buildQRCodeURL, buildIcon, buildDescription
        case buildUpdateDescription, buildFileSize, buildCreated
        case uploadedAt, localInstallType, localPassword, localUpdateDescription
        case localFileName, localFileSizeBytes
    }

    init(
        buildKey: String? = nil,
        buildType: String? = nil,
        buildName: String? = nil,
        buildVersion: String? = nil,
        buildVersionNo: String? = nil,
        buildShortcutUrl: String,
        buildQRCodeURL: String? = nil,
        buildIcon: String? = nil,
        buildDescription: String? = nil,
        buildUpdateDescription: String? = nil,
        buildFileSize: String? = nil,
        buildCreated: String? = nil,
        uploadedAt: Date? = nil,
        localInstallType: Int? = nil,
        localPassword: String? = nil,
        localUpdateDescription: String? = nil,
        localFileName: String? = nil,
        localFileSizeBytes: Int64? = nil
    ) {
        self.buildKey = buildKey
        self.buildType = buildType
        self.buildName = buildName
        self.buildVersion = buildVersion
        self.buildVersionNo = buildVersionNo
        self.buildShortcutUrl = buildShortcutUrl
        self.buildQRCodeURL = buildQRCodeURL
        self.buildIcon = buildIcon
        self.buildDescription = buildDescription
        self.buildUpdateDescription = buildUpdateDescription
        self.buildFileSize = buildFileSize
        self.buildCreated = buildCreated
        self.uploadedAt = uploadedAt
        self.localInstallType = localInstallType
        self.localPassword = localPassword
        self.localUpdateDescription = localUpdateDescription
        self.localFileName = localFileName
        self.localFileSizeBytes = localFileSizeBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.buildKey = try? container.decodeIfPresent(String.self, forKey: .buildKey)
        self.buildType = try? container.decodeIfPresent(String.self, forKey: .buildType)
        self.buildName = try? container.decodeIfPresent(String.self, forKey: .buildName)
        self.buildVersion = try? container.decodeIfPresent(String.self, forKey: .buildVersion)
        self.buildVersionNo = try? container.decodeIfPresent(String.self, forKey: .buildVersionNo)
        self.buildShortcutUrl = (try? container.decodeIfPresent(String.self, forKey: .buildShortcutUrl)) ?? ""
        self.buildQRCodeURL = try? container.decodeIfPresent(String.self, forKey: .buildQRCodeURL)
        self.buildIcon = try? container.decodeIfPresent(String.self, forKey: .buildIcon)
        self.buildDescription = try? container.decodeIfPresent(String.self, forKey: .buildDescription)
        self.buildUpdateDescription = try? container.decodeIfPresent(String.self, forKey: .buildUpdateDescription)

        if let sizeStr = try? container.decodeIfPresent(String.self, forKey: .buildFileSize) {
            self.buildFileSize = sizeStr
        } else if let sizeInt = try? container.decodeIfPresent(Int64.self, forKey: .buildFileSize) {
            self.buildFileSize = String(sizeInt)
        } else {
            self.buildFileSize = nil
        }

        self.buildCreated = try? container.decodeIfPresent(String.self, forKey: .buildCreated)
        self.uploadedAt = try? container.decodeIfPresent(Date.self, forKey: .uploadedAt)
        self.localInstallType = try? container.decodeIfPresent(Int.self, forKey: .localInstallType)
        self.localPassword = try? container.decodeIfPresent(String.self, forKey: .localPassword)
        self.localUpdateDescription = try? container.decodeIfPresent(String.self, forKey: .localUpdateDescription)
        self.localFileName = try? container.decodeIfPresent(String.self, forKey: .localFileName)
        self.localFileSizeBytes = try? container.decodeIfPresent(Int64.self, forKey: .localFileSizeBytes)
    }
}

/// 安装方式，对应 `buildInstallType`。
enum PgyerInstallType: Int, CaseIterable, Identifiable {
    case `public` = 1
    case password = 2
    case invite = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .public: return "公开"
        case .password: return "密码安装"
        case .invite: return "邀请安装"
        }
    }
}

enum PgyerError: LocalizedError {
    case unsupportedFile(String)
    case api(code: Int, message: String)
    case uploadFailed(Int)
    case publishTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name):
            return "不支持的文件：\(name)。请选择 APK、IPA 或 HAP 安装包。"
        case .api(1002, _):
            return "API Key 无效。请点击右上角钥匙图标重新填写。"
        case .api(let code, let message):
            return message.isEmpty ? "蒲公英返回错误（\(code)）。" : "\(message)（\(code)）"
        case .uploadFailed(let status):
            return "文件上传失败（HTTP \(status)）。"
        case .publishTimedOut:
            return "文件已上传，但蒲公英 3 分钟内未完成发布。请稍后在蒲公英后台查看。"
        }
    }
}

/// 蒲公英 API 2.0 快速上传：获取上传凭证 → 上传文件 → 轮询发布结果。
/// 文档：https://www.pgyer.com/doc/view/api_upload
enum PgyerService {
    static let supportedExtensions: Set<String> = ["apk", "ipa", "hap"]
    static let apiKeyPageURL = URL(string: "https://www.pgyer.com/account/api")!

    private static let baseURL = URL(string: "https://www.pgyer.com/apiv2/app/")!
    /// 发布中：每 3 秒查询一次，最多等 3 分钟。
    private static let pollInterval: Duration = .seconds(3)
    private static let pollAttempts = 60

    struct Options: Sendable {
        var updateDescription: String
        var installType: PgyerInstallType
        var password: String
    }

    static func upload(
        fileURL: URL,
        apiKey: String,
        options: Options,
        onProgress: @escaping @Sendable (PgyerUploadProgress) -> Void
    ) async throws -> PgyerBuild {
        let buildType = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(buildType) else {
            throw PgyerError.unsupportedFile(fileURL.lastPathComponent)
        }

        var fields = [
            "_api_key": apiKey,
            "buildType": buildType,
            "buildInstallType": String(options.installType.rawValue),
            "buildUpdateDescription": options.updateDescription
        ]
        if options.installType == .password {
            fields["buildPassword"] = options.password
        }
        let token = try await getCOSToken(fields: fields)
        try await uploadFile(fileURL, token: token, onProgress: onProgress)
        var build = try await waitForPublish(apiKey: apiKey, buildKey: token.key)
        if build.buildKey == nil || build.buildKey?.isEmpty == true {
            build.buildKey = token.key
        }
        return build
    }

    // MARK: - 第 1 步：上传凭证

    private struct COSToken: Decodable {
        let endpoint: URL
        let key: String
        let params: [String: String]
    }

    private static func getCOSToken(fields: [String: String]) async throws -> COSToken {
        var request = URLRequest(url: baseURL.appendingPathComponent("getCOSToken"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(fields)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decode(data)
    }

    // MARK: - 第 2 步：上传文件

    private static func uploadFile(
        _ fileURL: URL,
        token: COSToken,
        onProgress: @escaping @Sendable (PgyerUploadProgress) -> Void
    ) async throws {
        let boundary = "HTools-\(UUID().uuidString)"
        // 安装包可能有几百 MB：先流式写成临时 multipart 文件再上传，避免整包读进内存。
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgyer-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var fields = token.params
        fields["key"] = token.key
        fields["x-cos-meta-file-name"] = fileURL.lastPathComponent
        try writeMultipartBody(to: bodyURL, boundary: boundary, fields: fields, fileURL: fileURL)

        var request = URLRequest(url: token.endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 else { throw PgyerError.uploadFailed(status) }
    }

    /// 对象存储要求 `file` 是最后一个字段。
    private static func writeMultipartBody(to bodyURL: URL, boundary: String, fields: [String: String], fileURL: URL) throws {
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        var head = ""
        for (name, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        head += "Content-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(head.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    // MARK: - 第 3 步：等待发布

    private static func waitForPublish(apiKey: String, buildKey: String) async throws -> PgyerBuild {
        var components = URLComponents(url: baseURL.appendingPathComponent("buildInfo"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = String(decoding: formEncoded(["_api_key": apiKey, "buildKey": buildKey]), as: UTF8.self)
        let url = components.url!

        for _ in 0..<pollAttempts {
            let (data, _) = try await URLSession.shared.data(from: url)
            do {
                return try decode(data)
            } catch PgyerError.api(let code, _) where code == 1246 || code == 1247 {
                // 1246 / 1247：仍在解析或发布中。
                try await Task.sleep(for: pollInterval)
            }
        }
        throw PgyerError.publishTimedOut
    }

    // MARK: - 工具函数

    private struct Envelope<T: Decodable>: Decodable {
        let code: Int
        let message: String?
        let data: T?
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        // 失败时 data 可能是空数组等任意结构，先只解析 code 和 message。
        let status = try JSONDecoder().decode(Envelope<Empty>.self, from: data)
        guard status.code == 0 else {
            throw PgyerError.api(code: status.code, message: status.message ?? "")
        }
        guard let value = try JSONDecoder().decode(Envelope<T>.self, from: data).data else {
            throw PgyerError.api(code: status.code, message: "蒲公英返回的数据为空")
        }
        return value
    }

    private struct Empty: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// `application/x-www-form-urlencoded`：只保留 RFC 3986 非保留字符，
    /// 中文、`+`、`&` 等全部转义，避免发布内容被截断或变成空格。
    private static func formEncoded(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        return Data(query.joined(separator: "&").utf8)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (PgyerUploadProgress) -> Void

    init(onProgress: @escaping @Sendable (PgyerUploadProgress) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(PgyerUploadProgress(
            fraction: fraction,
            bytesSent: totalBytesSent,
            totalBytes: totalBytesExpectedToSend
        ))
    }
}

/// API Key 只需填写一次，保存在本机钥匙串。
enum PgyerKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "HTools.pgyer",
        kSecAttrAccount as String: "apiKey"
    ]

    static func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ apiKey: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(apiKey.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
