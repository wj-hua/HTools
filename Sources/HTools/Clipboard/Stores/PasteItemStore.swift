import Combine
import Foundation

final class PasteItemStore: ObservableObject {
    @Published private(set) var tags: [PasteTag] = [PasteTag.defaultTag]
    @Published private(set) var items: [PasteItem] = []

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        load()
    }

    @discardableResult
    func add(text: String) -> PasteItem? {
        add(text: text, to: PasteTag.defaultID)
    }

    @discardableResult
    func add(text: String, to tagID: UUID) -> PasteItem? {
        guard Self.isValidText(text) else { return nil }

        let targetTagID = tags.contains(where: { $0.id == tagID }) ? tagID : PasteTag.defaultID
        let item = PasteItem(text: text, order: items(for: targetTagID).count, tagID: targetTagID)
        items.append(item)
        normalizeAndSave()
        return item
    }

    @discardableResult
    func update(id: UUID, text: String, tagID: UUID? = nil) -> Bool {
        guard Self.isValidText(text), let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }

        items[index].text = text
        if let tagID, tags.contains(where: { $0.id == tagID }), items[index].tagID != tagID {
            items[index].tagID = tagID
            items[index].order = items(for: tagID).count
        }
        normalizeAndSave()
        return true
    }

    @discardableResult
    func moveItem(withID id: UUID, toTagID tagID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              tags.contains(where: { $0.id == tagID }) else {
            return false
        }

        guard items[index].tagID != tagID else { return true }

        items[index].tagID = tagID
        items[index].order = items(for: tagID).count
        normalizeAndSave()
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }

        items.remove(at: index)
        normalizeAndSave()
        return true
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        move(fromOffsets: offsets, toOffset: destination, in: PasteTag.defaultID)
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int, in tagID: UUID) {
        var taggedItems = items(for: tagID)
        guard !taggedItems.isEmpty else { return }

        taggedItems.move(fromOffsets: offsets, toOffset: destination)
        let orderByID = Dictionary(uniqueKeysWithValues: taggedItems.enumerated().map { ($0.element.id, $0.offset) })

        for index in items.indices {
            guard let order = orderByID[items[index].id] else { continue }
            items[index].order = order
        }
        normalizeAndSave()
    }

    @discardableResult
    func addTag(name: String) -> PasteTag? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTagNameAvailable(normalizedName) else { return nil }

        let tag = PasteTag(name: normalizedName, order: tags.count)
        tags.append(tag)
        normalizeAndSave()
        return tag
    }

    /// Renames an existing tag. The tag ID stays stable, so items keep their
    /// relationship and no reordering happens.
    @discardableResult
    func renameTag(id: UUID, name: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = tags.firstIndex(where: { $0.id == id }),
              isTagNameAvailable(normalizedName, excluding: id) else {
            return false
        }

        tags[index].name = normalizedName
        normalizeAndSave()
        return true
    }

    @discardableResult
    func deleteTag(id: UUID) -> Bool {
        guard id != PasteTag.defaultID,
              tags.contains(where: { $0.id == id }) else {
            return false
        }

        for index in items.indices where items[index].tagID == id {
            items[index].tagID = PasteTag.defaultID
        }
        tags.removeAll { $0.id == id }
        normalizeAndSave()
        return true
    }

    func moveTags(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        tags.move(fromOffsets: offsets, toOffset: destination)
        tags = tags.enumerated().map { index, tag in
            var movedTag = tag
            movedTag.order = index
            return movedTag
        }
        normalizeAndSave()
    }

    func items(for tagID: UUID) -> [PasteItem] {
        items.enumerated()
            .filter { $0.element.tagID == tagID }
            .sorted { left, right in
                if left.element.order == right.element.order {
                    return left.offset < right.offset
                }
                return left.element.order < right.element.order
            }
            .map(\.element)
    }

    func reload() {
        load()
    }

    static func isValidText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            tags = [PasteTag.defaultTag]
            items = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()

            if let decoded = try? decoder.decode(PersistedData.self, from: data) {
                tags = decoded.tags
                items = decoded.items
            } else {
                // Migrate the original top-level [PasteItem] format. PasteItem's
                // decoder supplies the default tag ID for missing tagID values.
                let legacyItems = try decoder.decode([PasteItem].self, from: data)
                tags = [PasteTag.defaultTag]
                items = legacyItems.map { item in
                    var migratedItem = item
                    migratedItem.tagID = PasteTag.defaultID
                    return migratedItem
                }
                normalizeInMemory()
                save()
                return
            }

            normalizeInMemory()
        } catch {
            // A corrupt or incompatible file should not prevent the app from launching.
            tags = [PasteTag.defaultTag]
            items = []
        }
    }

    private func normalizeAndSave() {
        normalizeInMemory()
        save()
    }

    private func normalizeInMemory() {
        var normalizedTags = tags
        if !normalizedTags.contains(where: { $0.id == PasteTag.defaultID }) {
            normalizedTags.append(PasteTag.defaultTag)
        }

        normalizedTags = normalizedTags.enumerated().sorted { left, right in
            if left.element.order == right.element.order {
                return left.offset < right.offset
            }
            return left.element.order < right.element.order
        }.map(\.element)

        tags = normalizedTags.enumerated().map { index, tag in
            var normalizedTag = tag
            normalizedTag.order = index
            return normalizedTag
        }

        let validTagIDs = Set(tags.map(\.id))
        items = items.map { item in
            var normalizedItem = item
            if !validTagIDs.contains(normalizedItem.tagID) {
                normalizedItem.tagID = PasteTag.defaultID
            }
            return normalizedItem
        }

        items = tags.flatMap { tag in
            items.enumerated()
                .filter { $0.element.tagID == tag.id }
                .sorted { left, right in
                    if left.element.order == right.element.order {
                        return left.offset < right.offset
                    }
                    return left.element.order < right.element.order
                }
                .enumerated()
                .map { index, pair in
                    var normalizedItem = pair.element
                    normalizedItem.order = index
                    return normalizedItem
                }
        }
    }

    private func save() {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(PersistedData(tags: tags, items: items))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence errors are intentionally non-fatal. The in-memory list remains usable.
        }
    }

    /// A tag name must be non-empty and unique. `excluding` lets a rename keep
    /// its own current name (including a pure letter-case change).
    private func isTagNameAvailable(_ normalizedName: String, excluding id: UUID? = nil) -> Bool {
        guard !normalizedName.isEmpty else { return false }

        return !tags.contains { tag in
            tag.id != id && tag.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent("com.mino.CommonClipboard", isDirectory: true)
            .appendingPathComponent("items.json", isDirectory: false)
    }

    private struct PersistedData: Codable {
        let tags: [PasteTag]
        let items: [PasteItem]
    }
}
