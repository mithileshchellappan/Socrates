import Foundation
import Observation
import StudyCore

/// The student's ink on one deck page (PRD #17, docs/plan-m6.md §4): loads the page's drawing
/// through `SlideInkRepository` and writes it back `debounce` after the last change (a stroke, an
/// erase, an undo) and when `flush()` is called (the page changes, the screen closes). Ink is per
/// deck page: the same drawing shows on that slide in every lecture. An empty drawing deletes the
/// page's row. Writes run one after another.
@MainActor
@Observable
public final class SlideInkEditor {
    public let deckID: Deck.ID
    public let page: Int
    /// In `InkDrawing.slide(aspectRatio:)` units of the page. Empty until `load()` has read it.
    public var drawing: InkDrawing {
        didSet {
            if isLoaded, drawing != oldValue { schedule() }
        }
    }
    /// The stored drawing has been read: only then may the student draw (an edit before that
    /// would overwrite the page's ink with the new strokes alone). Stays false when reading failed.
    public private(set) var isLoaded = false

    @ObservationIgnored private let repository: SlideInkRepository
    @ObservationIgnored private let debounce: Duration
    /// What the database holds (as far as this editor knows).
    @ObservationIgnored private var saved: InkDrawing
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    /// `aspectRatio`: the page's width / height with its crop box and rotation
    /// (`SlideDeck.aspectRatio(page:)`), for a page without ink yet.
    public init(deckID: Deck.ID, page: Int, aspectRatio: Double, store: RecordStore, debounce: Duration = .milliseconds(500)) {
        self.deckID = deckID
        self.page = page
        repository = SlideInkRepository(store: store)
        self.debounce = debounce
        let empty = InkDrawing.slide(aspectRatio: aspectRatio)
        drawing = empty
        saved = empty
    }

    /// Reads the page's drawing (once).
    public func load() async {
        guard !isLoaded else { return }
        do {
            if let stored = try await repository.drawing(deckID: deckID, page: page) {
                saved = stored
                drawing = stored
            }
            isLoaded = true
        } catch {
            ReviewLog.logger.error("Reading slide ink failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes a pending change now.
    public func flush() {
        pending?.cancel()
        pending = nil
        write()
    }

    // MARK: - Private

    private func schedule() {
        pending?.cancel()
        let debounce = debounce
        // Holds the editor until the write is queued, so leaving the slide never loses a stroke.
        pending = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.pending = nil
            self.write()
        }
    }

    private func write() {
        guard isLoaded, drawing != saved else { return }
        let drawing = drawing
        saved = drawing
        let previous = lastWrite
        let repository = repository
        let deckID = deckID
        let page = page
        lastWrite = Task {
            await previous?.value
            do {
                try await repository.save(drawing, deckID: deckID, page: page)
            } catch {
                ReviewLog.logger.error("Saving slide ink failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
