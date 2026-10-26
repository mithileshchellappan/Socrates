import ClaudeKit
import Deadlines
import Foundation
import StudyCore

/// A quote of a mail that code checked (M3.5, the mail chat's add_item): the exact span of the
/// mail it stands for, and whether the mail is free of text that talks to the model.
public struct VerifiedMailQuote: Sendable, Hashable {
    public var messageID: MailMessage.ID
    public var rfcMessageID: String
    /// The original span of the mail, byte for byte.
    public var span: String
    /// When the mail was written: relative dates in the quote are read against it.
    public var writtenAt: Date
    /// False when the mail has a paragraph that talks to the model (`InjectionGuard`): nothing
    /// from it goes into the calendar on its own.
    public var trusted: Bool

    public init(messageID: MailMessage.ID, rfcMessageID: String, span: String, writtenAt: Date, trusted: Bool) {
        self.messageID = messageID
        self.rfcMessageID = rfcMessageID
        self.span = span
        self.writtenAt = writtenAt
        self.trusted = trusted
    }
}

/// The deadline tools a conversation kind built outside this package assembles (M3.5: the mail
/// chat in MailIntelligence): the readers list_courses, list_sessions and find_items, the stager
/// propose_session_change, all as the `deadlines` conversation has them, and add_item as a
/// `.verifiedWrite` whose quote code checks (`addVerifiedItem(mailQuote:)`). No update, complete or
/// delete tool is offered here.
public struct DeadlineToolKit: Sendable {
    let tools: DeadlineTools.Tools

    /// Checks that `quote` is an exact span of mail `id`; nil when it is not (or the mail is gone,
    /// or the quote lies in text that talks to the model).
    public typealias MailQuoteCheck = @Sendable (_ id: MailMessage.ID, _ quote: String) async throws -> VerifiedMailQuote?

    public init(services: StudyServices, memory: DeadlineMemory) {
        tools = DeadlineTools.Tools(services: services, memory: memory)
    }

    public var listCourses: AgentTool { tools.listCourses }
    public var listSessions: AgentTool { tools.listSessions }
    public var findItems: AgentTool { tools.findItems }
    public var proposeSessionChange: AgentTool { tools.proposeSessionChange }

