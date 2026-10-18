import Foundation
import SQLiteData

// Repositories added with schema v10 (M6: notes & ink).

/// Slide ink (`slide_ink`): one row per deck page, an empty drawing has none.
public struct SlideInkRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// The page's drawing, nil when it has no ink. With more than one row (two devices wrote the
    /// page before sync merged them) the newest wins.
    public func drawing(deckID: Deck.ID, page: Int) async throws -> InkDrawing? {
        try await store.database.read { db in
            try Self.row(deckID: deckID, page: page, db: db)?.drawing
        }
    }

    /// The deck's pages that have ink (the rail's pencil).
    public func pages(deckID: Deck.ID) async throws -> Set<Int> {
        try await store.database.read { db in
            Set(try SlideInk.where { $0.deckID.eq(deckID) }.select(\.pageNumber).fetchAll(db))
        }
    }

    /// Writes the page's drawing: updates its row (and drops any duplicates), or inserts one; an
    /// empty drawing deletes the page's rows. One transaction.
    public func save(_ drawing: InkDrawing, deckID: Deck.ID, page: Int) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            let rows = try SlideInk
                .where { $0.deckID.eq(deckID) && $0.pageNumber.eq(page) }
                .order { $0.updatedAt.desc() }
                .fetchAll(db)
            if drawing.isEmpty {
                try SlideInk.where { $0.deckID.eq(deckID) && $0.pageNumber.eq(page) }.delete().execute(db)
                return
            }
            if var row = rows.first {
                row.drawing = drawing
                row.updatedAt = stamp
                try SlideInk.upsert { row }.execute(db)
                for duplicate in rows.dropFirst() {
                    try SlideInk.find(duplicate.id).delete().execute(db)
                }
            } else {
                let row = SlideInk(deckID: deckID, pageNumber: page, drawing: drawing, createdAt: stamp, updatedAt: stamp)
                try SlideInk.upsert { row }.execute(db)
            }
        }
    }

    private static func row(deckID: Deck.ID, page: Int, db: Database) throws -> SlideInk? {
        try SlideInk
            .where { $0.deckID.eq(deckID) && $0.pageNumber.eq(page) }
            .order { $0.updatedAt.desc() }
            .fetchOne(db)
    }
}
