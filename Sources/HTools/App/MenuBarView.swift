import SwiftUI

/// 菜单栏弹出面板：今日 Token 消耗、待办任务，以及打开主窗口。
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("selectedSection") private var selection: AppSection = .tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarTokenSection(store: model.usageStore) { open(.tokens) }
                .padding(14)

            Divider()

            MenuBarTaskSection(store: model.taskStore) { open(.tasks) }
                .padding(14)

            Divider()

            HStack {
                Button("打开 HTools") { open(nil) }
                    .keyboardShortcut("o", modifiers: .command)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .onAppear { model.usageStore.refreshIfStale() }
    }

    /// 打开主窗口，可选地切换到指定页面。
    private func open(_ section: AppSection?) {
        if let section { selection = section }
        openWindow(id: "main")
        NSApp.activate()
    }
}

// MARK: - Token

private struct MenuBarTokenSection: View {
    @ObservedObject var store: UsageStore
    let onOpen: () -> Void

    private var tools: [Tool] {
        Tool.allCases.filter { store.availableTools.contains($0) }
    }

    var body: some View {
        let today = store.currentBucket(for: .day)
        let total = today.combinedTotal

        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("今日 Token", subtitle: store.isRefreshing ? "正在同步…" : today.label, action: onOpen)

            BigNumber(text: TokenFormat.string(total), unit: "tokens", size: 30)

            if total > 0 {
                ProportionBar(
                    segments: tools.map { tool in
                        .init(id: tool.id, color: tool.accentColor, value: Double(today.totalsByTool[tool]?.totalTokens ?? 0))
                    },
                    height: 6
                )
            }

            HStack(spacing: 12) {
                MetricCell(label: "本周", value: TokenFormat.string(store.currentBucket(for: .week).combinedTotal), tint: .indigo)
                MetricCell(label: "本月", value: TokenFormat.string(store.currentBucket(for: .month).combinedTotal), tint: .teal)
            }
        }
    }
}

// MARK: - 任务

private struct MenuBarTaskSection: View {
    @ObservedObject var store: TaskStore
    let onOpen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var newTitle = ""

    /// 面板高度有限，只列出前几项待办。
    private let visibleLimit = 6

    var body: some View {
        let pending = store.pendingTasks

        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("待办", subtitle: "\(pending.count) 项", action: onOpen)

            TextField("添加待办，按 ↩ 保存…", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if store.add(title: newTitle) != nil { newTitle = "" }
                }

            if pending.isEmpty {
                Label("待办均已完成", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(pending.prefix(visibleLimit)) { task in
                    HStack(spacing: 8) {
                        TaskCheckbox(isDone: task.isDone) {
                            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard) {
                                store.setDone(id: task.id, true)
                            }
                        }
                        Text(task.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let dueDate = task.dueDate {
                            DueDateBadge(date: dueDate, isOverdue: task.isOverdue)
                        }
                    }
                    .padding(.vertical, 2)
                    .transition(.opacity)
                }

                if pending.count > visibleLimit {
                    Button("还有 \(pending.count - visibleLimit) 项…", action: onOpen)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 分区标题；右侧箭头跳到主窗口对应页面。
private func sectionHeader(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title)
            .font(.headline)
        Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        Spacer()
        Button(action: action) {
            Image(systemName: "arrow.up.forward.app")
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .foregroundStyle(.secondary)
        .help("在主窗口中查看")
    }
}
