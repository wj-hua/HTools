import AppKit
import Combine
import Foundation

final class ClipboardViewModel: ObservableObject {
    enum DoubleClickAction: String, CaseIterable, Identifiable {
        case paste
        case copy

        var id: Self { self }
    }

    enum Mode: Equatable {
        case list
        case editor
    }

    enum SearchScope: String, CaseIterable, Identifiable {
        case currentTag
        case allTags

        var id: Self { self }
    }

    @Published private(set) var tags: [PasteTag]
    @Published private(set) var items: [PasteItem]
    @Published var selectedTagID: UUID?
    @Published var selectedItemID: UUID?
    @Published private(set) var mode: Mode = .list
    @Published var draftText = ""
    @Published var draftTagID: UUID = PasteTag.defaultID
    @Published private(set) var editingItemID: UUID?
    @Published var isShowingPermission = false
    @Published var alertMessage: String?
    @Published var searchText = "" {
        didSet {
            synchronizeSelectionWithVisibleItems()
        }
    }
    @Published var searchScope: SearchScope = .currentTag {
        didSet {
            synchronizeSelectionWithVisibleItems()
        }
    }
    @Published private(set) var searchFocusRequest = 0
    @Published var doubleClickAction: DoubleClickAction {
        didSet {
            userDefaults.set(doubleClickAction.rawValue, forKey: Self.doubleClickActionDefaultsKey)
        }
    }

    private let store: PasteItemStore
    private let pasteService: PasteService
    private let userDefaults: UserDefaults
    private var targetApplication: NSRunningApplication?
    private static let doubleClickActionDefaultsKey = "doubleClickAction"

    convenience init(store: PasteItemStore, pasteService: PasteService) {
        self.init(store: store, pasteService: pasteService, userDefaults: .standard)
    }

    init(store: PasteItemStore, pasteService: PasteService, userDefaults: UserDefaults) {
        self.store = store
        self.pasteService = pasteService
        self.userDefaults = userDefaults
        self.doubleClickAction = userDefaults.string(forKey: Self.doubleClickActionDefaultsKey)
            .flatMap(DoubleClickAction.init(rawValue:)) ?? .paste
        self.tags = store.tags
        let initialTagID = store.tags.first?.id ?? PasteTag.defaultID
        self.selectedTagID = initialTagID
        self.draftTagID = initialTagID
        self.items = store.items(for: initialTagID)
        self.selectedItemID = self.items.first?.id
    }

    var isEditingExistingItem: Bool {
        editingItemID != nil
    }

    var canSaveDraft: Bool {
        PasteItemStore.isValidText(draftText)
    }

    var visibleItems: [PasteItem] {
        let candidates: [PasteItem]
        switch searchScope {
        case .currentTag:
            candidates = items
        case .allTags:
            candidates = store.items
        }

        let searchTerms = searchText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !searchTerms.isEmpty else { return candidates }

        return candidates.filter { item in
            searchTerms.allSatisfy { term in
                item.text.localizedStandardContains(term)
            }
        }
    }

    var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canReorderVisibleItems: Bool {
        searchScope == .currentTag && !hasSearchQuery
    }

    func prepareForPresentation(targetApplication: NSRunningApplication?) {
        self.targetApplication = targetApplication
        mode = .list
        editingItemID = nil
        draftText = ""
        draftTagID = selectedTagID ?? PasteTag.defaultID
        searchText = ""
        searchScope = .currentTag
        isShowingPermission = false
        alertMessage = nil
        refreshFromStore()
        selectedItemID = visibleItems.first?.id
    }

    func refreshFromStore() {
        store.reload()
        tags = store.tags

        if let selectedTagID, tags.contains(where: { $0.id == selectedTagID }) {
            self.selectedTagID = selectedTagID
        } else {
            self.selectedTagID = tags.first?.id
        }

        items = selectedTagID.map(store.items(for:)) ?? []

        if let selectedItemID, visibleItems.contains(where: { $0.id == selectedItemID }) {
            return
        }
        self.selectedItemID = visibleItems.first?.id
    }

