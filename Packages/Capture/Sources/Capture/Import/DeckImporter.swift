import Foundation
import StudyCore

/// Puts a slide PDF into the library: the file into the BlobStore and a `Deck` with one
/// `DeckPage` (number, label, text) per page into the database.
///
/// Minimal on purpose (no course/lecture detection); smart import (#2) builds on it.
public struct DeckImporter: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unreadablePDF(String)
    }

    public let database: any DatabaseWriter
    public let blobs: BlobStore

    public init(database: any DatabaseWriter, blobs: BlobStore) {
        self.database = database
        self.blobs = blobs
    }

    public init(services: StudyServices) {
        self.init(database: services.database, blobs: services.blobs)
    }

    /// Imports the PDF at `url`. If a deck with the same contents exists, returns it unchanged.
    @concurrent
    public func importDeck(at url: URL, courseID: Course.ID? = nil, title: String? = nil) async throws -> (Deck, [DeckPage]) {
        guard let text = DeckText.extract(from: url), !text.pages.isEmpty else {
            throw Failure.unreadablePDF(url.lastPathComponent)
        }
        let ref = try blobs.importFile(at: url, mode: .copy)
        let repository = DeckRepository(store: RecordStore(database: database))

        let existing = try await database.read { db in
            try Deck.where { $0.blobSHA256.eq(ref.sha256) }.fetchOne(db)
        }
        if let existing {
            return (existing, try await repository.pages(deckID: existing.id))
        }

        let deck = Deck(
            courseID: courseID,
            title: title ?? text.title ?? url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            blobSHA256: ref.sha256,
            blobPath: ref.relativePath,
            pageCount: text.pages.count
        )
        let pages = text.pages.map { page in
            DeckPage(deckID: deck.id, pageNumber: page.number, label: page.label, text: page.text)
        }
        try await repository.save(deck: deck, pages: pages)
        return (deck, pages)
    }
}
