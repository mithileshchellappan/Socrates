import Foundation
import GRDB
import StudyCore

/// mr: which slide chunks are a lecture's. Slide chunks stay per deck page (one deck serves
/// several lectures); a lecture's slides are the pages of its range (`LectureSlides.current`).
/// A lecture without a range (a capture's stamped deck whose link is gone) keeps the pages its
/// timed spans visited.
enum LectureSlideScope {
    /// A condition on the `search_chunk` row aliased `alias` that is true for the lecture's slide
    /// chunks, with its arguments. Inside the caller's read.
    static func condition(lectureID: Lecture.ID, alias c: String, in db: Database) throws -> (sql: String, arguments: StatementArguments) {
        if let range = try LectureSlides.current(lectureID: lectureID, in: db) {
            let sql = "(\(c).kind = 'slide' AND \(c).deck_id = ? AND \(c).page_number BETWEEN ? AND ?)"
            let arguments: StatementArguments = [range.deckID.storageText, range.firstPage, range.lastPage]
            return (sql, arguments)
        }
        let sql = """
            (\(c).kind = 'slide' AND EXISTS (SELECT 1 FROM lecture_deck_span s
               WHERE s.lecture_id = ? AND s.deck_id = \(c).deck_id AND s.first_page IS NOT NULL
                 AND \(c).page_number BETWEEN s.first_page AND coalesce(s.last_page, s.first_page)))
            """
        let arguments: StatementArguments = [lectureID.storageText]
        return (sql, arguments)
    }
}
