import Foundation
import StudyCore

/// Puts back the page text of decks that lost their `deck_page` rows (fewer rows than the deck's
/// `page_count`, or none) from their PDF in the BlobStore: the file's pages are read again
/// (`DeckText.extract`) and only the missing page numbers are inserted; rows that exist are never
/// touched. A deck without its file on this device (blobs do not sync) or with an unreadable one
/// stays as it is.
///
/// Rows went missing when iCloud refused a page whose deck record was not on the server yet
/// (SQLiteData then deletes such a child row on the device, docs/decisions.md 2026-10-22); a
/// lecture whose range of such a deck has no pages has nothing to write its Summary from. Run
/// once per launch where the library passes run (the Mac), in the background; one public log
/// line when a deck lacks pages. The inserted rows sync like any others, and the lecture notes
/// runner queues the versions that waited for them (`requeueWaiting`, it follows `deck_page`).
public struct DeckPageRepair: Sendable {
    public struct Outcome: Sendable, Equatable {
        /// Decks with fewer page rows than pages.
        public var short = 0
        public var repairedDecks = 0
        public var insertedPages = 0
        /// Short decks whose PDF is not on this device.
        public var withoutFile = 0
        /// Short decks whose PDF could not be read.
        public var unreadable = 0
    }

    public let database: any DatabaseWriter
    public let blobs: BlobStore
    private let now: @Sendable () -> Date

    public init(database: any DatabaseWriter, blobs: BlobStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.blobs = blobs
        self.now = now
    }

    public init(services: StudyServices) {
        self.init(database: services.database, blobs: services.blobs)
    }

    @concurrent
    @discardableResult
    public func run() async -> Outcome {
        var outcome = Outcome()
        do {
            let short = try await database.read { db in
                let counts = Dictionary(
                    try DeckPage.group(by: \.deckID).select { ($0.deckID, $0.id.count()) }.fetchAll(db),
                    uniquingKeysWith: { first, _ in first }
                )
                return try Deck.where { $0.pageCount.gt(0) }.fetchAll(db).filter { (counts[$0.id] ?? 0) < $0.pageCount }
            }
            outcome.short = short.count
            guard !short.isEmpty else { return outcome }
            for deck in short {
                guard let blob = deck.blob, blobs.contains(blob) else {
                    outcome.withoutFile += 1
                    continue
                }
                guard let text = DeckText.extract(from: blobs.url(for: blob)), !text.pages.isEmpty else {
                    outcome.unreadable += 1
                    continue
                }
                let deckID = deck.id
                let stamp = now()
                let inserted = try await database.write { db -> Int in
                    // As the deck is now (it may have gone or changed since the read).
                    guard let current = try Deck.find(deckID).fetchOne(db) else { return 0 }
                    let present = Set(try DeckPage.where { $0.deckID.eq(deckID) }.select(\.pageNumber).fetchAll(db))
                    var count = 0
                    for page in text.pages where !present.contains(page.number) && page.number <= current.pageCount {
                        let row = DeckPage(deckID: deckID, pageNumber: page.number, label: page.label, text: page.text, updatedAt: stamp)
                        try DeckPage.insert { row }.execute(db)
                        count += 1
                    }
                    return count
                }
                if inserted > 0 {
                    outcome.repairedDecks += 1
                    outcome.insertedPages += inserted
                }
            }
            Log.importer.notice(
                "Deck pages: \(outcome.short, privacy: .public) deck(s) short of their pages, \(outcome.insertedPages, privacy: .public) page(s) put back in \(outcome.repairedDecks, privacy: .public), \(outcome.withoutFile, privacy: .public) without their file here, \(outcome.unreadable, privacy: .public) unreadable"
            )
        } catch {
            Log.importer.error("Putting back deck pages failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        return outcome
    }
}
