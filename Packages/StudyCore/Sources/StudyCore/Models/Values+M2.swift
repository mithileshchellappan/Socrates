import Foundation
import SQLiteData

// Value types added in schema v5 (milestone 2): university mail, its routing to courses, what was
// extracted from it, and reply drafts. See docs/plan-m2.md and docs/schema.md.

// MARK: - Mail transport

/// How a mail connection is secured. Plain text is not offered.
public struct MailSecurity: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// TLS from the first byte (IMAPS 993, SMTPS 465).
    public static let tls: Self = "tls"
    /// Plain greeting, then STARTTLS before anything else is sent (SMTP submission 587).
    public static let startTLS: Self = "starttls"
}

/// A mailbox's role (IMAP SPECIAL-USE, RFC 6154; INBOX by name). Nil on `Mailbox.role` = an
/// ordinary folder.
public struct MailboxRole: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let inbox: Self = "inbox"
    public static let sent: Self = "sent"
    public static let drafts: Self = "drafts"
    public static let archive: Self = "archive"
    public static let trash: Self = "trash"
    public static let junk: Self = "junk"
}

/// A name and address from a mail header. Stored as JSON in `mail_message.to_addresses`,
/// `cc_addresses`, `reply_to` and the `mail_draft` recipient columns.
public struct MailAddress: Hashable, Sendable, Codable {
    /// Display name, decoded (RFC 2047); empty when the header had none.
    public var name: String
    /// `local@domain`, as written (compare with `normalizedAddress`).
    public var address: String

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    /// Lower-cased, trimmed address for comparisons and rules.
    public var normalizedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The name when there is one, else the address.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }
}

// MARK: - Routing

/// What a message is about, beyond a course. A message routed to a course has category `course`
/// and a `course_id`; the others are the mockup's "Other" mailboxes (University, Newsletters) or
/// stay in the Inbox only (personal, other).
public struct MailCategory: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// About one of the student's courses (`course_id` set).
    public static let course: Self = "course"
    /// University administration: IT services, the student office, the exam office, library, LMS service mail.
    public static let university: Self = "university"
    /// Mailing lists, newsletters, announcements to many recipients that need nothing from the student.
    public static let newsletter: Self = "newsletter"
    /// Written to the student personally and about no course.
    public static let personal: Self = "personal"
    /// Anything else (spam that got through, notifications of no use).
    public static let other: Self = "other"
}

/// Where a message belongs: a course, or a category without one. The router's output and what a
/// correction picks.
public enum MailRoute: Hashable, Sendable {
    case course(Course.ID)
    case category(MailCategory)

    /// `category` column value for this route.
    public var category: MailCategory {
        switch self {
        case .course: .course
        case .category(let category): category
        }
    }

    /// `course_id` column value for this route.
    public var courseID: Course.ID? {
        if case .course(let id) = self { return id }
        return nil
    }
}

/// Who decided a message's route.
public enum MailRoutingSource: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// A `mail_rule` matched (`routing_rule_id`).
    case rule
    /// The model (Haiku) decided (`routing_api_call_id`).
    case model
    /// The student picked it. Never overwritten by rules or the model.
    case user
}

/// What a `mail_rule` compares (case-insensitive, diacritics folded, substring).
public struct MailRuleKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// "Sender is": the From address (or display name) contains the pattern.
    public static let sender: Self = "sender"
    /// "Mailing list is": the List-Id header contains the pattern.
    public static let listID: Self = "list_id"
    /// "Subject contains".
    public static let subject: Self = "subject"
    /// "LMS course is": an LMS notification about the course with this title (the
    /// "[Data Centers]" subject prefix or the course path in the body, e.g.
    /// "Data Centers (WS 2026/27)").
    public static let platformCourse: Self = "platform_course"
}

/// Where a `mail_rule` came from.
public enum MailRuleOrigin: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Typed in Course Settings.
    case user
    /// Learned from a correction (the student moved a message to another course).
    case learned
}

// MARK: - Intelligence

/// Where a message is in the extraction pass (deadlines, announcements, room changes,
/// cancellations).
public enum MailExtractionState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Waits for routing, then extraction.
    case pending
    /// Nothing to extract (newsletter, outside the window, no date or change cue, sent by the student).
    case skipped
    /// Extracted (possibly nothing found).
    case done
    /// Gave up after `MailMessage.maximumExtractionAttempts`.
    case failed
}

/// A reply or new message the student writes (the agent may draft its text; only the Send button sends).
public enum MailDraftState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// The agent is streaming its text into the draft.
    case generating
    /// Editable; nothing sent.
    case draft
    /// Send was pressed and SMTP is in progress. Never resent automatically: after a crash the
    /// sender checks the Sent mailbox for `rfc_message_id` first.
    case sending
    /// The server accepted it (`sent_at`, `rfc_message_id`).
    case sent
    /// Sending failed (`error`); Send may be pressed again.
    case failed
}

extension TrackedItemKind {
    /// A room change of one lecture session (a proposal: `lecture_session_id` + new `room`,
    /// applied on Confirm).
    public static let roomChange: Self = "room_change"
    /// A cancelled lecture session (a proposal: `lecture_session_id`, applied on Confirm).
    public static let cancellation: Self = "cancellation"
    /// A dated event that is not something due (an info session, the first tutorial).
    public static let event: Self = "event"

    /// Kinds that are proposals to change a lecture session; they wait for Confirm.
    public var isSessionProposal: Bool { self == .roomChange || self == .cancellation }

    /// Kinds that go into the app's calendar on their own, once their date is verified
    /// against the source quote (PRD trust rule: deadlines only).
    public var addsToCalendarAutomatically: Bool { self == .deadline || self == .exercise || self == .exam }
}

extension SearchChunkKind {
    /// One stretch of a mail message (`mail_message_id`, `course_id`): subject + body paragraphs.
    public static let mail: Self = "mail"
}
