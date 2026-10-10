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
        ZStack {
            panelBackdrop

            Group {
                switch viewModel.mode {
                case .list:
                    listView
                case .editor:
                    editorView
                }
            }
        }
        .frame(width: Self.panelWidth, height: panelHeight)
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
        .overlay {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color.white.opacity(0.40),
                            ClipboardTheme.accent.opacity(0.20),
                            Color.white.opacity(0.60)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 30, y: 16)
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
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
        // 面板保持浅色高透玻璃，质感纯净通透。
        .environment(\.colorScheme, .light)
    }

    private var panelBackdrop: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.82))

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.92)

            // 极简温润的高级光晕微渐变，替代原先生硬的水波纹
            LinearGradient(
                colors: [
                    ClipboardTheme.accentSoft.opacity(0.65),
                    Color.white.opacity(0.20),
                    Color(red: 0.92, green: 0.95, blue: 0.98).opacity(0.55)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 左上角冷萃翡翠微光
            Circle()
                .fill(ClipboardTheme.accent.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: -150, y: -160)

            // 右下角冰川钛光
            Circle()
                .fill(Color(red: 0.35, green: 0.65, blue: 0.90).opacity(0.10))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: 170, y: 160)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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

            if viewModel.visibleItems.isEmpty, viewModel.hasSearchQuery {
                searchEmptyState
            } else if viewModel.visibleItems.isEmpty {
                emptyState
            } else {
                listContent
            }

            footer
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ClipboardTheme.accent.opacity(0.85))

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
                            .foregroundStyle(ClipboardTheme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                } else {
                    Text("⌘F")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ClipboardTheme.inkTertiary.opacity(0.75))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.black.opacity(0.04))
                        }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.75))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.95),
                                        Color.black.opacity(0.07)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    }
                    .shadow(color: Color.black.opacity(0.02), radius: 3, y: 1)
            }

            // 自研无缝融合的范围切换胶囊，消除系统默认突兀的亮蓝色
            HStack(spacing: 2) {
                scopeTabButton(title: "当前标签", scope: .currentTag)
                scopeTabButton(title: "全部", scope: .allTags)
            }
            .padding(2.5)
            .frame(width: 142, height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.045))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
                    }
            }
            .help("选择搜索当前标签或全部标签")
        }
        .frame(height: Self.searchBarHeight)
        .padding(.horizontal, 18)
        .background {
            Rectangle()
                .fill(Color.white.opacity(0.20))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.black.opacity(0.05))
                        .frame(height: 0.8)
                }
        }
        .excludedFromWindowDrag()
    }

    private func scopeTabButton(title: String, scope: ClipboardViewModel.SearchScope) -> some View {
        let isSelected = viewModel.searchScope == scope
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                viewModel.searchScope = scope
            }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .default))
                .foregroundStyle(isSelected ? ClipboardTheme.ink : ClipboardTheme.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.white, Color.black.opacity(0.06)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 0.8
                                    )
                            }
                            .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

                withAnimation(.snappy(duration: 0.22)) {
                    scrollProxy.scrollTo(selectedItemID, anchor: .center)
                }
            }
        }
        .frame(minHeight: listAreaHeight)
        .excludedFromWindowDrag()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // 主操作按钮：翡翠质感渐变与微反光
            Button {
                viewModel.beginAdding()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("添加")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ClipboardTheme.accentGradient)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                        }
                        .shadow(color: ClipboardTheme.accent.opacity(0.35), radius: 4, y: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: [.command])
            .excludedFromWindowDrag()

            controlButton(
                title: "编辑",
                systemImage: "square.and.pencil",
                isDisabled: viewModel.selectedItemID == nil
            ) {
                viewModel.beginEditingSelectedItem()
            }

            controlButton(
                title: "删除",
                systemImage: "trash",
                isDisabled: viewModel.selectedItemID == nil
            ) {
                isDeleteConfirmationPresented = true
            }

            Spacer(minLength: 8)

            Menu {
                Picker("双击操作", selection: $viewModel.doubleClickAction) {
                    Text("自动粘贴").tag(ClipboardViewModel.DoubleClickAction.paste)
                    Text("仅复制").tag(ClipboardViewModel.DoubleClickAction.copy)
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClipboardTheme.inkSecondary)
                    .frame(width: 32, height: 32)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(0.55))
                            .overlay {
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.white, Color.black.opacity(0.08)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 0.8
                                    )
                            }
                            .shadow(color: Color.black.opacity(0.02), radius: 2, y: 1)
                    }
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("设置双击时自动粘贴或仅复制")
            .accessibilityLabel("双击操作设置")
            .excludedFromWindowDrag()

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isUsageHelpPresented.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ClipboardTheme.accent)
                    Text("使用说明")
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundStyle(ClipboardTheme.inkSecondary)
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background {
                    Capsule()
                        .fill(Color.white.opacity(0.55))
                        .overlay {
                            Capsule()
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.white, Color.black.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.8
                                )
                        }
                        .shadow(color: Color.black.opacity(0.02), radius: 2, y: 1)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onDisappear {
                isUsageHelpPresented = false
            }
            .help("查看使用说明")
            .accessibilityHint("显示常用粘贴板的操作说明")
            .excludedFromWindowDrag()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.black.opacity(0.06))
                        .frame(height: 0.8)
                }
        }
        .overlay(alignment: .bottomTrailing) {
            if isUsageHelpPresented {
                UsageHelpBubble(doubleClickAction: viewModel.doubleClickAction)
                    .padding(.trailing, 16)
                    .offset(y: -46)
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.96, anchor: .bottomTrailing)
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private func controlButton(
        title: String,
        systemImage: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium, design: .default))
            }
            .foregroundStyle(isDisabled ? ClipboardTheme.inkTertiary : ClipboardTheme.ink)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white, Color.black.opacity(0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    }
                    .shadow(color: Color.black.opacity(0.02), radius: 2, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .excludedFromWindowDrag()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                ClipboardTheme.accent.opacity(0.16),
                                ClipboardTheme.accent.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(ClipboardTheme.accent.opacity(0.25), lineWidth: 1)
                    }

                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ClipboardTheme.accentDeep)
            }

            VStack(spacing: 4) {
                Text("还没有常用文本")
                    .font(.system(size: 16, weight: .bold, design: .default))
                    .foregroundStyle(ClipboardTheme.ink)

                Text("把经常输入的内容存起来，随时一键粘贴")
                    .font(.system(size: 12.5, weight: .regular, design: .default))
                    .foregroundStyle(ClipboardTheme.inkSecondary)
            }

            Button {
                viewModel.beginAdding()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("添加第一条")
                        .font(.system(size: 12.5, weight: .semibold, design: .default))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ClipboardTheme.accentGradient)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                        }
                        .shadow(color: ClipboardTheme.accent.opacity(0.30), radius: 4, y: 2)
                }
            }
            .buttonStyle(.plain)
            .excludedFromWindowDrag()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: listAreaHeight)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(ClipboardTheme.accent.opacity(0.70))

            VStack(spacing: 4) {
                Text("没有找到匹配文本")
                    .font(.system(size: 15, weight: .bold, design: .default))
                    .foregroundStyle(ClipboardTheme.ink)

                Text(viewModel.searchScope == .currentTag ? "可以换个关键词，或搜索全部标签" : "可以换个关键词再试试")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(ClipboardTheme.inkSecondary)
            }

            Button {
                viewModel.clearSearch()
                viewModel.requestSearchFocus()
            } label: {
                Text("清空搜索")
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(ClipboardTheme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.60))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                            }
                    }
            }
            .buttonStyle(.plain)
            .excludedFromWindowDrag()

            Spacer()
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
                        .font(.system(size: 12.5, weight: .bold, design: .default))
                        .foregroundStyle(ClipboardTheme.ink)

                    Spacer()

                    if viewModel.tags.count > 1 {
                        Menu {
                            ForEach(viewModel.tags) { tag in
                                Button {
                                    viewModel.draftTagID = tag.id
                                } label: {
                                    if viewModel.draftTagID == tag.id {
                                        Label(tag.name, systemImage: "checkmark")
                                    } else {
                                        Text(tag.name)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 9.5))
                                Text(draftTagName)
                                    .font(.system(size: 11.5, weight: .semibold, design: .default))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(ClipboardTheme.accentDeep.opacity(0.7))
                            }
                            .foregroundStyle(ClipboardTheme.accentDeep)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background {
                                Capsule()
                                    .fill(ClipboardTheme.accent.opacity(0.12))
                                    .overlay {
                                        Capsule()
                                            .stroke(ClipboardTheme.accent.opacity(0.22), lineWidth: 0.8)
                                    }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("选择所属标签")
                    }

                    Text("支持多行")
                        .font(.system(size: 11.5, weight: .medium, design: .default))
                        .foregroundStyle(ClipboardTheme.inkTertiary)
                }

                ZStack(alignment: .topLeading) {
                    ClipboardTextEditor(
                        text: $viewModel.draftText,
                        isComposing: $isTextEditorComposing,
                        onSubmit: viewModel.saveDraft
                    )

                    if viewModel.draftText.isEmpty && !isTextEditorComposing {
                        Text("输入你想保存的常用文本…")
                            .font(.system(size: 14, weight: .regular, design: .default))
                            .foregroundStyle(ClipboardTheme.inkTertiary)
                            // 与 macOS TextEditor 默认的文本容器内边距保持一致。
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.75))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.white, Color.black.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: Color.black.opacity(0.02), radius: 4, y: 1)
                }
                .excludedFromWindowDrag()

                HStack {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5, weight: .semibold))

                    Text("回车保存，Shift + 回车或 ⌘ + 回车换行")
                        .font(.system(size: 11.5, weight: .medium, design: .default))

                    Spacer()

                    Text("\(viewModel.draftText.count) 字")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(ClipboardTheme.inkTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 3)
            .onChange(of: viewModel.mode) { _, mode in
                if mode != .editor {
                    isTextEditorComposing = false
                }
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.cancelEditing()
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium, design: .default))
                        .foregroundStyle(ClipboardTheme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.60))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                                }
                                .shadow(color: Color.black.opacity(0.02), radius: 2, y: 1)
                        }
                }
                .buttonStyle(.plain)
                .excludedFromWindowDrag()

                Spacer()

                Button {
                    viewModel.saveDraft()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                        Text("保存")
                            .font(.system(size: 13, weight: .semibold, design: .default))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(viewModel.canSaveDraft ? AnyShapeStyle(ClipboardTheme.accentGradient) : AnyShapeStyle(Color.gray.opacity(0.35)))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                            }
                            .shadow(color: viewModel.canSaveDraft ? ClipboardTheme.accent.opacity(0.35) : .clear, radius: 4, y: 2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSaveDraft)
                .excludedFromWindowDrag()
            }
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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ClipboardTheme.inkSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background {
                    Circle()
                        .fill(Color.white.opacity(0.55))
                        .overlay {
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.white, Color.black.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.8
                                )
                        }
                        .shadow(color: Color.black.opacity(0.02), radius: 2, y: 1)
                }
                .help("返回列表")
                .excludedFromWindowDrag()
            }

            if let title {
                if showsTagButton {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            ClipboardTheme.accent.opacity(0.18),
                                            ClipboardTheme.accent.opacity(0.08)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.8),
                                                    ClipboardTheme.accent.opacity(0.3)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1
                                        )
                                }
                                .shadow(color: ClipboardTheme.accent.opacity(0.15), radius: 3, y: 1)

                            Image(systemName: "doc.on.clipboard.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [ClipboardTheme.accent, ClipboardTheme.accentDeep],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(.system(size: 14.5, weight: .bold, design: .default))
                                    .foregroundStyle(ClipboardTheme.ink)
                                    .lineLimit(1)

                                Text(viewModel.hasSearchQuery || viewModel.searchScope == .allTags
                                    ? "\(viewModel.visibleItems.count) 结果"
                                    : "\(viewModel.items.count) 项")
                                    .font(.system(size: 10, weight: .semibold, design: .default))
                                    .foregroundStyle(ClipboardTheme.inkSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background {
                                        Capsule()
                                            .fill(Color.black.opacity(0.04))
                                            .overlay {
                                                Capsule().stroke(Color.black.opacity(0.05), lineWidth: 0.5)
                                            }
                                    }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 18, weight: .bold, design: .default))
                            .foregroundStyle(ClipboardTheme.ink)
                            .lineLimit(1)

                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11.5, weight: .medium, design: .default))
                                .foregroundStyle(ClipboardTheme.inkTertiary)
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
                        HStack(spacing: 4) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 10))
                            Text("标签")
                            Image(systemName: "plus")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .font(.system(size: 11.5, weight: .semibold, design: .default))
                        .foregroundStyle(ClipboardTheme.accentDeep)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background {
                        Capsule()
                            .fill(ClipboardTheme.accent.opacity(0.10))
                            .overlay {
                                Capsule()
                                    .stroke(ClipboardTheme.accent.opacity(0.20), lineWidth: 0.8)
                            }
                    }
                    .help("添加标签分类")
                    .excludedFromWindowDrag()
                }

                // 全局快捷键指示徽章
                HStack(spacing: 3) {
                    Text("⌥")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                    Text("空格")
                        .font(.system(size: 9.5, weight: .medium, design: .default))
                }
                .foregroundStyle(ClipboardTheme.inkTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background {
                    Capsule()
                        .fill(Color.white.opacity(0.50))
                        .overlay {
                            Capsule().stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                        }
                }
                .help("全局唤起/隐藏快捷键")
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ClipboardTheme.inkSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background {
                Circle()
                    .fill(Color.white.opacity(0.60))
                    .overlay {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white, Color.black.opacity(0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    }
                    .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
            }
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

    private var draftTagName: String {
        viewModel.tags.first(where: { $0.id == viewModel.draftTagID })?.name ?? PasteTag.defaultName
    }
}
