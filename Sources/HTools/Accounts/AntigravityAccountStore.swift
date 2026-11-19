import Foundation

/// 一条 agy 账号快照的展示信息。凭据本体是 `~/.agy/accounts/<名称>.kc`，
/// 内容与 macOS 钥匙串 `gemini/antigravity` 里的值完全一致（go-keyring-base64 编码）。
struct AntigravityAccount: Identifiable, Hashable {
    let name: String
    let email: String
    let expiry: Date?

    var id: String { name }

    var expiryText: String {
        guard let expiry else { return "有效期未知" }
        return expiry.formatted(date: .abbreviated, time: .shortened)
    }

    /// access_token 过期不代表掉线：agy 会用 refresh_token 自动续期。
    var isExpired: Bool {
        guard let expiry else { return false }
        return expiry < Date()
    }
}

@MainActor
final class AntigravityAccountStore: ObservableObject {
    @Published private(set) var accounts: [AntigravityAccount] = []
    @Published private(set) var currentEmail: String?
    @Published private(set) var currentExpiry: Date?
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    /// 钥匙串条目的服务名与账号名，由 antigravity CLI 固定使用。
    private static let keychainService = "gemini"
    private static let keychainAccount = "antigravity"
    private static let keyringPrefix = "go-keyring-base64:"

    private static var securityURL: URL { URL(fileURLWithPath: "/usr/bin/security") }
    private static var homeURL: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 与命令行工具 agy-acct 共用的快照目录，两边可以互相切换。
    static var storeURL: URL {
        homeURL.appendingPathComponent(".agy/accounts", isDirectory: true)
    }

    private static var fallbackTokenURL: URL {
        homeURL.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
    }

    var currentAccountName: String? {
        guard let currentEmail else { return nil }
        return accounts.first { $0.email == currentEmail }?.name
    }

    func refresh() async {
        let blob = await Self.readBlob()
        if let blob, let credential = Self.decode(blob) {
            currentEmail = credential.email
            currentExpiry = credential.expiry
            errorMessage = nil
        } else {
            currentEmail = nil
            currentExpiry = nil
        }
        accounts = Self.loadSnapshots()
    }

    /// 把当前登录的账号保存成快照，快照名自动取邮箱前缀（如 example）。
    /// 同一邮箱重复保存会更新已有快照，不会产生重复项。
    func saveCurrent() async {
        guard !isBusy else { return }
        guard let blob = await Self.readBlob() else {
            errorMessage = "钥匙串里没有 agy 的登录凭据，请先在 agy 里登录。"
            return
        }
        guard let credential = Self.decode(blob) else {
            errorMessage = "无法解析当前凭据。"
            return
        }
        guard let email = credential.email, let name = Self.snapshotName(for: email, existing: Self.loadSnapshots()) else {
            errorMessage = "当前凭据缺少邮箱信息，无法自动命名，请在 agy 里重新登录。"
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            try FileManager.default.createDirectory(at: Self.storeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = Self.storeURL.appendingPathComponent("\(name).kc")
            try blob.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            statusMessage = "已保存 \(name)（\(email)）"
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func switchAccount(to name: String) async {
        guard !isBusy else { return }
        let url = Self.storeURL.appendingPathComponent("\(name).kc")
        guard let blob = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "找不到快照 \(name)。"
            return
        }
        guard let credential = Self.decode(blob) else {
            errorMessage = "快照 \(name) 已损坏。"
            return
        }

        isBusy = true
        defer { isBusy = false }
        // 切走之前先把当前账号刷新过的 token 写回它自己的快照，避免续期丢失。
        await Self.syncCurrentBack()
        let written = await Self.writeBlob(blob)
        guard written else {
            errorMessage = "写入钥匙串失败，可能需要在弹出的授权里允许 security 访问。"
            return
        }
        Self.writeFallbackToken(credential)
        statusMessage = "已切到 \(name)（\(credential.email ?? "未知邮箱")）"
        errorMessage = nil
        await refresh()
    }

    func delete(name: String) {
        let url = Self.storeURL.appendingPathComponent("\(name).kc")
        try? FileManager.default.removeItem(at: url)
        statusMessage = "已删除 \(name)"
        accounts = Self.loadSnapshots()
    }

    // MARK: - 钥匙串读写（走 /usr/bin/security，与 agy-acct 同一套 ACL）

    private static func readBlob() async -> String? {
        let result = await CommandRunner.run(
            executable: securityURL,
            arguments: ["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"],
            timeout: .seconds(15)
        )
        guard result.status == 0 else { return nil }
        let blob = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return blob.isEmpty ? nil : blob
    }

    private static func writeBlob(_ blob: String) async -> Bool {
        let result = await CommandRunner.run(
            executable: securityURL,
            arguments: ["add-generic-password", "-U", "-s", keychainService, "-a", keychainAccount, "-w", blob],
            timeout: .seconds(15)
        )
        return result.status == 0
    }

    /// 把钥匙串里最新的凭据写回同邮箱的快照。
    private static func syncCurrentBack() async {
        guard let blob = await readBlob(), let credential = decode(blob),
              let email = credential.email else { return }
        for account in loadSnapshots() where account.email == email {
            let url = storeURL.appendingPathComponent("\(account.name).kc")
            try? blob.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 兜底副本与钥匙串保持一致，命令行和 IDE 侧读到的账号不会打架。
    private static func writeFallbackToken(_ credential: Credential) {
        var payload: [String: Any] = [:]
        if let token = credential.raw["token"] {
            payload["token"] = token
        }
        payload["auth_method"] = credential.raw["auth_method"] ?? "consumer"
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: fallbackTokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fallbackTokenURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackTokenURL.path)
    }

    // MARK: - 快照解析

    struct Credential {
        let email: String?
        let expiry: Date?
        let raw: [String: Any]
    }

    static func decode(_ blob: String) -> Credential? {
        let body = blob.hasPrefix(keyringPrefix) ? String(blob.dropFirst(keyringPrefix.count)) : blob
        guard let data = Data(base64Encoded: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let token = json["token"] as? [String: Any]
        return Credential(
            email: json["id_token_email"] as? String,
            expiry: (token?["expiry"] as? String).flatMap(parseDate),
            raw: json
        )
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func loadSnapshots() -> [AntigravityAccount] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: storeURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "kc" }
            .compactMap { url -> AntigravityAccount? in
                guard let blob = try? String(contentsOf: url, encoding: .utf8),
                      let credential = decode(blob)
                else { return nil }
                return AntigravityAccount(
                    name: url.deletingPathExtension().lastPathComponent,
                    email: credential.email ?? "未知邮箱",
                    expiry: credential.expiry
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 邮箱前缀作为快照名；同名但不同邮箱时追加序号，避免覆盖别人的快照。
    private static func snapshotName(for email: String, existing: [AntigravityAccount]) -> String? {
        if let matched = existing.first(where: { $0.email == email }) {
            return matched.name
        }
        let base = sanitized(String(email.prefix(while: { $0 != "@" })))
        guard !base.isEmpty else { return nil }
        let taken = Set(existing.map(\.name))
        var candidate = base
        var index = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    /// 只保留文件名安全字符，避免快照名带路径分隔符。
    private static func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        return String(filtered.prefix(40))
    }
}
