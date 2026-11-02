import SwiftUI

struct ProcessesView: View {
    @ObservedObject var monitor: ProcessMonitor
    @StateObject private var systemMonitor = SystemProcessMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 已展开的工具（逗号分隔的 Tool.id）。默认为空，即全部收起；持久化以便下次打开保持原样。
    @AppStorage("expandedProcessTools") private var expandedRaw = ""

    private var expandedTools: Set<String> {
        Set(expandedRaw.split(separator: ",").map(String.init))
    }

    private func setExpanded(_ expanded: Bool, for id: String) {
        var current = expandedTools
        if expanded { current.insert(id) } else { current.remove(id) }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard) {
            expandedRaw = current.sorted().joined(separator: ",")
        }
    }

    private var runningSummaries: [ToolProcessSummary] {
        Tool.allCases
            .compactMap { monitor.summaries[$0] }
            .filter(\.isRunning)
            .sorted { $0.totalMemoryBytes > $1.totalMemoryBytes }
    }

    private var idleTools: [Tool] {
        Tool.allCases.filter { !(monitor.summaries[$0]?.isRunning ?? false) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                overview

                SystemProcessCard(monitor: systemMonitor)

                Text("AI 编码工具")
                    .font(.headline)
                    .padding(.top, 4)

                if runningSummaries.isEmpty {
                    Card {
                        ContentUnavailableView(
                            "没有正在运行的 AI 编码工具",
                            systemImage: "moon.zzz",
                            description: Text("启动 Claude Code、Codex 等工具后，这里会每 3 秒自动刷新。")
                        )
                    }
                } else {
                    ForEach(runningSummaries) { summary in
                        ToolProcessCard(
                            summary: summary,
                            totalMemory: monitor.totalMemoryBytes,
                            monitor: monitor,
                            isExpanded: expandedTools.contains(summary.id),
                            onToggle: { setExpanded(!expandedTools.contains(summary.id), for: summary.id) }
                        )
                        .transition(.opacity)
                    }
                }

                if !idleTools.isEmpty {
                    idleRow
                }
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: runningSummaries.map(\.id))
        }
        .navigationTitle("进程与内存")
        .navigationSubtitle(monitor.lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .standard))" } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    monitor.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("立即刷新进程列表")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .alert("结束进程失败", isPresented: Binding(
            get: { monitor.terminationError != nil },
            set: { if !$0 { monitor.terminationError = nil } }
        )) {
            Button("确定") { monitor.terminationError = nil }
        } message: {
            Text(monitor.terminationError ?? "")
        }
        // 页面可见时高频轮询，离开页面后降频，只维持侧边栏角标。
        .onAppear { monitor.startMonitoring(interval: ProcessMonitor.foregroundInterval) }
        .onDisappear { monitor.startMonitoring(interval: ProcessMonitor.backgroundInterval) }
        .task {
            while !Task.isCancelled {
                await systemMonitor.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var overview: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    stat("AI 工具内存 (RSS)", BigNumber(text: MemoryFormat.string(monitor.totalMemoryBytes), size: 34))
                    stat("AI 工具进程", BigNumber(text: "\(monitor.totalProcessCount)", size: 34))
                    stat("活跃工具", BigNumber(text: "\(monitor.activeToolCount)", unit: "/ \(Tool.allCases.count)", size: 34))
                    Spacer()
                }
                if monitor.totalMemoryBytes > 0 {
                    ProportionBar(
                        segments: Tool.allCases.map { tool in
                            .init(
                                id: tool.id,
                                color: tool.accentColor,
                                value: Double(monitor.summaries[tool]?.totalMemoryBytes ?? 0)
                            )
                        },
                        height: 10
                    )
                }
            }
        }
    }

    private func stat(_ title: String, _ value: BigNumber) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            value
        }
    }

    private var idleRow: some View {
        HStack(spacing: 8) {
            Text("未运行")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(idleTools) { tool in
                HStack(spacing: 5) {
                    tool.logo
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                    Text(tool.shortName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct SystemProcessCard: View {
    @ObservedObject var monitor: SystemProcessMonitor
    @State private var metric: Metric = .cpu

    private enum Metric: String, CaseIterable, Identifiable {
        case cpu = "CPU", gpu = "GPU", memory = "内存"
        var id: String { rawValue }
    }

    private var rankedProcesses: [SystemProcessUsage] {
        switch metric {
        case .cpu:
            return Array(monitor.processes.filter { ($0.cpuPercent ?? 0) > 0 }
                .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(10))
        case .gpu:
            return Array(monitor.processes.filter { ($0.gpuPercent ?? 0) > 0 }
                .sorted { ($0.gpuPercent ?? 0) > ($1.gpuPercent ?? 0) }.prefix(10))
        case .memory:
            return Array(monitor.processes.filter { $0.memoryBytes > 0 }
                .sorted { $0.memoryBytes > $1.memoryBytes }.prefix(10))
        }
    }

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("高占用进程")
                            .font(.headline)
                        Text("可读取的系统进程 · 前 10 名 · 每 3 秒刷新")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("排序依据", selection: $metric) {
                        ForEach(Metric.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                if !monitor.hasCaptured {
                    Text("正在采集进程数据…")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .padding(.vertical, 8)
                } else if metric == .gpu && !monitor.gpuAvailable {
                    Text("当前系统未提供逐进程 GPU 数据。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .padding(.vertical, 8)
                } else if metric != .memory && !monitor.hasSample {
                    Text("正在采集数据，等待下一次刷新…")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .padding(.vertical, 8)
                } else if rankedProcesses.isEmpty {
                    Text("暂无可显示的进程。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .padding(.vertical, 8)
                } else {
                    ForEach(rankedProcesses) { process in
                        HStack(spacing: 10) {
                            Text(String(process.pid))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Text(process.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(value(for: process))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                Text(metric == .memory ? "内存为进程常驻内存（RSS）。" :
                     metric == .cpu ? "CPU 为单核心占用率，多核心时可超过 100%。" :
                     "GPU 为采样期间的累计执行时间占比，可能超过 100%。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func value(for process: SystemProcessUsage) -> String {
        switch metric {
        case .cpu: return String(format: "%.1f%%", process.cpuPercent ?? 0)
        case .gpu: return String(format: "%.1f%%", process.gpuPercent ?? 0)
        case .memory: return MemoryFormat.string(process.memoryBytes)
        }
    }
}

private struct ToolProcessCard: View {
    let summary: ToolProcessSummary
    let totalMemory: UInt64
    let monitor: ProcessMonitor
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var isConfirmingTerminateAll = false

    private var tool: Tool { summary.tool }

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    IconTile(image: tool.logo, tint: tool.accentColor, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.rawValue)
                            .font(.headline)
                        Text("\(summary.processCount) 个进程 · 占 \(MemoryFormat.percentage(value: summary.totalMemoryBytes, total: totalMemory))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(summary.formattedMemory)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Button(role: .destructive) {
                        isConfirmingTerminateAll = true
                    } label: {
                        Label("全部结束", systemImage: "stop.circle")
                    }
                    .controlSize(.small)
                    .help("结束 \(tool.shortName) 的全部 \(summary.processCount) 个进程")
                    .confirmationDialog(
                        "结束 \(tool.rawValue) 的全部进程？",
                        isPresented: $isConfirmingTerminateAll
                    ) {
                        Button("结束 \(summary.processCount) 个进程", role: .destructive) {
                            monitor.terminateAllProcesses(for: tool)
                        }
                    } message: {
                        Text("未保存的会话内容可能会丢失。")
                    }
                }
                .padding(16)
                // 整个标题行都可点击展开/收起；“全部结束”按钮优先响应自己的点击。
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(tool.rawValue)，\(isExpanded ? "已展开" : "已收起")")

                if isExpanded {
                    Divider()

                    VStack(spacing: 0) {
                        ForEach(summary.processes) { process in
                            ProcessRow(process: process, isTerminating: monitor.terminatingPIDs.contains(process.pid)) {
                                monitor.terminateProcess(pid: process.pid)
                            }
                            if process.id != summary.processes.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipped()
        }
    }
}

private struct ProcessRow: View {
    let process: ToolProcessItem
    let isTerminating: Bool
    let onTerminate: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text(String(process.pid))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(process.name)
                .fontWeight(process.isMain ? .medium : .regular)
                .lineLimit(1)
            if !process.isMain {
                Text("子进程")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 8)
            Text(process.formattedMemory)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                onTerminate()
            } label: {
                Image(systemName: isTerminating ? "hourglass" : "xmark.circle.fill")
                    .foregroundStyle(isHovered || isTerminating ? Color.red : Color.secondary.opacity(0.5))
                    .imageScale(.large)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.88))
            .help("结束此进程及其子进程")
            .disabled(isTerminating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.secondary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(process.path)
    }
}
