import Foundation
import StudyCore

/// mc: a lecture's transcript lines and slides as the study pass reads them, for the study coach's
/// question drafting (`Coach.QuestionDrafter`): the same line ids ("l12"), the slide on screen
/// while each line was said, and the deck's page texts. Quotes are checked against `original`
/// (the line's `original_text`). The lines of every recording of the lecture (`LectureMaterial`):
/// each with its recording and its times on that recording's clock.
public struct LectureText: Sendable {
    public struct Line: Sendable {
        /// "l12": its position on the lecture's timeline.
        public var id: String
        public var segmentID: TranscriptSegment.ID
        public var recordingID: Recording.ID
        /// Seconds on `recordingID`'s clock.
        public var start: Double
        public var end: Double
        /// `original_text` (quotes are exact spans of it).
        public var original: String
        public var words: [TranscriptWord]
        /// The slide on screen (nil off-slide).
        public var page: Int?
    }

    /// "Lecture 2: Virtualization Basics".
    public var lectureName: String
    /// "Data Centers (DC)".
    public var courseName: String
    public var language: String
    public var deckID: Deck.ID?
    public var lines: [Line]
    /// Page number → the slide's text.
    public var slides: [Int: String]

    /// The study pass's own stages (the coach's `quiz` units are not the pass's).
    public static var passStages: [StudyStage] { StudyPlanner.stages }

    /// Nil when the lecture is gone or has no transcript lines.
    public static func load(_ lectureID: Lecture.ID, in db: Database) throws -> LectureText? {
        guard let material = try LectureMaterial.load(lectureID, in: db) else { return nil }
        let lines = material.lines.map { line in
            Line(
                id: line.id, segmentID: line.segment.id, recordingID: line.segment.recordingID, start: line.start, end: line.end,
                original: line.original, words: line.segment.words ?? [], page: material.page(ofLine: line.index)
            )
        }
        return LectureText(
            lectureName: material.lectureName, courseName: material.courseName, language: material.language, deckID: material.deck?.id,
            lines: lines, slides: material.pages.mapValues(\.text)
        )
    }

    /// The slide's title line.
    public func slideTitle(_ page: Int) -> String {
        DeckPage.title(fromPageText: slides[page] ?? "")
    }
}
