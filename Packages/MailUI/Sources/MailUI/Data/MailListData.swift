import Foundation
import StudyCore
import StudyUI

/// One row of the message list (a message, or a draft in the Drafts scope).
struct MailListItem: Hashable, Sendable, Identifiable {
    /// The message's id (the draft's in Drafts).
    var id: UUID
    /// The sender; in Sent and Drafts the recipients.
    var sender: String
    var subject: String
    var snippet: String
    var date: Date
    var isUnread: Bool
    var isFlagged: Bool
    /// M3.5: triage found the mail asks the student something and it is not answered yet.
    var needsReply = false
    /// The course's colour (`#rrggbb`) when the message is routed to a course.
    var courseColor: String?
    /// The one extra line, only where there is something to act on.
    var extra: MailListExtra?
}

/// The extra line of a list row.
enum MailListExtra: Hashable, Sendable {
    /// A room change or cancellation waiting for Confirm ("Move to Room 5?").
    case proposal(itemID: TrackedItem.ID, kind: TrackedItemKind, room: String?, title: String)
    /// A learning platform's "New file" mail whose file smart import filed: the lecture, as a menu.
    case filed(filingID: Filing.ID, lectureID: Lecture.ID, number: Int?, title: String, date: Date?)
    /// A draft whose sending failed, with the reason.
    case failed(String)
}

/// What the message list shows for a scope.
struct MailListData: Hashable, Sendable {
    /// Nil until loaded; false without a mail account (the screen offers Set Up Mail…).
    var hasAccount: Bool?
    /// The account a new message is written from (the oldest enabled one).
    var accountID: MailAccount.ID?
    var rows: [MailListItem] = []

    init(hasAccount: Bool? = nil, accountID: MailAccount.ID? = nil, rows: [MailListItem] = []) {
        self.hasAccount = hasAccount
        self.accountID = accountID
        self.rows = rows
    }
}

/// The columns a list row needs (never the body): 2,000 rows read in a few milliseconds.
@Selection
struct MessageListColumns: Hashable, Sendable {
    let id: UUID
    let fromName: String
    let fromAddress: String
    @Column(as: [MailAddress].JSONRepresentation.self)
    let to: [MailAddress]
    let subject: String
    let snippet: String
    let receivedAt: Date
    let isSeen: Bool
    let isFlagged: Bool
    let courseID: UUID?
    let needsReply: Bool?
    let isAnswered: Bool
}

/// Reads one scope's rows in one transaction; observed, so new mail, flags and routes show up.
struct MailListRequest: FetchKeyRequest {
    var scope: MailScope
    /// Search hits (best first) from `MailActions.search`; nil lists the whole scope, newest first.
    var searchIDs: [UUID]? = nil

