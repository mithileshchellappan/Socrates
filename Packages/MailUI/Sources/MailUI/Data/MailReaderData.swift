import Foundation
import StudyCore
import Synchronization

/// What the reader shows for one message, read (and its body rendered) in one pass.
struct MailReaderData: Hashable, Sendable {
    var message: MailMessage?
    var attachments: [MailAttachment] = []
    /// What was read from this mail ("found" rows), in due order.
    var found: [FoundRow] = []
    /// Courses for the route menu, in sidebar order.
    var courses: [Course] = []
    var body = MailBody()
}

/// One "found" row: an item this mail added or proposed, with the source that ties it to the mail.
struct FoundRow: Hashable, Sendable, Identifiable {
    var item: TrackedItem
    var source: TrackedItemSource
    /// The lecture session a proposal (or an event) is about.
    var session: LectureSession?
    /// Where a lecture said the same (another source of the item, M3): a jump-to-time chip.
    var lectureSource: LectureMoment?

    var id: TrackedItemSource.ID { source.id }

    struct LectureMoment: Hashable, Sendable {
        var lectureID: Lecture.ID
        var number: Int?
        /// Seconds on the recording clock.
        var time: Double
    }

    /// What the row offers.
    enum State: Hashable, Sendable {
        /// In the calendar ("In Calendar"); `undoable`: with Undo (not for an existing session or
        /// a confirmed proposal).
        case inCalendar(undoable: Bool)
        /// A dated item the mail did not confirm well enough to add on its own: Add to Calendar.
        case addable
        /// A room change or cancellation waiting: Discard / Confirm.
        case proposal
        /// Undone through this mail: Restore.
        case undone
        /// A discarded proposal (nothing to do).
        case discarded
        /// No date (an announcement): the text only.
        case info
    }

    var state: State {
        // ma: session changes (room, cancellation, time, extra session) are applied on their own
        // and read "In Calendar" with Undo while this source stands; M2's open proposals still
        // wait for Confirm.
        if item.kind.isSessionChange {
            switch item.status {
            case .open: return item.kind.isSessionProposal ? .proposal : .info
            case .done: return .inCalendar(undoable: source.undoneAt == nil)
            case .dismissed: return .discarded
            }
        }
        if source.undoneAt != nil || item.status == .dismissed { return .undone }
        if item.status == .done { return .info }
        if item.lectureSessionID != nil { return .inCalendar(undoable: false) }
        if item.inCalendar { return .inCalendar(undoable: true) }
        if item.dueAt != nil { return .addable }
        return .info
    }

    /// The quote is underlined in the body while the row stands.
    var marksQuote: Bool {
        switch state {
        case .undone, .discarded: false
        default: true
        }
    }
}

struct MailReaderRequest: FetchKeyRequest {
    let messageID: MailMessage.ID
    /// Where the sanitized HTML lives (`BlobStore.root`); nil reads `body_text` only.
    let blobRoot: URL?

    func fetch(_ db: Database) throws -> MailReaderData {
        guard let message = try MailMessage.find(messageID).fetchOne(db) else { return MailReaderData() }
        var data = MailReaderData(message: message)
        let messageID = messageID
        data.attachments = try MailAttachment
            .where { $0.mailMessageID.eq(messageID) && !$0.isInline }
            .order(by: \.part)
            .fetchAll(db)
        data.courses = try Course.order { ($0.sortOrder, $0.name) }.fetchAll(db)
        data.found = try Self.found(for: message, db: db)

        let quotes = data.found.filter(\.marksQuote).map(\.source.quote)
        data.body = Self.body(of: message, quotes: quotes, blobRoot: blobRoot)
        return data
    }

