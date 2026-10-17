import ClaudeKit
import Deadlines
import Foundation
import GRDB
import StudyCore

/// Reads deadlines, exercises, exams, events, room changes, cancellations and announcements out
/// of routed mail (PRD #32) into `tracked_item` rows with `tracked_item_source` provenance.
///
/// Trust rules in code, whatever the model says:
/// 1. a quote is kept only when it is an exact substring of the subject or body (after whitespace
///    and typographic normalization); the original span is stored, byte for byte, 8–300 characters;
/// 2. a deadline, exercise or exam goes into the calendar on its own (`in_calendar`, source
///    `calendar_added`) only when `DateMentions` finds its day — and its time, when the quote has
///    one — in that quote; otherwise it is kept with `in_calendar` false (Add to Calendar);
/// 3. a room change or cancellation becomes a proposal only when exactly one non-cancelled session
///    of the course matches the quoted day (and time), else an announcement;
/// 4. a repeat (same course, kind group, day, similar title; or the same Message-ID and quote),
///    also of an item read from a lecture or told by the student, becomes another source of the
///    existing item, also when it was dismissed: Undo sticks and nothing goes into the calendar
///    twice (rules 2-4 live in `Deadlines.DeadlineMemory`, the one write path);
/// 5. items, sources and the message's extraction state are written in one transaction.
public struct MailExtractor: Sendable {
    /// What one pass did.
    public struct Report: Sendable, Equatable {
        public var skipped = 0
        public var done = 0
        public var failed = 0
        public var calls = 0
        public var itemsCreated = 0
        public var sourcesAdded = 0
        public var rejected = 0
        /// Messages left pending (no key, cost guard, service trouble).
        public var waiting = 0

        public init() {}
    }

    /// What applying one answer wrote.
    struct Applied: Sendable, Equatable {
        var itemsCreated = 0
        var sourcesAdded = 0
        var rejected = 0
    }

    /// Default number of extraction calls in flight.
    public static let defaultConcurrency = 2
    /// Mail older than this many days (when the account has no `sync_since`) is not read.
    static let defaultWindowDays = 30

    let services: StudyServices
    let client: ClaudeClient?
    let now: @Sendable () -> Date
    let timeZone: TimeZone

    public init(
        services: StudyServices,
        client: ClaudeClient?,
        timeZone: TimeZone = MailIntelligenceModule.timeZone,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.client = client
        self.timeZone = timeZone
        self.now = now
    }

    var repository: MailRepository { MailRepository(store: services.records) }

    // MARK: - Pending mail

    enum Decision: Sendable, Equatable {
        case skip
        /// A copy of this message (same Message-ID) was already read.
        case alreadyRead
        case needsModel
    }

