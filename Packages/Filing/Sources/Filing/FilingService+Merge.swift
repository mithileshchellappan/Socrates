import Foundation
import GRDB
import Processing
import StudyCore

/// One class meeting filed as two lectures, merged (2026-10-21). Before that day a recording made
/// in the recitation right after a lecture became a lecture of its own, numbered with the
/// exercise's count ("L2" twice on one day), next to the lecture its slides made.
///
/// Two lectures of a course are one class meeting when they belong to the same session (an
/// exercise, tutorial or seminar that adjoins a lecture counts as that lecture's,
/// `SessionLectures.meeting`; a lecture without a session by where it was held,
/// `SessionLectures.session(for:)`), or, when one of them has no session, carry the same number
/// on the same day. They are merged unless what the student or filing put in them keeps them
/// apart (`Holdings`): both have recordings, or each shows other slides; or the student undid
/// their merge (never redone). What the app generated
/// never does (second pass, 2026-10-21: continuation detection had linked the recording's
/// lecture to the slides lecture's deck, so it no longer held "only recordings"): Claude's notes
/// versions, the study pass's units and AI rows, transcript extraction, `auto` deck links.
///
/// The lecture that keeps the meeting is the one filed to a lecture session (else to any session,
/// else the older; the student may name it, `mergeLectures`). The other's recordings move with
/// their transcript, stamps, notes and flags (`moveRecording`), its slides with their range
/// (`moveDeck`; a deck the survivor shows already keeps the survivor's range, and continuation
/// detection's links give way to slides: the other's stay with it when the survivor has slides,
/// the survivor's go when the other brings slides), and its notes, flags, item sources, tutor
/// conversations, practice questions, kept answers and filings follow; then it is deleted, its
/// study pass, generated notes and detected links kept for Undo (`DeletedRows`). Claude's
/// slides-only notes of the survivor that are not written yet are cancelled when a recording
/// comes in: its study pass writes them from the recording, once (`queueAfterStudyPass`). One
/// `agent_change` row (`lecture_merge`) holds it all in `before.deletion`; Undo splits the two
/// again.
public struct LectureMerges: Sendable, Codable {
    /// One merge: `loserID` went into `survivorID`.
    struct Pair: Sendable, Codable {
        var survivorID: Lecture.ID
        var loserID: Lecture.ID
        /// Recordings moved to the survivor, with whether each is a capture (its deck link moves).
        var recordings: [Recording.ID]
        var captures: [Recording.ID]
        /// Decks whose link moved to the survivor.
        var decks: [Deck.ID]
        /// Rows re-pointed to the survivor, by table (Undo points them back while they are there).
        var moved: [String: [UUID]]
        /// The loser's filings as they were.
        var filings: [FilingBefore]
        /// What the survivor took from the loser because it had none.
        var title: String?
        var number: Int?
        /// The loser's study pass (the survivor's pass covers its recordings from now on).
        var studyPass: DeletedRows
        /// The loser and what went with it (its generated notes, detected links, jobs; references
        /// it cleared).
        var lecture: DeletedRows
        /// The survivor's own detected (`auto`) deck links that gave way to the loser's slides
        /// (nil: none; merges before the second pass have no such key).
        var superseded: DeletedRows?
    }

    struct FilingBefore: Sendable, Codable {
        var id: Filing.ID
        var lectureSessionID: LectureSession.ID?
        var createdLecture: Bool
    }

    var pairs: [Pair]

    /// How many lectures went into another.
    public var count: Int { pairs.count }
    public var recordingCount: Int { pairs.reduce(0) { $0 + $1.recordings.count } }
    public var deckCount: Int { pairs.reduce(0) { $0 + $1.decks.count } }
    /// Notes, flags, sources, conversations, questions, kept answers and filings re-pointed.
    public var rowCount: Int { pairs.reduce(0) { $0 + $1.moved.values.reduce(0) { $0 + $1.count } + $1.filings.count } }
    /// Generated rows set aside (kept for Undo): study pass rows, the loser's notes versions,
    /// detected links and jobs, the survivor's superseded links.
    public var setAsideCount: Int {
        pairs.reduce(0) { $0 + $1.studyPass.count + max($1.lecture.count - 1, 0) + ($1.superseded?.count ?? 0) }
    }

    /// The merges as JSON (`agent_change.before.deletion`).
    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    /// Merges `encoded()` kept.
    public init(encoded: String) throws {
        self = try JSONDecoder().decode(LectureMerges.self, from: Data(encoded.utf8))
    }

