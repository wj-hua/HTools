import Foundation

struct ToolProcessItem: Identifiable, Equatable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let path: String
    let memoryBytes: UInt64
    let tool: Tool
    let isMain: Bool

    var id: pid_t { pid }

    var formattedMemory: String {
        MemoryFormat.string(memoryBytes)
    }

    init(
        pid: pid_t,
        ppid: pid_t,
        name: String,
        path: String,
        memoryBytes: UInt64,
        tool: Tool,
        isMain: Bool = true
    ) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.memoryBytes = memoryBytes
        self.tool = tool
        self.isMain = isMain
    }
}

struct ToolProcessSummary: Identifiable, Equatable {
    let tool: Tool
    let processes: [ToolProcessItem]

    var id: String { tool.id }

    var processCount: Int {
        processes.count
    }

    var totalMemoryBytes: UInt64 {
        processes.reduce(0) { $0 + $1.memoryBytes }
    }

    var formattedMemory: String {
        MemoryFormat.string(totalMemoryBytes)
    }

    var isRunning: Bool {
        !processes.isEmpty
    }

    init(tool: Tool, processes: [ToolProcessItem] = []) {
        self.tool = tool
        self.processes = processes
    }
}
