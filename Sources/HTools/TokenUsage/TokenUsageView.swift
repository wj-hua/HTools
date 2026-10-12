import Charts
import SwiftUI

struct TokenUsageView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("tokenGranularity") private var granularity: Granularity = .day
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var buckets: [UsageBucket] {
        store.buckets(for: granularity)
    }

    private var tools: [Tool] {
        Tool.allCases.filter { store.availableTools.contains($0) }
    }

    var body: some View {
        Group {
            if store.events.isEmpty {
                if store.isRefreshing {
                    ProgressView("正在扫描本地 Token 日志…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("暂无 Token 消耗数据", systemImage: "chart.bar.doc.horizontal")
                    } description: {
                        Text("支持 Claude Code、Codex、agy、pi、ZCode、StepCode 的本地日志")
                    } actions: {
                        Button("重新扫描") { store.refresh() }
                    }
                }
            } else {
                content
            }
        }
        .navigationTitle("Token 用量")
        .navigationSubtitle(lastRefreshedText)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("统计周期", selection: $granularity) {
                    ForEach(Granularity.allCases) { g in
                        Text(g.rawValue).tag(g)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeating, isActive: store.isRefreshing)
                }
                .help("重新扫描本地日志")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        // 页面可见且 App 在前台时，数据超过 1 分钟就自动重新扫描；
        // 未变化的日志文件走缓存，只解析新增内容。
        .task {
            while !Task.isCancelled {
                if NSApp.isActive { store.refreshIfStale() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfStale()
        }
    }

    private var lastRefreshedText: String {
        if store.isRefreshing { return "正在同步…" }
        guard let date = store.lastRefreshed else { return "" }
        return "同步于 \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var content: some View {
        let bucket = currentBucket
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                overviewCard(bucket)
                if granularity != .total {
                    trendCard
                }
                toolGrid(bucket)
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: granularity)
    }

    // MARK: - 概览

    private func overviewCard(_ bucket: UsageBucket) -> some View {
        let total = bucket.combinedTotal
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(periodTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        BigNumber(text: TokenFormat.string(total), unit: "tokens", size: 40)
                        Text(bucket.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let top = sortedTools(in: bucket).first, total > 0,
                       let topTotal = bucket.totalsByTool[top]?.totalTokens, topTotal > 0 {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text("主力工具")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                IconTile(image: top.logo, tint: top.accentColor, size: 28)
                                Text(top.rawValue)
                                    .font(.title3.weight(.semibold))
                            }
                            Text("占 \(TokenFormat.percentage(value: topTotal, total: total))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                if total > 0 {
                    ProportionBar(
                        segments: tools.map { tool in
                            .init(
                                id: tool.id,
                                color: tool.accentColor,
                                value: Double(bucket.totalsByTool[tool]?.totalTokens ?? 0)
                            )
                        },
                        height: 10
                    )

                    HStack(spacing: 16) {
                        ForEach(sortedTools(in: bucket)) { tool in
                            let amount = bucket.totalsByTool[tool]?.totalTokens ?? 0
                            if amount > 0 {
                                HStack(spacing: 5) {
                                    Circle().fill(tool.accentColor).frame(width: 7, height: 7)
                                    Text(tool.shortName)
                                        .foregroundStyle(.secondary)
                                    Text(TokenFormat.percentage(value: amount, total: total))
                                        .monospacedDigit()
                                }
                                .font(.caption)
                            }
                        }
                    }
                } else {
                    Text("当前周期暂无模型 Token 消耗")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 趋势

    private struct TrendPoint: Identifiable {
        let id: String
        let date: Date
        let tool: Tool
        let tokens: Int
    }

    private var trendPoints: [TrendPoint] {
        let limit: Int
        switch granularity {
        case .hour: limit = 24
        case .day: limit = 14
        case .week, .month: limit = 12
        case .total: limit = 0
        }
        return buckets.prefix(limit).reversed().flatMap { bucket in
            tools.compactMap { tool -> TrendPoint? in
                guard let amount = bucket.totalsByTool[tool]?.totalTokens, amount > 0 else { return nil }
                return TrendPoint(id: "\(bucket.id)-\(tool.id)", date: bucket.startDate, tool: tool, tokens: amount)
            }
        }
    }

    private var chartUnit: Calendar.Component {
        switch granularity {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month, .total: return .month
        }
    }

    private var trendCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("趋势", systemImage: "chart.bar.fill") {
                    Text("最近 \(Set(trendPoints.map(\.date)).count) 个\(granularity.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Chart(trendPoints) { point in
                    BarMark(
                        x: .value("时间", point.date, unit: chartUnit),
                        y: .value("Tokens", point.tokens)
                    )
                    .foregroundStyle(by: .value("工具", point.tool.rawValue))
                    .cornerRadius(3)
                }
                .chartForegroundStyleScale(
                    domain: tools.map(\.rawValue),
                    range: tools.map(\.accentColor)
                )
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) {
                                Text(TokenFormat.string(tokens))
                            }
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .frame(height: 220)
            }
        }
    }

    // MARK: - 各工具明细

    private func toolGrid(_ bucket: UsageBucket) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
            ForEach(sortedTools(in: bucket)) { tool in
                ToolUsageCard(
                    tool: tool,
                    totals: bucket.totalsByTool[tool] ?? ToolTotals(),
                    periodTotal: bucket.combinedTotal
                )
            }
        }
    }

    private func sortedTools(in bucket: UsageBucket) -> [Tool] {
        tools.sorted { t1, t2 in
            let c1 = bucket.totalsByTool[t1]?.totalTokens ?? 0
            let c2 = bucket.totalsByTool[t2]?.totalTokens ?? 0
            return c1 != c2 ? c1 > c2 : t1.rawValue < t2.rawValue
        }
    }

    // MARK: - 当前周期

    private var periodTitle: String {
        switch granularity {
        case .hour: return "本小时消耗"
        case .day: return "今日消耗"
        case .week: return "本周消耗"
        case .month: return "本月消耗"
        case .total: return "历史累计消耗"
        }
    }

    private var currentBucket: UsageBucket {
        store.currentBucket(for: granularity)
    }
}

private struct ToolUsageCard: View {
    let tool: Tool
    let totals: ToolTotals
    let periodTotal: Int

    private var isActive: Bool { totals.totalTokens > 0 }
    private var share: Double {
        periodTotal > 0 ? Double(totals.totalTokens) / Double(periodTotal) : 0
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconTile(image: tool.logo, tint: tool.accentColor, size: 32, isActive: isActive)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.rawValue)
                            .font(.headline)
                        Text(isActive ? "占本期 \(TokenFormat.percentage(value: totals.totalTokens, total: periodTotal))" : "本期未使用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(TokenFormat.string(totals.totalTokens))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .contentTransition(.numericText())
                }

                ProgressView(value: share)
                    .progressViewStyle(.linear)
                    .tint(tool.accentColor)

                if isActive {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            MetricCell(label: "输入", value: TokenFormat.string(totals.inputTokens), tint: tool.accentColor)
                            MetricCell(label: "输出", value: TokenFormat.string(totals.outputTokens), tint: .indigo)
                            MetricCell(label: "思考", value: TokenFormat.string(totals.reasoningTokens), tint: .purple)
                        }
                        GridRow {
                            MetricCell(label: "缓存读取", value: TokenFormat.string(totals.cacheReadTokens), tint: .teal)
                            MetricCell(label: "缓存写入", value: TokenFormat.string(totals.cacheCreationTokens), tint: .orange)
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
        .opacity(isActive ? 1 : 0.7)
    }
}