    init(pairs: [Pair]) {
        self.pairs = pairs
    }
}

/// What `mergeDuplicateLectures` / `mergeLectures` did.
public struct LectureMergeOutcome: Sendable {
    /// The change row (nil: nothing merged).
    public var change: AgentChange?
    public var merged: Int
    public var recordings: Int
    public var decks: Int
    /// Pairs left for later: a recording of theirs is being processed right now.
    public var busy: Int
}

/// Why `mergeLectures` merged nothing (the agent says it in its own words).
public enum LectureMergeRefusal: Error, Equatable, Sendable {
    /// A lecture is gone.
    case missing
    /// The two are one lecture.
    case sameLecture
    /// They belong to two courses.
    case otherCourses
    /// Both have recordings (counts), and the merge was not asked for anyway.
    case bothRecorded(Int, Int)
    /// A recording of theirs is being processed right now.
    case busy
}

extension FilingService {
    // MARK: - Merging lectures filed twice

    /// Set once the launch merged the lectures filed twice (an Undo of it is never redone). v2
    /// (2026-10-21, second pass): rows the app generated (Claude's notes, the study pass,
    /// continuation detection's deck links) no longer keep a pair apart, so every library gets
    /// one more pass; the first pass's key ("Socrates.mergedDuplicateLectures") is left as it is.
    static let mergedDuplicateLecturesKey = "Socrates.mergedDuplicateLectures.v2"

