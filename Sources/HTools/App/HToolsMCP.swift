import Foundation
import ImageIO

/// A local, read-only MCP server. stdout is reserved for newline-delimited JSON-RPC.
@MainActor
enum HToolsMCP {
    private static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let emptySchema: [String: Any] = ["type": "object", "properties": [:], "additionalProperties": false]
    private static let deviceSchema: [String: Any] = [
        "type": "object", "properties": [
            "deviceId": ["type": "string", "description": "设备 ID，来自 list_devices；多设备时必填"]
        ], "additionalProperties": false
    ]
    static let definitions: [[String: Any]] = [
        ["name": "get_token_usage", "description": "查询本机 AI 工具的 token 用量；总数包括缓存和推理 token。", "inputSchema": [
            "type": "object", "properties": ["period": ["type": "string", "enum": ["today", "week", "month", "total"], "description": "默认 today，按 Mac 本地时区计算"]], "additionalProperties": false
        ]],
        ["name": "list_ai_processes", "description": "查询本机当前用户的 AI 工具进程及内存。", "inputSchema": emptySchema],
        ["name": "list_tasks", "description": "查询 HTools 已保存的任务清单。", "inputSchema": [
            "type": "object", "properties": ["status": ["type": "string", "enum": ["all", "pending", "completed"], "description": "默认 all"]], "additionalProperties": false
        ]],
        ["name": "list_devices", "description": "列出 ADB 和 HDC 设备及连接状态。", "inputSchema": emptySchema],
        ["name": "get_device_info", "description": "查询已连接设备的信息。", "inputSchema": deviceSchema],
        ["name": "get_foreground_app", "description": "查询已连接设备当前前台应用。", "inputSchema": deviceSchema],
        ["name": "capture_device_screen", "description": "截取已连接手机的当前屏幕并返回图片。", "inputSchema": deviceSchema],
        ["name": "upload_to_pgyer", "description": "上传 APK（或 IPA、HAP）安装包到蒲公英分发平台，返回版本信息、下载链接、二维码和分享文案。", "inputSchema": [
            "type": "object", "properties": [
                "filePath": ["type": "string", "description": "安装包文件路径（绝对路径或带 ~ 路径，支持 .apk、.ipa、.hap）"],
                "path": ["type": "string", "description": "filePath 的别名"],
                "updateDescription": ["type": "string", "description": "版本更新说明，可选"],
                "installType": ["type": "string", "enum": ["public", "password", "invite"], "description": "安装方式：public（公开，默认）、password（密码安装）、invite（邀请安装）"],
                "password": ["type": "string", "description": "安装密码（当 installType 为 password 时必填）"],
                "apiKey": ["type": "string", "description": "蒲公英 API Key。默认自动从 HTools 钥匙串读取，如未配置可在参数中传入"]
            ], "additionalProperties": false
        ]],
        ["name": "list_stetho_targets", "description": "列出已连接 Android 设备上运行且支持 Stetho 抓包的应用进程与 socket。", "inputSchema": deviceSchema],
        ["name": "capture_stetho_requests", "description": "在指定时间内抓取 Android 设备上 Stetho 应用的网络请求（默认抓取 10 秒），直接返回抓到的请求及响应正文。适合单次即时抓包与接口分析。", "inputSchema": [
            "type": "object", "properties": [
                "deviceId": ["type": "string", "description": "设备 ID，来自 list_devices；多设备时必填"],
                "processName": ["type": "string", "description": "目标应用进程名（如 com.example.app）；单应用或前台应用时可省略"],
                "target": ["type": "string", "description": "processName 的别名"],
                "duration": ["type": "integer", "description": "抓包持续时间（秒，默认 10，范围 1-60）"],
                "maxRequests": ["type": "integer", "description": "最多抓取的请求数（默认 50，达到后提前结束）"],
                "includeBody": ["type": "boolean", "description": "是否加载并包含响应正文（默认 true）"],
                "urlFilter": ["type": "string", "description": "URL 包含的关键字过滤"]
            ], "additionalProperties": false
        ]],
        ["name": "start_stetho_capture", "description": "启动后台 Stetho 抓包会话，持续监听网络请求。可调用 get_stetho_requests 查询请求，使用完毕后需调用 stop_stetho_capture 停止。", "inputSchema": [
            "type": "object", "properties": [
                "deviceId": ["type": "string", "description": "设备 ID，来自 list_devices；多设备时必填"],
                "processName": ["type": "string", "description": "目标应用进程名；单应用或前台应用时可省略"],
                "target": ["type": "string", "description": "processName 的别名"],
                "autoStopSeconds": ["type": "integer", "description": "自动停止超时时间（秒，默认 120，范围 10-600）"]
            ], "additionalProperties": false
        ]],
        ["name": "get_stetho_requests", "description": "查询当前 Stetho 抓包会话中的请求列表或特定请求详情。传入 requestId 可获取完整标头、正文和 cURL 命令。", "inputSchema": [
            "type": "object", "properties": [
                "requestId": ["type": "string", "description": "特定请求的 ID（传入时返回该请求的详细信息及正文）"],
                "urlFilter": ["type": "string", "description": "按 URL 关键字过滤"],
                "statusFilter": ["type": "string", "enum": ["all", "success", "failed", "pending"], "description": "按状态过滤：all（默认）、success、failed、pending"],
                "includeBody": ["type": "boolean", "description": "是否加载并包含响应正文（默认查询详情时为 true，列表时为 false）"],
                "limit": ["type": "integer", "description": "返回的最多请求数量（默认 50）"],
                "clear": ["type": "boolean", "description": "查询后是否清空内存中的抓包记录（默认 false）"]
            ], "additionalProperties": false
        ]],
        ["name": "stop_stetho_capture", "description": "停止当前后台 Stetho 抓包会话，断开调试连接并释放端口转发。", "inputSchema": emptySchema]
    ]

