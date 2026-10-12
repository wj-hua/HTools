import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    let onClose: () -> Void
    let onWindowDragChanged: () -> Void
    let onWindowDragEnded: () -> Void

    @State private var windowDragExclusions: [CGRect] = []
    @State private var isDeleteConfirmationPresented = false
    @State private var draggedItemID: UUID?
    @State private var draggedTagID: UUID?
    @State private var isAddTagAlertPresented = false
    @State private var newTagName = ""
    @State private var tagToDelete: PasteTag?
    @State private var tagToRename: PasteTag?
    @State private var renamedTagName = ""
    @State private var tagErrorMessage: String?
    @State private var isTextEditorComposing = false
    @State private var isUsageHelpPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let panelCornerRadius: CGFloat = 24

    static let panelWidth: CGFloat = 500
    static let listRowHeight: CGFloat = 42
    static let listRowSpacing: CGFloat = 6
    static let minimumListRows = 5
    static let maximumListRows = 10
    static let panelCoordinateSpace = "ClipboardPanel"

    private static let titleHeaderHeight: CGFloat = 50
    private static let searchBarHeight: CGFloat = 48
    static let listHeaderHeight: CGFloat = titleHeaderHeight + searchBarHeight
    private static let listFooterHeight: CGFloat = 60
    private static let editorPanelHeight: CGFloat = 420

    /// 面板高度预算。标签栏会随标签数量换行变高，列表行数必须让位，
    /// 否则面板会长到屏幕可视区域之外，底栏按钮点不到。
    /// 取 700 是为了在 1280x800 这类最小的 Mac 屏幕上也留有余量。
    static let maxPanelHeight: CGFloat = 700

    static var listRowSlotHeight: CGFloat {
        listRowHeight + listRowSpacing
    }

    /// 只有多于一个标签时才显示标签栏，高度计算与视图必须用同一个判断。
    static func tagBarHeight(for tags: [PasteTag]) -> CGFloat {
        tags.count > 1 ? TagBarMetrics.barHeight(for: tags) : 0
    }

    static func visibleListRows(for itemCount: Int, tagBarHeight: CGFloat = 0) -> Int {
        let desired = min(max(itemCount, minimumListRows), maximumListRows)
        let available = maxPanelHeight - listHeaderHeight - listFooterHeight - tagBarHeight
        let fitting = Int(floor(available / listRowSlotHeight))
        // 列表本身可以滚动，压缩行数只是少露几行；但不能压到比最小行数还少。
        return max(minimumListRows, min(desired, fitting))
    }

    static func panelHeight(
        for itemCount: Int,
        tags: [PasteTag] = [],
        mode: ClipboardViewModel.Mode
    ) -> CGFloat {
        switch mode {
        case .list:
            // 标签栏会按标签实际宽度换行，面板高度必须跟着行数一起长，
            // 否则多出来的行会被窗口边界裁掉。
            let barHeight = tagBarHeight(for: tags)
            return listHeaderHeight
                + barHeight
                + listFooterHeight
                + listRowSlotHeight * CGFloat(visibleListRows(for: itemCount, tagBarHeight: barHeight))
        case .editor:
            return editorPanelHeight
        }
    }

    private var panelHeight: CGFloat {
        Self.panelHeight(
            for: viewModel.visibleItems.count,
            tags: viewModel.tags,
            mode: viewModel.mode
        )
    }

    private var listAreaHeight: CGFloat {
        Self.listRowSlotHeight * CGFloat(
            Self.visibleListRows(
                for: viewModel.visibleItems.count,
                tagBarHeight: Self.tagBarHeight(for: viewModel.tags)
            )
        )
    }

    private func isWindowDragExcluded(_ location: CGPoint) -> Bool {
        windowDragExclusions.contains { $0.contains(location) }
    }

    var body: some View {
        Group {
            switch viewModel.mode {
            case .list:
                listView
            case .editor:
                editorView
            }
        }
        .frame(width: Self.panelWidth, height: panelHeight)
        // 只用一层系统材质：跟随浅色 / 深色，不再叠加白色半透明面和装饰光晕。
        .background(.regularMaterial)
        // The panel itself is the hit-test surface. Empty glass areas must still
        // receive the mouse event instead of letting it fall through to the app
        // underneath.
        .contentShape(Rectangle())
        .onPreferenceChange(WindowDragExclusionPreferenceKey.self) { exclusions in
            windowDragExclusions = exclusions
        }
        .onChange(of: viewModel.searchFocusRequest) { _, _ in
            guard viewModel.mode == .list else { return }

            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.panelCoordinateSpace))
                .onChanged { value in
                    // 手势按下的位置一旦落在按钮、列表或文本编辑器上，就完全不上报，
                    // 让这些控件保留自己的点击与拖拽语义。
                    guard !isWindowDragExcluded(value.startLocation) else { return }

                    onWindowDragChanged()
                }
                .onEnded { _ in
                    onWindowDragEnded()
                }
        )
        // 命名坐标系要包住手势本身，手势和上报排除矩形的 GeometryReader 才会落在同一个
        // 空间里 —— 命名空间只对其后代可见。
        .coordinateSpace(name: Self.panelCoordinateSpace)
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        // 投影由 NSPanel 自己绘制（窗口外的 SwiftUI 阴影会被窗口边界裁掉）。
        .overlay {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $viewModel.isShowingPermission) {
            AccessibilityPermissionView(viewModel: viewModel)
                .frame(width: 430, height: 280)
        }
        .alert("删除常用文本？", isPresented: $isDeleteConfirmationPresented) {
            Button("删除", role: .destructive) {
                viewModel.deleteSelectedItem()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法从应用中恢复这条文本。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.alertMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .alert("新建标签", isPresented: $isAddTagAlertPresented) {
            TextField("标签名称", text: $newTagName)

            Button("添加") {
                let name = newTagName
                newTagName = ""
                if !viewModel.addTag(name: name) {
                    tagErrorMessage = "标签名称不能为空，且不能与现有标签重复。"
                }
            }

            Button("取消", role: .cancel) {
                newTagName = ""
            }
        } message: {
            Text("为常用文本创建一个分类标签。")
        }
        .alert(
            "重命名标签",
            isPresented: Binding(
                get: { tagToRename != nil },
                set: { isPresented in
                    if !isPresented {
                        tagToRename = nil
                    }
                }
            )
        ) {
            TextField("标签名称", text: $renamedTagName)

            Button("保存") {
                let name = renamedTagName
                let tagID = tagToRename?.id
                tagToRename = nil
                renamedTagName = ""
                if let tagID, !viewModel.renameTag(id: tagID, name: name) {
                    tagErrorMessage = "标签名称不能为空，且不能与现有标签重复。"
                }
            }

            Button("取消", role: .cancel) {
                tagToRename = nil
                renamedTagName = ""
            }
        } message: {
            Text("标签中的常用文本不会受影响。")
        }
        .alert(
            "无法保存标签",
            isPresented: Binding(
                get: { tagErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        tagErrorMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(tagErrorMessage ?? "")
        }
        .alert(
            "删除标签？",
            isPresented: Binding(
                get: { tagToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        tagToDelete = nil
                    }
                }
            )
        ) {
            Button("删除", role: .destructive) {
                if let tagID = tagToDelete?.id {
                    viewModel.deleteTag(id: tagID)
                }
                tagToDelete = nil
            }
            Button("取消", role: .cancel) {
                tagToDelete = nil
            }
        } message: {
            Text("该标签中的文本会移动到“默认”标签，不会被删除。")
        }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            header(title: "常用粘贴板", showsTagButton: true)
            searchBar

            if viewModel.tags.count > 1 {
                TagBarView(
                    viewModel: viewModel,
                    draggedTagID: $draggedTagID,
                    draggedItemID: $draggedItemID,
                    onAddTag: beginAddingTag,
                    onRenameTag: beginRenamingTag,
                    onDeleteTag: { tag in tagToDelete = tag }
                )
            }

            Divider()

            if viewModel.visibleItems.isEmpty, viewModel.hasSearchQuery {
                searchEmptyState
            } else if viewModel.visibleItems.isEmpty {
                emptyState
            } else {
                listContent
            }

            Divider()

            footer
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("搜索文本...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        if viewModel.pasteSelectedItem() {
                            onClose()
                        }
                    }

                if viewModel.hasSearchQuery {
                    Button {
                        viewModel.clearSearch()
                        isSearchFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                } else {
                    Keycap("⌘F")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Picker("搜索范围", selection: $viewModel.searchScope) {
                Text("当前标签").tag(ClipboardViewModel.SearchScope.currentTag)
                Text("全部").tag(ClipboardViewModel.SearchScope.allTags)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("选择搜索当前标签或全部标签")
        }
        .frame(height: Self.searchBarHeight)
        .padding(.horizontal, 18)
        .excludedFromWindowDrag()
    }

    private func beginAddingTag() {
        newTagName = ""
        isAddTagAlertPresented = true
    }

    private func beginRenamingTag(_ tag: PasteTag) {
        renamedTagName = tag.name
        tagToRename = tag
    }

    private var listContent: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(Array(viewModel.visibleItems.enumerated()), id: \.element.id) { index, item in
                    ClipboardRow(
                        item: item,
                        index: index,
                        isSelected: viewModel.selectedItemID == item.id,
                        preview: preview(for: item.text),
                        tagName: viewModel.searchScope == .allTags ? viewModel.tagName(for: item) : nil,
                        showsDragHandle: viewModel.canReorderVisibleItems
                    )
                    .id(item.id)
                    // 单击更新选中项，双击执行用户选择的粘贴或复制操作。
                    // 与 List 的原生拖动手势并行识别，避免点击手势拦截排序。
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            viewModel.selectedItemID = item.id
                        }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            if viewModel.performDoubleClickAction(on: item.id) {
                                onClose()
                            }
                        }
                    )
                    .onDrag {
                        draggedItemID = item.id
                        return NSItemProvider(object: item.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: ClipboardDropDelegate(
                            itemID: item.id,
                            draggedItemID: $draggedItemID,
                            items: viewModel.visibleItems,
                            moveItems: viewModel.moveItems
                        )
                    )
                    .listRowInsets(
                        EdgeInsets(
                            top: Self.listRowSpacing / 2,
                            leading: 18,
                            bottom: Self.listRowSpacing / 2,
                            trailing: 18
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button("复制") {
                            viewModel.copyItem(withID: item.id)
                        }

                        Divider()

                        if viewModel.tags.count > 1 {
                            Menu("移动到标签") {
                                ForEach(viewModel.tags) { tag in
                                    Button {
                                        viewModel.moveItem(withID: item.id, toTagID: tag.id)
                                    } label: {
                                        if item.tagID == tag.id {
                                            Label(tag.name, systemImage: "checkmark")
                                        } else {
                                            Text(tag.name)
                                        }
                                    }
                                    .disabled(item.tagID == tag.id)
                                }
                            }

                            Divider()
                        }

                        Button("编辑") {
                            viewModel.beginEditing(item: item)
                        }
                        Button("删除", role: .destructive) {
                            viewModel.selectedItemID = item.id
                            isDeleteConfirmationPresented = true
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.selectedItemID) { _, selectedItemID in
                guard let selectedItemID else { return }

                withAnimation(PanelStyle.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                    scrollProxy.scrollTo(selectedItemID, anchor: .center)
                }
            }
        }
        .frame(minHeight: listAreaHeight)
        .excludedFromWindowDrag()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.beginAdding()
            } label: {
                Label("添加", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: [.command])
            .excludedFromWindowDrag()

            Button {
                viewModel.beginEditingSelectedItem()
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
            .disabled(viewModel.selectedItemID == nil)
            .excludedFromWindowDrag()

            Button {
                isDeleteConfirmationPresented = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(viewModel.selectedItemID == nil)
            .excludedFromWindowDrag()

            Spacer(minLength: 8)

            Menu {
                Picker("双击操作", selection: $viewModel.doubleClickAction) {
                    Text("自动粘贴").tag(ClipboardViewModel.DoubleClickAction.paste)
                    Text("仅复制").tag(ClipboardViewModel.DoubleClickAction.copy)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("设置双击时自动粘贴或仅复制")
            .accessibilityLabel("双击操作设置")
            .excludedFromWindowDrag()

            Button {
                withAnimation(PanelStyle.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                    isUsageHelpPresented.toggle()
                }
            } label: {
                // 与左侧的设置菜单保持同样的无底板图标样式。
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.92))
            .onDisappear {
                isUsageHelpPresented = false
            }
            .help("查看使用说明")
            .accessibilityLabel("使用说明")
            .accessibilityHint("显示常用粘贴板的操作说明")
            .excludedFromWindowDrag()
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottomTrailing) {
            if isUsageHelpPresented {
                // 气泡从“使用说明”按钮的位置长出，收起时原路缩回。
                UsageHelpBubble(doubleClickAction: viewModel.doubleClickAction)
                    .padding(.trailing, 16)
                    .offset(y: -50)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing))
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有常用文本", systemImage: "doc.on.clipboard")
        } description: {
            Text("把经常输入的内容存起来，随时一键粘贴")
        } actions: {
            Button("添加第一条") {
                viewModel.beginAdding()
            }
            .buttonStyle(.borderedProminent)
            .excludedFromWindowDrag()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: listAreaHeight)
    }

    private var searchEmptyState: some View {
        ContentUnavailableView {
            Label("没有找到匹配文本", systemImage: "magnifyingglass")
        } description: {
            Text(viewModel.searchScope == .currentTag ? "可以换个关键词，或搜索全部标签" : "可以换个关键词再试试")
        } actions: {
            Button("清空搜索") {
                viewModel.clearSearch()
                viewModel.requestSearchFocus()
            }
            .excludedFromWindowDrag()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: listAreaHeight)
    }

    private var editorView: some View {
        VStack(spacing: 0) {
            header(
                title: viewModel.isEditingExistingItem ? "编辑常用文本" : "添加常用文本",
                subtitle: "保存后可用快捷键快速粘贴",
                showsBackButton: true
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("文本内容")
                        .font(.system(size: 12.5, weight: .semibold))

                    Spacer()

                    if viewModel.tags.count > 1 {
                        Picker("所属标签", selection: $viewModel.draftTagID) {
                            ForEach(viewModel.tags) { tag in
                                Label(tag.name, systemImage: TagBarMetrics.symbolName(for: tag))
                                    .tag(tag.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .help("选择所属标签")
                    }

                    Text("支持多行")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                ZStack(alignment: .topLeading) {
                    ClipboardTextEditor(
                        text: $viewModel.draftText,
                        isComposing: $isTextEditorComposing,
                        onSubmit: viewModel.saveDraft
                    )

                    if viewModel.draftText.isEmpty && !isTextEditorComposing {
                        Text("输入你想保存的常用文本…")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            // 与 macOS TextEditor 默认的文本容器内边距保持一致。
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .excludedFromWindowDrag()

                HStack {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5, weight: .semibold))

                    Text("回车保存，Shift + 回车或 ⌘ + 回车换行")
                        .font(.system(size: 11.5, weight: .medium))

                    Spacer()

                    Text("\(viewModel.draftText.count) 字")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 3)
            .onChange(of: viewModel.mode) { _, mode in
                if mode != .editor {
                    isTextEditorComposing = false
                }
            }

            HStack(spacing: 10) {
                Button("取消") {
                    viewModel.cancelEditing()
                }
                .excludedFromWindowDrag()

                Spacer()

                Button {
                    viewModel.saveDraft()
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSaveDraft)
                .excludedFromWindowDrag()
            }
            .controlSize(.large)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func header(
        title: String? = nil,
        subtitle: String? = nil,
        showsBackButton: Bool = false,
        showsTagButton: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            if showsBackButton {
                Button {
                    viewModel.cancelEditing()
                } label: {
                    Image(systemName: "chevron.left")
                        .panelCircleIcon()
                }
                .buttonStyle(PressableButtonStyle(scale: 0.92))
                .help("返回列表")
                .excludedFromWindowDrag()
            }

            if let title {
                if showsTagButton {
                    HStack(spacing: 10) {
                        IconTile(systemImage: "doc.on.clipboard.fill", tint: .accentColor, size: 28)

                        Text(title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)

                        Text(viewModel.hasSearchQuery || viewModel.searchScope == .allTags
                            ? "\(viewModel.visibleItems.count) 结果"
                            : "\(viewModel.items.count) 项")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(.quinary, in: Capsule())
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 18, weight: .bold))
                            .tracking(-0.2)
                            .lineLimit(1)

                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 5)

            if showsTagButton {
                if viewModel.tags.count <= 1 {
                    Button {
                        beginAddingTag()
                    } label: {
                        Label("标签", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("添加标签分类")
                    .excludedFromWindowDrag()
                }

                Keycap("⌥ 空格")
                    .help("全局唤起/隐藏快捷键")
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .panelCircleIcon()
            }
            .buttonStyle(PressableButtonStyle(scale: 0.92))
            .help("关闭")
            .excludedFromWindowDrag()
        }
        .frame(minHeight: showsTagButton ? 32 : 42)
        .padding(.horizontal, showsTagButton ? 18 : 20)
        .padding(.vertical, showsTagButton ? 9 : 14)
    }

    private func preview(for text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "  ↵  ")
            .replacingOccurrences(of: "\r", with: "")
    }
}
