import Foundation
import Security
import Vision

// MARK: - 本机 OCR

struct TextRecognizer: Sendable {
    /// 在后台线程同步执行 Vision；取消时在下一个检查点丢弃结果。
    func recognize(_ image: CGImage) async throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let available = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { available.contains($0) }
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()

        // 先按行分组再排序，避免“y 接近即同一行”这种不可传递的比较器。
        struct Line { var box: CGRect; var fragments: [(CGRect, String)] }
        var lines: [Line] = []
        for observation in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let box = observation.boundingBox
            if let index = lines.firstIndex(where: { abs($0.box.midY - box.midY) < min($0.box.height, box.height) * 0.45 }) {
                lines[index].fragments.append((box, text))
                lines[index].box = lines[index].box.union(box)
            } else {
                lines.append(Line(box: box, fragments: [(box, text)]))
            }
        }
        lines.sort { $0.box.midY > $1.box.midY }

        var output = ""
        var previous: CGRect?
        for line in lines {
            if let previous {
                let gap = previous.minY - line.box.maxY
                output += gap > max(previous.height, line.box.height) * 0.85 ? "\n\n" : "\n"
            }
            var row = ""
            for (_, fragment) in line.fragments.sorted(by: { $0.0.minX < $1.0.minX }) {
                // 两段西文之间补空格；中日韩文字不补。
                if let last = row.unicodeScalars.last, let first = fragment.unicodeScalars.first,
                   CharacterSet.alphanumerics.contains(last), CharacterSet.alphanumerics.contains(first),
                   last.value < 0x2E80, first.value < 0x2E80 { row += " " }
                row += fragment
            }
            output += row
            previous = line.box
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslateError("图片中没有识别到文字。请选取更清晰的文字区域。")
        }
        return output
    }
}

// MARK: - API Key

/// 每个接口配置一项，account 为配置 UUID。沿用 HTranslate 的 service，已存的密钥无需重填。
struct TranslateKeychain: Sendable {
    private let service = "com.mino.HTranslate.api-key"

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    func read(_ id: UUID) throws -> String {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return key
    }

    func write(_ key: String, for id: UUID) throws {
        if key.isEmpty { try delete(id); return }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query(id)
            entry.merge(attributes) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(entry as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }

    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> TranslateError {
        TranslateError("Keychain 操作失败，配置未保存。请解锁登录钥匙串后重试。 (\(status))")
    }
}

// MARK: - SSE

/// 增量 SSE 分帧；行和事件的大小限制与网络分块边界无关。
struct SSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var previousWasCR = false
    private let limit = 512 * 1024

    mutating func append(_ byte: UInt8) throws -> String? {
        if byte == 10, previousWasCR { previousWasCR = false; return nil }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 { return try endLine() }
        line.append(byte)
        guard line.count + eventBytes <= limit else { throw TranslateError("流式事件过大，已停止接收。") }
        return nil
    }

    private mutating func endLine() throws -> String? {
        guard !line.isEmpty else {
            let payload = dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            return payload
        }
        guard let value = String(data: line, encoding: .utf8) else {
            throw TranslateError("流式响应包含无效文字编码。")
        }
        eventBytes += line.count
        line.removeAll(keepingCapacity: true)
        if value.hasPrefix("data:") {
            var data = String(value.dropFirst(5))
            if data.hasPrefix(" ") { data.removeFirst() }
            dataLines.append(data)
        }
        guard eventBytes <= limit else { throw TranslateError("流式事件过大，已停止接收。") }
        return nil
    }
}

// MARK: - OpenAI 兼容客户端

struct TranslateClient: Sendable {
    typealias Update = @MainActor @Sendable (String) -> Void

