import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published var events: [UsageEvent] = []
    @Published var isRefreshing = false
    @Published var lastRefreshed: Date?
    @Published var availableTools: Set<Tool> = []
    @Published private(set) var bucketsByGranularity: [Granularity: [UsageBucket]] = [:]

    func buckets(for granularity: Granularity) -> [UsageBucket] {
        bucketsByGranularity[granularity] ?? []
    }

    /// A scan already in progress is not restarted: the detached parsing work cannot
    /// be cancelled anyway, and its result is at most a few seconds old.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let (resultEvents, resultTools, resultBuckets) = await Self.loadAllData()
            self.events = resultEvents
            self.availableTools = resultTools
            self.bucketsByGranularity = resultBuckets
            self.lastRefreshed = Date()
            self.isRefreshing = false
            if ProcessInfo.processInfo.environment["USEDTOKEN_DEBUG_DUMP"] != nil {
                Self.debugDump(resultEvents)
            }
        }
    }

    /// Refreshes only when the data is older than `maxAge`. Cheap to call often:
    /// unchanged files are served from `UsageFileCache`.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < maxAge { return }
        refresh()
    }

    private static func loadAllData() async -> (events: [UsageEvent], tools: Set<Tool>, buckets: [Granularity: [UsageBucket]]) {
        await Task.detached(priority: .userInitiated) {
            var all: [UsageEvent] = []
            all.append(contentsOf: ClaudeCodeParser.parseAll())
            all.append(contentsOf: CodexParser.parseAll())
            all.append(contentsOf: AgyParser.parseAll())
            all.append(contentsOf: PiParser.parseAll())
            all.append(contentsOf: ZCodeParser.parseAll())
            all.append(contentsOf: StepCodeParser.parseAll())
            UsageFileCache.shared.save()

            // StepCode forks copy a branch's entries into a second session file, so the
            // same request can arrive twice. Drop the repeats before bucketing.
            var seenRequestIDs = Set<String>()
            all = all.filter { event in
                guard let requestID = event.requestID else { return true }
                return seenRequestIDs.insert(requestID).inserted
            }

            var buckets: [Granularity: [UsageBucket]] = [:]
            for g in Granularity.allCases {
                buckets[g] = UsageAggregator.buckets(for: all, granularity: g)
            }

            let tools = Set(all.map(\.tool))
            return (all, tools, buckets)
        }.value
    }

    private static func debugDump(_ events: [UsageEvent]) {
        print("== events by tool ==")
        for tool in Tool.allCases {
            let toolEvents = events.filter { $0.tool == tool }
            let total = toolEvents.reduce(0) { $0 + $1.totalTokens }
            print("\(tool.rawValue): \(toolEvents.count) events, \(total) tokens")
        }
        for g in Granularity.allCases {
            print("-- \(g.rawValue) --")
            for bucket in UsageAggregator.buckets(for: events, granularity: g).prefix(5) {
                print("  \(bucket.label): \(bucket.combinedTotal) (" +
                      bucket.totalsByTool.map { "\($0.key.rawValue)=\($0.value.totalTokens)" }.joined(separator: ", ") + ")")
            }
        }
        exit(0)
    }
}