    /// As `TrackedItemRepository.items(mailMessageID:)`: sources by row or by Message-ID (a copy in
    /// another mailbox), one row per item, in due order.
    static func found(for message: MailMessage, db: Database) throws -> [FoundRow] {
        let messageID = message.id
        let rfcID = message.rfcMessageID
        let sources = try TrackedItemSource
            .where { $0.mailMessageID.eq(messageID) || ($0.rfcMessageID.eq(rfcID) && $0.rfcMessageID.neq("")) }
            .order(by: \.createdAt)
            .fetchAll(db)
        var seen: Set<TrackedItem.ID> = []
        var rows: [FoundRow] = []
        for source in sources where seen.insert(source.trackedItemID).inserted {
            guard let item = try TrackedItem.find(source.trackedItemID).fetchOne(db) else { continue }
            let session = try item.lectureSessionID.flatMap { id in try LectureSession.find(id).fetchOne(db) }
            let itemID = item.id
            let spoken = try TrackedItemSource
                .where { $0.trackedItemID.eq(itemID) && $0.lectureID.isNot(nil) && $0.time.isNot(nil) && $0.undoneAt.is(nil) }
                .order(by: \.createdAt)
                .fetchOne(db)
            var moment: FoundRow.LectureMoment?
            if let spoken, let lectureID = spoken.lectureID, let time = spoken.time {
                let lecture = try Lecture.find(lectureID).fetchOne(db)
                moment = FoundRow.LectureMoment(lectureID: lectureID, number: lecture?.number, time: time)
            }
            rows.append(FoundRow(item: item, source: source, session: session, lectureSource: moment))
        }
        return inReadingOrder(rows, subject: message.subject, text: message.bodyText)
    }

    /// Rows in the order their quotes stand in the mail (the subject first), as the student reads
    /// it; a quote not found in either goes last, by due date.
    static func inReadingOrder(_ rows: [FoundRow], subject: String, text: String) -> [FoundRow] {
        let folded = QuoteMatcher.normalized(text)
        func position(_ row: FoundRow) -> Int {
            if let range = QuoteMatcher.offsetRanges(of: row.source.quote, in: folded).first { return range.lowerBound }
            return QuoteMatcher.ranges(of: row.source.quote, in: subject).isEmpty ? Int.max : -1
        }
        return rows.map { (row: $0, position: position($0)) }.sorted { lhs, rhs in
            let left = (lhs.position, lhs.row.item.dueAt ?? .distantFuture, lhs.row.item.createdAt)
            let right = (rhs.position, rhs.row.item.dueAt ?? .distantFuture, rhs.row.item.createdAt)
            return left < right
        }.map(\.row)
    }

    /// The rendered body, cached by message version and quotes (an unrelated write re-reads the
    /// rows, not the HTML).
    static func body(of message: MailMessage, quotes: [String], blobRoot: URL?) -> MailBody {
        let key = BodyCache.Key(messageID: message.id, html: message.htmlSHA256, text: message.bodyText, quotes: quotes)
        if let cached = BodyCache.shared.body(for: key) { return cached }
        var html: String?
        if let ref = message.html, let blobRoot {
            let url = BlobStore(root: blobRoot).url(for: ref)
            if let data = try? Data(contentsOf: url) { html = String(decoding: data, as: UTF8.self) }
        }
        let body = MailBodyRenderer.render(html: html, text: message.bodyText, quotes: quotes)
        BodyCache.shared.store(body, for: key)
        return body
    }
}

/// The last few rendered bodies.
final class BodyCache: Sendable {
    struct Key: Hashable, Sendable {
        var messageID: MailMessage.ID
        var html: String
        var text: String
        var quotes: [String]
    }

    static let shared = BodyCache()
    private let entries = Mutex<[(key: Key, body: MailBody)]>([])
    private let capacity = 24

    func body(for key: Key) -> MailBody? {
        entries.withLock { entries in entries.first { $0.key == key }?.body }
    }

    func store(_ body: MailBody, for key: Key) {
        entries.withLock { entries in
            entries.removeAll { $0.key == key }
            entries.insert((key, body), at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        }
    }
}
