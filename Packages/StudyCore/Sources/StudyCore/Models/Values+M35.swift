import Foundation
import SQLiteData

// Values added with schema v7 (M3.5: the AI runs through Claude Code; mail triage finds tasks and
// mail that needs a reply; chat with the agent, mail in context). docs/plan-m35.md §2.

extension TrackedItemKind {
    /// Something the student must do that has no due date of its own: register in the exam portal, fill in
    /// a survey, bring a laptop, hand in a form. A dated action is a `deadline` (or `exercise`,
    /// `exam`); extraction turns a task with a due date into a deadline. Tied to a session when
    /// the source names one (`lecture_session_id`). Never goes into the calendar on its own
    /// (`addsToCalendarAutomatically` false); not `isDue`. Today lists open tasks in Coming up
    /// with the open ring; Mark as Done completes one.
    public static let task: Self = "task"
}

extension ConversationKind {
    /// The chat in the inspector (Today, Mail): the student asks about their mail and the agent
    /// searches and reads it, adds deadlines (verified, with Undo) and writes reply drafts. On
    /// Mail each turn carries the open message as delimited data. No send tool, no web tools.
    /// Tools (fixed): search_mail, read_mail, list_mail (read, untrusted content); list_courses,
    /// list_sessions, find_items (read); add_item (verified write); propose_session_change
    /// (stage); draft_reply (draft). docs/plan-m35.md §2.3.
    public static let mailChat: Self = "mail_chat"
}

/// How a call was paid for (v7 `api_call.billing`). Nil on rows written before v7 and on
/// Messages API calls.
public struct CallBilling: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Billed per token with an API key.
    public static let api: Self = "api"
    /// The student's Claude Code subscription: `cost_usd` is notional (list prices); the real
    /// limit is the plan's usage limit.
    public static let subscription: Self = "subscription"
}
