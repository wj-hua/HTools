import Foundation
import Security

/// 发布成功后蒲公英返回的版本信息（`buildInfo` 接口）。
struct PgyerBuild: Decodable, Sendable, Equatable {
    let buildName: String?
    let buildVersion: String?
    let buildVersionNo: String?
    let buildShortcutUrl: String
    let buildQRCodeURL: String?

    var shortcutURL: URL? { URL(string: "https://www.pgyer.com/\(buildShortcutUrl)") }
    var qrCodeURL: URL? { buildQRCodeURL.flatMap(URL.init(string:)) }
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
        onProgress: @escaping @Sendable (Double) -> Void
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
        return try await waitForPublish(apiKey: apiKey, buildKey: token.key)
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
        onProgress: @escaping @Sendable (Double) -> Void
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
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
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
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
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
}
