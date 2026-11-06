import Combine
import Foundation

/// 使用 Stetho 已有的 DevTools 协议，不需要代理、证书或修改手机网络配置。
@MainActor
final class StethoInspector: ObservableObject {
    enum Phase: Equatable {
        case idle, connecting, capturing
    }

    @Published private(set) var targets: [StethoTarget] = []
    @Published private(set) var requests: [StethoRequest] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isDiscovering = false
    @Published private(set) var appTitle: String?
    @Published private(set) var connectedTarget: StethoTarget?
    @Published var errorMessage: String?

    private let adb: ADBService
    let device: ADBDevice
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var bodyTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var forwardedPort: Int?
    private var bodyGeneration = UUID()
    private var generation = UUID()
    private var nextCommandID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var commandTimeouts: [Int: Task<Void, Never>] = [:]

    static let requestLimit = 500
    private static let bodyLimit = 8 * 1_048_576
    private static let cacheLimit = 32 * 1_048_576

    init(device: ADBDevice, adb: ADBService) {
        self.device = device
        self.adb = adb
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 10
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    static func discoverTargets(device: ADBDevice, adb: ADBService) async throws -> [StethoTarget] {
        let result = await adb.runADB(["-s", device.serial, "shell", "cat", "/proc/net/unix"])
        guard result.status == 0 else {
            throw InspectorError.message("无法读取 Stetho 应用：\(result.combinedText)")
        }
        return StethoTarget.discover(in: result.stdoutText)
    }

    func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { isDiscovering = false }
            do {
                targets = try await Self.discoverTargets(device: device, adb: adb)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func start(_ target: StethoTarget) {
        Task { [weak self] in
            try? await self?.startAsync(target)
        }
    }

    func startAsync(_ target: StethoTarget) async throws {
        stop()
        clear()
        appTitle = nil
        connectedTarget = target
        phase = .connecting
        let token = generation

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.startContinuation = continuation
            self.connectionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    // tcp:0 由 adb 分配空闲端口，每个会话只移除自己创建的转发。
                    let result = await adb.runADB([
                        "-s", device.serial, "forward", "tcp:0", "localabstract:\(target.socketName)"
                    ])
                    guard result.status == 0, let assigned = Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65_535).contains(assigned) else {
                        throw InspectorError.message("无法连接 Stetho：\(result.combinedText)")
                    }
                    self.forwardedPort = assigned
                    try Task.checkCancellation()
                    let url = URL(string: "http://127.0.0.1:\(assigned)/json")!
                    let (data, response) = try await session.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          let pages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                          let page = pages.first,
                          let address = page["webSocketDebuggerUrl"] as? String,
                          let websocketURL = Self.localWebSocketURL(address, port: assigned) else {
                        throw InspectorError.message("Stetho 未返回可用的调试连接，请重新打开手机上的应用后刷新。")
                    }
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    appTitle = page["title"] as? String
                    let socket = session.webSocketTask(with: websocketURL)
                    // 正文经 Base64 和 JSON 转义后会变大，单条消息超限会导致整个连接断开。
                    socket.maximumMessageSize = 64 * 1_048_576
                    self.socket = socket
                    socket.resume()

                    // 先启动接收循环，再等 Network.enable 的响应，避免双方互相等待。
                    let receiver = Task { [weak self] in
                        do {
                            while !Task.isCancelled {
                                let message = try await socket.receive()
                                guard let self, self.generation == token else { return }
                                try self.receive(message)
                            }
                        } catch {
                            guard let self, self.generation == token, !Task.isCancelled else { return }
                            self.fail(error)
                        }
                    }
                    defer { receiver.cancel(); socket.cancel(with: .goingAway, reason: nil) }
                    _ = try await command("Network.enable")
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    phase = .capturing
                    resumeStartContinuation(with: .success(()))
                    await receiver.value
                } catch {
                    resumeStartContinuation(with: .failure(error))
                    if generation == token, !Task.isCancelled { fail(error) }
                }
                if let p = self.forwardedPort {
                    self.forwardedPort = nil
                    _ = await adb.runADB(["-s", device.serial, "forward", "--remove", "tcp:\(p)"])
                }
            }
        }
    }

    private func resumeStartContinuation(with result: Result<Void, Error>) {
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(with: result)
        }
    }

    func stopAsync() async {
        resumeStartContinuation(with: .failure(CancellationError()))
        generation = UUID()
        bodyGeneration = UUID()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        bodyTask?.cancel()
        _ = await bodyTask?.result
        bodyTask = nil
        connectionTask?.cancel()
        _ = await connectionTask?.result
        connectionTask = nil
        finishPending(with: CancellationError())
        markInterruptedRequests()
        if let port = forwardedPort {
            forwardedPort = nil
            _ = await adb.runADB(["-s", device.serial, "forward", "--remove", "tcp:\(port)"])
        }
        phase = .idle
    }

    func stop() {
        resumeStartContinuation(with: .failure(CancellationError()))
        generation = UUID()
        bodyGeneration = UUID()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connectionTask?.cancel()
        connectionTask = nil
        bodyTask?.cancel()
        bodyTask = nil
        finishPending(with: CancellationError())
        markInterruptedRequests()
        if let port = forwardedPort {
            forwardedPort = nil
            Task { [adb, serial = device.serial] in
                _ = await adb.runADB(["-s", serial, "forward", "--remove", "tcp:\(port)"])
            }
        }
        phase = .idle
    }

    func close() {
        discoveryTask?.cancel()
        stop()
        session.invalidateAndCancel()
    }

    func clear() {
        bodyGeneration = UUID()
        bodyTask?.cancel()
        bodyTask = nil
        requests.removeAll()
    }

    func loadBody(for id: UUID) {
        guard phase == .capturing,
              let request = requests.first(where: { $0.id == id }), request.isFinished,
              request.body == .notLoaded, request.failure == nil else { return }
        bodyTask?.cancel()
        for index in requests.indices where requests[index].body == .loading {
            requests[index].body = .notLoaded
        }
        bodyTask = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.loadBodyAsync(for: id)
        }
    }

    @discardableResult
    func loadBodyAsync(for id: UUID) async throws -> StethoRequest.Body {
        guard let request = requests.first(where: { $0.id == id }) else {
            throw InspectorError.message("未找到指定的请求。")
        }
        switch request.body {
        case .text, .base64, .unavailable:
            return request.body
        case .notLoaded, .loading:
            break
        }
        guard request.isFinished else {
            throw InspectorError.message("请求尚未完成，暂无法读取响应正文。")
        }
        guard phase == .capturing else {
            throw InspectorError.message("抓包连接已关闭，未缓存的正文无法再读取。请在抓包停止前读取。")
        }
        let token = generation
        bodyGeneration = UUID()
        let bodyToken = bodyGeneration
        update(id) { $0.body = .loading }
        do {
            let result = try await command("Network.getResponseBody", params: ["requestId": request.requestID])
            try Task.checkCancellation()
            guard generation == token, bodyGeneration == bodyToken else {
                throw CancellationError()
            }
            guard let text = result["body"] as? String else {
                throw InspectorError.message("Stetho 未返回响应正文。")
            }
            let body: StethoRequest.Body
            if text.utf8.count > Self.bodyLimit {
                body = .unavailable("响应正文超过 8 MB，请使用 Chrome DevTools 查看。")
            } else if result["base64Encoded"] as? Bool == true {
                if let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) {
                    body = .text(StethoRequest.formattedBody(decoded))
                } else {
                    body = .base64(text)
                }
            } else {
                body = .text(StethoRequest.formattedBody(text))
            }
            evictBodies(reserving: body.storedSize, except: id)
            update(id) { $0.body = body }
            return body
        } catch {
            guard generation == token, bodyGeneration == bodyToken else {
                throw CancellationError()
            }
            let body: StethoRequest.Body = Task.isCancelled ? .notLoaded : .unavailable(error.localizedDescription)
            update(id) { $0.body = body }
            throw error
        }
    }

    /// Stetho 返回的是 ws:///inspector，不带 host；有些版本则返回完整地址。
    static func localWebSocketURL(_ address: String, port: Int) -> URL? {
        guard var components = URLComponents(string: address) else { return nil }
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.user = nil
        components.password = nil
        guard !components.path.isEmpty else { return nil }
        return components.url
    }

    private func command(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let socket else { throw InspectorError.message("Stetho 连接已断开。") }
        nextCommandID += 1
        let id = nextCommandID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                commandTimeouts[id] = Task { [weak self] in
                    do {
                        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                        try await Task.sleep(for: .seconds(10))
                        self?.finishCommand(id, result: .failure(InspectorError.message("Stetho 响应超时，请检查手机上的应用是否仍在运行。")))
                    } catch {
                        if !Task.isCancelled { self?.finishCommand(id, result: .failure(error)) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishCommand(id, result: .failure(CancellationError()))
            }
        }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = event["id"] as? Int {
            if let error = event["error"] as? [String: Any] {
                finishCommand(id, result: .failure(InspectorError.message(error["message"] as? String ?? "Stetho 命令失败。")))
            } else {
                finishCommand(id, result: .success(event["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        guard let method = event["method"] as? String,
              let params = event["params"] as? [String: Any],
              let requestID = params["requestId"] as? String else { return }
        let timestamp = params["timestamp"] as? Double ?? 0
        if method == "Network.requestWillBeSent", let request = params["request"] as? [String: Any] {
            // 重定向可能复用 requestId，保留上一跳，并把后续事件关联到最后一跳。
            if let index = requests.lastIndex(where: { $0.requestID == requestID }),
               let redirect = params["redirectResponse"] as? [String: Any] {
                applyResponse(redirect, to: &requests[index])
                requests[index].finishedTimestamp = timestamp
                requests[index].body = .unavailable("重定向响应没有可读取的正文。")
            }
            let entry = StethoRequest(
                requestID: requestID,
                startedAt: (params["wallTime"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date(),
                timestamp: timestamp,
                method: request["method"] as? String ?? "GET",
                url: request["url"] as? String ?? "",
                requestHeaders: StethoRequest.headers(request["headers"]),
                postData: request["postData"] as? String
            )
            requests.append(entry)
            if requests.count > Self.requestLimit { requests.removeFirst(requests.count - Self.requestLimit) }
            return
        }
        guard let index = requests.lastIndex(where: { $0.requestID == requestID }) else { return }
        switch method {
        case "Network.responseReceived":
            if let response = params["response"] as? [String: Any] { applyResponse(response, to: &requests[index]) }
        case "Network.loadingFinished":
            requests[index].finishedTimestamp = timestamp
        case "Network.loadingFailed":
            requests[index].finishedTimestamp = timestamp
            requests[index].failure = params["errorText"] as? String ?? "请求失败"
            requests[index].body = .unavailable("请求失败，未获取到响应正文。")
        default: break
        }
    }

    private func applyResponse(_ response: [String: Any], to request: inout StethoRequest) {
        request.status = response["status"] as? Int
        request.statusText = response["statusText"] as? String ?? ""
        request.responseHeaders = StethoRequest.headers(response["headers"])
        request.mimeType = response["mimeType"] as? String ?? ""
    }

    private func finishCommand(_ id: Int, result: Result<[String: Any], Error>) {
        commandTimeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func finishPending(with error: Error) {
        for timeout in commandTimeouts.values { timeout.cancel() }
        commandTimeouts.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func fail(_ error: Error) {
        errorMessage = "Stetho 连接已中断：\(error.localizedDescription)"
        stop()
    }

    private func markInterruptedRequests() {
        for index in requests.indices {
            if !requests[index].isFinished { requests[index].failure = "抓包已停止，未收到完成事件" }
            if requests[index].body == .loading { requests[index].body = .notLoaded }
        }
    }

    private func update(_ id: UUID, _ change: (inout StethoRequest) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        change(&requests[index])
    }

    private func evictBodies(reserving size: Int, except id: UUID) {
        var stored = requests.reduce(0) { $0 + $1.body.storedSize }
        for index in requests.indices where requests[index].id != id && stored + size > Self.cacheLimit {
            stored -= requests[index].body.storedSize
            requests[index].body = .notLoaded
        }
    }
}

private enum InspectorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
