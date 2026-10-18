import Foundation
import SQLiteData

// Record types added in schema v10 (M6: notes & ink). docs/plan-m6.md §3–4.

/// The student's ink on one slide page (PRD #17): pen and highlighter strokes drawn in Review,
/// stored per deck page (the same ink shows on that slide in every lecture that shows it), never
/// written into the PDF. One row per (`deck_id`, `page_number`), kept by `SlideInkRepository`
/// (no unique index: CloudKit rules); an empty drawing has no row.
@Table("slide_ink")
public struct SlideInk: StudyRecord {
    public let id: UUID
    /// The deck the page belongs to (CASCADE: the ink goes with the deck).
    @Column("deck_id") public var deckID: Deck.ID
    /// 1-based deck page.
    @Column("page_number") public var pageNumber: Int
    /// The strokes, in `InkDrawing.slide(aspectRatio:)` units of the page.
    @Column(as: InkDrawing.JSONRepresentation.self) public var drawing: InkDrawing
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        deckID: Deck.ID,
        pageNumber: Int,
        drawing: InkDrawing,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.drawing = drawing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
