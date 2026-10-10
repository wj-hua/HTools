import Foundation

struct PasteTag: Identifiable, Codable, Equatable {
    // A stable ID lets legacy items keep the same relationship after migration.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultName = "默认"
    static let defaultTag = PasteTag(id: defaultID, name: defaultName, order: 0)

    let id: UUID
    var name: String
    var order: Int

    init(id: UUID = UUID(), name: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.order = order
    }

    var isDefault: Bool {
        id == Self.defaultID
    }
}

struct PasteItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var order: Int
    var tagID: UUID

    init(
        id: UUID = UUID(),
        text: String,
        order: Int = 0,
        tagID: UUID = PasteTag.defaultID
    ) {
        self.id = id
        self.text = text
        self.order = order
        self.tagID = tagID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case order
        case tagID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        order = try container.decode(Int.self, forKey: .order)

        // The original items.json did not contain tagID. Treat those records
        // as members of the stable default tag during decoding.
        tagID = try container.decodeIfPresent(UUID.self, forKey: .tagID) ?? PasteTag.defaultID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(order, forKey: .order)
        try container.encode(tagID, forKey: .tagID)
    }
}
