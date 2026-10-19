import Capture
import Foundation
import StudyCore

/// Opens slide PDFs for the result thumbnails off the main actor: opening reads every page's box
/// (88 pages for DC L2), which must not stall the first render of a result list.
enum SlideDeckOpener {
    @concurrent
    static func open(_ deck: Deck, services: StudyServices) async -> SlideDeck? {
        guard let blob = deck.blob else { return nil }
        return try? SlideDeck(
            url: services.blobs.url(for: blob),
            sha256: deck.blobSHA256,
            cacheDirectory: services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory),
            // Thumbnails only: a small budget, as Coach's and Notes' (the default is 128 MB).
            memoryBudgetBytes: 8 << 20
        )
    }
}