    /// Reads every routed, pending message: the ones extraction is not for (newsletters, the
    /// student's own mail, outside the sync window, Sent) and those without any date or cue word
    /// are marked skipped without a call; the rest go to Haiku when `useModel`, at most
    /// `concurrency` at a time, each only while `allowCall()` says so.
    @discardableResult
    public func extractPending(
        useModel: Bool = true,
        concurrency: Int = MailExtractor.defaultConcurrency,
        allowCall: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> Report {
        var report = Report()
        let database = services.database
        let ids = try await database.read { db in
            try MailMessage
                .where { $0.category.isNot(nil) && $0.extractionState.eq(MailExtractionState.pending) }
                .order(by: \.receivedAt)
                .select(\.id)
                .fetchAll(db)
        }
        guard !ids.isEmpty else { return report }
        let mailboxes = try await MailboxDirectory.load(database)

        var forModel: [MailMessage] = []
        for page in ids.chunked(200) {
            let messages = try await database.read { db in
                try MailMessage.where { $0.id.in(Array(page)) }.order(by: \.receivedAt).fetchAll(db)
            }
            for message in messages {
                switch try await decide(message, mailboxes: mailboxes) {
                case .skip:
                    try await repository.recordExtraction(message.id, .skipped, at: now())
                    report.skipped += 1
                case .alreadyRead:
                    try await repository.recordExtraction(message.id, .done, at: now())
                    report.done += 1
                case .needsModel:
                    forModel.append(message)
                }
            }
        }
        guard useModel, let client, !forModel.isEmpty else {
            report.waiting = forModel.count
            return report
        }

        let courses = try await CourseDirectory.load(database)
        var queue = forModel[...]
        var stopped = false
        try await withThrowingTaskGroup(of: (Outcome, Applied).self) { group in
            func launch() async -> Bool {
                guard !stopped, let message = queue.popFirst() else { return false }
                guard await allowCall() else {
                    stopped = true
                    queue.insert(message, at: queue.startIndex)
                    return false
                }
                report.calls += 1
                group.addTask { await self.extract(message, client: client, courses: courses) }
                return true
            }
            for _ in 0..<max(1, concurrency) {
                guard await launch() else { break }
            }
            while let (outcome, applied) = try await group.next() {
                switch outcome {
                case .done: report.done += 1
                case .failed: report.failed += 1
                case .waiting:
                    report.waiting += 1
                    stopped = true
                }
                report.itemsCreated += applied.itemsCreated
                report.sourcesAdded += applied.sourcesAdded
                report.rejected += applied.rejected
                _ = await launch()
            }
        }
        report.waiting += queue.count
        return report
    }

    /// Whether `message` needs the model.
    func decide(_ message: MailMessage, mailboxes: MailboxDirectory) async throws -> Decision {
        guard let category = message.category, [.course, .university, .personal].contains(category) else { return .skip }
        guard let role = mailboxes.role(of: message), role == .inbox || role == .archive else { return .skip }
        guard !mailboxes.isOwn(message) else { return .skip }
        let account = mailboxes.accounts[message.accountID]
        let windowStart = account?.syncSince?.start(in: timeZone)
            ?? now().addingTimeInterval(-Double(Self.defaultWindowDays) * 86_400)
        guard message.receivedAt >= windowStart else { return .skip }
        if !message.rfcMessageID.isEmpty {
            let rfcID = message.rfcMessageID
            let messageID = message.id
            let readCopy = try await services.database.read { db in
                try MailMessage
                    .where { $0.rfcMessageID.eq(rfcID) && $0.id.neq(messageID) && $0.extractionState.eq(MailExtractionState.done) }
                    .fetchCount(db)
            }
            if readCopy > 0 { return .alreadyRead }
        }
        let reference = message.sentAt ?? message.receivedAt
        guard CuePrefilter.hasCue(subject: message.subject, body: message.bodyText, reference: reference) else { return .skip }
        return .needsModel
    }

    enum Outcome: Sendable { case done, failed, waiting }

    /// One call and its validated write. Service trouble (no key, rate limits, outages) leaves the
    /// message pending without counting an attempt; anything else counts a failed attempt.
    func extract(_ message: MailMessage, client: ClaudeClient, courses: CourseDirectory) async -> (Outcome, Applied) {
        let caller = ModelCaller(client: client, database: services.database)
        let request = ExtractionPrompt.request(message: message, courses: courses, now: now())
        do {
            let answer = try await caller.structured(ExtractionPrompt.Answer.self, request, purpose: MailIntelligence.Purpose.extract)
            let applied = try await apply(answer.value, to: message, courses: courses, apiCallID: answer.apiCallID)
            return (.done, applied)
        } catch let failure as CallFailure {
            MailIntelligence.log.error("Extraction answer unusable: \(failure.description, privacy: .public)")
            _ = try? await repository.recordExtraction(message.id, .failed, apiCallID: failure.apiCallID, at: now())
            return (.failed, Applied())
        } catch let error as ClaudeError where Self.isServiceTrouble(error) {
            MailIntelligence.log.notice("Extraction waits: \(error.description, privacy: .public)")
            return (.waiting, Applied())
        } catch is CancellationError {
            return (.waiting, Applied())
        } catch {
            MailIntelligence.log.error("Extraction failed: \(String(describing: error), privacy: .public)")
            _ = try? await repository.recordExtraction(message.id, .failed, at: now())
            return (.failed, Applied())
        }
    }

    static func isServiceTrouble(_ error: ClaudeError) -> Bool {
        error.isServiceTrouble
    }

    // MARK: - Validation

    /// An item that passed validation, before deduplication.
    struct Candidate: Sendable {
        var kind: TrackedItemKind
        var title: String
        /// At most 12 words on why it matters, or "".
        var details = ""
        var relevance: ItemRelevance?
        var courseID: Course.ID?
        var due: Date?
        var allDay: Bool
        /// `DateMentions` found the due day (and time) in the quote.
        var verified: Bool
        var quote: String
        var confidence: Double
        var room: String?
        var mentions: DateMentions
        /// False for every item of a mail that talks to the model: nothing from it goes into the
        /// calendar on its own.
        var trusted = true
    }

    /// The model's items that survive the checks, and how many were rejected.
    func candidates(from answer: ExtractionPrompt.Answer, message: MailMessage, courses: CourseDirectory) -> ([Candidate], Int) {
        let reference = message.sentAt ?? message.receivedAt
        let hostile = InjectionGuard.hostileParagraphs(subject: message.subject, body: message.bodyText)
        var accepted: [Candidate] = []
        var rejected = 0
        for item in answer.items {
            let kind = TrackedItemKind(rawValue: item.kind.trimmingCharacters(in: .whitespaces).lowercased())
            let known: Set<TrackedItemKind> = [.deadline, .exercise, .exam, .event, .roomChange, .cancellation, .announcement]
            let confidence = min(max(item.confidence.isFinite ? item.confidence : 0, 0), 1)
            let title = String(item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            guard known.contains(kind), confidence >= ExtractionPrompt.minimumConfidence, !title.isEmpty else {
                rejected += 1
                continue
            }
            guard let quote = QuoteVerifier.verify(item.quote, subject: message.subject, body: message.bodyText) else {
                MailIntelligence.log.notice("Rejected an extracted item whose quote is not in the mail")
                rejected += 1
                continue
            }
            guard !InjectionGuard.isHostile(quote, paragraphs: hostile) else {
                MailIntelligence.log.notice("Rejected an extracted item quoting instructions in a mail")
                rejected += 1
                continue
            }
            let courseID = message.courseID ?? courses.course(token: item.course)?.id
            let mentions = DateMentions.parse(quote, reference: reference, timeZone: timeZone)
            var due = Self.parseDue(item.due, allDay: item.allDay, timeZone: timeZone)
            var verified = false
            if let parsed = due {
                switch mentions.verdict(for: parsed.date, allDay: parsed.allDay, timeZone: timeZone) {
                case .confirmed(let withTime):
                    verified = true
                    // A time the quote does not state is not kept: the item is due that day.
                    if !withTime, !parsed.allDay {
                        due = (CalendarDay(parsed.date, in: timeZone).start(in: timeZone), true)
                    }
                case .unconfirmed:
                    break
                }
            }
            var finalKind = kind
            if due == nil, kind != .announcement { finalKind = .announcement }
            let room = item.room?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            accepted.append(Candidate(
                kind: finalKind, title: title, details: ExtractionPrompt.details(item.details),
                relevance: ExtractionPrompt.relevance(item.relevance), courseID: courseID, due: due?.date,
                allDay: due?.allDay ?? false, verified: verified, quote: quote, confidence: confidence, room: room,
                mentions: mentions, trusted: hostile.isEmpty
            ))
        }
        return (accepted, rejected)
    }

    /// "2026-10-29T23:59" (local) or "2026-10-29" (all day).
    static func parseDue(_ text: String?, allDay: Bool, timeZone: TimeZone) -> (date: Date, allDay: Bool)? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), let day = CalendarDay(rawValue: text) else { return nil }
        let rest = text.dropFirst(10).drop { $0 == "T" || $0 == " " || $0 == "t" }
        let parts = rest.split(separator: ":")
        if !allDay, parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1].prefix(2)),
           (0...24).contains(hour), (0..<60).contains(minute) {
            return (day.date(minute: hour * 60 + minute, in: timeZone), false)
        }
        return (day.start(in: timeZone), true)
    }

    // MARK: - Writing

    /// Validates `answer` and writes its items, their sources and the message's `done` state in
    /// one transaction.
    func apply(
        _ answer: ExtractionPrompt.Answer,
        to message: MailMessage,
        courses: CourseDirectory,
        apiCallID: APICall.ID?
    ) async throws -> Applied {
        let (candidates, rejected) = candidates(from: answer, message: message, courses: courses)
        let store = services.records
        let timeZone = timeZone
        let date = now()
        var applied = try await services.database.write { db -> Applied in
            var applied = Applied()
            var writer = ItemWriter(db: db, store: store, message: message, apiCallID: apiCallID, timeZone: timeZone, date: date)
            for candidate in candidates {
                let result = try writer.write(candidate)
                applied.itemsCreated += result.created ? 1 : 0
                applied.sourcesAdded += result.sourceAdded ? 1 : 0
            }
            let stamp = store.currentDate
            try MailMessage.find(message.id).update {
                $0.extractionState = MailExtractionState.done
                $0.extractedAt = Date?.some(date)
                $0.extractionAPICallID = apiCallID
                $0.updatedAt = stamp
            }
            .execute(db)
            return applied
        }
        applied.rejected = rejected
        return applied
    }
}