    /// 每段数据最多等 30 秒，整次请求最多 120 秒。
    func translate(_ snapshot: TranslationRequest, onUpdate: @escaping Update) async throws -> String {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await consume(snapshot, onUpdate: onUpdate) }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func consume(_ snapshot: TranslationRequest, onUpdate: @escaping Update) async throws -> String {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: snapshot.urlRequest())
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw TranslateError("接口未返回有效 HTTP 响应。") }
            guard (200...299).contains(http.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if body.count >= 64 * 1024 { break }
                    body.append(byte)
                }
                throw Self.httpError(http.statusCode, body: body, reasoning: snapshot.reasoningEffort)
            }
            let mime = http.mimeType?.lowercased() ?? ""
            if snapshot.streaming {
                guard mime == "text/event-stream" else {
                    throw TranslateError("接口未返回 SSE 流，请在此配置中关闭“流式输出”后重试。")
                }
                return try await consumeSSE(bytes, onUpdate: onUpdate)
            }
            guard mime == "application/json" || mime.hasSuffix("+json") else {
                throw TranslateError("接口未返回兼容的 JSON 响应，请检查接口地址。")
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 8 * 1024 * 1024 else { throw TranslateError("接口响应过大，已停止接收。") }
                data.append(byte)
            }
            guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let choice = response.choices.first, let content = choice.message?.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslateError("接口没有返回译文正文，请检查模型与接口兼容性。")
            }
            await onUpdate(content)
            if let reason = choice.finish_reason, reason != "stop" {
                throw TranslateError("译文未完成：模型达到长度限制或提前终止。")
            }
            return content
        } onCancel: {
            // 不在这里 invalidate：取消可能早于 bytes(for:) 创建任务。
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
    }

    private func consumeSSE(_ bytes: URLSession.AsyncBytes, onUpdate: @escaping Update) async throws -> String {
        var parser = SSEParser()
        var text = ""
        var finished = false
        var finishReason: String?
        var lastUpdate = ContinuousClock.now
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let event = try parser.append(byte) else { continue }
                if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { finished = true; break }
                if event.isEmpty { continue }
                guard let data = event.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
                    throw TranslateError("无法解析流式响应。请检查接口兼容性，或关闭流式输出后重试。")
                }
                // 只取第一个候选，不把其他 choice 混进译文。
                if let choice = chunk.choices.first(where: { ($0.index ?? 0) == 0 }) {
                    text += choice.delta?.content ?? ""
                    if let reason = choice.finish_reason { finishReason = reason }
                }
                guard text.utf8.count <= 8 * 1024 * 1024 else { throw TranslateError("接口响应过大，已停止接收。") }
                if lastUpdate.duration(to: .now) >= .milliseconds(50) {
                    await onUpdate(text)
                    lastUpdate = .now
                }
            }
            try Task.checkCancellation()
            await onUpdate(text)
            guard finished || finishReason == "stop" else { throw TranslateError("连接已结束，译文未完成。请重试。") }
            if let finishReason, finishReason != "stop" {
                throw TranslateError("译文未完成：模型达到长度限制或提前终止。")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslateError("接口没有返回译文正文；推理内容不会作为译文显示。")
            }
            return text
        } catch {
            // 出错也把已收到的内容刷出去；调用方会校验请求轮次。
            await onUpdate(text)
            throw error
        }
    }

    private static func httpError(_ code: Int, body: Data, reasoning: ReasoningEffort) -> TranslateError {
        let message: String
        switch code {
        case 401, 403: message = "接口拒绝访问，请检查此配置的 API Key、模型及账户权限。"
        case 429: message = "接口请求过多或额度不足，请稍后重试并检查账户额度。"
        case 400, 422:
            let raw = String(data: body, encoding: .utf8)?.lowercased() ?? ""
            message = reasoning != .omitted && (raw.contains("reasoning") || raw.contains("effort"))
                ? "接口不支持此推理参数，请将此配置的推理强度改为“不发送”后重试。"
                : "接口拒绝了请求，请检查模型、地址与参数；可尝试将推理强度改为“不发送”。"
        default: message = "接口返回错误，请检查服务状态后重试。"
        }
        return TranslateError(message + " (HTTP \(code))")
    }
}

private struct ChatResponse: Decodable {
    struct Content: Decodable { let content: String? }
    struct Choice: Decodable {
        let index: Int?
        let message: Content?
        let delta: Content?
        let finish_reason: String?
    }
    let choices: [Choice]
}

/// 不跟随重定向，避免把密钥和原文转发到别的地址；请填写最终接口地址。
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
