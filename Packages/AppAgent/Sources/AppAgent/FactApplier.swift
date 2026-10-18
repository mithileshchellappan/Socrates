import Agent
import Deadlines
import Foundation
import MailIntelligence
import StudyCore

/// Where a decided action's words come from, to check its quote in code (docs/plan-agent.md §4
/// "Verified writes") and to read its dates relative to when they were written or said.
enum FactMaterial: Sendable {
    /// A mail: the quote must be an exact span of it (`QuoteVerifier`, outside text that talks
    /// to the model); trusted only when the mail has no such text.
    case mail(MailMessage.ID, writtenAt: Date)
    /// Transcript lines the triage saw: an exact span of the window from the named line on, with
    /// its first word's time (`TranscriptQuote.locate`).
    case transcript(lectureID: Lecture.ID?, recordingID: Recording.ID, lines: [TranscriptQuote.Line], windows: [ClosedRange<Int>], heldAt: Date)
    /// The study pass's said-in-class quotes of a lecture (each the professor's exact words).
    case saidInClass(lectureID: Lecture.ID, quotes: [SaidQuote], heldAt: Date)
    /// Text code wrote from rows (a timetable diff, a calendar edit elsewhere).
    case text(String, kind: SourceRef.Kind, reference: String, date: Date)
    /// The student's words in the app agent's conversation (≥ 3 words).
    case chat(AgentConversation.ID, words: String, date: Date)

    struct SaidQuote: Sendable, Hashable {
        var text: String
        var recordingID: Recording.ID?
        var time: Double?
    }
}

/// A quote that passed its check.
struct VerifiedQuote: Sendable {
    var quote: String
    var source: ItemFinding.Source
    /// When the words were written or said (relative dates are read against it).
    var reference: Date
    var trusted: Bool
}

/// Turns decided actions (`FactAction`, the triage's or the mail extraction's) into change-log
/// requests, checking everything the model filled in code: the quote (an exact span of its
/// source), the dates (found in the quote: `DateMentions`), the ids (rows of the course), the room
/// (named in the quote).
struct FactApplier: Sendable {
    let services: StudyServices

    var timeZone: TimeZone { AppAgentModule.timeZone }

    // MARK: Quotes

    func verify(_ quote: String, line: String?, material: FactMaterial) async throws -> VerifiedQuote? {
        switch material {
        case .mail(let id, _):
            guard let checked = try await MailChat.verifyQuote(id: id, quote: quote, services: services) else { return nil }
            return VerifiedQuote(
                quote: checked.span, source: .mail(checked.messageID, rfcMessageID: checked.rfcMessageID), reference: checked.writtenAt,
                trusted: checked.trusted
            )
        case .transcript(let lectureID, let recordingID, let lines, let windows, let heldAt):
            guard let line, let found = TranscriptQuote.locate(quote, line: line, lines: lines, windows: windows) else { return nil }
            return VerifiedQuote(
                quote: found.quote, source: .transcript(lectureID: lectureID, recordingID: recordingID, time: found.time),
                reference: heldAt, trusted: true
            )
        case .saidInClass(let lectureID, let quotes, let heldAt):
            let cleaned = TranscriptQuote.cleaned(quote)
            guard cleaned.count >= 8 else { return nil }
            for said in quotes {
                guard let span = NormalizedText(said.text).originalSpan(of: cleaned) else { continue }
                guard let recordingID = said.recordingID else {
                    return VerifiedQuote(quote: String(span), source: .external(.transcript, reference: lectureID.uuidString.lowercased()), reference: heldAt, trusted: true)
                }
                return VerifiedQuote(
                    quote: String(span), source: .transcript(lectureID: lectureID, recordingID: recordingID, time: said.time ?? 0),
                    reference: heldAt, trusted: true
                )
            }
            return nil
        case .text(let text, let kind, let reference, let date):
            let cleaned = TranscriptQuote.cleaned(quote)
            guard cleaned.count >= 8, let span = NormalizedText(text).originalSpan(of: cleaned) else { return nil }
            return VerifiedQuote(quote: String(span), source: .external(kind, reference: reference), reference: date, trusted: true)
        case .chat(let conversationID, let words, let date):
            guard let span = AgentToolSupport.span(of: quote, in: words), TextFolding.words(span).count >= 3 || span.count >= 12 else { return nil }
            return VerifiedQuote(quote: span, source: .chat(conversationID), reference: date, trusted: true)
        }
    }