    func dismiss() {
        mode = .list
        editingItemID = nil
        draftText = ""
        draftTagID = selectedTagID ?? PasteTag.defaultID
        searchText = ""
        searchScope = .currentTag
        isShowingPermission = false
        alertMessage = nil
        targetApplication = nil
    }

    func beginAdding() {
        mode = .editor
        editingItemID = nil
        draftText = ""
        draftTagID = selectedTagID ?? PasteTag.defaultID
        alertMessage = nil
    }

    func beginEditingSelectedItem() {
        guard let selectedItem = selectedItem else { return }
        beginEditing(item: selectedItem)
    }

    func beginEditing(item: PasteItem) {
        mode = .editor
        editingItemID = item.id
        draftText = item.text
        draftTagID = item.tagID
        selectedItemID = item.id
        alertMessage = nil
    }

    func cancelEditing() {
        mode = .list
        editingItemID = nil
        draftText = ""
        draftTagID = selectedTagID ?? PasteTag.defaultID
        alertMessage = nil
    }

    func selectTag(withID tagID: UUID) {
        guard tags.contains(where: { $0.id == tagID }) else { return }

        searchScope = .currentTag
        selectedTagID = tagID
        items = store.items(for: tagID)
        selectedItemID = visibleItems.first?.id
    }

    func moveTagSelection(by offset: Int) {
        guard let selectedTagID,
              let currentIndex = tags.firstIndex(where: { $0.id == selectedTagID }) else {
            guard let firstTag = tags.first else { return }
            selectTag(withID: firstTag.id)
            return
        }

        let nextIndex = wrappedIndex(from: currentIndex, offset: offset, count: tags.count)

        selectTag(withID: tags[nextIndex].id)
    }

    @discardableResult
    func addTag(name: String) -> Bool {
        guard let tag = store.addTag(name: name) else { return false }

        tags = store.tags
        selectedTagID = tag.id
        items = store.items(for: tag.id)
        selectedItemID = nil
        return true
    }

    @discardableResult
    func renameTag(id: UUID, name: String) -> Bool {
        guard store.renameTag(id: id, name: name) else { return false }

        tags = store.tags
        return true
    }

    @discardableResult
    func deleteTag(id: UUID) -> Bool {
        guard store.deleteTag(id: id) else { return false }

        tags = store.tags
        if selectedTagID == id {
            selectedTagID = PasteTag.defaultID
        } else if !tags.contains(where: { $0.id == selectedTagID }) {
            selectedTagID = tags.first?.id
        }
        items = selectedTagID.map(store.items(for:)) ?? []
        selectedItemID = items.first?.id
        return true
    }

    func moveTags(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        store.moveTags(fromOffsets: offsets, toOffset: destination)
        tags = store.tags
    }

    func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    @discardableResult
    func clearSearch() -> Bool {
        guard hasSearchQuery else { return false }

        searchText = ""
        return true
    }

    func tagName(for item: PasteItem) -> String? {
        tags.first(where: { $0.id == item.tagID })?.name
    }

    func saveDraft() {
        guard canSaveDraft else { return }

        if let editingItemID {
            guard store.update(id: editingItemID, text: draftText, tagID: draftTagID) else { return }
            selectedItemID = editingItemID
        } else if let newItem = store.add(text: draftText, to: draftTagID) {
            selectedItemID = newItem.id
        } else {
            return
        }

        refreshFromStore()
        mode = .list
        self.editingItemID = nil
        draftText = ""
    }

    @discardableResult
    func moveItem(withID itemID: UUID, toTagID tagID: UUID) -> Bool {
        guard store.moveItem(withID: itemID, toTagID: tagID) else { return false }
        refreshFromStore()
        return true
    }

    @discardableResult
    func deleteSelectedItem() -> Bool {
        guard let selectedItemID else { return false }

        let deleted = store.delete(id: selectedItemID)
        guard deleted else { return false }

        refreshFromStore()
        return true
    }