    func fetch(_ db: Database) throws -> MailListData {
        let account = try MailAccount.where { $0.isEnabled }.order(by: \.createdAt).fetchOne(db)
            ?? MailAccount.order(by: \.createdAt).fetchOne(db)
        guard let account else { return MailListData(hasAccount: false) }
        var data = MailListData(hasAccount: true, accountID: account.id)
        let courses = try Course.all.fetchAll(db)
        let colors = Dictionary(courses.map { ($0.id, $0.colorHex) }, uniquingKeysWith: { first, _ in first })

        if scope == .drafts {
            data.rows = try draftRows(db, colors: colors)
        } else {
            data.rows = try messageRows(db, colors: colors)
        }
        if let searchIDs {
            let rank = Dictionary(searchIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            data.rows = data.rows.filter { rank[$0.id] != nil }.sorted { rank[$0.id, default: 0] < rank[$1.id, default: 0] }
        }
        return data
    }

    /// The mailboxes a scope lists.
    static func mailboxIDs(for scope: MailScope, in mailboxes: [Mailbox]) -> [Mailbox.ID] {
        let roles: Set<MailboxRole> = switch scope {
        case .inbox: [.inbox]
        case .course, .category: [.inbox, .archive]
        case .sent: [.sent]
        case .drafts: []
        }
        return mailboxes.filter { $0.role.map(roles.contains) ?? false }.map(\.id)
    }

    private func messageRows(_ db: Database, colors: [Course.ID: String]) throws -> [MailListItem] {
        let mailboxes = try Mailbox.all.fetchAll(db)
        let boxes = Self.mailboxIDs(for: scope, in: mailboxes)
        guard !boxes.isEmpty else { return [] }
        let base = MailMessage.where { $0.mailboxID.in(boxes) }
        let scoped = switch scope {
        case .inbox: base.where { $0.moveToMailboxID.is(nil) }
        case .course(let courseID): base.where { $0.courseID.eq(courseID) }
        case .category(let category): base.where { $0.category.eq(MailCategory?.some(category)) && $0.courseID.is(nil) }
        case .sent, .drafts: base
        }
        let columns = try scoped
            .order { $0.receivedAt.desc() }
            .select {
                MessageListColumns.Columns(
                    id: $0.id, fromName: $0.fromName, fromAddress: $0.fromAddress, to: $0.to, subject: $0.subject,
                    snippet: $0.snippet, receivedAt: $0.receivedAt, isSeen: $0.isSeen, isFlagged: $0.isFlagged,
                    courseID: $0.courseID, needsReply: $0.needsReply, isAnswered: $0.isAnswered
                )
            }
            .fetchAll(db)
        let proposals = try openProposals(db)
        let filed = try filedLectures(db)
        let isSent = scope == .sent
        return columns.map { row in
            let sender = isSent
                ? row.to.map(\.displayName).joined(separator: ", ")
                : (row.fromName.trimmingCharacters(in: .whitespaces).isEmpty ? row.fromAddress : row.fromName)
            var extra: MailListExtra?
            if let proposal = proposals[row.id] {
                extra = .proposal(itemID: proposal.id, kind: proposal.kind, room: proposal.room, title: proposal.title)
            } else if let name = Self.newFileName(in: row.subject), let lecture = filed[name.lowercased()] {
                extra = lecture
            }
            return MailListItem(
                id: row.id, sender: sender, subject: row.subject, snippet: row.snippet, date: row.receivedAt,
                isUnread: !isSent && !row.isSeen, isFlagged: row.isFlagged,
                needsReply: !isSent && row.needsReply == true && !row.isAnswered,
                courseColor: row.courseID.flatMap { colors[$0] }, extra: extra
            )
        }
    }

    private func draftRows(_ db: Database, colors: [Course.ID: String]) throws -> [MailListItem] {
        let open: [MailDraftState] = [.generating, .draft, .failed, .sending]
        return try MailDraft.where { $0.state.in(open) }.order { $0.updatedAt.desc() }.fetchAll(db).map { draft in
            let snippet = draft.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return MailListItem(
                id: draft.id, sender: draft.to.map(\.displayName).joined(separator: ", "), subject: draft.subject,
                snippet: String(snippet.prefix(200)), date: draft.updatedAt, isUnread: false, isFlagged: false,
                courseColor: draft.courseID.flatMap { colors[$0] },
                extra: draft.state == .failed ? .failed(draft.error ?? "") : nil
            )
        }
    }

    /// Open room changes and cancellations by the message they were read from.
    private func openProposals(_ db: Database) throws -> [MailMessage.ID: TrackedItem] {
        let kinds: [TrackedItemKind] = [.roomChange, .cancellation]
        let items = try TrackedItem.where { $0.status.eq(TrackedItemStatus.open) && $0.kind.in(kinds) }.fetchAll(db)
        guard !items.isEmpty else { return [:] }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let itemIDs = items.map(\.id)
        let sources = try TrackedItemSource
            .where { $0.trackedItemID.in(itemIDs) && $0.mailMessageID.isNot(nil) && $0.undoneAt.is(nil) }
            .order(by: \.createdAt)
            .fetchAll(db)
        var result: [MailMessage.ID: TrackedItem] = [:]
        for source in sources {
            guard let messageID = source.mailMessageID, result[messageID] == nil, let item = byID[source.trackedItemID] else { continue }
            result[messageID] = item
        }
        return result
    }

    /// Filed files with a lecture, by lower-cased file name.
    private func filedLectures(_ db: Database) throws -> [String: MailListExtra] {
        let filings = try Filing.where { $0.lectureID.isNot(nil) }.order(by: \.createdAt).fetchAll(db)
        guard !filings.isEmpty else { return [:] }
        let lectureIDs = filings.compactMap(\.lectureID)
        let lectures = try Lecture.where { $0.id.in(lectureIDs) }.fetchAll(db)
        let byID = Dictionary(lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessionIDs = lectures.compactMap(\.lectureSessionID)
        let sessions = try LectureSession.where { $0.id.in(sessionIDs) }.fetchAll(db)
        let starts = Dictionary(sessions.map { ($0.id, $0.startsAt) }, uniquingKeysWith: { first, _ in first })
        var result: [String: MailListExtra] = [:]
        for filing in filings {
            guard let lectureID = filing.lectureID, let lecture = byID[lectureID] else { continue }
            let date = lecture.lectureSessionID.flatMap { starts[$0] } ?? lecture.heldAt
            // The newest filing of a name wins.
            result[filing.fileName.lowercased()] = .filed(
                filingID: filing.id, lectureID: lectureID, number: lecture.number, title: lecture.title, date: date
            )
        }
        return result
    }

    /// The file name of a learning platform's "New file" notification ("[Data Centers] New file: 02_….pdf").
    static func newFileName(in subject: String) -> String? {
        for marker in ["new file:", "neue datei:", "datei hinzugefügt:", "file added:"] {
            if let range = subject.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) {
                let name = subject[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }
}

/// Sidebar badges: unread Inbox mail by course and category, open drafts.
struct MailCounts: Hashable, Sendable {
    var unread = MailUnreadCounts()
    var drafts = 0
    var courses: [Course.ID: Course] = [:]

    func count(for scope: MailScope) -> Int {
        switch scope {
        case .inbox: unread.inbox
        case .course(let id): unread.byCourse[id, default: 0]
        case .category(let category): unread.byCategory[category, default: 0]
        case .drafts: drafts
        case .sent: 0
        }
    }
}

struct MailCountsRequest: FetchKeyRequest {
    func fetch(_ db: Database) throws -> MailCounts {
        var counts = MailCounts()
        let courses = try Course.all.fetchAll(db)
        counts.courses = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let open: [MailDraftState] = [.generating, .draft, .failed]
        counts.drafts = try MailDraft.where { $0.state.in(open) }.fetchCount(db)
        // As `MailRepository.unreadCounts`: INBOX only, not waiting to be archived.
        let inboxes = try Mailbox.where { $0.role.eq(MailboxRole?.some(.inbox)) }.select(\.id).fetchAll(db)
        guard !inboxes.isEmpty else { return counts }
        let unread = try MailMessage
            .where { $0.mailboxID.in(inboxes) && !$0.isSeen && $0.moveToMailboxID.is(nil) }
            .select { ($0.courseID, $0.category) }
            .fetchAll(db)
        counts.unread.inbox = unread.count
        for (courseID, category) in unread {
            if let courseID {
                counts.unread.byCourse[courseID, default: 0] += 1
            } else if let category, category != .course {
                counts.unread.byCategory[category, default: 0] += 1
            }
        }
        return counts
    }
}
