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
        ["name": "capture_device_screen", "description": "截取已连接手机的当前屏幕并返回图片。", "inputSchema": deviceSchema]
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
                        guard MCPSettings.isEnabled(name) else { throw MCPError.message("该工具已在 HTools 的 MCP 管理中关闭") }
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
            let devices = try await service.listDevices()
            if name == "list_devices" {
                return ["devices": devices.map { ["id": $0.identifier.selectionKey, "serial": $0.serial, "bridge": $0.bridge.rawValue, "state": $0.state.rawValue, "model": $0.model as Any? ?? NSNull()] as [String: Any] }, "note": "设备列表由可用的 ADB/HDC 提供；桥接工具执行失败时现有服务可能返回空列表。"]
            }
            let deviceId = try string(arguments, key: "deviceId")
            let connected = devices.filter { $0.state == .device }
            let device: ADBDevice
            if let deviceId {
                guard let match = connected.first(where: { $0.identifier.selectionKey == deviceId }) else { throw MCPError.message("指定设备未连接或不可用") }
                device = match
            } else {
                guard connected.count == 1, let only = connected.first else { throw MCPError.message(connected.isEmpty ? "没有已连接设备" : "存在多台设备，请指定 deviceId") }
                device = only
            }
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