    func moveItems(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard canReorderVisibleItems else { return }

        store.move(
            fromOffsets: offsets,
            toOffset: destination,
            in: selectedTagID ?? PasteTag.defaultID
        )
        items = selectedTagID.map(store.items(for:)) ?? []
    }

    func selectItem(at index: Int) {
        let visibleItems = self.visibleItems
        guard visibleItems.indices.contains(index) else { return }

        selectedItemID = visibleItems[index].id
    }

    @discardableResult
    func pasteItem(at index: Int) -> Bool {
        let visibleItems = self.visibleItems
        guard visibleItems.indices.contains(index) else { return false }

        selectedItemID = visibleItems[index].id
        return pasteSelectedItem()
    }

    func moveSelection(by offset: Int) {
        let visibleItems = self.visibleItems
        guard !visibleItems.isEmpty else {
            selectedItemID = nil
            return
        }

        guard let selectedItemID,
              let currentIndex = visibleItems.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = visibleItems.first?.id
            return
        }

        let nextIndex = wrappedIndex(from: currentIndex, offset: offset, count: visibleItems.count)
        self.selectedItemID = visibleItems[nextIndex].id
    }

    @discardableResult
    func pasteSelectedItem() -> Bool {
        guard let selectedItem else { return false }

        guard pasteService.isAccessibilityTrusted() else {
            isShowingPermission = true
            return false
        }

        guard let targetApplication else {
            alertMessage = "没有找到需要粘贴的目标应用。请从其他应用中按 Option + 空格 打开。"
            return false
        }

        pasteService.paste(text: selectedItem.text, into: targetApplication)
        return true
    }

    /// Copies the selected text to the system clipboard without activating a
    /// target app or requiring Accessibility permission.
    @discardableResult
    func copySelectedItem() -> Bool {
        guard let selectedItem else { return false }

        guard pasteService.copy(text: selectedItem.text) else {
            alertMessage = "无法将所选文本复制到系统剪贴板，请重试。"
            return false
        }
        return true
    }

    @discardableResult
    func copyItem(withID itemID: UUID) -> Bool {
        guard visibleItems.contains(where: { $0.id == itemID }) else { return false }

        selectedItemID = itemID
        return copySelectedItem()
    }

    @discardableResult
    func performDoubleClickAction(on itemID: UUID) -> Bool {
        switch doubleClickAction {
        case .paste:
            return pasteItem(withID: itemID)
        case .copy:
            return copyItem(withID: itemID)
        }
    }

    /// Selects an item and sends it through the same paste path as Return.
    /// Keeping selection and paste together prevents an item shortcut from
    /// pasting whichever item happened to be selected previously.
    @discardableResult
    func pasteItem(withID itemID: UUID) -> Bool {
        guard visibleItems.contains(where: { $0.id == itemID }) else { return false }

        selectedItemID = itemID
        return pasteSelectedItem()
    }

    func requestAccessibilityPermission() {
        pasteService.requestAccessibilityPermission()
    }

    func openAccessibilitySettings() {
        pasteService.openAccessibilitySettings()
    }

    func dismissPermissionNotice() {
        isShowingPermission = false
    }

    @discardableResult
    func refreshAccessibilityPermission() -> Bool {
        let isTrusted = pasteService.isAccessibilityTrusted()
        if isTrusted {
            isShowingPermission = false
        }
        return isTrusted
    }

    private var selectedItem: PasteItem? {
        guard let selectedItemID else { return nil }
        return visibleItems.first(where: { $0.id == selectedItemID })
    }

    private func synchronizeSelectionWithVisibleItems() {
        let visibleItems = self.visibleItems
        if let selectedItemID,
           visibleItems.contains(where: { $0.id == selectedItemID }) {
            return
        }

        selectedItemID = visibleItems.first?.id
    }

    private func wrappedIndex(from currentIndex: Int, offset: Int, count: Int) -> Int {
        let normalizedOffset = offset % count
        return (currentIndex + normalizedOffset + count) % count
    }
}
