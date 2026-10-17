import Capture
import Foundation
import StudyCore

/// Opened slide PDFs for the result thumbnails, one per deck for the life of the screen.
///
/// Not observable on purpose: filling it while a row is drawn must not invalidate the view.
@MainActor
final class SlideDeckCache {
    private var decks: [Deck.ID: SlideDeck?] = [:]

    func deck(_ deck: Deck, services: StudyServices?) -> SlideDeck? {
        if let known = decks[deck.id] { return known }
        guard let services, let blob = deck.blob else { return nil }
        let opened = try? SlideDeck(
            url: services.blobs.url(for: blob),
            sha256: deck.blobSHA256,
            cacheDirectory: services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory)
        )
        decks[deck.id] = opened
        return opened
    }
}