    /// add_item {kind, title, course?, due?, all_day, details?, relevance?, session?, quote, mail_id?}
    /// as a `.verifiedWrite`:
    /// - with `mail_id`, `quote` must be an exact span of that mail (`mailQuote`); the source is
    ///   the mail, `trusted` only when the mail passes the injection guard;
    /// - without, `quote` must be an exact span of the student's words of this turn; the source is
    ///   the conversation.
    /// `DateMentions` on the quote decides whether the due date is verified (relative to when the
    /// mail was written or the student spoke); a time the quote does not state is dropped. Written
    /// through the deadline memory (dedup, the calendar rule, Undo). Kinds include `task` (a task
    /// with a date becomes a deadline).
    public func addVerifiedItem(mailQuote: @escaping MailQuoteCheck) -> AgentTool {
        let tools = tools
        return AgentTool(
            tool: .custom(
                name: "add_item",
                description: """
                    Adds a deadline, exercise, exam, event, announcement or task the student asked you to add or a mail \
                    states. quote is copied character for character: from the mail whose id you give as mail_id, or, \
                    without mail_id, from the student's own words in their current message. A date is kept only when the \
                    quote states it. Look with find_items first; never add an item twice.
                    """,
                inputSchema: DeadlineTools.Tools.object([
                    "kind": ["type": "string", "enum": ["deadline", "exercise", "exam", "event", "announcement", "task"]],
                    "title": ["type": "string", "description": "Short title, at most 8 words."],
                    "course": DeadlineTools.Tools.nullable(["type": "string", "description": "Course token."]),
                    "due": DeadlineTools.Tools.nullable([
                        "type": "string",
                        "description": "YYYY-MM-DDTHH:MM or YYYY-MM-DD; null for announcements and tasks without a date.",
                    ]),
                    "all_day": ["type": "boolean"],
                    "details": DeadlineTools.Tools.nullable(["type": "string", "description": "At most 12 words on why it matters."]),
                    "relevance": DeadlineTools.Tools.nullable(["type": "string", "enum": ["exam_admission", "bonus"]]),
                    "session": DeadlineTools.Tools.nullable(["type": "string", "description": "Id of the session it is tied to (list_sessions)."]),
                    "quote": ["type": "string", "description": "The exact words that state the item (and its date)."],
                    "mail_id": DeadlineTools.Tools.nullable(["type": "string", "description": "The id of the mail the quote is from; null for the student's words."]),
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            try await tools.addVerified(call, context: context, mailQuote: mailQuote)
        }
    }
}

extension DeadlineTools.Tools {
    func addVerified(_ call: ToolUseBlock, context: ToolContext, mailQuote: DeadlineToolKit.MailQuoteCheck) async throws -> ToolOutput {
        let courses = try await CourseTokens.load(database)
        let kind = TrackedItemKind(rawValue: call.string("kind") ?? "deadline")
        guard [.deadline, .exercise, .exam, .event, .announcement, .task].contains(kind) else { return .error("Unknown kind.") }
        guard let title = call.string("title") else { return .error("A title is needed.") }
        if call.string("course") != nil, courses.course(call.string("course")) == nil {
            return .error("Unknown course. Use a token from list_courses.")
        }
        guard let quote = call.string("quote") else { return .error("A quote is needed.") }

        // Where the quote is from, checked in code: a mail, or the student's words of this turn.
        let source: ItemFinding.Source
        let span: String
        let reference: Date
        let trusted: Bool
        if let mail = call.string("mail_id") {
            guard let id = UUID(uuidString: mail) else { return .error("mail_id is not a mail id.") }
            guard let checked = try await mailQuote(id, quote) else {
                return .error("The quote is not in that mail. Copy the mail's words exactly.")
            }
            source = .mail(checked.messageID, rfcMessageID: checked.rfcMessageID)
            span = checked.span
            reference = checked.writtenAt
            trusted = checked.trusted
        } else {
            guard let words = Self.span(of: quote, in: context.studentText) else {
                return .error("Without mail_id the quote must be the student's own words of this message, copied exactly.")
            }
            source = .chat(context.conversationID)
            span = words
            reference = context.wordsWrittenAt
            trusted = true
        }

        var draft = DeadlineDraft(
            kind: kind, title: title, details: Self.details(call.string("details")),
            courseID: courses.course(call.string("course"))?.id,
            relevance: call.string("relevance").map(ItemRelevance.init(rawValue:)),
            lectureSessionID: call.string("session").flatMap(UUID.init(uuidString:))
        )
        var verified = false
        if let text = call.string("due") {
            guard let due = AgentDates.parse(text, allDay: call.bool("all_day") ?? false) else {
                return .error("due must be YYYY-MM-DDTHH:MM or YYYY-MM-DD.")
            }
            let checked = AgentDates.verify(due, in: span, reference: reference)
            draft.dueAt = checked.date
            draft.isAllDay = checked.allDay
            verified = checked.verified
        } else if kind != .announcement, kind != .task {
            return .error("A \(kind.rawValue) needs a due date; use task or announcement when there is none.")
        }
        let finding = ItemFinding(
            draft: draft, source: source, quote: span, confidence: 1, dateVerified: verified, trusted: trusted,
            createdBy: .agent, mentions: DateMentions.parse(span, reference: reference, timeZone: timeZone)
        )
        let result = try await memory.record(finding)
        let untrusted = try await untrustedItems([result.item.id])
        return .json(Self.json(result.item, courses: courses, untrusted: !untrusted.isEmpty, extra: ["created": .bool(result.created)]))
    }

    /// The original span of `words` that `quote` stands for (whitespace and typographic quotes
    /// normalized), at least 3 characters.
    static func span(of quote: String, in words: String) -> String? {
        let candidate = quote.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”„'‘’")))
        guard candidate.count >= 3, let span = NormalizedText(words).originalSpan(of: candidate) else { return nil }
        return String(span)
    }
}
