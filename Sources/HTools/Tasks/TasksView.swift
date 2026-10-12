import SwiftUI

/// 任务清单：顶部输入框快速添加，左侧列表勾选完成，右侧编辑备注与截止日期。
struct TasksView: View {
    @ObservedObject var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("tasksShowCompleted") private var showsCompleted = true

    @State private var newTitle = ""
    @FocusState private var isQuickAddFocused: Bool
    @State private var selectedID: UUID?
    @State private var draftTitle = ""
    @State private var taskToDelete: TaskItem?
    @State private var isConfirmingClear = false

    private var selectedTask: TaskItem? {
        selectedID.flatMap { id in store.tasks.first { $0.id == id } }
    }

    private var listAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard
    }

    var body: some View {
        VStack(spacing: 0) {
            quickAddBar
            Divider()
            HSplitView {
                listColumn
                    .frame(minWidth: 300, idealWidth: 380, maxHeight: .infinity)
                detailColumn
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("任务清单")
        .navigationSubtitle("\(store.pendingCount) 项待办 · \(store.completedTasks.count) 项已完成")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isQuickAddFocused = true
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .help("新建任务 (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .onChange(of: selectedID) { _, _ in
            draftTitle = selectedTask?.title ?? ""
        }
        .confirmationDialog(
            "删除任务“\(taskToDelete?.title ?? "")”？",
            isPresented: Binding(get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } })
        ) {
            Button("删除", role: .destructive) {
                if let task = taskToDelete { delete(task) }
            }
        } message: {
            Text("删除后无法恢复。")
        }
        .confirmationDialog("清除全部已完成任务？", isPresented: $isConfirmingClear) {
            Button("清除 \(store.completedTasks.count) 项", role: .destructive) {
                if selectedTask?.isDone == true { selectedID = nil }
                withAnimation(listAnimation) { store.clearCompleted() }
            }
        } message: {
            Text("清除后无法恢复。")
        }
    }

    // MARK: - 快速添加

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            TextField("添加任务，按 ↩ 确认", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isQuickAddFocused)
                .onSubmit(addTask)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 列表

    @ViewBuilder
    private var listColumn: some View {
        if store.tasks.isEmpty {
            ContentUnavailableView(
                "没有任务",
                systemImage: "checklist",
                description: Text("在上方输入框中添加第一个任务")
            )
        } else {
            List(selection: $selectedID) {
                Section("待办") {
                    if store.pendingTasks.isEmpty {
                        Text("全部完成")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(store.pendingTasks) { task in
                        row(task)
                    }
                    .onMove { store.movePending(fromOffsets: $0, toOffset: $1) }
                }

                if !store.completedTasks.isEmpty {
                    Section {
                        if showsCompleted {
                            ForEach(store.completedTasks) { task in
                                row(task)
                            }
                        }
                    } header: {
                        completedHeader
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let task = store.tasks.first(where: { $0.id == id }) {
                    Button(task.isDone ? "标记为未完成" : "标记为完成") { toggle(task) }
                    Divider()
                    Button("删除…", role: .destructive) { taskToDelete = task }
                }
            }
            .onDeleteCommand {
                taskToDelete = selectedTask
            }
        }
    }

    private var completedHeader: some View {
        HStack {
            Text("已完成")
            Spacer()
            Button("清除…") { isConfirmingClear = true }
            Button(showsCompleted ? "隐藏" : "显示") {
                withAnimation(listAnimation) { showsCompleted.toggle() }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private func row(_ task: TaskItem) -> some View {
        TaskRow(task: task) { toggle(task) }
            .tag(task.id)
    }

    // MARK: - 详情

    @ViewBuilder
    private var detailColumn: some View {
        if let task = selectedTask {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("标题", text: $draftTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .onChange(of: draftTitle) { _, newValue in
                            store.update(id: task.id) { $0.title = newValue }
                        }

                    HStack(spacing: 10) {
                        Toggle("截止日期", isOn: dueDateEnabledBinding(for: task))
                        if task.dueDate != nil {
                            DatePicker("截止日期", selection: dueDateBinding(for: task), displayedComponents: .date)
                                .labelsHidden()
                                .fixedSize()
                        }
                        if task.isOverdue {
                            Label("已逾期", systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Text("备注")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

                TextEditor(text: notesBinding(for: task))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor))

                Divider()
                HStack(spacing: 10) {
                    if !TaskStore.isValidTitle(draftTitle) {
                        Label("标题为空时不会保存", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("创建于 \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { taskToDelete = task } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button { toggle(task) } label: {
                        Label(task.isDone ? "标记为未完成" : "标记为完成", systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        } else {
            ContentUnavailableView(
                "选择一个任务查看详情",
                systemImage: "checklist",
                description: Text("点击左侧圆圈可直接标记完成")
            )
        }
    }

    private func dueDateEnabledBinding(for task: TaskItem) -> Binding<Bool> {
        Binding(
            get: { task.dueDate != nil },
            set: { enabled in
                store.update(id: task.id) { $0.dueDate = enabled ? Date() : nil }
            }
        )
    }

    private func dueDateBinding(for task: TaskItem) -> Binding<Date> {
        Binding(
            get: { task.dueDate ?? Date() },
            set: { date in store.update(id: task.id) { $0.dueDate = date } }
        )
    }

    private func notesBinding(for task: TaskItem) -> Binding<String> {
        Binding(
            get: { task.notes },
            set: { notes in store.update(id: task.id) { $0.notes = notes } }
        )
    }

    // MARK: - 操作

    private func addTask() {
        guard let task = withAnimation(listAnimation, { store.add(title: newTitle) }) else { return }
        newTitle = ""
        selectedID = task.id
        // 保持焦点，便于连续添加。
        isQuickAddFocused = true
    }

    private func toggle(_ task: TaskItem) {
        withAnimation(listAnimation) {
            store.setDone(id: task.id, !task.isDone)
        }
    }

    private func delete(_ task: TaskItem) {
        let visible = store.pendingTasks + (showsCompleted ? store.completedTasks : [])
        let index = visible.firstIndex(where: { $0.id == task.id })
        guard withAnimation(listAnimation, { store.delete(id: task.id) }) else { return }

        let remaining = store.pendingTasks + (showsCompleted ? store.completedTasks : [])
        if selectedID == task.id {
            selectedID = index.flatMap { remaining.isEmpty ? nil : remaining[min($0, remaining.count - 1)].id }
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableButtonStyle(scale: 0.85))
            .help(task.isDone ? "标记为未完成" : "标记为完成")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .lineLimit(2)

                if task.dueDate != nil || !task.notes.isEmpty {
                    HStack(spacing: 8) {
                        if let dueDate = task.dueDate {
                            Label(Self.dueText(dueDate), systemImage: "calendar")
                                .foregroundStyle(task.isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        }
                        if !task.notes.isEmpty {
                            Image(systemName: "note.text")
                                .foregroundStyle(.secondary)
                                .help("有备注")
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private static func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.month().day())
            : date.formatted(.dateTime.year().month().day())
    }
}
