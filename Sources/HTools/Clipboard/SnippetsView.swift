import SwiftUI

/// 主窗口里的“常用文本”管理页。快速粘贴仍由 ⌥Space 浮动面板负责，
/// 这里专注于整理：标签、排序、编辑。两者共享同一个 PasteItemStore。
struct SnippetsView: View {
    @ObservedObject var store: PasteItemStore
    @EnvironmentObject private var model: AppModel

    @State private var selectedTagID: UUID = PasteTag.defaultID
    @State private var selectedItemID: UUID?
    @State private var searchText = ""
    @State private var isCreating = false
    @State private var draftText = ""
    @State private var toastMessage: String?

    @State private var isAddingTag = false
    @State private var newTagName = ""
    @State private var tagToRename: PasteTag?
    @State private var renamedTagName = ""
    @State private var tagToDelete: PasteTag?
    @State private var itemToDelete: PasteItem?
    @State private var errorMessage: String?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleItems: [PasteItem] {
        let terms = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return store.items(for: selectedTagID) }
        return store.items.filter { item in
            terms.allSatisfy { item.text.localizedStandardContains($0) }
        }
    }

    private var selectedItem: PasteItem? {
        selectedItemID.flatMap { id in store.items.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            QuickPasteBanner()
            Divider()
            HSplitView {
                tagColumn
                    .frame(minWidth: 160, idealWidth: 190, maxWidth: 260, maxHeight: .infinity)
                itemColumn
                    .frame(minWidth: 260, idealWidth: 340, maxHeight: .infinity)
                editorColumn
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("常用文本")
        .navigationSubtitle("\(store.items.count) 条 · \(store.tags.count) 个标签")
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索全部常用文本")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    beginCreating()
                } label: {
                    Label("新建文本", systemImage: "square.and.pencil")
                }
                .help("新建常用文本 (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .toast($toastMessage)
        .onAppear(perform: normalizeSelection)
        .onChange(of: store.tags) { _, _ in normalizeSelection() }
        .onChange(of: selectedItemID) { _, _ in
            if selectedItemID != nil { isCreating = false }
            draftText = selectedItem?.text ?? ""
        }
        .alert("新建标签", isPresented: $isAddingTag) {
            TextField("标签名称", text: $newTagName)
            Button("添加") { addTag() }
            Button("取消", role: .cancel) { newTagName = "" }
        }
        .alert("重命名标签", isPresented: Binding(get: { tagToRename != nil }, set: { if !$0 { tagToRename = nil } })) {
            TextField("标签名称", text: $renamedTagName)
            Button("保存") { renameTag() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除标签“\(tagToDelete?.name ?? "")”？",
            isPresented: Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } })
        ) {
            Button("删除标签", role: .destructive) {
                if let tag = tagToDelete, store.deleteTag(id: tag.id) {
                    selectedTagID = PasteTag.defaultID
                }
            }
        } message: {
            Text("标签中的文本会移到“\(defaultTagName)”，不会被删除。")
        }
        .confirmationDialog(
            "删除这条常用文本？",
            isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } })
        ) {
            Button("删除", role: .destructive) {
                if let item = itemToDelete { deleteItem(item) }
            }
        } message: {
            Text("删除后无法恢复。")
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var defaultTagName: String {
        store.tags.first(where: \.isDefault)?.name ?? PasteTag.defaultName
    }

    // MARK: - 标签列

    private var tagColumn: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selectedTagID }, set: { if let id = $0 { selectTag(id) } })) {
                Section("标签") {
                    ForEach(store.tags) { tag in
                        Label(tag.name, systemImage: TagBarMetrics.symbolName(for: tag))
                            .badge(store.items(for: tag.id).count)
                            .tag(tag.id)
                            .contextMenu {
                                Button("重命名…") {
                                    renamedTagName = tag.name
                                    tagToRename = tag
                                }
                                if !tag.isDefault {
                                    Button("删除标签…", role: .destructive) { tagToDelete = tag }
                                }
                            }
                    }
                    .onMove { store.moveTags(fromOffsets: $0, toOffset: $1) }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 0) {
                Button {
                    newTagName = ""
                    isAddingTag = true
                } label: {
                    Image(systemName: "plus").frame(width: 26, height: 22)
                }
                .help("新建标签")
                Button {
                    tagToDelete = store.tags.first { $0.id == selectedTagID }
                } label: {
                    Image(systemName: "minus").frame(width: 26, height: 22)
                }
                .help("删除所选标签")
                .disabled(selectedTagID == PasteTag.defaultID)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    // MARK: - 文本列表

    private var itemColumn: some View {
        Group {
            if visibleItems.isEmpty {
                if isSearching {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView {
                        Label("这个标签还没有文本", systemImage: "text.badge.plus")
                    } actions: {
                        Button("新建文本") { beginCreating() }
                    }
                }
            } else {
                List(selection: $selectedItemID) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        SnippetRow(
                            item: item,
                            shortcutIndex: isSearching ? nil : index,
                            tagName: isSearching ? store.tags.first { $0.id == item.tagID }?.name : nil
                        )
                        .tag(item.id)
                    }
                    .onMove(perform: isSearching ? nil : { offsets, destination in
                        store.move(fromOffsets: offsets, toOffset: destination, in: selectedTagID)
                    })
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let item = store.items.first(where: { $0.id == id }) {
                        Button("复制") { copy(item) }
                        Menu("移动到") {
                            ForEach(store.tags) { tag in
                                Button(tag.name) { _ = store.moveItem(withID: item.id, toTagID: tag.id) }
                                    .disabled(tag.id == item.tagID)
                            }
                        }
                        Divider()
                        Button("删除…", role: .destructive) { itemToDelete = item }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let item = store.items.first(where: { $0.id == id }) {
                        copy(item)
                    }
                }
                .onDeleteCommand {
                    itemToDelete = selectedItem
                }
            }
        }
    }

    // MARK: - 编辑器

    @ViewBuilder
    private var editorColumn: some View {
        if isCreating || selectedItem != nil {
            VStack(spacing: 0) {
                HStack {
                    Text(isCreating ? "新建文本" : "编辑")
                        .font(.headline)
                    Spacer()
                    Picker("标签", selection: editorTagBinding) {
                        ForEach(store.tags) { tag in
                            Text(tag.name).tag(tag.id)
                        }
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                TextEditor(text: $draftText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: draftText) { _, newValue in
                        // 编辑已有文本时实时保存；空内容不写回，避免误删。
                        guard !isCreating, let id = selectedItemID,
                              newValue != selectedItem?.text,
                              PasteItemStore.isValidText(newValue) else { return }
                        store.update(id: id, text: newValue)
                    }

                Divider()
                HStack(spacing: 10) {
                    Text("\(draftText.count) 字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if !isCreating, !PasteItemStore.isValidText(draftText) {
                        Label("内容为空时不会保存", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if isCreating {
                        Button("取消") { isCreating = false; draftText = "" }
                            .keyboardShortcut(.cancelAction)
                        Button("添加") { commitCreation() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(!PasteItemStore.isValidText(draftText))
                    } else if let item = selectedItem {
                        Button(role: .destructive) { itemToDelete = item } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button { copy(item) } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        } else {
            ContentUnavailableView(
                "选择一条文本进行编辑",
                systemImage: "text.cursor",
                description: Text("双击列表中的文本可直接复制")
            )
        }
    }

    @State private var creationTagID: UUID = PasteTag.defaultID

    private var editorTagBinding: Binding<UUID> {
        Binding(
            get: { isCreating ? creationTagID : (selectedItem?.tagID ?? selectedTagID) },
            set: { tagID in
                if isCreating {
                    creationTagID = tagID
                } else if let id = selectedItemID {
                    _ = store.moveItem(withID: id, toTagID: tagID)
                }
            }
        )
    }

    // MARK: - 操作

    private func normalizeSelection() {
        if !store.tags.contains(where: { $0.id == selectedTagID }) {
            selectedTagID = store.tags.first?.id ?? PasteTag.defaultID
        }
    }

    private func selectTag(_ id: UUID) {
        selectedTagID = id
        searchText = ""
        selectedItemID = store.items(for: id).first?.id
    }

    private func beginCreating() {
        selectedItemID = nil
        creationTagID = selectedTagID
        draftText = ""
        isCreating = true
    }

    private func commitCreation() {
        guard let item = store.add(text: draftText, to: creationTagID) else { return }
        isCreating = false
        searchText = ""
        selectedTagID = item.tagID
        selectedItemID = item.id
        toastMessage = "已添加"
    }

    private func copy(_ item: PasteItem) {
        if Pasteboard.copy(item.text) {
            toastMessage = "已复制到剪贴板"
        } else {
            errorMessage = "无法写入系统剪贴板，请重试。"
        }
    }

    private func deleteItem(_ item: PasteItem) {
        let items = visibleItems
        let index = items.firstIndex(where: { $0.id == item.id })
        guard store.delete(id: item.id) else { return }
        let remaining = visibleItems
        if let index, !remaining.isEmpty {
            selectedItemID = remaining[min(index, remaining.count - 1)].id
        } else {
            selectedItemID = nil
        }
    }

    private func addTag() {
        let name = newTagName
        newTagName = ""
        guard let tag = store.addTag(name: name) else {
            errorMessage = "标签名称不能为空，且不能与现有标签重复。"
            return
        }
        selectTag(tag.id)
    }

    private func renameTag() {
        guard let tag = tagToRename else { return }
        if !store.renameTag(id: tag.id, name: renamedTagName) {
            errorMessage = "标签名称不能为空，且不能与现有标签重复。"
        }
        tagToRename = nil
    }
}

private struct SnippetRow: View {
    let item: PasteItem
    let shortcutIndex: Int?
    let tagName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let shortcutIndex, shortcutIndex < 9 {
                    Text("⌥\(shortcutIndex + 1)")
                } else {
                    Text(" ")
                }
            }
            .font(.system(.caption, design: .rounded).weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, alignment: .leading)
            .help("在快速粘贴面板中按 ⌥\((shortcutIndex ?? 0) + 1) 直接粘贴")

            VStack(alignment: .leading, spacing: 3) {
                Text(preview)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let tagName {
                    Label(tagName, systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var preview: String {
        item.text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }
}

/// 顶部提示条：快捷键与自动粘贴权限状态一目了然。
private struct QuickPasteBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isHotKeyRegistered ? "在任意应用中按 ⌥ Space 呼出快速粘贴面板" : "⌥ Space 快捷键注册失败")
                    .font(.callout.weight(.medium))
                Text(model.isHotKeyRegistered ? "↑↓ 选择 · ↩ 粘贴 · ⌥1–9 直接粘贴 · ⌘C 仅复制" : "可能被其他应用占用，请关闭冲突应用后重新启动 HTools。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isAccessibilityTrusted {
                Label("自动粘贴已授权", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button {
                    model.requestAccessibilityPermission()
                } label: {
                    Label("授予辅助功能权限", systemImage: "hand.raised.fill")
                }
                .controlSize(.small)
                .help("自动粘贴需要在“隐私与安全性 > 辅助功能”中允许 HTools")
            }
            Button("打开面板") {
                model.showQuickPastePanel()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