    /// The launch pass (before the processor starts): `mergeDuplicateLectures` on the first launch
    /// with it; again only when a recording of a pair was busy (none is before the processor
    /// starts). Never throws: a failure is logged and the next launch tries again.
    public func mergeDuplicateLecturesOnce() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.mergedDuplicateLecturesKey) else { return }
        do {
            let outcome = try await mergeDuplicateLectures()
            if outcome.busy == 0 { defaults.set(true, forKey: Self.mergedDuplicateLecturesKey) }
        } catch {
            Log.importer.error("Merging lectures filed twice failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Merges every pair of lectures that are one class meeting (of `courseID`, or of every
    /// course), in one transaction with its `agent_change` row (`lecture_merge`, `quote` and the
    /// source columns given; without a quote the two lectures' names). Logs one public line per
    /// pair left apart (why, in counts), one when merges happened or a pair was busy, else one
    /// saying none was found.
    public func mergeDuplicateLectures(
        courseID: Course.ID? = nil, quote: String? = nil, sourceKind: SourceRef.Kind = .slide, model: String = "",
        conversationID: AgentConversation.ID? = nil, taskID: AgentTask.ID? = nil
    ) async throws -> LectureMergeOutcome {
        let now = now()
        let store = store
        let result = try await services.database.write { db -> (merges: LectureMerges, change: AgentChange?, apart: [Apart], checked: Int) in
            let found = try Self.duplicateLectures(courseID: courseID, in: db)
            var apart = found.apart
            var pairs: [LectureMerges.Pair] = []
            var names: [String] = []
            for (survivor, loser) in found.pairs {
                if try Self.busy(survivor.id, loser.id, in: db) {
                    apart.append(Apart(first: survivor.id, second: loser.id, reason: .busy))
                    continue
                }
                let course = try Course.find(survivor.courseID).fetchOne(db)
                let semesters = try Semester.order(by: \.lectureStart).fetchAll(db)
                let zone = Self.zone(of: course, semesters: semesters)
                let held = [survivor, loser].compactMap(\.heldAt).map { FilingMatcher.stamp($0, zone: zone) }
                names.append("\(Self.lectureName(survivor, course: course)) twice: \(held.joined(separator: " and "))")
                pairs.append(try Self.merge(loser, into: survivor, in: db, store: store, now: now))
            }
            let merges = LectureMerges(pairs: pairs)
            let change = try Self.record(
                merges, summary: "Filed twice, merged", quote: quote ?? names.joined(separator: "; "), sourceKind: sourceKind, model: model,
                conversationID: conversationID, taskID: taskID, in: db, store: store, now: now
            )
            return (merges, change, apart, found.checked)
        }
        let merges = result.merges
        let busy = result.apart.filter { $0.reason == .busy }.count
        for pair in result.apart {
            Log.importer.notice(
                "Lectures \(ChatCitation.key(pair.first), privacy: .public) and \(ChatCitation.key(pair.second), privacy: .public) are one class meeting, left apart: \(pair.reason.text, privacy: .public)"
            )
        }
        if merges.count > 0 || busy > 0 {
            Log.importer.notice(
                "Merged \(merges.count, privacy: .public) lecture(s) filed twice: \(merges.recordingCount, privacy: .public) recording(s), \(merges.deckCount, privacy: .public) deck(s), \(merges.rowCount, privacy: .public) row(s) moved, \(merges.setAsideCount, privacy: .public) generated row(s) set aside; \(busy, privacy: .public) busy"
            )
        } else if result.apart.isEmpty {
            Log.importer.notice("No lectures filed twice (\(result.checked, privacy: .public) lecture(s) checked)")
        }
        if merges.count > 0 { await afterImport() }
        return LectureMergeOutcome(
            change: result.change, merged: merges.count, recordings: merges.recordingCount, decks: merges.deckCount, busy: busy
        )
    }

    /// Merges two lectures the student named (the agent's `merge_lectures`), in one transaction
    /// with its `lecture_merge` row (`quote`: their words asking). `keep` (one of the two) stays,
    /// else the one filed to a lecture session (else to any session, else the older). Refused
    /// (`LectureMergeRefusal`): a lecture gone, the same lecture twice, two courses, a recording
    /// of theirs being processed, or both with recordings unless `bothRecorded` (the student said
    /// so). Two lectures with other slides merge (the survivor's slides stay its current ones).
    public func mergeLectures(
        _ firstID: Lecture.ID, _ secondID: Lecture.ID, keep keepID: Lecture.ID? = nil, bothRecorded: Bool = false, quote: String,
        sourceKind: SourceRef.Kind = .chat, model: String = "", conversationID: AgentConversation.ID? = nil, taskID: AgentTask.ID? = nil
    ) async throws -> LectureMergeOutcome {
        let now = now()
        let store = store
        let merges = try await services.database.write { db -> (LectureMerges, AgentChange?) in
            guard firstID != secondID else { throw LectureMergeRefusal.sameLecture }
            guard let first = try Lecture.find(firstID).fetchOne(db), let second = try Lecture.find(secondID).fetchOne(db) else {
                throw LectureMergeRefusal.missing
            }
            guard first.courseID == second.courseID else { throw LectureMergeRefusal.otherCourses }
            let holdings = try Self.holdings(in: db)
            let left = holdings[first.id]?.recordings ?? 0
            let right = holdings[second.id]?.recordings ?? 0
            if left > 0, right > 0, !bothRecorded { throw LectureMergeRefusal.bothRecorded(left, right) }
            if try Self.busy(first.id, second.id, in: db) { throw LectureMergeRefusal.busy }
            let sessions = try LectureSession.where { $0.courseID.eq(first.courseID) }.fetchAll(db)
            let (survivor, loser): (Lecture, Lecture)
            if let keepID, keepID == second.id {
                (survivor, loser) = (second, first)
            } else if keepID == first.id {
                (survivor, loser) = (first, second)
            } else {
                (survivor, loser) = Self.survivor(first, second, sessions: sessions)
            }
            let merges = LectureMerges(pairs: [try Self.merge(loser, into: survivor, in: db, store: store, now: now)])
            let change = try Self.record(
                merges, summary: "Merged", quote: quote, sourceKind: sourceKind, model: model, conversationID: conversationID, taskID: taskID,
                in: db, store: store, now: now
            )
            return (merges, change)
        }
        let (done, change) = merges
        Log.importer.notice(
            "Merged lecture \(ChatCitation.key(done.pairs.first?.loserID ?? firstID), privacy: .public) into \(ChatCitation.key(done.pairs.first?.survivorID ?? secondID), privacy: .public) as asked: \(done.recordingCount, privacy: .public) recording(s), \(done.deckCount, privacy: .public) deck(s), \(done.rowCount, privacy: .public) row(s) moved, \(done.setAsideCount, privacy: .public) generated row(s) set aside"
        )
        await afterImport()
        return LectureMergeOutcome(change: change, merged: done.count, recordings: done.recordingCount, decks: done.deckCount, busy: 0)
    }

    /// Undo of a `lecture_merge` change: each lecture that went comes back with what it held, and
    /// the change is marked undone, in one transaction. False when it was undone already;
    /// `FilingError.changedSince` when a lecture that kept a meeting is gone or one that went is
    /// back.
    public func undoMerge(_ change: AgentChange) async throws -> Bool {
        guard change.kind == .lectureMerge, let kept = change.before?.deletion else { throw FilingError.missing }
        let merges = try LectureMerges(encoded: kept)
        let now = now()
        let store = store
        let id = change.id
        let undone = try await services.database.write { db -> Bool in
            guard let current = try AgentChange.find(id).fetchOne(db), current.undoneAt == nil else { return false }
            for pair in merges.pairs.reversed() {
                try Self.split(pair, in: db, store: store, now: now)
            }
            try AgentChangeRepository.markUndone(id, at: now, db: db)
            return true
        }
        if undone {
            Log.importer.notice("Split \(merges.count, privacy: .public) merged lecture(s) again")
            await afterImport()
        }
        return undone
    }

    /// The `lecture_merge` row of `merges` (nil: nothing merged), inserted in the caller's
    /// transaction: titled by the survivor (or the count), the summary with what moved.
    static func record(
        _ merges: LectureMerges, summary: String, quote: String, sourceKind: SourceRef.Kind, model: String,
        conversationID: AgentConversation.ID?, taskID: AgentTask.ID?, in db: Database, store: RecordStore, now: Date
    ) throws -> AgentChange? {
        guard let first = merges.pairs.first, let survivor = try Lecture.find(first.survivorID).fetchOne(db) else { return nil }
        let course = try Course.find(survivor.courseID).fetchOne(db)
        let title = merges.count == 1 ? Self.lectureName(survivor, course: course) : "\(merges.count) lectures"
        let moved = [
            merges.recordingCount > 0 ? "\(merges.recordingCount) recording(s)" : nil,
            merges.deckCount > 0 ? "\(merges.deckCount) slide deck(s)" : nil,
        ].compactMap(\.self).joined(separator: " and ")
        let change = store.stamp(AgentChange(
            kind: .lectureMerge, targetTable: .lecture, targetID: survivor.id, title: title,
            summary: summary + (moved.isEmpty ? "" : ": \(moved) moved"),
            before: AgentChangeValues(exists: true, deletion: try merges.encoded()),
            after: AgentChangeValues(exists: true, lectureID: survivor.id),
            sourceKind: sourceKind, lectureID: survivor.id, conversationID: conversationID, taskID: taskID,
            quote: quote, confidence: 1, model: model, appliedAt: now, createdAt: now, updatedAt: now
        ))
        try AgentChangeRepository.insert(change, db: db)
        return change
    }

    /// A recording of either lecture is being processed (a running job).
    static func busy(_ first: Lecture.ID, _ second: Lecture.ID, in db: Database) throws -> Bool {
        let both: [Lecture.ID?] = [first, second]
        let working: [Recording.ID?] = try Recording.where { $0.lectureID.in(both) }.fetchAll(db).map(\.id)
        return try Job.where { $0.recordingID.in(working) && $0.state.eq(JobState.running) }.fetchCount(db) > 0
    }

    // MARK: - Finding them

    /// What the student, filing or a capture put in a lecture, as far as it decides a merge.
    /// Generated rows (Claude's notes versions, study pass units and AI rows, transcript
    /// extraction, continuation detection's `auto` links) are not counted: they never keep two
    /// lectures of one class meeting apart.
    struct Holdings: Sendable {
        /// A deck range shown as the lecture's slides.
        struct Slides: Hashable, Sendable {
            var deckID: Deck.ID
            var firstPage: Int?
            var lastPage: Int?
        }

        var recordings = 0
        /// Its slides that continuation detection did not find.
        var slides: Set<Slides> = []
    }

    /// Two lectures of one class meeting left apart, and why.
    struct Apart: Sendable {
        enum Reason: Equatable, Sendable {
            case bothRecorded(Int, Int)
            case otherSlides(Int, Int)
            /// The student split them again with Undo (never redone).
            case undone
            case busy

            /// Counts and kinds only (a public log line).
            var text: String {
                switch self {
                case .bothRecorded(let left, let right): "both have recordings (\(left) and \(right))"
                case .otherSlides(let left, let right): "each shows other slides (\(left) and \(right) linked)"
                case .undone: "their merge was undone"
                case .busy: "a recording of theirs is being processed (again at the next launch)"
                }
            }
        }

        var first: Lecture.ID
        var second: Lecture.ID
        var reason: Reason
    }

    /// The pairs to merge (survivor, loser; each lecture in one pair), the pairs of one class
    /// meeting left apart, and how many lectures were checked.
    struct Duplicates {
        var pairs: [(Lecture, Lecture)]
        var apart: [Apart]
        var checked: Int
    }

    /// Every lecture's holdings (lectures without any are missing).
    static func holdings(in db: Database) throws -> [Lecture.ID: Holdings] {
        var holdings: [Lecture.ID: Holdings] = [:]
        for recording in try Recording.where({ $0.lectureID.isNot(nil) }).fetchAll(db) {
            if let id = recording.lectureID { holdings[id, default: Holdings()].recordings += 1 }
        }
        for span in try LectureDeckSpan.where({ $0.startTime.is(nil) && $0.source.neq(SpanSource.auto) }).fetchAll(db) {
            holdings[span.lectureID, default: Holdings()].slides.insert(
                Holdings.Slides(deckID: span.deckID, firstPage: span.firstPage, lastPage: span.lastPage)
            )
        }
        return holdings
    }

    /// Why two lectures of one class meeting stay apart; nil: they merge.
    static func apart(_ lhs: Holdings?, _ rhs: Holdings?) -> Apart.Reason? {
        let left = lhs ?? Holdings()
        let right = rhs ?? Holdings()
        if left.recordings > 0, right.recordings > 0 { return .bothRecorded(left.recordings, right.recordings) }
        if !left.slides.isEmpty, !right.slides.isEmpty, left.slides != right.slides {
            return .otherSlides(left.slides.count, right.slides.count)
        }
        return nil
    }

    /// Pairs of lectures that are one class meeting, (survivor, loser), each lecture in one pair,
    /// and the pairs of one class meeting that stay apart.
    static func duplicateLectures(courseID: Course.ID?, in db: Database) throws -> Duplicates {
        let lectures: [Lecture]
        if let courseID {
            lectures = try Lecture.where { $0.courseID.eq(courseID) }.order(by: \.createdAt).fetchAll(db)
        } else {
            lectures = try Lecture.order(by: \.createdAt).fetchAll(db)
        }
        guard lectures.count > 1 else { return Duplicates(pairs: [], apart: [], checked: lectures.count) }
        let courseIDs = Set(lectures.map(\.courseID))
        let allSessions = try LectureSession.all.fetchAll(db).filter { courseIDs.contains($0.courseID) }
        let semesters = try Semester.order(by: \.lectureStart).fetchAll(db)
        let courses = try Course.all.fetchAll(db)
        let holdings = try Self.holdings(in: db)
        // Pairs the student split again with Undo stay apart (an Undo of a merge is never redone).
        var undone: Set<Set<Lecture.ID>> = []
        for change in try AgentChange.where({ $0.undoneAt.isNot(nil) }).fetchAll(db) where change.kind == .lectureMerge {
            guard let kept = change.before?.deletion, let merges = try? LectureMerges(encoded: kept) else { continue }
            for pair in merges.pairs { undone.insert([pair.survivorID, pair.loserID]) }
        }

        var pairs: [(Lecture, Lecture)] = []
        var apart: [Apart] = []
        for (course, members) in Dictionary(grouping: lectures, by: \.courseID) {
            let sessions = allSessions.filter { $0.courseID == course }
            let zone = Self.zone(of: courses.first { $0.id == course }, semesters: semesters)
            let ordered = members.sorted { $0.createdAt < $1.createdAt }
            var taken: Set<Lecture.ID> = []
            for (index, first) in ordered.enumerated() where !taken.contains(first.id) {
                for second in ordered.dropFirst(index + 1) where !taken.contains(second.id) {
                    guard Self.sameMeeting(first, second, sessions: sessions, zone: zone) else { continue }
                    if let reason = undone.contains([first.id, second.id]) ? .undone : Self.apart(holdings[first.id], holdings[second.id]) {
                        apart.append(Apart(first: first.id, second: second.id, reason: reason))
                        continue
                    }
                    pairs.append(Self.survivor(first, second, sessions: sessions))
                    taken.formUnion([first.id, second.id])
                    break
                }
            }
        }
        return Duplicates(pairs: pairs.sorted { $0.0.createdAt < $1.0.createdAt }, apart: apart, checked: lectures.count)
    }

    /// The session whose class meeting a lecture is: its own session's meeting, else (no
    /// session) the session it was held in.
    static func meeting(_ lecture: Lecture, sessions: [LectureSession], zone: TimeZone) -> LectureSession.ID? {
        if let id = lecture.lectureSessionID {
            guard let session = sessions.first(where: { $0.id == id }) else { return id }
            return SessionLectures.meeting(of: session, among: sessions).id
        }
        return SessionLectures.session(for: lecture, in: sessions, zone: zone)?.id
    }

    /// One class meeting: the same meeting session, or (one without) the same number that day.
    /// Two different meetings (two lectures on one day, a tutorial in the evening) never are.
    static func sameMeeting(_ lhs: Lecture, _ rhs: Lecture, sessions: [LectureSession], zone: TimeZone) -> Bool {
        if let left = meeting(lhs, sessions: sessions, zone: zone), let right = meeting(rhs, sessions: sessions, zone: zone) {
            return left == right
        }
        guard let number = lhs.number, number == rhs.number, let left = lhs.heldAt, let right = rhs.heldAt else { return false }
        return CalendarDay(left, in: zone) == CalendarDay(right, in: zone)
    }

    /// (survivor, loser): the lecture filed to a lecture session keeps the meeting, else the one
    /// filed to any session, else the older.
    static func survivor(_ lhs: Lecture, _ rhs: Lecture, sessions: [LectureSession]) -> (Lecture, Lecture) {
        func rank(_ lecture: Lecture) -> Int {
            guard let id = lecture.lectureSessionID, let session = sessions.first(where: { $0.id == id }) else { return 0 }
            return SessionLectures.numbersLectures(session, among: sessions) ? 2 : 1
        }
        let left = rank(lhs)
        let right = rank(rhs)
        if left != right { return left > right ? (lhs, rhs) : (rhs, lhs) }
        return lhs.createdAt <= rhs.createdAt ? (lhs, rhs) : (rhs, lhs)
    }

    static func zone(of course: Course?, semesters: [Semester]) -> TimeZone {
        if let id = course?.semesterID, let own = semesters.first(where: { $0.id == id }) { return own.zone }
        return semesters.first?.zone ?? UniversityProfile.current.zone
    }

    // MARK: - Merging and splitting

    /// Moves everything of `loser` into `survivor` and deletes it (inside the transaction).
    static func merge(_ loser: Lecture, into survivor: Lecture, in db: Database, store: RecordStore, now: Date) throws -> LectureMerges.Pair {
        let loserID = loser.id
        let survivorID = survivor.id
        let newID: Lecture.ID? = survivorID
        // Its study pass goes first (kept): moving a recording would drop it unkept.
        let studyPass = try DeletedRows.collect([.init(table: "study_unit", column: "lecture_id", values: [loserID])], in: db)
        try studyPass.deleteRoots(in: db)

        let recordings = try Recording.where { $0.lectureID.eq(loserID) }.order(by: \.startedAt).fetchAll(db)
        let loserSlides = try LectureSlides.current(lectureID: loserID, in: db)
        if !recordings.isEmpty {
            // Claude's slides-only notes of the survivor not written yet: with a recording, the
            // study pass writes its notes from it (once, `queueAfterStudyPass`).
            for notes in try LectureNotes.where({ $0.lectureID.eq(survivorID) }).fetchAll(db) where notes.state.isOpen && notes.source == .slides {
                _ = try LectureNotesRepository.cancel(notes.id, in: db, now: now)
            }
        }
        for recording in recordings {
            try moveRecording(
                recording.id, kind: recording.source == .file ? .recording : .capture, from: loserID, to: survivor,
                in: db, store: store, now: now
            )
        }

        // Slides: what the student or filing linked moves (a deck the survivor shows already keeps
        // the survivor's range); continuation detection's links give way to slides. The loser's
        // that do not move go with it, the survivor's that give way are kept apart (both for Undo).
        let spans = try LectureDeckSpan.where { $0.lectureID.eq(loserID) && $0.startTime.is(nil) }.order(by: \.updatedAt).fetchAll(db)
        let linked = spans.filter { $0.source != .auto }
        let detected = spans.filter { $0.source == .auto }
        var superseded: DeletedRows?
        if !linked.isEmpty {
            let own = try LectureDeckSpan
                .where { $0.lectureID.eq(survivorID) && $0.startTime.is(nil) && $0.source.eq(SpanSource.auto) }
                .fetchAll(db)
                .map(\.id)
            if !own.isEmpty {
                let rows = try DeletedRows.collect([.init(table: "lecture_deck_span", column: "id", values: own)], in: db)
                try rows.deleteRoots(in: db)
                superseded = rows
            }
        }
        let current = try LectureSlides.current(lectureID: survivorID, in: db)
        var decks: [Deck.ID] = []
        for span in linked + detected {
            let deckID = span.deckID
            let shown = try LectureDeckSpan.where { $0.lectureID.eq(survivorID) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }.fetchCount(db)
            if shown > 0 { continue }
            if span.source == .auto, try LectureSlides.current(lectureID: survivorID, in: db) != nil { continue }
            try moveDeck(deckID, from: loserID, to: survivor, in: db, store: store, now: now)
            decks.append(deckID)
        }
        // The survivor's own slides stay its current ones.
        if let current, let after = try LectureSlides.current(lectureID: survivorID, in: db), after.spanID != current.spanID {
            let newest = max(now, after.updatedAt).addingTimeInterval(0.001)
            try LectureDeckSpan.find(current.spanID).update { $0.updatedAt = newest }.execute(db)
        }
        // Recordings aligned against another range of the same deck (the loser's detected window)
        // align against the survivor's (another deck queued it already).
        if !recordings.isEmpty, let loserSlides, let slides = try LectureSlides.current(lectureID: survivorID, in: db),
           slides.deckID == loserSlides.deckID, slides.firstPage != loserSlides.firstPage || slides.lastPage != loserSlides.lastPage {
            for job in try LectureImporter.alignmentJobs(lectureID: survivorID, in: db, now: now) {
                let stamped = store.stamp(job)
                try Job.upsert { stamped }.execute(db)
            }
        }

        // What is the student's (and what points at the meeting) follows.
        var moved: [String: [UUID]] = [:]
        let notes = try Note.where { $0.lectureID.eq(loserID) }.fetchAll(db).map(\.id)
        try Note.where { $0.id.in(notes) }.update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)
        moved["note"] = notes
        let flags = try Annotation.where { $0.lectureID.eq(loserID) && $0.studyUnitID.is(nil) }.fetchAll(db).map(\.id)
        try Annotation.where { $0.id.in(flags) }.update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)
        moved["annotation"] = flags
        let sources = try TrackedItemSource.where { $0.lectureID.eq(loserID) }.fetchAll(db).map(\.id)
        try TrackedItemSource.where { $0.id.in(sources) }.update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)
        moved["tracked_item_source"] = sources
        let conversations = try AgentConversation.where { $0.lectureID.eq(loserID) }.fetchAll(db).map(\.id)
        try AgentConversation.where { $0.id.in(conversations) }.update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)
        moved["agent_conversation"] = conversations
        let questions = try StudyQuestion.where { $0.lectureID.eq(loserID) }.fetchAll(db).map(\.id)
        try StudyQuestion.where { $0.id.in(questions) }.update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)
        moved["study_question"] = questions
        let marks = try LectureNotesMark.where { $0.lectureID.eq(loserID) }.fetchAll(db).map(\.id)
        try LectureNotesMark.where { $0.id.in(marks) }.update { $0.lectureID = survivorID; $0.updatedAt = now }.execute(db)
        moved["lecture_notes_mark"] = marks

        var filings: [LectureMerges.FilingBefore] = []
        let sessionID = survivor.lectureSessionID
        for filing in try Filing.where({ $0.lectureID.eq(loserID) }).fetchAll(db) {
            filings.append(.init(id: filing.id, lectureSessionID: filing.lectureSessionID, createdLecture: filing.createdLecture))
            try Filing.find(filing.id)
                .update { $0.lectureID = newID; $0.lectureSessionID = sessionID; $0.createdLecture = false; $0.updatedAt = now }
                .execute(db)
        }

        // An untitled or unnumbered survivor takes the other's.
        let latest = try Lecture.find(survivorID).fetchOne(db) ?? survivor
        let title = latest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !loser.title.isEmpty ? loser.title : nil
        let number = latest.number == nil ? loser.number : nil
        if title != nil || number != nil {
            let newTitle = title ?? latest.title
            let newNumber = number ?? latest.number
            try Lecture.find(survivorID).update { $0.title = newTitle; $0.number = newNumber; $0.updatedAt = now }.execute(db)
        }

        let lecture = try DeletedRows.collect([.init(table: "lecture", column: "id", values: [loserID])], in: db)
        try lecture.deleteRoots(in: db)
        return LectureMerges.Pair(
            survivorID: survivorID, loserID: loserID, recordings: recordings.map(\.id),
            captures: recordings.filter { $0.source != .file }.map(\.id), decks: decks, moved: moved,
            filings: filings, title: title, number: number, studyPass: studyPass, lecture: lecture, superseded: superseded
        )
    }

    /// Undo of one merge (inside the transaction): the lecture that went comes back with what it
    /// held; what moved goes back while it is still with the survivor; the survivor's detected
    /// links that gave way come back (its recordings align again).
    static func split(_ pair: LectureMerges.Pair, in db: Database, store: RecordStore, now: Date) throws {
        let survivorID = pair.survivorID
        let loserID = pair.loserID
        guard let survivor = try Lecture.find(survivorID).fetchOne(db), try Lecture.find(loserID).fetchCount(db) == 0 else {
            throw FilingError.changedSince
        }
        try pair.lecture.restore(in: db)
        try pair.studyPass.restore(in: db)
        guard let loser = try Lecture.find(loserID).fetchOne(db) else { throw FilingError.changedSince }

        for recordingID in pair.recordings {
            guard try Recording.find(recordingID).fetchOne(db)?.lectureID == survivorID else { continue }
            try moveRecording(
                recordingID, kind: pair.captures.contains(recordingID) ? .capture : .recording, from: survivorID, to: loser,
                in: db, store: store, now: now
            )
        }
        for deckID in pair.decks {
            let linked = try LectureDeckSpan
                .where { $0.lectureID.eq(survivorID) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
                .fetchCount(db)
            if linked > 0 { try moveDeck(deckID, from: survivorID, to: loser, in: db, store: store, now: now) }
        }
        if let superseded = pair.superseded {
            try superseded.restore(in: db)
            for job in try LectureImporter.alignmentJobs(lectureID: survivorID, in: db, now: now) {
                let stamped = store.stamp(job)
                try Job.upsert { stamped }.execute(db)
            }
        }

        let oldID: Lecture.ID? = loserID
        let survivorLink: Lecture.ID? = survivorID
        try Note.where { $0.id.in(pair.moved["note"] ?? []) && $0.lectureID.eq(survivorLink) }
            .update { $0.lectureID = oldID; $0.updatedAt = now }.execute(db)
        try Annotation.where { $0.id.in(pair.moved["annotation"] ?? []) && $0.lectureID.eq(survivorLink) }
            .update { $0.lectureID = oldID; $0.updatedAt = now }.execute(db)
        try TrackedItemSource.where { $0.id.in(pair.moved["tracked_item_source"] ?? []) && $0.lectureID.eq(survivorLink) }
            .update { $0.lectureID = oldID; $0.updatedAt = now }.execute(db)
        try AgentConversation.where { $0.id.in(pair.moved["agent_conversation"] ?? []) && $0.lectureID.eq(survivorLink) }
            .update { $0.lectureID = oldID; $0.updatedAt = now }.execute(db)
        try StudyQuestion.where { $0.id.in(pair.moved["study_question"] ?? []) && $0.lectureID.eq(survivorLink) }
            .update { $0.lectureID = oldID; $0.updatedAt = now }.execute(db)
        try LectureNotesMark.where { $0.id.in(pair.moved["lecture_notes_mark"] ?? []) && $0.lectureID.eq(survivorID) }
            .update { $0.lectureID = loserID; $0.updatedAt = now }.execute(db)
        for before in pair.filings {
            let sessionID = before.lectureSessionID
            let created = before.createdLecture
            try Filing.where { $0.id.eq(before.id) && $0.lectureID.eq(survivorLink) }
                .update { $0.lectureID = oldID; $0.lectureSessionID = sessionID; $0.createdLecture = created; $0.updatedAt = now }
                .execute(db)
        }

        // The survivor gives back what it took, unless it was changed since.
        let title = pair.title.flatMap { survivor.title == $0 ? "" : nil }
        let number: Int?? = pair.number.flatMap { survivor.number == $0 ? .some(nil) : nil }
        if title != nil || number != nil {
            let newTitle = title ?? survivor.title
            let newNumber = number ?? survivor.number
            try Lecture.find(survivorID).update { $0.title = newTitle; $0.number = newNumber; $0.updatedAt = now }.execute(db)
        }
    }
}