/// Writes the candidates of one message inside MailExtractor's transaction, through the deadline
/// memory (`Deadlines.DeadlineMemory`, the one write path for tracked items): session proposals,
/// deduplication across mail, transcripts and chat, the calendar rule and the source rows live
/// there. This adapter only turns a validated candidate into an `ItemFinding`.
struct ItemWriter {
    let db: Database
    let store: RecordStore
    let message: MailMessage
    let apiCallID: APICall.ID?
    let timeZone: TimeZone
    /// When the extraction ran (`created_at` of new items and sources; the digest's "added").
    let date: Date

    struct Result {
        var created = false
        var sourceAdded = false
    }

    mutating func write(_ candidate: MailExtractor.Candidate) throws -> Result {
        let finding = ItemFinding(
            draft: DeadlineDraft(
                kind: candidate.kind, title: candidate.title, details: candidate.details, courseID: candidate.courseID,
                dueAt: candidate.due, isAllDay: candidate.allDay, relevance: candidate.relevance, room: candidate.room
            ),
            source: .mail(message.id, rfcMessageID: message.rfcMessageID),
            quote: candidate.quote,
            confidence: candidate.confidence,
            dateVerified: candidate.verified,
            trusted: candidate.trusted,
            createdBy: .agent,
            apiCallID: apiCallID,
            mentions: candidate.mentions
        )
        let result = try DeadlineMemory.record(finding, in: db, store: store, now: date)
        return Result(created: result.created, sourceAdded: result.source != nil)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
