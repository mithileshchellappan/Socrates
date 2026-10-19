import Foundation
import Processing
import StudyCore

extension FilingService {
    // MARK: - Asking the advisor

    /// After a deck filing the heuristics were not sure of (review, ask, no course, a drop on a
    /// course without a number or date): the advisor looks again in a detached task; a confident
    /// answer files it there as an automatic change with Undo (`agent_change`, its reason).
    func adviseLater(_ filingID: Filing.ID, decision: FilingDecision) {
        guard advisor != nil else { return }
        let candidates = ([decision.best].compactMap(\.self) + decision.alternatives).map(Self.adviceCandidate)
        Task.detached(priority: .background) { [self] in
            await self.adviseFiling(filingID, candidates: candidates)
        }
    }

    private func adviseFiling(_ filingID: Filing.ID, candidates: [FilingAdviceRequest.Candidate]) async {
        guard let advisor else { return }
        do {
            guard let filing = try await store.fetch(Filing.self, id: filingID), filing.source == .auto, let deckID = filing.deckID,
                  let request = try await adviceRequest(deckID: deckID, fileName: filing.fileName, candidates: candidates)
            else { return }
            guard let raw = await advisor.advise(request), let advice = request.validated(raw) else { return }
            guard advice.isSlides, advice.confidence >= FilingAdvice.applyThreshold else {
                Log.importer.info("Filing advice not applied (\(advice.confidence, privacy: .public))")
                return
            }
            let moved = try await apply(advice, to: filing, quote: request.firstLine)
            await afterAdvice(moved)
        } catch is Superseded {
            // The student filed it meanwhile: their choice stands.
        } catch {
            Log.importer.error("Filing advice failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
    }

    static func adviceCandidate(_ choice: FilingChoice) -> FilingAdviceRequest.Candidate {
        FilingAdviceRequest.Candidate(
            courseID: choice.place.course.id, sessionID: choice.place.sessionID, lectureID: choice.place.lectureID,
            number: choice.place.number, confidence: choice.confidence
        )
    }

    /// The request for a deck in the library (its first pages' stored text).
    func adviceRequest(
        deckID: Deck.ID, fileName: String, candidates: [FilingAdviceRequest.Candidate]
    ) async throws -> FilingAdviceRequest? {
        guard let deck = try await store.fetch(Deck.self, id: deckID) else { return nil }
        let pages = try await services.database.read { db in
            try DeckPage.where { $0.deckID.eq(deckID) && $0.pageNumber.lte(3) }.order(by: \.pageNumber).fetchAll(db).map(\.text)
        }
        return Self.request(
            library: try await loadLibrary(), fileName: fileName, deckTitle: deck.title, pages: pages, studentWords: nil,
            candidates: candidates, interactive: false
        )
    }

    /// The request for a slide PDF not filed yet (dropped on the agent panel with the student's
    /// words); nil when it is no readable PDF.
    public func adviceRequest(forDeckAt url: URL, studentWords: String?) async -> FilingAdviceRequest? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let evidence = await evidence(for: url), evidence.kind == .deck, let probe = DeckProbe.read(url, sampleSize: 3),
              let library = try? await loadLibrary()
        else { return nil }
        let decision = FilingMatcher(library: library).decide(evidence)
        let candidates = ([decision.best].compactMap(\.self) + decision.alternatives).map(Self.adviceCandidate)
        let words = studentWords?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.request(
            library: library, fileName: evidence.fileName, deckTitle: evidence.deckTitle, pages: probe.pages.prefix(3).map(\.text),
            studentWords: words?.isEmpty == false ? words : nil, candidates: candidates, interactive: true
        )
    }

    static func request(
        library: FilingLibrary, fileName: String, deckTitle: String, pages: [String], studentWords: String?,
        candidates: [FilingAdviceRequest.Candidate], interactive: Bool
    ) -> FilingAdviceRequest {
        let courses = library.courses.map { course -> FilingAdviceRequest.CourseOption in
            let numbered = library.numberedSessions(courseID: course.id)
            let sessions = numbered.map { session in
                FilingAdviceRequest.Session(
                    id: session.id, number: session.number, startsAt: session.startsAt,
                    hasSlides: library.lecture(sessionID: session.id)?.hasDeck == true
                )
            }
            let inSessions = Set(numbered.compactMap { library.lecture(sessionID: $0.id)?.lecture.id })
            let lectures = library.lectures(courseID: course.id).filter { !inSessions.contains($0.lecture.id) }.map { info in
                FilingAdviceRequest.LectureOption(
                    id: info.lecture.id, number: info.lecture.number, heldAt: info.lecture.heldAt, title: info.lecture.title,
                    hasSlides: info.hasDeck
                )
            }
            return FilingAdviceRequest.CourseOption(
                id: course.id, name: course.name, shortName: course.shortName, lecturers: course.professors,
                sessions: sessions, lectures: lectures
            )
        }
        return FilingAdviceRequest(
            fileName: fileName, deckTitle: deckTitle, pages: pages.prefix(3).map { String($0.prefix(1_500)) }, studentWords: studentWords,
            courses: courses, candidates: Array(candidates.prefix(4)), now: library.now, timeZone: library.zone, interactive: interactive
        )
    }

    // MARK: - Applying advice

    /// Where the advice files a deck already in the library: its session (or the session's
    /// lecture), the course's lecture or session with its number, a new lecture with the number;
    /// without either, the lecture it is in (same course) or the matcher's pick in the course.
    func adviceTarget(_ advice: FilingAdvice, filing: Filing, library: FilingLibrary) async throws -> LectureTarget {
        func sessionTarget(_ id: LectureSession.ID) -> LectureTarget {
            library.lecture(sessionID: id).flatMap { $0.lecture.lectureSessionID == id ? .lecture($0.lecture.id) : nil } ?? .session(id)
        }
        if let sessionID = advice.sessionID { return sessionTarget(sessionID) }
        if let number = advice.lectureNumber {
            if let session = library.numberedSessions(courseID: advice.courseID).first(where: { $0.number == number }) {
                return sessionTarget(session.id)
            }
            if let info = library.lectures(courseID: advice.courseID).first(where: { $0.lecture.number == number }) {
                return .lecture(info.lecture.id)
            }
            return .newLecture(number: number)
        }
        if filing.courseID == advice.courseID, let lectureID = filing.lectureID { return .lecture(lectureID) }
        let evidence = try await storedEvidence(of: filing)
        return FilingMatcher(library: library).decide(evidence, destination: .course(advice.courseID)).best?.target ?? .new
    }

    /// Moves a deck filing where the advice says (or confirms it where it is), reviewed, and logs
    /// the move as an automatic change (`agent_change` target `filing`, the advisor's model and
    /// reason, the deck's first line as quote) in the move's transaction. Gives way (`Superseded`)
    /// to any change since `filing` was read.
    @discardableResult
    func apply(_ advice: FilingAdvice, to filing: Filing, quote: String) async throws -> Filing {
        let library = try await loadLibrary()
        let target = try await adviceTarget(advice, filing: filing, library: library)
        let signal = FilingSignal(kind: .advisor, evidence: advice.reason, weight: advice.confidence)
        let hook = Self.adviceHook(advice, quote: quote, created: false, conversationID: nil, library: library, now: now())
        let moved = try await move(filing, to: target, courseID: advice.courseID, reason: .advice(signal), hook: hook)
        Log.importer.info("Filing advice applied (\(advice.confidence, privacy: .public))")
        return moved
    }

    /// Files a slide PDF where the advice says (the agent panel: a deck dropped with "this is DC
    /// lecture 3"), reviewed, as an automatic change whose Undo takes the filing back (the deck
    /// goes, as the toast's Undo would). Nil when nothing was filed (not a deck, or it failed).
    public func file(_ url: URL, following advice: FilingAdvice, quote: String, conversationID: AgentConversation.ID?) async -> AdvisedFiling? {
        guard let library = try? await loadLibrary() else { return nil }
        let destination = Self.adviceDestination(advice, library: library)
        guard let outcome = await file([url], to: destination, advise: false).first, var filing = outcome.filing, outcome.kind == .deck
        else { return nil }
        if outcome.status == .known { return AdvisedFiling(outcome: outcome, change: nil, placed: Self.placed(outcome.place)) }
        let signal = FilingSignal(kind: .advisor, evidence: advice.reason, weight: advice.confidence)
        let stamp = now()
        let store = store
        let hook = Self.adviceHook(advice, quote: quote, created: true, conversationID: conversationID, library: library, now: stamp)
        let filingID = filing.id
        do {
            let change = try await services.database.write { db -> AgentChange? in
                guard var current = try Filing.find(filingID).fetchOne(db), let lectureID = current.lectureID,
                      let lecture = try Lecture.find(lectureID).fetchOne(db)
                else { return nil }
                // The lecture the filing made takes the advised number.
                if current.createdLecture, let number = advice.lectureNumber, lecture.number != number {
                    let value: Int? = number
                    try Lecture.find(lectureID).update { $0.number = value; $0.updatedAt = stamp }.execute(db)
                }
                let before = current
                current.source = .auto
                current.confidence = 1
                current.signals = [signal] + current.signals.filter { $0.kind != .advisor && $0.kind != .user }
                current.candidates = []
                let stamped = store.stamp(current)
                try Filing.upsert { stamped }.execute(db)
                try hook(db, before, stamped, try Lecture.find(lectureID).fetchOne(db) ?? lecture)
                return try AgentChange.where { $0.targetTable.eq(AgentChangeTarget.filing) && $0.targetID.eq(UUID?.some(stamped.id)) }
                    .order { $0.appliedAt.desc() }
                    .fetchOne(db)
            }
            filing = (try? await store.fetch(Filing.self, id: filing.id)) ?? filing
            var updated = outcome
            updated.filing = filing
            updated.status = .filed
            updated.place = (try? await place(of: filing)) ?? outcome.place
            return AdvisedFiling(outcome: updated, change: change, placed: Self.placed(updated.place))
        } catch {
            Log.importer.error("Recording a filing advice failed: \(String(reflecting: type(of: error)), privacy: .public)")
            return AdvisedFiling(outcome: outcome, change: nil, placed: Self.placed(outcome.place))
        }
    }

    /// The drop destination for advice on a new file: its session, the lecture or session with
    /// its number, else the course (the matcher picks the lecture; a new one takes the number).
    static func adviceDestination(_ advice: FilingAdvice, library: FilingLibrary) -> FilingDestination {
        if let sessionID = advice.sessionID { return .session(sessionID) }
        if let number = advice.lectureNumber {
            if let session = library.numberedSessions(courseID: advice.courseID).first(where: { $0.number == number }) {
                return .session(session.id)
            }
            if let info = library.lectures(courseID: advice.courseID).first(where: { $0.lecture.number == number }) {
                return .lecture(info.lecture.id)
            }
        }
        return .course(advice.courseID)
    }

    /// Writes the advice's change row (when the filing changed place, or was made by it) and
    /// gives an untitled lecture the advised title, inside the transaction.
    static func adviceHook(
        _ advice: FilingAdvice, quote: String, created: Bool, conversationID: AgentConversation.ID?, library: FilingLibrary, now: Date
    ) -> MoveHook {
        { db, before, after, lecture in
            if lecture.title.isEmpty, !advice.title.isEmpty {
                let title = advice.title
                try Lecture.find(lecture.id).update { $0.title = title; $0.updatedAt = now }.execute(db)
            }
            guard created || before.lectureID != after.lectureID || before.courseID != after.courseID else { return }
            let course = library.course(lecture.courseID)
            let short = course.map { $0.shortName.isEmpty ? $0.name : $0.shortName } ?? ""
            let number = lecture.number.map { "L\($0)" }
            let title = lecture.title.isEmpty ? advice.title : lecture.title
            let place = [short, number, title.isEmpty ? nil : title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            let change = AgentChange(
                kind: .filing, targetTable: .filing, targetID: after.id, title: after.fileName,
                summary: "Filed as \(place)",
                before: created
                    ? AgentChangeValues(exists: false)
                    : AgentChangeValues(exists: true, courseID: before.courseID, lectureID: before.lectureID, lectureSessionID: before.lectureSessionID),
                after: AgentChangeValues(
                    exists: true, courseID: after.courseID, lectureID: after.lectureID, lectureSessionID: after.lectureSessionID,
                    reason: advice.reason
                ),
                sourceKind: .slide, lectureID: lecture.id, conversationID: conversationID, quote: quote, confidence: advice.confidence,
                model: advice.model, apiCallID: advice.apiCallID, appliedAt: now, createdAt: now, updatedAt: now
            )
            try AgentChangeRepository.insert(change, db: db)
        }
    }

    /// "DC · L3 · Virtualization" for a place.
    static func placed(_ place: FilingPlace?) -> String {
        guard let place else { return "" }
        let short = place.course.shortName.isEmpty ? place.course.name : place.course.shortName
        let number = place.number.map { "L\($0)" }
        return [short, number, place.title.isEmpty ? nil : place.title].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Undo of advice

    /// Undo of a change the advisor made (`agent_change` target `filing`): a deck it filed from
    /// the panel is taken back (`undo`, the deck goes unless the student's work is on it); a
    /// filing it moved goes back to where it was. Refused (`FilingError.changedSince`) when the
    /// filing is no longer where the advice put it.
    public func undoAdvice(_ change: AgentChange) async throws {
        guard change.targetTable == .filing, let filingID = change.targetID,
              let filing = try await store.fetch(Filing.self, id: filingID) else { throw FilingError.missing }
        guard filing.lectureID == change.after?.lectureID else { throw FilingError.changedSince }
        if change.before?.exists == false {
            try await undo(filingID)
            return
        }
        let library = try await loadLibrary()
        if let lectureID = change.before?.lectureID, let info = library.lecture(lectureID) {
            _ = try await move(filing, to: .lecture(lectureID), courseID: info.lecture.courseID)
        } else if let sessionID = change.before?.lectureSessionID, let session = library.session(sessionID) {
            _ = try await move(filing, to: .session(sessionID), courseID: session.courseID)
        } else if let courseID = change.before?.courseID {
            try await changeToNewLecture(filingID, courseID: courseID)
        } else {
            try await unfileDeck(filing)
        }
    }

    /// A deck filing back to "no course" (Undo of advice that filed an unfiled deck): its link
    /// goes (the lecture re-aligns), the lecture it made goes when nothing else uses it, the
    /// filing stays without a place.
    func unfileDeck(_ filing: Filing) async throws {
        let now = now()
        let store = store
        try await services.database.write { db in
            guard var current = try Filing.find(filing.id).fetchOne(db), let deckID = current.deckID else { throw FilingError.missing }
            let oldLectureID = current.lectureID
            if let oldLectureID { try Self.unlinkDeck(deckID, from: oldLectureID, in: db, store: store, now: now) }
            let noCourse: Course.ID? = nil
            try Deck.find(deckID).update { $0.courseID = noCourse; $0.updatedAt = now }.execute(db)
            let createdLecture = current.createdLecture
            current.courseID = nil
            current.lectureID = nil
            current.lectureSessionID = nil
            current.createdLecture = false
            current.source = .auto
            current.confidence = 0
            let stamped = store.stamp(current)
            try Filing.upsert { stamped }.execute(db)
            if createdLecture, let oldLectureID, try Self.lectureIsUnused(oldLectureID, except: current.id, in: db) {
                try Lecture.find(oldLectureID).delete().execute(db)
            }
        }
        await afterImport()
    }
}