    // MARK: Requests

    /// The change-log request an action stands for, or why it cannot be applied.
    func request(_ action: FactAction, verified: VerifiedQuote, explicitSession: Bool = false) async throws -> Result<ChangeLog.Request, FactRefusal> {
        let courses = try await CourseList.load(services.database)
        let courseID = course(action.course, courses: courses)
        let mentions = DateMentions.parse(verified.quote, reference: verified.reference, timeZone: timeZone)
        switch action.changeKind {
        case .sessionRoom, .sessionCancel, .sessionRestore, .sessionTime:
            let restoring = action.changeKind == .sessionRestore
            let session: LectureSession
            switch try await resolveSession(action, courseID: courseID, mentions: mentions, cancelled: restoring, explicit: explicitSession) {
            case .success(let found): session = found
            case .failure(let refusal): return .failure(refusal)
            }
            switch action.changeKind {
            case .sessionRoom:
                guard let room = action.room?.trimmingCharacters(in: .whitespacesAndNewlines), !room.isEmpty else {
                    return .failure(.invalid("A room change needs the new room."))
                }
                guard explicitSession || TextFolding.fold(verified.quote).contains(TextFolding.fold(room)) else {
                    return .failure(.invalid("The quote does not name the room \(room)."))
                }
                return .success(.sessionRoom(session.id, room: room))
            case .sessionTime:
                guard let start = AgentToolSupport.parseDate(action.startsAt, allDay: false), !start.allDay else {
                    return .failure(.invalid("A time change needs the new start as YYYY-MM-DDTHH:MM."))
                }
                guard case .confirmed = mentions.verdict(for: start.date, allDay: false, timeZone: timeZone) else {
                    return .failure(.unverifiedDate("The quote does not state the new day and time."))
                }
                let duration = session.endsAt.timeIntervalSince(session.startsAt)
                let end = AgentToolSupport.parseDate(action.endsAt, allDay: false).map(\.date) ?? start.date.addingTimeInterval(duration)
                return .success(.sessionTime(session.id, startsAt: start.date, endsAt: max(end, start.date.addingTimeInterval(15 * 60))))
            case .sessionCancel:
                return .success(.sessionCancel(session.id))
            default:
                return .success(.sessionRestore(session.id))
            }
        case .sessionExtra:
            guard let courseID else { return .failure(.invalid("An extra session needs its course.")) }
            guard let start = AgentToolSupport.parseDate(action.startsAt, allDay: false), !start.allDay else {
                return .failure(.invalid("An extra session needs its start as YYYY-MM-DDTHH:MM."))
            }
            guard case .confirmed = mentions.verdict(for: start.date, allDay: false, timeZone: timeZone) else {
                return .failure(.unverifiedDate("The quote does not state the extra session's day and time."))
            }
            let end = AgentToolSupport.parseDate(action.endsAt, allDay: false).map(\.date) ?? start.date.addingTimeInterval(90 * 60)
            let kind = action.sessionKind.map(SessionKind.init(rawValue:)) ?? .lecture
            return .success(.sessionExtra(courseID: courseID, kind: kind, startsAt: start.date, endsAt: max(end, start.date), room: action.room ?? ""))
        case .itemAdd:
            let kind = TrackedItemKind(rawValue: action.itemKind ?? "deadline")
            guard [.deadline, .exercise, .exam, .event, .announcement, .task].contains(kind) else { return .failure(.invalid("Unknown item kind.")) }
            guard let title = action.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return .failure(.invalid("An item needs a title."))
            }
            var draft = DeadlineDraft(
                kind: kind, title: String(title.prefix(120)), details: Self.details(action.details), courseID: courseID,
                relevance: action.relevance.flatMap(Self.relevance), room: action.room
            )
            var dateVerified = false
            if let due = AgentToolSupport.parseDate(action.due, allDay: action.allDay ?? false) {
                let checked = AgentToolSupport.verify(due, in: verified.quote, reference: verified.reference)
                draft.dueAt = checked.date
                draft.isAllDay = checked.allDay
                dateVerified = checked.verified
                if !dateVerified, kind.isDue { return .failure(.unverifiedDate("The quote does not state the item's date.")) }
            } else if kind.isDue || kind == .event {
                return .failure(.invalid("A \(kind.rawValue) needs a date; use task or announcement without one."))
            }
            return .success(.itemAdd(draft, dateVerified: dateVerified))
        case .itemMove:
            guard let item = try await item(action.item) else { return .failure(.invalid("Unknown item.")) }
            guard let due = AgentToolSupport.parseDate(action.due, allDay: action.allDay ?? false) else {
                return .failure(.invalid("A move needs the new date."))
            }
            let checked = AgentToolSupport.verify(due, in: verified.quote, reference: verified.reference)
            guard checked.verified else { return .failure(.unverifiedDate("The quote does not state the new date.")) }
            return .success(.itemMove(item.id, due: checked.date, allDay: checked.allDay, dateVerified: true))
        case .itemDone:
            guard let item = try await item(action.item) else { return .failure(.invalid("Unknown item.")) }
            return .success(.itemDone(item.id))
        case .itemUpdate:
            guard let item = try await item(action.item) else { return .failure(.invalid("Unknown item.")) }
            return .success(.itemUpdate(
                item.id, title: action.title.map { String($0.prefix(120)) }, details: action.details.map(Self.details), room: action.room,
                relevance: action.relevance.flatMap(Self.relevance)
            ))
        case .courseFact:
            guard let courseID else { return .failure(.invalid("A course fact needs its course.")) }
            let fact = (action.fact ?? "other").trimmingCharacters(in: .whitespaces).lowercased()
            let text = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if fact == "lecturers" {
                let names = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !names.isEmpty, names.allSatisfy({ name in
                    TextFolding.words(name).filter { $0.count > 2 }.contains { TextFolding.fold(verified.quote).contains($0) }
                }) else { return .failure(.invalid("The quote does not name these lecturers.")) }
                return .success(.courseFact(courseID, kind: nil, text: text, professors: names))
            }
            guard !text.isEmpty else { return .failure(.invalid("A course fact needs its text.")) }
            return .success(.courseFact(courseID, kind: CourseRule.Kind(rawValue: fact), text: text, professors: nil))
        case .reminder:
            guard let fire = AgentToolSupport.parseDate(action.due, allDay: false), !fire.allDay else {
                return .failure(.invalid("A reminder needs its time as YYYY-MM-DDTHH:MM."))
            }
            let item = try await item(action.item)
            let title = action.title ?? item?.title ?? "Reminder"
            return .success(.reminder(itemID: item?.id, courseID: item?.courseID ?? courseID, title: title, body: action.text ?? "", fireAt: fire.date))
        default:
            return .failure(.invalid("Unknown action \(action.kind)."))
        }
    }

    /// Why an action was not turned into a request.
    enum FactRefusal: Error, Sendable, CustomStringConvertible {
        case invalid(String)
        case unverifiedDate(String)
        /// Several sessions fit (a careful decision is needed).
        case ambiguous(String)

        var description: String {
            switch self {
            case .invalid(let text), .unverifiedDate(let text), .ambiguous(let text): text
            }
        }
    }

    // MARK: Rows

    func course(_ reference: String?, courses: CourseList) -> Course.ID? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
        if let id = UUID(uuidString: reference), courses.courses.contains(where: { $0.id == id }) { return id }
        return courses.course(reference)?.id
    }

    func item(_ reference: String?) async throws -> TrackedItem? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
        if let id = UUID(uuidString: reference) { return try await services.records.fetch(TrackedItem.self, id: id) }
        let key = reference.lowercased()
        guard key.count >= 8, key.allSatisfy(\.isHexDigit) else { return nil }
        return try await services.database.read { db in
            let ids = try String.fetchAll(db, sql: #"SELECT "id" FROM "tracked_item" WHERE "id" LIKE ? LIMIT 2"#, arguments: [key + "%"])
            guard ids.count == 1, let id = UUID(uuidString: ids[0]) else { return nil }
            return try TrackedItem.find(id).fetchOne(db)
        }
    }

    /// The one session an action names: its id (of the course), else the course's sessions on
    /// the quoted day (and time), or of a quoted week ("next week's lecture"), narrowed by kind.
    func resolveSession(
        _ action: FactAction, courseID: Course.ID?, mentions: DateMentions, cancelled: Bool, explicit: Bool
    ) async throws -> Result<LectureSession, FactRefusal> {
        if let reference = action.session, let id = UUID(uuidString: reference.trimmingCharacters(in: .whitespaces)) {
            guard let session = try await services.records.fetch(LectureSession.self, id: id), courseID == nil || session.courseID == courseID else {
                return .failure(.invalid("Unknown session."))
            }
            guard session.isCancelled == cancelled else {
                return .failure(.invalid(cancelled ? "That session is not cancelled." : "That session is cancelled."))
            }
            // An id the model chose from a list: the quote must still state the session's day
            // (or week), unless the student named the session themselves.
            guard explicit || Self.mentions(mentions, session: session, timeZone: timeZone) else {
                return .failure(.unverifiedDate("The quote does not state that session's day."))
            }
            return .success(session)
        }
        guard let courseID else { return .failure(.invalid("A session change needs its course.")) }
        let sessions = try await services.database.read { db in
            try LectureSession.where { $0.courseID.eq(courseID) && $0.isCancelled.eq(cancelled) }.order(by: \.startsAt).fetchAll(db)
        }
        var matches: [LectureSession]
        let planned = AgentToolSupport.parseDate(action.sessionDay, allDay: !(action.sessionDay ?? "").contains("T"))
        if let planned, mentions.days.contains(CalendarDay(planned.date, in: timeZone)) {
            let day = CalendarDay(planned.date, in: timeZone)
            matches = sessions.filter { CalendarDay($0.startsAt, in: timeZone) == day }
        } else if !mentions.weeks.isEmpty {
            matches = sessions.filter { session in
                let day = CalendarDay(session.startsAt, in: timeZone)
                return mentions.weeks.contains(day.adding(days: 1 - day.weekday))
            }
        } else if !mentions.days.isEmpty {
            matches = sessions.filter { mentions.days.contains(CalendarDay($0.startsAt, in: timeZone)) }
        } else {
            return .failure(.unverifiedDate("The quote does not state the session's day or week."))
        }
        if matches.count > 1, !mentions.minutes.isEmpty {
            matches = matches.filter { session in
                let minute = DateMentions.minute(of: session.startsAt, timeZone: timeZone)
                return mentions.minutes.contains { abs($0 - minute) <= 20 }
            }
        }
        if matches.count > 1, let kind = action.sessionKind.map(SessionKind.init(rawValue:)) {
            matches = matches.filter { $0.kind == kind }
        }
        if matches.count > 1, let planned, !planned.allDay {
            let minute = DateMentions.minute(of: planned.date, timeZone: timeZone)
            matches = matches.filter { abs(DateMentions.minute(of: $0.startsAt, timeZone: timeZone) - minute) <= 20 }
        }
        guard let first = matches.first else { return .failure(.invalid("No session of the course fits the quote.")) }
        guard matches.count == 1 else { return .failure(.ambiguous("\(matches.count) sessions fit the quote.")) }
        return .success(first)
    }

    static func mentions(_ mentions: DateMentions, session: LectureSession, timeZone: TimeZone) -> Bool {
        let day = CalendarDay(session.startsAt, in: timeZone)
        return mentions.days.contains(day) || mentions.weeks.contains(day.adding(days: 1 - day.weekday))
    }

    static func details(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
    }

    static func relevance(_ text: String) -> ItemRelevance? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        return ["exam_admission", "bonus"].contains(value) ? ItemRelevance(rawValue: value) : nil
    }
}
