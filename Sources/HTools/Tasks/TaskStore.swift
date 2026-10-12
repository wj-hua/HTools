import Combine
import Foundation

struct TaskItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var notes: String
    /// 只精确到天，统一存为当天零点。
    var dueDate: Date?
    var isDone: Bool
    var completedAt: Date?
    let createdAt: Date
    /// 待办之间的手动排序；已完成的任务按完成时间倒序展示。
    var order: Int

    init(id: UUID = UUID(), title: String, notes: String = "", dueDate: Date? = nil, order: Int = 0) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isDone = false
        self.completedAt = nil
        self.createdAt = Date()
        self.order = order
    }

    var isOverdue: Bool {
        guard !isDone, let dueDate else { return false }
        return dueDate < Calendar.current.startOfDay(for: Date())
    }
}

final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []

    let fileURL: URL
    private let fileManager: FileManager
    private var pendingSave: DispatchWorkItem?

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        load()
    }

    var pendingTasks: [TaskItem] {
        tasks.filter { !$0.isDone }.sorted { $0.order < $1.order }
    }

    var completedTasks: [TaskItem] {
        tasks.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var pendingCount: Int {
        tasks.lazy.filter { !$0.isDone }.count
    }

    @discardableResult
    func add(title: String) -> TaskItem? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return nil }

        let task = TaskItem(title: normalizedTitle, order: pendingCount)
        tasks.append(task)
        normalizeAndSave()
        return task
    }

    /// 修改任务的标题、备注或截止日期。标题为空时不写回，避免误删内容。
    func update(id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        var task = tasks[index]
        change(&task)
        guard Self.isValidTitle(task.title), task != tasks[index] else { return }
        task.dueDate = task.dueDate.map { Calendar.current.startOfDay(for: $0) }
        tasks[index] = task
        normalizeAndSave()
    }

    func setDone(id: UUID, _ isDone: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].isDone != isDone else { return }

        tasks[index].isDone = isDone
        tasks[index].completedAt = isDone ? Date() : nil
        // 重新打开的任务放回待办末尾。
        if !isDone { tasks[index].order = pendingCount }
        normalizeAndSave()
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }

        tasks.remove(at: index)
        normalizeAndSave()
        return true
    }

    func movePending(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var pending = pendingTasks
        pending.move(fromOffsets: offsets, toOffset: destination)
        let orderByID = Dictionary(uniqueKeysWithValues: pending.enumerated().map { ($0.element.id, $0.offset) })

        for index in tasks.indices {
            guard let order = orderByID[tasks[index].id] else { continue }
            tasks[index].order = order
        }
        normalizeAndSave()
    }

    func clearCompleted() {
        tasks.removeAll(where: \.isDone)
        normalizeAndSave()
    }

    static func isValidTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            tasks = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            tasks = try JSONDecoder().decode([TaskItem].self, from: data)
            normalizeInMemory()
        } catch {
            // 文件已损坏时先留底再从空列表开始，不影响启动，也不会被下一次保存覆盖。
            fileManager.backUpUnreadableFile(at: fileURL)
            tasks = []
        }
    }

    private func normalizeAndSave() {
        normalizeInMemory()
        scheduleSave()
    }

    /// 编辑标题、备注时每敲一个字都会修改一次；合并为最后一次修改 0.5 秒后写一次盘。
    /// 退出前用 `flushPendingSave()` 立即写入。
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.save()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushPendingSave() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        save()
    }

    /// 待办的 order 重排为 0...n-1，保持连续。
    private func normalizeInMemory() {
        let orderByID = Dictionary(uniqueKeysWithValues: pendingTasks.enumerated().map { ($0.element.id, $0.offset) })
        for index in tasks.indices {
            if let order = orderByID[tasks[index].id] {
                tasks[index].order = order
            }
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 持久化失败不致命，内存中的列表仍可继续使用。
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mino.htools", isDirectory: true)
            .appendingPathComponent("tasks.json", isDirectory: false)
    }
}
