import Foundation
import GRDB
import StudyCore

/// One class meeting filed as two lectures, merged (2026-10-21). Before that day a recording made
/// in the recitation right after a lecture became a lecture of its own, numbered with the
/// exercise's count ("L2" twice on one day), next to the lecture its slides made.
///
/// Two lectures of a course are one class meeting when they belong to the same session (an
/// exercise, tutorial or seminar that adjoins a lecture counts as that lecture's,
/// `SessionLectures.meeting`; a lecture without a session by where it was held,
/// `SessionLectures.session(for:)`), or, when one of them has no session, carry the same number
/// on the same day. Only a pair where one holds only slides and the other only recordings or the
/// student's notes is merged; two lectures that both have recordings, or both slides, stay apart.
///
/// The lecture that keeps the meeting is the one filed to a lecture session (else to any session,
/// else the older). The other's recordings move with their transcript, stamps, notes and flags
/// (`moveRecording`), its slides with their range (`moveDeck`), and its notes, flags, item
/// sources, tutor conversations, practice questions, kept answers and filings follow; then it is
/// deleted, its study pass and generated notes kept for Undo (`DeletedRows`). One `agent_change`
/// row (`lecture_merge`) holds it all in `before.deletion`; Undo splits the two again.
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
        /// The loser and what went with it (its generated notes, jobs; references it cleared).
        var lecture: DeletedRows
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

/// What `mergeDuplicateLectures` did.
public struct LectureMergeOutcome: Sendable {
    /// The change row (nil: nothing merged).
    public var change: AgentChange?
    public var merged: Int
    public var recordings: Int
    public var decks: Int
    /// Pairs left for later: a recording of theirs is being processed right now.
    public var busy: Int
}

extension FilingService {
    // MARK: - Merging lectures filed twice

