import ClaudeKit
import Deadlines
import Foundation
import GRDB
import StudyCore

/// Mail triage (PRD #31/#32, M3.5 addition): reads routed mail for deadlines, exercises,
/// exams, events, room changes, cancellations, announcements and tasks (`tracked_item` rows with
/// `tracked_item_source` provenance), and decides whether each mail needs a reply from the
/// student (`mail_message.needs_reply`).
///
/// What it reads: every new routed message (`extraction_state` pending), and once the last 30
/// days, newest first: routed rows of that window whose `needs_reply` is still NULL (mail read
/// before triage existed). NULL is the resume point, so the backlog continues by itself after a
/// quit and waits while the backend pauses. Mail extraction never reads (newsletters, other
/// categories, the student's own mail, Sent, older than the window) gets `needs_reply = false`
/// without a call. Haiku 5.5, effort medium, `.background`, up to 6 mails and 24,000 characters
/// of envelopes per call, one answer per envelope id.
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
/// 5. an item quoting a paragraph that talks to the model is dropped, and nothing from such a mail
///    goes into the calendar on its own (`InjectionGuard`);
/// 6. `needs_reply` is false for mailing-list and bulk mail whatever the model says;
/// 7. a message's items, sources, extraction state and `needs_reply` are written in one transaction.
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
        /// Messages left pending (no backend, cost guard, service trouble).
        public var waiting = 0
        /// Messages found to need a reply.
        public var needsReply = 0
        /// Backlog messages left for the next pass (each pass reads at most `backlogPerPass`).
        public var backlogLeft = 0

        public init() {}
    }

    /// What applying one mail's answer wrote.
    struct Applied: Sendable, Equatable {
        var itemsCreated = 0
        var sourcesAdded = 0
        var rejected = 0
        var needsReply = false
    }

    /// Default number of triage calls in flight (the Claude Code engine runs one process at a time
    /// and queues the rest).
    public static let defaultConcurrency = 2
    /// Mail older than this many days (when the account has no `sync_since`) is not read; the
    /// backlog is this window.
    static let defaultWindowDays = 30
    /// Backlog messages one pass reads, so new mail is routed between backlog stretches.
    public static let backlogPerPass = 24

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
        /// A copy of this message (same Message-ID) was already triaged: its answer.
        case alreadyRead(needsReply: Bool)
        case needsModel
    }

    /// Triages new mail and up to `backlogPerPass` backlog messages, newest first. Messages
    /// triage is not for get `needs_reply = false` (and `skipped`) without a call; the rest go to
    /// Haiku in batches when `useModel`, at most `concurrency` calls at a time, each only while
    /// `allowCall()` says so.
    @discardableResult
    public func extractPending(
        useModel: Bool = true,
        concurrency: Int = MailExtractor.defaultConcurrency,
        backlogPerPass: Int = MailExtractor.backlogPerPass,
        allowCall: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> Report {
        var report = Report()
        let database = services.database
        let backlogStart = now().addingTimeInterval(-Double(Self.defaultWindowDays) * 86_400)
        let pending = MailExtractionState.pending
        let failed = MailExtractionState.failed
        let candidates = try await database.read { db in
            try MailMessage
                .where {
                    $0.category.isNot(nil) && $0.needsReply.is(nil) && $0.extractionState.neq(failed)
                        && ($0.extractionState.eq(pending) || $0.receivedAt.gte(backlogStart))
                }
                .order { $0.receivedAt.desc() }
                .select { ($0.id, $0.extractionState) }
                .fetchAll(db)
        }
        guard !candidates.isEmpty else { return report }
        // New mail always; backlog rows (read before triage existed) a stretch at a time.
        var ids: [MailMessage.ID] = []
        var backlog = 0
        for (id, state) in candidates {
            if state == pending {
                ids.append(id)
            } else if backlog < backlogPerPass {
                ids.append(id)
                backlog += 1
            } else {
                report.backlogLeft += 1
            }
        }
        let mailboxes = try await MailboxDirectory.load(database)

        var forModel: [MailMessage] = []
        for page in ids.chunked(200) {
            let messages = try await database.read { db in
                try MailMessage.where { $0.id.in(Array(page)) }.order { $0.receivedAt.desc() }.fetchAll(db)
            }
            for message in messages {
                switch try await decide(message, mailboxes: mailboxes) {
                case .skip:
                    try await markTriaged(message, state: .skipped, needsReply: false)
                    report.skipped += 1
                case .alreadyRead(let needsReply):
                    try await markTriaged(message, state: .done, needsReply: needsReply)
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
        var queue = Self.batches(forModel, courses: courses)[...]
        var stopped = false
        try await withThrowingTaskGroup(of: [(Outcome, Applied)].self) { group in
            func launch() async -> Bool {
                guard !stopped, let batch = queue.popFirst() else { return false }
                guard await allowCall() else {
                    stopped = true
                    queue.insert(batch, at: queue.startIndex)
                    return false
                }
                report.calls += 1
                group.addTask { await self.triage(batch, client: client, courses: courses) }
                return true
            }
            for _ in 0..<max(1, concurrency) {
                guard await launch() else { break }
            }
            while let outcomes = try await group.next() {
                for (outcome, applied) in outcomes {
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
                    report.needsReply += applied.needsReply ? 1 : 0
                }
                _ = await launch()
            }
        }
        report.waiting += queue.reduce(0) { $0 + $1.messages.count }
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
            let copy = try await services.database.read { db in
                try MailMessage
                    .where {
                        $0.rfcMessageID.eq(rfcID) && $0.id.neq(messageID) && $0.extractionState.eq(MailExtractionState.done)
                            && $0.needsReply.isNot(nil)
                    }
                    .select(\.needsReply)
                    .fetchOne(db)
            }
            if let copy { return .alreadyRead(needsReply: copy ?? false) }
        }
        return .needsModel
    }

    /// One call's mails: envelopes with ids "m1"… in order.
    struct Batch: Sendable {
        var messages: [MailMessage]
        var envelopes: [String]
    }

    /// Groups messages into calls of at most `ExtractionPrompt.batchSize` mails and
    /// `ExtractionPrompt.batchCharacters` characters of envelopes, in order.
    static func batches(_ messages: [MailMessage], courses: CourseDirectory) -> [Batch] {
        var batches: [Batch] = []
        var current = Batch(messages: [], envelopes: [])
        var characters = 0
        for message in messages {
            var envelope = ExtractionPrompt.envelope(message, id: "m\(current.messages.count + 1)", courses: courses)
            if !current.messages.isEmpty,
               current.messages.count >= ExtractionPrompt.batchSize || characters + envelope.count > ExtractionPrompt.batchCharacters {
                batches.append(current)
                current = Batch(messages: [], envelopes: [])
                characters = 0
                envelope = ExtractionPrompt.envelope(message, id: "m1", courses: courses)
            }
            current.messages.append(message)
            current.envelopes.append(envelope)
            characters += envelope.count
        }
        if !current.messages.isEmpty { batches.append(current) }
        return batches
    }

    enum Outcome: Sendable { case done, failed, waiting }

    /// One call and the validated writes of its mails. Service trouble (no backend, usage limits,
    /// outages) leaves the mails pending without counting an attempt; a mail the answer leaves out,
    /// or an unusable answer, counts a failed attempt.
    func triage(_ batch: Batch, client: ClaudeClient, courses: CourseDirectory) async -> [(Outcome, Applied)] {
        let caller = ModelCaller(client: client, database: services.database)
        let request = ExtractionPrompt.request(envelopes: batch.envelopes, courses: courses, now: now())
        let answer: ModelCaller.Answer<ExtractionPrompt.Answer>
        do {
            answer = try await caller.structured(ExtractionPrompt.Answer.self, request, purpose: MailIntelligence.Purpose.extract)
        } catch let failure as CallFailure {
            MailIntelligence.log.error("Triage answer unusable: \(failure.description, privacy: .public)")
            return await failAll(batch, apiCallID: failure.apiCallID)
        } catch let error as ClaudeError where error.isServiceTrouble {
            MailIntelligence.log.notice("Triage waits: \(error.description, privacy: .public)")
            return batch.messages.map { _ in (.waiting, Applied()) }
        } catch is CancellationError {
            return batch.messages.map { _ in (.waiting, Applied()) }
        } catch {
            MailIntelligence.log.error("Triage failed: \(String(describing: error), privacy: .public)")
            return await failAll(batch, apiCallID: nil)
        }
        var byID: [String: ExtractionPrompt.MailAnswer] = [:]
        for mail in answer.value.mails {
            let id = mail.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if byID[id] == nil { byID[id] = mail }
        }
        var outcomes: [(Outcome, Applied)] = []
        for (index, message) in batch.messages.enumerated() {
            guard let mail = byID["m\(index + 1)"] else {
                MailIntelligence.log.notice("Triage answer left a mail out")
                _ = try? await repository.recordExtraction(message.id, .failed, apiCallID: answer.apiCallID, at: now())
                outcomes.append((.failed, Applied()))
                continue
            }
            do {
                let applied = try await apply(mail, to: message, courses: courses, apiCallID: answer.apiCallID)
                outcomes.append((.done, applied))
            } catch {
                MailIntelligence.log.error("Writing a triaged mail failed: \(String(describing: error), privacy: .public)")
                _ = try? await repository.recordExtraction(message.id, .failed, apiCallID: answer.apiCallID, at: now())
                outcomes.append((.failed, Applied()))
            }
        }
        return outcomes
    }

    private func failAll(_ batch: Batch, apiCallID: APICall.ID?) async -> [(Outcome, Applied)] {
        var outcomes: [(Outcome, Applied)] = []
        for message in batch.messages {
            _ = try? await repository.recordExtraction(message.id, .failed, apiCallID: apiCallID, at: now())
            outcomes.append((.failed, Applied()))
        }
        return outcomes
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
    func candidates(from items: [ExtractionPrompt.Item], message: MailMessage, courses: CourseDirectory) -> ([Candidate], Int) {
        let reference = message.sentAt ?? message.receivedAt
        let hostile = InjectionGuard.hostileParagraphs(subject: message.subject, body: message.bodyText)
        var accepted: [Candidate] = []
        var rejected = 0
        for item in items {
            let kind = TrackedItemKind(rawValue: item.kind.trimmingCharacters(in: .whitespaces).lowercased())
            // ma: room changes and cancellations come as `sessions` (applied with Undo), never items.
            let known: Set<TrackedItemKind> = [.deadline, .exercise, .exam, .event, .announcement, .task]
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
            // A task with a date is a deadline; anything else without one is an announcement.
            if kind == .task, due != nil { finalKind = .deadline }
            if due == nil, kind != .announcement, kind != .task { finalKind = .announcement }
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

    /// Mail sent to a list or in bulk never needs a personal reply, whatever the model says.
    static func needsReply(_ answer: Bool, message: MailMessage) -> Bool {
        guard answer, message.listID.isEmpty else { return false }
        let precedence = message.headers["precedence"]?.lowercased() ?? ""
        if ["bulk", "list", "junk"].contains(where: precedence.contains) { return false }
        let autoSubmitted = message.headers["auto-submitted"]?.lowercased() ?? ""
        if !autoSubmitted.isEmpty, autoSubmitted != "no" { return false }
        return true
    }

    // MARK: - Writing

    /// Validates one mail's answer and writes its items, their sources, the message's `done`
    /// state and `needs_reply` in one transaction. A backlog mail that was already extracted
    /// (`done` before triage existed) keeps its items: only tasks, which that extraction did not
    /// look for, are added (an undated item quoted slightly differently would be a duplicate).
    func apply(
        _ answer: ExtractionPrompt.MailAnswer,
        to message: MailMessage,
        courses: CourseDirectory,
        apiCallID: APICall.ID?
    ) async throws -> Applied {
        var items = answer.items
        if message.extractionState == .done {
            items = items.filter { TrackedItemKind(rawValue: $0.kind.trimmingCharacters(in: .whitespaces).lowercased()) == .task }
        }
        let (candidates, rejected) = candidates(from: items, message: message, courses: courses)
        let needsReply = Self.needsReply(answer.needsReply, message: message)
        // ma: session changes, course facts and escalation go to the app agent's triage as a
        // decided `mail` event (no second call per mail); its change log applies them with Undo.
        let decision = factDecision(answer, message: message, courses: courses, apiCallID: apiCallID)
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
            if let decision, let detail = decision.detail() {
                let key = "mail:" + (message.rfcMessageID.isEmpty ? message.id.uuidString.lowercased() : message.rfcMessageID)
                    + ":\(message.parseVersion)"
                if try AgentEvent.where({ $0.sourceKey.eq(key) }).fetchCount(db) == 0 {
                    let event = store.stamp(AgentEvent(
                        kind: .mail, sourceKey: key, courseID: message.courseID, mailMessageID: message.id, detail: detail,
                        apiCallID: apiCallID, createdAt: date
                    ))
                    try AgentEvent.upsert { event }.execute(db)
                }
            }
            let stamp = store.currentDate
            try MailMessage.find(message.id).update {
                $0.extractionState = MailExtractionState.done
                $0.extractedAt = Date?.some(date)
                $0.extractionAPICallID = apiCallID
                $0.needsReply = Bool?.some(needsReply)
                $0.updatedAt = stamp
            }
            .execute(db)
            return applied
        }
        applied.rejected = rejected
        applied.needsReply = needsReply
        return applied
    }

    /// ma: the answer's session changes and course facts as the app agent's triage applies them
    /// (each quote an exact span of the mail outside text that talks to the model, confidence ≥
    /// 0.5), and its escalation; nil when there is nothing. Dates are checked when applied
    /// (`DateMentions` against the quote, relative to when the mail was written).
    func factDecision(
        _ answer: ExtractionPrompt.MailAnswer, message: MailMessage, courses: CourseDirectory, apiCallID: APICall.ID?
    ) -> FactDecision? {
        let hostile = InjectionGuard.hostileParagraphs(subject: message.subject, body: message.bodyText)
        func verified(_ quote: String, _ confidence: Double) -> (String, Double)? {
            let confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
            guard confidence >= ExtractionPrompt.minimumConfidence,
                  let span = QuoteVerifier.verify(quote, subject: message.subject, body: message.bodyText),
                  !InjectionGuard.isHostile(span, paragraphs: hostile)
            else { return nil }
            return (span, confidence)
        }
        func course(_ token: String?) -> String? {
            (courses.course(token: token)?.id ?? message.courseID)?.uuidString.lowercased()
        }
        var actions: [FactAction] = []
        for change in answer.sessions {
            let kind: AgentChangeKind
            switch change.change.trimmingCharacters(in: .whitespaces).lowercased() {
            case "room": kind = .sessionRoom
            case "time": kind = .sessionTime
            case "cancel": kind = .sessionCancel
            case "restore": kind = .sessionRestore
            case "extra": kind = .sessionExtra
            default: continue
            }
            guard let (quote, confidence) = verified(change.quote, change.confidence) else { continue }
            actions.append(FactAction(
                kind: kind.rawValue, course: course(change.course), sessionDay: change.sessionDay, sessionKind: change.sessionKind,
                startsAt: change.startsAt, endsAt: change.endsAt, room: change.room?.trimmingCharacters(in: .whitespacesAndNewlines),
                quote: quote, confidence: confidence
            ))
        }
        for fact in answer.facts where ExtractionPrompt.facts.contains(fact.fact) {
            guard let (quote, confidence) = verified(fact.quote, fact.confidence) else { continue }
            actions.append(FactAction(
                kind: AgentChangeKind.courseFact.rawValue, course: course(fact.course), fact: fact.fact,
                text: String(fact.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), quote: quote, confidence: confidence
            ))
        }
        guard !actions.isEmpty || answer.escalate else { return nil }
        return FactDecision(
            actions: actions, escalate: answer.escalate || !hostile.isEmpty && !actions.isEmpty,
            reason: String(answer.reason.prefix(200)) + (hostile.isEmpty ? "" : " The mail has text that talks to a model."),
            model: ExtractionPrompt.model.rawValue, apiCallID: apiCallID
        )
    }

    /// A message triaged without a call: `needs_reply`, and the extraction state when it was
    /// still pending (a backlog row keeps the state its first read gave it).
    func markTriaged(_ message: MailMessage, state: MailExtractionState, needsReply: Bool) async throws {
        let store = services.records
        let date = now()
        try await services.database.write { db in
            let stamp = store.currentDate
            if message.extractionState == .pending {
                try MailMessage.find(message.id).update {
                    $0.extractionState = state
                    $0.extractedAt = Date?.some(date)
                    $0.needsReply = Bool?.some(needsReply)
                    $0.updatedAt = stamp
                }
                .execute(db)
            } else {
                try MailMessage.find(message.id).update {
                    $0.needsReply = Bool?.some(needsReply)
                    $0.updatedAt = stamp
                }
                .execute(db)
            }
        }
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
        // ma: every automatic change is in the activity log.
        if let change = ItemChangeRows.change(for: result, finding: finding, model: ExtractionPrompt.model.rawValue, now: date) {
            try AgentChangeRepository.insert(store.stamp(change), db: db)
        }
        return Result(created: result.created, sourceAdded: result.source != nil)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
