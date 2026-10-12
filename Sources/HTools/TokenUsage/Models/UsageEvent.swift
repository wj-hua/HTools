import Foundation

/// A single token-consuming turn from one of the tracked tools.
struct UsageEvent: Codable {
    let tool: Tool
    let date: Date
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int

    /// The tool's own identifier for the request that produced this turn, when it
    /// exposes one. Used to drop repeats when a tool copies an entry into a second
    /// file (StepCode's `/fork` and `/clone` do) so the same request is not counted
    /// twice.
    let requestID: String?

    init(
        tool: Tool,
        date: Date,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        requestID: String? = nil
    ) {
        self.tool = tool
        self.date = date
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.requestID = requestID
    }

    var totalTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens + outputTokens + reasoningTokens
    }
}

/// Aggregated totals for one tool within a bucket (an hour, a day, a whole range, ...).
struct ToolTotals {
    var inputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0

    var totalTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens + outputTokens + reasoningTokens
    }

    mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheCreationTokens += event.cacheCreationTokens
        outputTokens += event.outputTokens
        reasoningTokens += event.reasoningTokens
    }
}

/// One row in the aggregated usage list: a time bucket with per-tool totals.
struct UsageBucket: Identifiable {
    let id: String
    let label: String
    let startDate: Date
    var totalsByTool: [Tool: ToolTotals] = [:]

    var combinedTotal: Int {
        totalsByTool.values.reduce(0) { $0 + $1.totalTokens }
    }
}