    static func run() async {
        while let line = readLine() {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                    sendError(id: NSNull(), code: -32600, message: "Invalid Request")
                    continue
                }
                guard let id = request["id"] else { continue }
                let params = request["params"] as? [String: Any] ?? [:]
                switch method {
                case "initialize":
                    let requested = params["protocolVersion"] as? String ?? ""
                    send(id: id, result: ["protocolVersion": versions.contains(requested) ? requested : versions[0], "capabilities": ["tools": [:]], "serverInfo": ["name": "htools", "version": "0.1.0"]])
                case "ping": send(id: id, result: [:])
                case "tools/list":
                    send(id: id, result: ["tools": definitions.filter { MCPSettings.isEnabled($0["name"] as? String ?? "") }])
                case "tools/call":
                    do {
                        guard let name = params["name"] as? String else { throw MCPError.message("缺少工具名称") }
                        guard params["arguments"] == nil || params["arguments"] is [String: Any] else { throw MCPError.message("工具参数必须是对象") }
                        guard MCPSettings.isEnabled(name == "upload_apk_to_pgyer" ? "upload_to_pgyer" : name) else { throw MCPError.message("该工具已在 HTools 的 MCP 管理中关闭") }
                        let value = try await call(name, arguments: params["arguments"] as? [String: Any] ?? [:])
                        if let image = value as? ScreenImage {
                            send(id: id, result: ["content": [
                                ["type": "text", "text": "设备截图：\(image.deviceId)"],
                                ["type": "image", "data": image.data.base64EncodedString(), "mimeType": image.mimeType]
                            ]])
                        } else {
                            let payload = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                            send(id: id, result: ["content": [["type": "text", "text": String(decoding: payload, as: UTF8.self)]]])
                        }
                    } catch {
                        send(id: id, result: ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
                    }
                default: sendError(id: id, code: -32601, message: "Method not found")
                }
            } catch {
                sendError(id: NSNull(), code: -32700, message: "Parse error")
            }
        }
    }

    private static func call(_ name: String, arguments: [String: Any]) async throws -> Any {
        switch name {
        case "get_token_usage":
            try validate(arguments, allowed: ["period"])
            let period = try string(arguments, key: "period") ?? "today"
            let granularity: Granularity
            switch period {
            case "today": granularity = .day
            case "week": granularity = .week
            case "month": granularity = .month
            case "total": granularity = .total
            default: throw MCPError.message("period 必须是 today、week、month 或 total")
            }
            let timeZone = UsageStore.resolveTimeZone(UserDefaults.standard.string(forKey: "tokenTimeZone") ?? "")
            let loaded = await UsageStore.loadAllData(saveCache: false, timeZone: timeZone)
            let now = Date()
            var calendar = Calendar.current
            calendar.timeZone = timeZone
            let bucket = loaded.buckets[granularity]?.first { bucket in
                switch granularity {
                case .day: return calendar.isDate(bucket.startDate, inSameDayAs: now)
                case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.contains(bucket.startDate) == true
                case .month: return calendar.isDate(bucket.startDate, equalTo: now, toGranularity: .month)
                case .total: return true
                case .hour: return false
                }
            }
            let totals = bucket?.totalsByTool ?? [:]
            let rows: [[String: Any]] = Tool.allCases.compactMap { tool in
                guard let t = totals[tool] else { return nil }
                return ["tool": tool.rawValue, "inputTokens": t.inputTokens, "cacheReadTokens": t.cacheReadTokens, "cacheCreationTokens": t.cacheCreationTokens, "outputTokens": t.outputTokens, "reasoningTokens": t.reasoningTokens, "totalTokens": t.totalTokens]
            }
            return ["period": period, "timezone": timeZone.identifier, "generatedAt": ISO8601DateFormatter().string(from: now), "totalTokens": bucket?.combinedTotal ?? 0, "byTool": rows, "note": "基于本机可读取的记录；与账单不同。部分来源或记录可能不可用，DeepSeek 需要 zstd。"]
        case "list_ai_processes":
            try validate(arguments, allowed: [])
            let items = ProcessMonitor.scanProcesses().sorted { $0.memoryBytes > $1.memoryBytes }
            return ["generatedAt": ISO8601DateFormatter().string(from: Date()), "processes": items.map { ["pid": Int($0.pid), "ppid": Int($0.ppid), "name": $0.name, "tool": $0.tool.rawValue, "memoryBytes": $0.memoryBytes, "isMain": $0.isMain] as [String: Any] }]
        case "list_tasks":
            try validate(arguments, allowed: ["status"])
            let status = try string(arguments, key: "status") ?? "all"
            guard ["all", "pending", "completed"].contains(status) else { throw MCPError.message("status 必须是 all、pending 或 completed") }
            let url = TaskStore.defaultFileURL(fileManager: .default)
            guard FileManager.default.fileExists(atPath: url.path) else { return ["tasks": [], "note": "任务文件尚不存在；界面中尚未保存的编辑可能未包含在内。"] }
            let tasks = try JSONDecoder().decode([TaskItem].self, from: Data(contentsOf: url))
            let formatter = ISO8601DateFormatter()
            let rows = tasks.filter { status == "all" || ($0.isDone == (status == "completed")) }.map { task -> [String: Any] in
                ["id": task.id.uuidString, "title": task.title, "notes": task.notes, "isDone": task.isDone, "dueDate": task.dueDate.map { formatter.string(from: $0) } as Any? ?? NSNull(), "createdAt": formatter.string(from: task.createdAt), "completedAt": task.completedAt.map { formatter.string(from: $0) } as Any? ?? NSNull(), "order": task.order]
            }
            return ["tasks": rows, "note": "读取已保存的数据；界面中尚未保存的编辑可能未包含在内。"]
        case "list_devices", "get_device_info", "get_foreground_app", "capture_device_screen":
            try validate(arguments, allowed: name == "list_devices" ? [] : ["deviceId"])
            let service = try ADBService(requireSelectedDevice: true)
            if name == "list_devices" {
                let devices = try await service.listDevices()
                return ["devices": devices.map { ["id": $0.identifier.selectionKey, "serial": $0.serial, "bridge": $0.bridge.rawValue, "state": $0.state.rawValue, "model": $0.model as Any? ?? NSNull()] as [String: Any] }, "note": "设备列表由可用的 ADB/HDC 提供；桥接工具执行失败时现有服务可能返回空列表。"]
            }
            let device = try await resolveConnectedDevice(arguments: arguments, service: service)
            service.selectDevice(device)
            if name == "capture_device_screen" {
                let data = try await service.screenshot(for: device)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(source) as String?,
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                    throw MCPError.message("设备返回的截图不是有效图片")
                }
                let mimeType: String
                switch type {
                case "public.png": mimeType = "image/png"
                case "public.jpeg": mimeType = "image/jpeg"
                default: throw MCPError.message("设备返回了不支持的截图格式")
                }
                return ScreenImage(deviceId: device.identifier.selectionKey, data: data, mimeType: mimeType)
            }
            if name == "get_foreground_app" {
                return ["deviceId": device.identifier.selectionKey, "package": try await service.foregroundPackage() as Any? ?? NSNull()]
            }
            let info = try await service.deviceInfo()
            return ["deviceId": device.identifier.selectionKey, "manufacturer": info.manufacturer, "model": info.model, "systemVersion": info.systemVersion, "apiLevel": info.apiLevel, "resolution": info.resolution, "battery": info.battery, "storage": info.storage, "ipAddress": info.ipAddress]
        case "list_stetho_targets":
            try validate(arguments, allowed: ["deviceId"])
            let service = try ADBService(requireSelectedDevice: true)
            let device = try await resolveConnectedDevice(arguments: arguments, service: service)
            guard device.bridge == .adb else {
                throw MCPError.message("Stetho 仅支持 Android (ADB) 设备，不支持鸿蒙 (HDC) 设备")
            }
            let targets = try await StethoInspector.discoverTargets(device: device, adb: service)
            return [
                "deviceId": device.identifier.selectionKey,
                "deviceModel": device.model as Any? ?? NSNull(),
                "count": targets.count,
                "targets": targets.map { [
                    "processName": $0.processName,
                    "socketName": $0.socketName
                ] },
                "note": targets.isEmpty ? "未发现运行中的 Stetho 应用。请在手机上打开已集成 Stetho 的应用。" : "已发现 \(targets.count) 个 Stetho 应用"
            ]
        case "capture_stetho_requests":
            try validate(arguments, allowed: ["deviceId", "processName", "target", "duration", "maxRequests", "includeBody", "urlFilter"])
            let service = try ADBService(requireSelectedDevice: true)
            let device = try await resolveConnectedDevice(arguments: arguments, service: service)
            guard device.bridge == .adb else {
                throw MCPError.message("Stetho 抓包仅支持 Android (ADB) 设备，不支持鸿蒙 (HDC) 设备")
            }
            let target = try await resolveTarget(device: device, service: service, arguments: arguments)

            if activeInspector?.phase == .capturing {
                await stopCurrentSession()
            }

            let tempInspector = StethoInspector(device: device, adb: service)
            try await tempInspector.startAsync(target)

            let duration = min(max(try int(arguments, key: "duration") ?? 10, 1), 60)
            let maxRequests = min(max(try int(arguments, key: "maxRequests") ?? 50, 1), 200)
            let checkIntervalMs = 200
            let iterations = max(1, (duration * 1000) / checkIntervalMs)

            for _ in 0..<iterations {
                try await Task.sleep(for: .milliseconds(checkIntervalMs))
                if tempInspector.phase != .capturing || tempInspector.requests.count >= maxRequests {
                    break
                }
            }

            try? await Task.sleep(for: .milliseconds(300))

            var captured = tempInspector.requests
            if let filter = try string(arguments, key: "urlFilter"), !filter.isEmpty {
                captured = captured.filter { $0.url.localizedCaseInsensitiveContains(filter) }
            }

            let includeBody = try bool(arguments, key: "includeBody") ?? true
            if includeBody && tempInspector.phase == .capturing {
                for req in captured.prefix(30) where req.isFinished && req.body == .notLoaded && req.failure == nil {
                    _ = try? await tempInspector.loadBodyAsync(for: req.id)
                }
            }

            lastCapturedRequests = tempInspector.requests
            await tempInspector.stopAsync()
            tempInspector.close()

            let resultRows = captured.prefix(maxRequests).map { req in
                let current = lastCapturedRequests.first(where: { $0.id == req.id }) ?? req
                return includeBody ? current.detailDictionary() : current.summaryDictionary()
            }

            return [
                "deviceId": device.identifier.selectionKey,
                "processName": target.processName,
                "durationSeconds": duration,
                "totalCaptured": tempInspector.requests.count,
                "returnedCount": resultRows.count,
                "requests": resultRows,
                "note": "抓包已完成并断开连接。最近抓包记录已保存在内存中，后续可通过 get_stetho_requests 查看详情。"
            ]
        case "start_stetho_capture":
            try validate(arguments, allowed: ["deviceId", "processName", "target", "autoStopSeconds"])
            let service = try ADBService(requireSelectedDevice: true)
            let device = try await resolveConnectedDevice(arguments: arguments, service: service)
            guard device.bridge == .adb else {
                throw MCPError.message("Stetho 抓包仅支持 Android (ADB) 设备，不支持鸿蒙 (HDC) 设备")
            }
            let target = try await resolveTarget(device: device, service: service, arguments: arguments)

            await stopCurrentSession()

            let inspector = StethoInspector(device: device, adb: service)
            try await inspector.startAsync(target)

            activeInspector = inspector
            activeSessionDevice = device
            activeSessionTarget = target
            let startedAt = Date()
            activeSessionStartedAt = startedAt

            let autoStopSeconds = try int(arguments, key: "autoStopSeconds") ?? 120
            let clampedAutoStop = min(max(autoStopSeconds, 10), 600)
            activeSessionAutoStopTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(clampedAutoStop))
                if activeInspector === inspector {
                    await stopCurrentSession()
                }
            }

            return [
                "status": "capturing",
                "deviceId": device.identifier.selectionKey,
                "device": device.displayName,
                "processName": target.processName,
                "socketName": target.socketName,
                "appTitle": inspector.appTitle as Any? ?? NSNull(),
                "startedAt": ISO8601DateFormatter().string(from: startedAt),
                "autoStopSeconds": clampedAutoStop,
                "message": "Stetho 抓包会话已建立并正在监听网络请求。可调用 get_stetho_requests 查询请求摘要或详情；使用完毕后请调用 stop_stetho_capture 停止。"
            ]
        case "get_stetho_requests":
            try validate(arguments, allowed: ["requestId", "urlFilter", "statusFilter", "includeBody", "limit", "clear"])
            let inspector = activeInspector
            let sourceRequests = inspector?.requests ?? lastCapturedRequests
            guard !sourceRequests.isEmpty || inspector != nil else {
                throw MCPError.message("当前没有正在运行的抓包会话，也没有历史记录。请先调用 start_stetho_capture 或 capture_stetho_requests。")
            }

            if let requestId = try string(arguments, key: "requestId") {
                guard let request = sourceRequests.first(where: { $0.id.uuidString == requestId || $0.requestID == requestId }) else {
                    throw MCPError.message("未找到 ID 为 \(requestId) 的请求。")
                }
                let includeBody = try bool(arguments, key: "includeBody") ?? true
                if includeBody && inspector != nil && inspector?.phase == .capturing && request.body == .notLoaded && request.isFinished && request.failure == nil {
                    _ = try? await inspector?.loadBodyAsync(for: request.id)
                }
                let current = inspector?.requests.first(where: { $0.id == request.id }) ?? request
                return current.detailDictionary()
            }

            var list = sourceRequests
            if let urlFilter = try string(arguments, key: "urlFilter"), !urlFilter.isEmpty {
                list = list.filter { $0.url.localizedCaseInsensitiveContains(urlFilter) }
            }
            if let statusFilter = try string(arguments, key: "statusFilter") {
                switch statusFilter {
                case "success": list = list.filter { ($0.status ?? 0) >= 200 && ($0.status ?? 0) < 400 }
                case "failed": list = list.filter { $0.failure != nil || ($0.status ?? 0) >= 400 }
                case "pending": list = list.filter { !$0.isFinished && $0.failure == nil }
                case "all": break
                default: throw MCPError.message("statusFilter 必须是 all、success、failed 或 pending")
                }
            }

            let limit = min(max(try int(arguments, key: "limit") ?? 50, 1), 200)
            let paged = Array(list.suffix(limit))
            let includeBody = try bool(arguments, key: "includeBody") ?? false
            if includeBody && inspector != nil && inspector?.phase == .capturing {
                for req in paged where req.isFinished && req.body == .notLoaded && req.failure == nil {
                    _ = try? await inspector?.loadBodyAsync(for: req.id)
                }
            }

            let rows = paged.map { req -> [String: Any] in
                let current = inspector?.requests.first(where: { $0.id == req.id }) ?? req
                return includeBody ? current.detailDictionary() : current.summaryDictionary()
            }

            let shouldClear = try bool(arguments, key: "clear") ?? false
            if shouldClear {
                inspector?.clear()
                lastCapturedRequests.removeAll()
            }

            return [
                "isCapturing": inspector?.phase == .capturing,
                "totalCount": sourceRequests.count,
                "returnedCount": rows.count,
                "requests": rows
            ]
        case "stop_stetho_capture":
            try validate(arguments, allowed: [])
            guard activeInspector != nil else {
                return [
                    "status": "idle",
                    "message": "当前没有运行中的抓包会话",
                    "lastCapturedCount": lastCapturedRequests.count
                ]
            }
            let (_, count) = await stopCurrentSession()
            return [
                "status": "stopped",
                "totalCaptured": count,
                "message": "Stetho 抓包已停止，ADB 端口转发与调试连接已断开。"
            ]
        case "upload_to_pgyer", "upload_apk_to_pgyer":
            try validate(arguments, allowed: ["filePath", "path", "updateDescription", "installType", "password", "apiKey"])
            let rawPath = try (string(arguments, key: "filePath") ?? string(arguments, key: "path"))
            guard let rawPath, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.message("缺少 filePath 参数（请提供安装包文件路径）")
            }
            let expandedPath = (rawPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir), !isDir.boolValue else {
                throw MCPError.message("指定的文件不存在或不是有效文件：\(rawPath)")
            }
            let fileURL = URL(fileURLWithPath: expandedPath)
            let ext = fileURL.pathExtension.lowercased()
            guard PgyerService.supportedExtensions.contains(ext) else {
                let supported = PgyerService.supportedExtensions.sorted().joined(separator: ", ")
                throw MCPError.message("不支持的文件类型：.\(ext)。仅支持 \(supported) 文件。")
            }

            let apiKeyArgument = try string(arguments, key: "apiKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiKey: String
            if let apiKeyArgument, !apiKeyArgument.isEmpty {
                apiKey = apiKeyArgument
            } else if let savedKey = PgyerKeychain.load(), !savedKey.isEmpty {
                apiKey = savedKey
            } else {
                throw MCPError.message("未配置蒲公英 API Key。请在 HTools 应用中的「蒲公英分发」设置，或在调用参数中传入 apiKey。可在 https://www.pgyer.com/account/api 获取。")
            }

            let installTypeStr = try string(arguments, key: "installType") ?? "public"
            let installType: PgyerInstallType
            switch installTypeStr {
            case "public": installType = .public
            case "password": installType = .password
            case "invite": installType = .invite
            default: throw MCPError.message("installType 必须是 public、password 或 invite")
            }

            let password = try string(arguments, key: "password") ?? ""
            if installType == .password && password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MCPError.message("当 installType 为 password 时，必须提供 password 参数")
            }

            let updateDescription = try string(arguments, key: "updateDescription") ?? ""
            let options = PgyerService.Options(
                updateDescription: updateDescription,
                installType: installType,
                password: password
            )

            let build = try await PgyerService.upload(fileURL: fileURL, apiKey: apiKey, options: options) { _ in }
            var finalBuild = build
            finalBuild.uploadedAt = Date()
            finalBuild.localInstallType = options.installType.rawValue
            finalBuild.localPassword = options.installType == .password ? options.password : nil
            finalBuild.localUpdateDescription = options.updateDescription
            finalBuild.localFileName = fileURL.lastPathComponent
            finalBuild.localFileSizeBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

            PgyerUploader.recordBuildToHistory(finalBuild)

            return [
                "success": true,
                "appName": finalBuild.buildName as Any? ?? NSNull(),
                "version": finalBuild.buildVersion as Any? ?? NSNull(),
                "buildVersionNo": finalBuild.buildVersionNo as Any? ?? NSNull(),
                "displayVersion": finalBuild.displayVersion,
                "platform": finalBuild.platform.rawValue,
                "fileSize": finalBuild.formattedFileSize,
                "downloadURL": finalBuild.downloadURL?.absoluteString as Any? ?? NSNull(),
                "fixedURL": finalBuild.fixedURL?.absoluteString as Any? ?? NSNull(),
                "shortcutURL": finalBuild.shortcutURL?.absoluteString as Any? ?? NSNull(),
                "qrCodeURL": finalBuild.qrCodeURL?.absoluteString as Any? ?? NSNull(),
                "iconURL": finalBuild.iconURL?.absoluteString as Any? ?? NSNull(),
                "buildKey": finalBuild.buildKey as Any? ?? NSNull(),
                "installType": finalBuild.installTypeDescription,
                "updateDescription": finalBuild.localUpdateDescription as Any? ?? NSNull(),
                "shareText": finalBuild.shareText
            ]
        default: throw MCPError.message("未知工具：\(name)")
        }
    }

    private static func validate(_ arguments: [String: Any], allowed: Set<String>) throws {
        guard Set(arguments.keys).isSubset(of: allowed) else { throw MCPError.message("存在不支持的参数") }
    }

    private static func string(_ arguments: [String: Any], key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let value = value as? String else { throw MCPError.message("\(key) 必须是字符串") }
        return value
    }

    private static func int(_ arguments: [String: Any], key: String) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        if let num = value as? Int { return num }
        if let num = value as? NSNumber { return num.intValue }
        if let str = value as? String, let num = Int(str) { return num }
        throw MCPError.message("\(key) 必须是整数")
    }

    private static func bool(_ arguments: [String: Any], key: String) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        if let b = value as? Bool { return b }
        if let num = value as? NSNumber { return num.boolValue }
        if let str = value as? String {
            let lower = str.lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
        }
        throw MCPError.message("\(key) 必须是布尔值")
    }

    private static var activeInspector: StethoInspector?
    private static var activeSessionDevice: ADBDevice?
    private static var activeSessionTarget: StethoTarget?
    private static var activeSessionStartedAt: Date?
    private static var activeSessionAutoStopTask: Task<Void, Never>?
    private static var lastCapturedRequests: [StethoRequest] = []

    private static func resolveConnectedDevice(arguments: [String: Any], service: ADBService) async throws -> ADBDevice {
        let devices = try await service.listDevices()
        let connected = devices.filter { $0.state == .device }
        let deviceId = try string(arguments, key: "deviceId")
        if let deviceId {
            guard let match = connected.first(where: { $0.identifier.selectionKey == deviceId }) else {
                throw MCPError.message("指定设备未连接或不可用：\(deviceId)")
            }
            return match
        }
        guard connected.count == 1, let only = connected.first else {
            throw MCPError.message(connected.isEmpty ? "没有已连接设备" : "存在多台设备，请指定 deviceId")
        }
        return only
    }

    private static func resolveTarget(
        device: ADBDevice,
        service: ADBService,
        arguments: [String: Any]
    ) async throws -> StethoTarget {
        let targets = try await StethoInspector.discoverTargets(device: device, adb: service)
        guard !targets.isEmpty else {
            throw MCPError.message("在设备 \(device.displayName) 上未发现运行中的 Stetho 应用。请在手机上打开已集成 Stetho 的应用后重试。")
        }
        let requested = try (string(arguments, key: "processName") ?? string(arguments, key: "target"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty {
            if let matched = targets.first(where: {
                $0.processName == requested || $0.socketName == requested || $0.processName.localizedCaseInsensitiveContains(requested)
            }) {
                return matched
            }
            let available = targets.map { $0.processName }.joined(separator: ", ")
            throw MCPError.message("未找到匹配的目标应用：\(requested)。当前可抓包的应用：\(available)")
        }
        if targets.count == 1, let only = targets.first {
            return only
        }
        service.selectDevice(device)
        if let foreground = try? await service.foregroundPackage(),
           let matched = targets.first(where: { $0.processName == foreground }) {
            return matched
        }
        let available = targets.map { $0.processName }.joined(separator: ", ")
        throw MCPError.message("发现多个 Stetho 应用：\(available)。请通过 processName 参数指定要抓包的应用。")
    }

    @discardableResult
    private static func stopCurrentSession() async -> (inspector: StethoInspector?, count: Int) {
        activeSessionAutoStopTask?.cancel()
        activeSessionAutoStopTask = nil
        guard let inspector = activeInspector else { return (nil, 0) }
        lastCapturedRequests = inspector.requests
        let count = inspector.requests.count
        await inspector.stopAsync()
        inspector.close()
        activeInspector = nil
        activeSessionDevice = nil
        activeSessionTarget = nil
        activeSessionStartedAt = nil
        return (inspector, count)
    }

    private static func send(id: Any, result: [String: Any]) { write(["jsonrpc": "2.0", "id": id, "result": result]) }
    private static func sendError(id: Any, code: Int, message: String) { write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }
    private static func write(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    private struct ScreenImage {
        let deviceId: String
        let data: Data
        let mimeType: String
    }

    private enum MCPError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
