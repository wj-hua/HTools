import SwiftUI

/// 任务清单：左侧列表待办/已完成分组与快速添加，右侧卡片式编辑备注与截止日期。
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
        HSplitView {
            listColumn
                .frame(minWidth: 300, idealWidth: 360, maxHeight: .infinity)
            detailColumn
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - 左侧列表列

    @ViewBuilder
    private var listColumn: some View {
        VStack(spacing: 0) {
            quickAddBar
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if !store.tasks.isEmpty {
                progressHeader
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            if store.tasks.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "暂无任务",
                    systemImage: "checklist",
                    description: Text("在上方输入框中输入内容，按 ↩ 快速创建待办")
                )
                Spacer()
            } else {
                taskList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 快速添加栏

    private var quickAddBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isQuickAddFocused ? Color.accentColor : Color.secondary)

            TextField("添加待办任务，按 ↩ 保存…", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isQuickAddFocused)
                .onSubmit(addTask)

            if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: addTask) {
                    HStack(spacing: 2) {
                        Image(systemName: "return")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .help("按回车添加任务")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isQuickAddFocused
                        ? Color.accentColor.opacity(0.6)
                        : Color(nsColor: .separatorColor).opacity(0.4),
                    lineWidth: isQuickAddFocused ? 1.2 : 0.5
                )
        }
        .animation(Motion.snappy, value: isQuickAddFocused)
    }

    // MARK: - 进度条

    private var progressHeader: some View {
        let completed = store.completedTasks.count
        let total = store.tasks.count
        let percent = total > 0 ? Double(completed) / Double(total) : 0

        return VStack(spacing: 4) {
            HStack {
                Text("\(completed)/\(total) 已完成")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percent * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, proxy.size.width * CGFloat(percent)))
                }
            }
            .frame(height: 4)
            .animation(Motion.standard, value: percent)
        }
    }

    // MARK: - 列表主体

    private var taskList: some View {
        List(selection: $selectedID) {
            Section {
                if store.pendingTasks.isEmpty {
                    emptyPendingRow
                } else {
                    ForEach(store.pendingTasks) { task in
                        row(task)
                    }
                    .onMove { store.movePending(fromOffsets: $0, toOffset: $1) }
                }
            } header: {
                pendingHeader
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
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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

    private var pendingHeader: some View {
        HStack(spacing: 6) {
            Text("待办")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if !store.pendingTasks.isEmpty {
                Text("\(store.pendingTasks.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var emptyPendingRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.green)
            Text("待办均已完成")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .selectionDisabled()
    }

    private var completedHeader: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(listAnimation) { showsCompleted.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                    Text("已完成")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(store.completedTasks.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                isConfirmingClear = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                    Text("清空")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("清除所有已完成任务")
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ task: TaskItem) -> some View {
        TaskRow(task: task, onToggle: { toggle(task) }, onDelete: { taskToDelete = task })
            .tag(task.id)
    }

    // MARK: - 详情列

    @ViewBuilder
    private var detailColumn: some View {
        if let task = selectedTask {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 顶部状态操作条
                        HStack {
                            Button {
                                toggle(task)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(task.isDone ? Color.green : Color.accentColor)
                                    Text(task.isDone ? "已完成" : "待办中")
                                        .fontWeight(.medium)
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(task.isDone ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.12))
                                )
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.95))

                            Spacer()

                            if task.isOverdue {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                    Text("已逾期")
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                            }
                        }

                        // 标题输入
                        TextField("任务标题", text: $draftTitle, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1...5)
                            .onChange(of: draftTitle) { _, newValue in
                                if TaskStore.isValidTitle(newValue) {
                                    store.update(id: task.id) { $0.title = newValue }
                                }
                            }

                        Divider()

                        // 截止日期卡片
                        dueDateCard(for: task)

                        // 备注卡片
                        notesCard(for: task)
                    }
                    .padding(20)
                }

                Divider()

                // 底部栏
                detailFooter(for: task)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        } else {
            ContentUnavailableView {
                Label("未选择任务", systemImage: "checklist")
            } description: {
                Text("从左侧选择任务查看或编辑详情，\n或在左上方快速添加新待办。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        }
    }

    // MARK: - 截止日期卡片

    private func dueDateCard(for task: TaskItem) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("截止日期", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if task.dueDate != nil {
                        Button("清除日期") {
                            withAnimation(Motion.snappy) {
                                store.update(id: task.id) { $0.dueDate = nil }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    } else {
                        Text("未设置")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 8) {
                    datePresetPill(title: "今天", isSelected: isDateToday(task.dueDate)) {
                        setDueDate(Calendar.current.startOfDay(for: Date()), for: task)
                    }
                    datePresetPill(title: "明天", isSelected: isDateTomorrow(task.dueDate)) {
                        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                        setDueDate(tomorrow, for: task)
                    }
                    datePresetPill(title: "下周", isSelected: isDateNextWeek(task.dueDate)) {
                        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                        setDueDate(nextWeek, for: task)
                    }

                    Spacer()

                    DatePicker(
                        "截止日期",
                        selection: dueDateBinding(for: task),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .fixedSize()
                }

                if task.isOverdue {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text("任务已逾期")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private func datePresetPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                )
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
    }

    // MARK: - 备注卡片

    private func notesCard(for task: TaskItem) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("备注", systemImage: "note.text")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if task.notes.isEmpty {
                        Text("添加详细备注、待办事项或链接…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: notesBinding(for: task))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                }
            }
        }
    }

    // MARK: - 详情底部栏

    private func detailFooter(for task: TaskItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("创建于 \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let completedAt = task.completedAt {
                    Text("完成于 \(completedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                taskToDelete = task
            } label: {
                Label("删除", systemImage: "trash")
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                toggle(task)
            } label: {
                Label(
                    task.isDone ? "标记为未完成" : "完成任务",
                    systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 辅助绑定与操作

    private func dueDateBinding(for task: TaskItem) -> Binding<Date> {
        Binding(
            get: { task.dueDate ?? Date() },
            set: { date in
                store.update(id: task.id) { $0.dueDate = date }
            }
        )
    }

    private func notesBinding(for task: TaskItem) -> Binding<String> {
        Binding(
            get: { task.notes },
            set: { notes in store.update(id: task.id) { $0.notes = notes } }
        )
    }

    private func setDueDate(_ date: Date, for task: TaskItem) {
        withAnimation(Motion.snappy) {
            store.update(id: task.id) { $0.dueDate = date }
        }
    }

    private func isDateToday(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.isDateInToday(date)
    }

    private func isDateTomorrow(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.isDateInTomorrow(date)
    }

    private func isDateNextWeek(_ date: Date?) -> Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: Date()) else { return false }
        return calendar.isDate(date, inSameDayAs: nextWeek)
    }

    private func addTask() {
        guard let task = withAnimation(listAnimation, { store.add(title: newTitle) }) else { return }
        newTitle = ""
        selectedID = task.id
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

// MARK: - 任务行组件

private struct TaskRow: View {
    let task: TaskItem
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TaskCheckbox(isDone: task.isDone, onToggle: onToggle)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.isDone, color: .secondary.opacity(0.6))
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if task.dueDate != nil || !task.notes.isEmpty {
                    HStack(spacing: 6) {
                        if let dueDate = task.dueDate {
                            DueDateBadge(date: dueDate, isOverdue: task.isOverdue)
                        }
                        if !task.notes.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "text.alignleft")
                                    .font(.system(size: 9))
                                Text("备注")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                            .help("包含备注")
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.9))
                .help("删除任务")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - 任务复选框

private struct TaskCheckbox: View {
    let isDone: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                if isDone {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 17, height: 17)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .strokeBorder(
                            isHovered ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: 1.5
                        )
                        .background(
                            Circle()
                                .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
                        )
                        .frame(width: 17, height: 17)
                    if isHovered {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.6))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.85))
        .onHover { isHovered = $0 }
        .help(isDone ? "标记为未完成" : "标记为完成")
    }
}

// MARK: - 截止日期徽章

private struct DueDateBadge: View {
    let date: Date
    let isOverdue: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isOverdue ? "exclamationmark.circle.fill" : "calendar")
                .font(.system(size: 9))
            Text(Self.dueText(date))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(backgroundColor)
        )
    }

    private var color: Color {
        if isOverdue { return .red }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .orange }
        if calendar.isDateInTomorrow(date) { return .blue }
        return .secondary
    }

    private var backgroundColor: Color {
        if isOverdue { return Color.red.opacity(0.12) }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return Color.orange.opacity(0.12) }
        if calendar.isDateInTomorrow(date) { return Color.blue.opacity(0.1) }
        return Color.secondary.opacity(0.08)
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
