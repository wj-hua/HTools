import Foundation
import Combine
import Darwin

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published var summaries: [Tool: ToolProcessSummary] = [:]
    @Published var totalProcessCount: Int = 0
    @Published var totalMemoryBytes: UInt64 = 0
    @Published var activeToolCount: Int = 0
    @Published var isScanning: Bool = false
    @Published var lastUpdated: Date?
    @Published private(set) var terminatingPIDs: Set<pid_t> = []
    @Published var terminationError: String?

    /// 页面可见时 3 秒刷新；离开页面后降到 30 秒一次，只为让侧边栏角标保持大致准确。
    static let foregroundInterval: TimeInterval = 3
    static let backgroundInterval: TimeInterval = 30

    private var monitorTask: Task<Void, Never>?
    private var monitorInterval: TimeInterval?

    init() {
        // Initialize with empty summaries for all tools
        var initial: [Tool: ToolProcessSummary] = [:]
        for tool in Tool.allCases {
            initial[tool] = ToolProcessSummary(tool: tool, processes: [])
        }
        self.summaries = initial
    }

    /// 以指定间隔轮询；已在以相同间隔轮询时不重复启动，换间隔时立即刷新一次。
    func startMonitoring(interval: TimeInterval) {
        guard monitorInterval != interval else { return }
        monitorInterval = interval
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshAsync()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func refresh() {
        Task { [weak self] in
            await self?.refreshAsync()
        }
    }

    func terminateProcess(pid: pid_t) {
        terminateProcesses(pids: [pid])
    }

    func terminateAllProcesses(for tool: Tool) {
        // 点击时重新扫描，避免漏掉上次刷新后启动的包装器或后台进程。
        let pids = Self.scanProcesses().filter { $0.tool == tool }.map(\.pid)
        terminateProcesses(pids: pids)
    }

    private func terminateProcesses(pids: [pid_t]) {
        let targets = Self.processTree(rootPIDs: pids).filter {
            !terminatingPIDs.contains($0.pid)
        }
        guard !targets.isEmpty else {
            refresh()
            return
        }
        let targetPIDs = Set(targets.map(\.pid))
        terminatingPIDs.formUnion(targetPIDs)
        terminationError = nil

        Task {
            defer { terminatingPIDs.subtract(targetPIDs) }
            var failures: [pid_t: String] = [:]
            for target in targets {
                if let error = Self.sendSignal(SIGTERM, to: target) {
                    failures[target.pid] = error
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            for target in targets {
                if let error = Self.sendSignal(SIGKILL, to: target) {
                    failures[target.pid] = error
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let remaining = targets.filter { Self.isSameProcess($0) }
            if !remaining.isEmpty {
                terminationError = remaining.map {
                    "PID \($0.pid)：\(failures[$0.pid] ?? "进程仍在运行，请重试")"
                }.joined(separator: "\n")
            }
            await refreshAsync()
        }
    }

    private struct ProcessTarget {
        let pid: pid_t
        let parentPID: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    nonisolated private static func processInfo(pid: pid_t) -> proc_bsdinfo? {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        let length = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                  Int32(MemoryLayout<proc_bsdinfo>.size))
        guard length == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
        return info
    }

    nonisolated private static func processTree(rootPIDs: [pid_t]) -> [ProcessTarget] {
        let processes = allProcessIDs().compactMap { pid -> ProcessTarget? in
            guard let info = processInfo(pid: pid) else { return nil }
            return ProcessTarget(pid: pid, parentPID: pid_t(info.pbi_ppid),
                                 startSeconds: info.pbi_start_tvsec,
                                 startMicroseconds: info.pbi_start_tvusec)
        }
        var selected = Set(rootPIDs)
        var targets = processes.filter { selected.contains($0.pid) }
        // 只沿子进程方向查找，不能结束启动 Cline 的终端或编辑器。
        // 先保存整个进程树，父进程退出后子进程的 PPID 会改变。
        while true {
            let children = processes.filter {
                selected.contains($0.parentPID) && !selected.contains($0.pid)
            }
            guard !children.isEmpty else { break }
            targets.append(contentsOf: children)
            selected.formUnion(children.map(\.pid))
        }
        return targets
    }

    nonisolated private static func isSameProcess(_ target: ProcessTarget) -> Bool {
        guard let info = processInfo(pid: target.pid) else { return false }
        // 延迟强制结束前核对启动时间，防止 PID 被其他进程复用。
        return info.pbi_start_tvsec == target.startSeconds
            && info.pbi_start_tvusec == target.startMicroseconds
    }

    nonisolated private static func sendSignal(_ signal: Int32, to target: ProcessTarget) -> String? {
        guard isSameProcess(target) else { return nil }
        guard Darwin.kill(target.pid, signal) != 0 else { return nil }
        let code = errno
        return code == ESRCH ? nil : String(cString: strerror(code))
    }

    private func refreshAsync() async {
        isScanning = true
        let items = await Task.detached(priority: .userInitiated) {
            Self.scanProcesses()
        }.value

        guard !Task.isCancelled else {
            isScanning = false
            return
        }

        var newSummaries: [Tool: ToolProcessSummary] = [:]
        var count = 0
        var mem: UInt64 = 0
        var activeTools = 0

        for tool in Tool.allCases {
            let toolItems = items.filter { $0.tool == tool }
                .sorted { $0.memoryBytes > $1.memoryBytes }
            let summary = ToolProcessSummary(tool: tool, processes: toolItems)
            newSummaries[tool] = summary
            count += summary.processCount
            mem += summary.totalMemoryBytes
            if summary.isRunning {
                activeTools += 1
            }
        }

        self.summaries = newSummaries
        self.totalProcessCount = count
        self.totalMemoryBytes = mem
        self.activeToolCount = activeTools
        self.lastUpdated = Date()
        self.isScanning = false
    }

    // MARK: - Process Scanning (Darwin Low-Level APIs)

    nonisolated private static func scanProcesses() -> [ToolProcessItem] {
        let pids = allProcessIDs()
        let currentUid = getuid()
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        var taskInfo = proc_taskinfo()

        var results: [ToolProcessItem] = []

        for pid in pids {
            guard pid > 0 else { continue }

            // 1. Check process ownership (only current user's processes)
            guard let bsdInfo = processInfo(pid: pid), bsdInfo.pbi_uid == currentUid else { continue }

            // 2. Query binary path
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLen > 0 else { continue }
            let execPath = String(cString: pathBuffer)
            let binaryName = (execPath as NSString).lastPathComponent.lowercased()

            var matchedTool: Tool?
            var displayName: String = binaryName
            var isMain = true

            // 原生安装的 Claude Code 实际可执行文件是 .../claude/versions/<版本号>，
            // 进程名是版本号（如 2.1.295），~/.local/bin/claude 只是指向它的符号链接。
            if binaryName == "claude" || execPath.contains("/claude/versions/") {
                matchedTool = .claude
                displayName = "claude"
            } else if binaryName == "codex" {
                matchedTool = .codex
                displayName = "codex"
            } else if binaryName == "codex-code-mode-host" {
                matchedTool = .codex
                displayName = "codex-code-mode-host"
                isMain = false
            } else if binaryName == "agy" {
                matchedTool = .agy
                displayName = "agy"
            } else if binaryName == "cline" || binaryName == ".cline" || binaryName == "cline-core" {
                matchedTool = .cline
                displayName = "cline"
                if let args = getProcessArguments(pid: pid), args.contains("--cline-hub-daemon") {
                    displayName = "cline (hub)"
                    isMain = false
                } else if binaryName == "cline-core" {
                    isMain = false
                }
            } else if isScriptInterpreter(binaryName) {
                // Script interpreter: inspect process arguments
                if let args = getProcessArguments(pid: pid), args.count > 1 {
                    for arg in args.dropFirst() {
                        let lower = arg.lowercased()
                        if lower.hasSuffix("/codex") || lower.hasSuffix("/codex.js") || lower.contains("@openai/codex") {
                            matchedTool = .codex
                            displayName = "\(binaryName) (codex)"
                            isMain = false
                            break
                        } else if lower.hasSuffix("/claude") || lower.hasSuffix("/claude.js") || lower.contains("@anthropic-ai/claude-code") {
                            matchedTool = .claude
                            displayName = "\(binaryName) (claude)"
                            isMain = false
                            break
                        } else if lower.hasSuffix("/agy") || lower.contains("/antigravity-cli/") {
                            matchedTool = .agy
                            displayName = "\(binaryName) (agy)"
                            isMain = false
                            break
                        } else if lower.hasSuffix("/cline") || lower.hasSuffix("/cline.js") || lower.contains("/node_modules/cline/") || lower.contains("/node_modules/@cline/") {
                            matchedTool = .cline
                            displayName = "\(binaryName) (cline)"
                            isMain = false
                            break
                        }
                    }
                }
            }

            guard let tool = matchedTool else { continue }

            // 3. Query resident memory
            var memoryBytes: UInt64 = 0
            let taskLen = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            if taskLen > 0 {
                memoryBytes = taskInfo.pti_resident_size
            }

            results.append(
                ToolProcessItem(
                    pid: pid,
                    ppid: pid_t(bsdInfo.pbi_ppid),
                    name: displayName,
                    path: execPath,
                    memoryBytes: memoryBytes,
                    tool: tool,
                    isMain: isMain
                )
            )
        }

        return results
    }

    nonisolated private static func allProcessIDs() -> [pid_t] {
        // proc_listallpids 返回 PID 数量，预留余量以容纳扫描期间启动的进程。
        let capacity = Int(proc_listallpids(nil, 0)) + 128
        guard capacity > 128 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count)))
    }

    nonisolated private static func isScriptInterpreter(_ name: String) -> Bool {
        switch name {
        case "node", "bun", "deno", "python", "python3", "sh", "bash", "zsh":
            return true
        default:
            return false
        }
    }

    nonisolated private static func getProcessArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }

        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }

        let argc = Int(data.withUnsafeBytes { $0.load(as: Int32.self) })
        var offset = 4

        // Skip executable path
        guard let execEnd = data[offset...].firstIndex(of: 0) else { return nil }
        offset = execEnd
        while offset < data.count && data[offset] == 0 {
            offset += 1
        }

        var args: [String] = []
        for _ in 0..<argc {
            guard offset < data.count else { break }
            if let argEnd = data[offset...].firstIndex(of: 0) {
                let argString = String(decoding: data[offset..<argEnd], as: UTF8.self)
                args.append(argString)
                offset = argEnd + 1
            } else {
                let argString = String(decoding: data[offset...], as: UTF8.self)
                args.append(argString)
                break
            }
        }
        return args
    }
}
