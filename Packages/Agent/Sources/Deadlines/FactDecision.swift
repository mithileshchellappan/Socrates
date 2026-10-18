import Foundation
import StudyCore

/// ma (docs/plan-agent.md §4): one action a triage decided about a new fact, before code verifies
/// and applies it through AppAgent's change log. The batched Haiku triage answers with these, and
/// the mail pipeline's extraction call (the mail half of triage) writes them into its
/// `agent_event.detail` (`FactDecision.decided`), so nothing is asked twice. Every field the model
/// fills is checked in code: the quote must be an exact span of the source, dates must be found
/// in it, ids must name rows of the course.
public struct FactAction: Codable, Hashable, Sendable {
    /// `AgentChangeKind` raw value: session_room, session_time, session_cancel, session_restore,
    /// session_extra, item_add, item_move, item_done, item_update, course_fact, reminder.
    public var kind: String
    /// Course token (or id).
    public var course: String?
    /// The session's id when the triage saw it (the state block lists ids).
    public var session: String?
    /// The day (and time) of the session the source talks about, "YYYY-MM-DD[THH:MM]", when no
    /// id is given; with the course and `sessionKind` code finds the one session it names.
    public var sessionDay: String?
    /// lecture / exercise / tutorial / seminar.
    public var sessionKind: String?
    /// The item's id (item_move / item_done / item_update).
    public var item: String?
    /// deadline / exercise / exam / event / task / announcement (item_add).
    public var itemKind: String?
    public var title: String?
    public var details: String?
    /// The item's date, "YYYY-MM-DDTHH:MM" or "YYYY-MM-DD".
    public var due: String?
    public var allDay: Bool?
    /// A session's new start and end (session_time, session_extra), "YYYY-MM-DDTHH:MM".
    public var startsAt: String?
    public var endsAt: String?
    public var room: String?
    /// course_fact: `CourseRule.Kind` raw value (exam_admission, exam_form, bonus, exercise,
    /// attendance, other) or "lecturers".
    public var fact: String?
    /// course_fact: the rule's text, or the lecturers separated by ";".
    public var text: String?
    /// exam_admission / bonus.
    public var relevance: String?
    /// The exact words of the source that state it.
    public var quote: String
    /// A transcript source's line id ("l17") where the quote starts.
    public var line: String?
    public var confidence: Double

    public init(
        kind: String, course: String? = nil, session: String? = nil, sessionDay: String? = nil, sessionKind: String? = nil,
        item: String? = nil, itemKind: String? = nil, title: String? = nil, details: String? = nil, due: String? = nil,
        allDay: Bool? = nil, startsAt: String? = nil, endsAt: String? = nil, room: String? = nil, fact: String? = nil,
        text: String? = nil, relevance: String? = nil, quote: String, line: String? = nil, confidence: Double
    ) {
        self.kind = kind
        self.course = course
        self.session = session
        self.sessionDay = sessionDay
        self.sessionKind = sessionKind
        self.item = item
        self.itemKind = itemKind
        self.title = title
        self.details = details
        self.due = due
        self.allDay = allDay
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.room = room
        self.fact = fact
        self.text = text
        self.relevance = relevance
        self.quote = quote
        self.line = line
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case kind, course, session, item, title, details, due, room, fact, text, relevance, quote, line, confidence
        case sessionDay = "session_day"
        case sessionKind = "session_kind"
        case itemKind = "item_kind"
        case allDay = "all_day"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    public var changeKind: AgentChangeKind { AgentChangeKind(rawValue: kind) }
}

/// A triage's answer for one event: its actions, and whether a bigger model must decide.
public struct FactDecision: Codable, Hashable, Sendable {
    /// The event's id in the batch ("e1"; empty in a mail event's detail).
    public var event: String
    public var actions: [FactAction]
    /// Ambiguous, conflicting or high impact: an Opus 5.5 escalation task decides.
    public var escalate: Bool
    /// Why (one short sentence; shown to the escalation, never to the student as is).
    public var reason: String
    /// Who decided ("claude-haiku-5-5").
    public var model: String?
    /// The `api_call` row of the call that decided (the mail extraction's).
    public var apiCallID: UUID?

    public init(event: String = "", actions: [FactAction], escalate: Bool, reason: String, model: String? = nil, apiCallID: UUID? = nil) {
        self.event = event
        self.actions = actions
        self.escalate = escalate
        self.reason = reason
        self.model = model
        self.apiCallID = apiCallID
    }

    enum CodingKeys: String, CodingKey {
        case event, actions, escalate, reason, model
        case apiCallID = "api_call_id"
    }

    /// The prefix of an `agent_event.detail` that holds a decision already made (the mail
    /// extraction's): triage applies it without another call.
    public static let decidedPrefix = "decided:"

    /// This decision as an `agent_event.detail` (`decided:` + JSON, sorted keys).
    public func detail() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else { return nil }
        return Self.decidedPrefix + json
    }

    /// The decision an event's detail holds, if it holds one.
    public static func decided(in detail: String?) -> FactDecision? {
        guard let detail, detail.hasPrefix(decidedPrefix) else { return nil }
        return try? JSONDecoder().decode(FactDecision.self, from: Data(detail.dropFirst(decidedPrefix.count).utf8))
    }
}
