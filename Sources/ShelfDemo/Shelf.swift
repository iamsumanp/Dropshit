import Foundation

struct Shelf: Identifiable, Equatable {
    let id: UUID
    var items: [ShelfItem]
    let createdAt: Date
    var name: String?
    var pinned: Bool
    var accent: ShelfAccent?

    init(
        id: UUID = UUID(),
        items: [ShelfItem] = [],
        createdAt: Date = Date(),
        name: String? = nil,
        pinned: Bool = false,
        accent: ShelfAccent? = nil
    ) {
        self.id = id
        self.items = items
        self.createdAt = createdAt
        self.name = name
        self.pinned = pinned
        self.accent = accent
    }
}

enum ShelfAccent: Equatable, Hashable, Codable {
    case color(String)   // hex like "#FF6B6B"
    case emoji(String)   // single grapheme cluster
}
