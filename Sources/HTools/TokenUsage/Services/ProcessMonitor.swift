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

    private var monitorTask: Task<Void, Never>?
    private var isMonitoring: Bool = false

    init() {
        // Initialize with empty summaries for all tools
        var initial: [Tool: ToolProcessSummary] = [:]
        for tool in Tool.allCases {
            initial[tool] = ToolProcessSummary(tool: tool, processes: [])
        }
        self.summaries = initial
    }

    func startMonitoring(interval: TimeInterval = 3.0) {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshAsync()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        monitorTask?.cancel()
        monitorTask = nil
    }

    func refresh() {
        Task { [weak self] in
            await self?.refreshAsync()
        }
    }

    func terminateProcess(pid: pid_t) {
        Darwin.kill(pid, SIGTERM)
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Darwin.kill(pid, 0) == 0 {
                Darwin.kill(pid, SIGKILL)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await self.refreshAsync()
        }
    }

    func terminateAllProcesses(for tool: Tool) {
        guard let summary = summaries[tool], !summary.processes.isEmpty else { return }
        let pids = summary.processes.map(\.pid)
        for pid in pids {
            Darwin.kill(pid, SIGTERM)
        }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            for pid in pids {
                if Darwin.kill(pid, 0) == 0 {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await self.refreshAsync()
        }
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
        var pids = [pid_t](repeating: 0, count: 4096)
        let numPids = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard numPids > 0 else { return [] }

        let currentUid = getuid()
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        var bsdInfo = proc_bsdinfo()
        var taskInfo = proc_taskinfo()

        var results: [ToolProcessItem] = []

        for i in 0..<Int(numPids) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            // 1. Check process ownership (only current user's processes)
            let bsdLen = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard bsdLen > 0, bsdInfo.pbi_uid == currentUid else { continue }

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
            } else if binaryName == "pi" || binaryName == "pi-rpc" {
                matchedTool = .pi
                displayName = binaryName
            } else if binaryName == "zcode" || binaryName == "zcode-cli" {
                matchedTool = .zcode
                displayName = binaryName
            } else if binaryName.hasPrefix("zcode helper") || binaryName == "zcode-node-repl-mcp" || binaryName.hasPrefix("zcode-host-") {
                matchedTool = .zcode
                displayName = binaryName
                isMain = false
            } else if binaryName == "step" {
                matchedTool = .stepcode
                displayName = "step"
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
                        } else if lower.hasSuffix("/pi") || lower.hasSuffix("/pi.js") || lower.contains("@earendil-works/pi-coding-agent") {
                            matchedTool = .pi
                            displayName = "\(binaryName) (pi)"
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
                        } else if lower.hasSuffix("/step") || lower.contains("/stepcode/") {
                            matchedTool = .stepcode
                            displayName = "\(binaryName) (step)"
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
