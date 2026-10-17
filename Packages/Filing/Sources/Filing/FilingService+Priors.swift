import Foundation
import Processing
import StudyCore

extension FilingSignal.Kind {
    /// The lecture's `held_at` before this filing dated it with the recording's start (evidence:
    /// seconds since the reference date, empty when it was undated). Not a clue (weight 0): Undo
    /// and Change put the date back from it.
    public static let priorHeldAt: Self = "prior_held_at"
    /// The deck's course before this filing moved the (reused) deck to its own (evidence: the
    /// course id, empty when it had none). Not a clue (weight 0): Undo puts the deck back.
    public static let priorDeckCourse: Self = "prior_deck_course"
}

extension FilingSignal {
    /// Records what a filing changed on rows it did not create; never evidence.
    var isPrior: Bool { kind == .priorHeldAt || kind == .priorDeckCourse }

    static func priorHeldAt(_ date: Date?) -> FilingSignal {
        FilingSignal(kind: .priorHeldAt, evidence: date.map { String($0.timeIntervalSinceReferenceDate) } ?? "", weight: 0)
    }

    static func priorDeckCourse(_ courseID: Course.ID?) -> FilingSignal {
        FilingSignal(kind: .priorDeckCourse, evidence: courseID?.uuidString ?? "", weight: 0)
    }
}

extension Filing {
    /// The date the filing's lecture had before the filing dated it (`.some(nil)`: undated);
    /// nil when the filing dated nothing.
    var priorHeldAt: Date?? {
        guard let signal = signals.last(where: { $0.kind == .priorHeldAt }) else { return nil }
        return .some(Double(signal.evidence).map(Date.init(timeIntervalSinceReferenceDate:)))
    }

    /// The course a reused deck had before the filing moved it (`.some(nil)`: none); nil when
    /// the filing moved no deck.
    var priorDeckCourseID: Course.ID?? {
        guard let signal = signals.last(where: { $0.kind == .priorDeckCourse }) else { return nil }
        return .some(UUID(uuidString: signal.evidence))
    }
}

extension FilingService {
    /// Puts back the date a filing gave `lectureID` (the recording's start) while the lecture
    /// still has it and no session, and forgets it. Inside a transaction.
    static func restorePriorHeldAt(
        _ filing: inout Filing, lectureID: Lecture.ID, recordingStart: Date?, in db: Database, stamp: Date
    ) throws {
        guard let prior = filing.priorHeldAt else { return }
        filing.signals.removeAll { $0.kind == .priorHeldAt }
        guard let recordingStart, let lecture = try Lecture.find(lectureID).fetchOne(db), lecture.lectureSessionID == nil,
              let heldAt = lecture.heldAt, abs(heldAt.timeIntervalSince(recordingStart)) < 1
        else { return }
        try Lecture.find(lectureID).update { $0.heldAt = prior; $0.updatedAt = stamp }.execute(db)
    }

    /// Puts a deck the filing moved back into its earlier course, unless it was moved since.
    static func restorePriorDeckCourse(_ filing: Filing, deckID: Deck.ID, in db: Database, stamp: Date) throws {
        guard let prior = filing.priorDeckCourseID,
              let deck = try Deck.find(deckID).fetchOne(db), deck.courseID == filing.courseID
        else { return }
        try Deck.find(deckID).update { $0.courseID = prior; $0.updatedAt = stamp }.execute(db)
    }
}