    /// Merges every pair of lectures that are one class meeting (of `courseID`, or of every
    /// course), in one transaction with its `agent_change` row (`lecture_merge`, `quote` and the
    /// source columns given; without a quote the two lectures' names). Logs one public line.
    public func mergeDuplicateLectures(
        courseID: Course.ID? = nil, quote: String? = nil, sourceKind: SourceRef.Kind = .slide, model: String = "",
        conversationID: AgentConversation.ID? = nil, taskID: AgentTask.ID? = nil
    ) async throws -> LectureMergeOutcome {
        let now = now()
        let store = store
        let result = try await services.database.write { db -> (merges: LectureMerges, change: AgentChange?, busy: Int) in
            var pairs: [LectureMerges.Pair] = []
            var names: [String] = []
            var busy = 0
            for (survivor, loser) in try Self.duplicateLectures(courseID: courseID, in: db) {
                let both: [Lecture.ID?] = [survivor.id, loser.id]
                let working = try Recording.where { $0.lectureID.in(both) }.fetchAll(db).map(\.id)
                let ids: [Recording.ID?] = working.map { $0 }
                if try Job.where({ $0.recordingID.in(ids) && $0.state.eq(JobState.running) }).fetchCount(db) > 0 {
                    busy += 1
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
            guard let first = pairs.first, let survivor = try Lecture.find(first.survivorID).fetchOne(db) else {
                return (merges, nil, busy)
            }
            let course = try Course.find(survivor.courseID).fetchOne(db)
            let title = pairs.count == 1 ? Self.lectureName(survivor, course: course) : "\(pairs.count) lectures"
            let moved = [
                merges.recordingCount > 0 ? "\(merges.recordingCount) recording(s)" : nil,
                merges.deckCount > 0 ? "\(merges.deckCount) slide deck(s)" : nil,
            ].compactMap(\.self).joined(separator: " and ")
            let change = store.stamp(AgentChange(
                kind: .lectureMerge, targetTable: .lecture, targetID: survivor.id, title: title,
                summary: "Filed twice, merged" + (moved.isEmpty ? "" : ": \(moved) moved"),
                before: AgentChangeValues(exists: true, deletion: try merges.encoded()),
                after: AgentChangeValues(exists: true, lectureID: survivor.id),
                sourceKind: sourceKind, lectureID: survivor.id, conversationID: conversationID, taskID: taskID,
                quote: quote ?? names.joined(separator: "; "), confidence: 1, model: model, appliedAt: now, createdAt: now, updatedAt: now
            ))
            try AgentChangeRepository.insert(change, db: db)
            return (merges, change, busy)
        }
        let merges = result.merges
        if merges.count > 0 || result.busy > 0 {
            Log.importer.notice(
                "Merged \(merges.count, privacy: .public) lecture(s) filed twice: \(merges.recordingCount, privacy: .public) recording(s), \(merges.deckCount, privacy: .public) deck(s), \(merges.rowCount, privacy: .public) row(s) moved; \(result.busy, privacy: .public) busy"
            )
        }
        if merges.count > 0 { await afterImport() }
        return LectureMergeOutcome(
            change: result.change, merged: merges.count, recordings: merges.recordingCount, decks: merges.deckCount, busy: result.busy
        )
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

    // MARK: - Finding them

    /// Pairs of lectures that are one class meeting, (survivor, loser), each lecture in one pair.
    static func duplicateLectures(courseID: Course.ID?, in db: Database) throws -> [(Lecture, Lecture)] {
        let lectures: [Lecture]
        if let courseID {
            lectures = try Lecture.where { $0.courseID.eq(courseID) }.order(by: \.createdAt).fetchAll(db)
        } else {
            lectures = try Lecture.order(by: \.createdAt).fetchAll(db)
        }
        guard lectures.count > 1 else { return [] }
        let courseIDs = Set(lectures.map(\.courseID))
        let allSessions = try LectureSession.all.fetchAll(db).filter { courseIDs.contains($0.courseID) }
        let semesters = try Semester.order(by: \.lectureStart).fetchAll(db)
        let courses = try Course.all.fetchAll(db)
        var recordings: [Lecture.ID: Int] = [:]
        for recording in try Recording.where({ $0.lectureID.isNot(nil) }).fetchAll(db) {
            if let id = recording.lectureID { recordings[id, default: 0] += 1 }
        }
        var decks: [Lecture.ID: Set<Deck.ID>] = [:]
        for span in try LectureDeckSpan.where({ $0.startTime.is(nil) }).fetchAll(db) {
            decks[span.lectureID, default: []].insert(span.deckID)
        }
        var notes: [Lecture.ID: Int] = [:]
        for note in try Note.where({ $0.lectureID.isNot(nil) }).fetchAll(db) {
            if let id = note.lectureID { notes[id, default: 0] += 1 }
        }
        func slidesOnly(_ lecture: Lecture) -> Bool {
            recordings[lecture.id, default: 0] == 0 && !(decks[lecture.id] ?? []).isEmpty
        }
        func recordedOnly(_ lecture: Lecture) -> Bool {
            (recordings[lecture.id, default: 0] > 0 || notes[lecture.id, default: 0] > 0) && (decks[lecture.id] ?? []).isEmpty
        }

        var pairs: [(Lecture, Lecture)] = []
        for (course, members) in Dictionary(grouping: lectures, by: \.courseID) {
            let sessions = allSessions.filter { $0.courseID == course }
            let zone = Self.zone(of: courses.first { $0.id == course }, semesters: semesters)
            let ordered = members.sorted { $0.createdAt < $1.createdAt }
            var taken: Set<Lecture.ID> = []
            for (index, first) in ordered.enumerated() where !taken.contains(first.id) {
                for second in ordered.dropFirst(index + 1) where !taken.contains(second.id) {
                    guard (slidesOnly(first) && recordedOnly(second)) || (recordedOnly(first) && slidesOnly(second)),
                          Self.sameMeeting(first, second, sessions: sessions, zone: zone)
                    else { continue }
                    pairs.append(Self.survivor(first, second, sessions: sessions))
                    taken.formUnion([first.id, second.id])
                    break
                }
            }
        }
        return pairs.sorted { $0.0.createdAt < $1.0.createdAt }
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
        let newID: Lecture.ID? = survivor.id
        // Its study pass goes first (kept): moving a recording would drop it unkept.
        let studyPass = try DeletedRows.collect([.init(table: "study_unit", column: "lecture_id", values: [loserID])], in: db)
        try studyPass.deleteRoots(in: db)

        let recordings = try Recording.where { $0.lectureID.eq(loserID) }.order(by: \.startedAt).fetchAll(db)
        for recording in recordings {
            try moveRecording(
                recording.id, kind: recording.source == .file ? .recording : .capture, from: loserID, to: survivor,
                in: db, store: store, now: now
            )
        }
        let spans = try LectureDeckSpan.where { $0.lectureID.eq(loserID) && $0.startTime.is(nil) }.order(by: \.updatedAt).fetchAll(db)
        for span in spans {
            try moveDeck(span.deckID, from: loserID, to: survivor, in: db, store: store, now: now)
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
        let survivorID = survivor.id
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
        let current = try Lecture.find(survivorID).fetchOne(db) ?? survivor
        let title = current.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !loser.title.isEmpty ? loser.title : nil
        let number = current.number == nil ? loser.number : nil
        if title != nil || number != nil {
            let newTitle = title ?? current.title
            let newNumber = number ?? current.number
            try Lecture.find(survivorID).update { $0.title = newTitle; $0.number = newNumber; $0.updatedAt = now }.execute(db)
        }

        let lecture = try DeletedRows.collect([.init(table: "lecture", column: "id", values: [loserID])], in: db)
        try lecture.deleteRoots(in: db)
        return LectureMerges.Pair(
            survivorID: survivorID, loserID: loserID, recordings: recordings.map(\.id),
            captures: recordings.filter { $0.source != .file }.map(\.id), decks: spans.map(\.deckID), moved: moved,
            filings: filings, title: title, number: number, studyPass: studyPass, lecture: lecture
        )
    }

    /// Undo of one merge (inside the transaction): the lecture that went comes back with what it
    /// held; what moved goes back while it is still with the survivor.
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
