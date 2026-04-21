import Foundation

struct Shelf: Identifiable, Equatable {
    let id: UUID
    var items: [ShelfItem]
    let createdAt: Date

    init(id: UUID = UUID(), items: [ShelfItem] = [], createdAt: Date = Date()) {
        self.id = id
        self.items = items
        self.createdAt = createdAt
    }
}
