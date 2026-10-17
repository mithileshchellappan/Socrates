import ClaudeKit
import Foundation
import Search
import StudyCore
import Synchronization

/// Reply drafts (PRD #34): the agent writes, the student edits and presses Send.
///
/// `draftReply(to:)` creates the `mail_draft` row at once (`generating`; To = Reply-To ?? From;
/// "Re: " without stacking; In-Reply-To and References; the course) and returns its id; Opus 5.5
/// (effort medium, adaptive thinking, **no tools**) streams the text into the row through
/// `MailDraftRepository.streamGenerated` about ten times a second, so the student's edits win
/// (`body` stops following `generated_body` once they differ). Then `generating → draft`; an
/// error keeps what came and sets `error`. Nothing here can send: there is no send path.
public actor ReplyDrafter {
    public enum DraftError: Error, Sendable {
        case messageNotFound
        case accountNotFound
    }

    /// Opus output cap per draft. It covers adaptive thinking as well as the reply.
    public static let maxTokens = 4_096
    /// Thread messages given to the model (the replied-to one and up to three before it).
    public static let threadLimit = 4

    let services: StudyServices
    let client: ClaudeClient?
    let now: @Sendable () -> Date
    let writeInterval: Duration
    private var running: [MailDraft.ID: Running] = [:]

    private struct Running {
        var stream: Task<StreamOutcome, Never>
        var finisher: Task<Void, Never>
    }

    /// What a stream ended with.
    struct StreamOutcome: Sendable {
        var text: String
        var error: String?
        var apiCallID: APICall.ID?
    }

    public init(
        services: StudyServices,
        client: ClaudeClient?,
        writeInterval: Duration = .milliseconds(100),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.client = client
        self.writeInterval = writeInterval
        self.now = now
    }

    var drafts: MailDraftRepository { MailDraftRepository(store: services.records) }

    // MARK: - Drafting

    /// The open reply to `id` (a new one, streaming, when there is none) — returns at once.
    /// Without a client or an API key the draft is empty and editable (the student writes it).
    public func draftReply(to id: MailMessage.ID) async throws -> MailDraft.ID {
        if let open = try await drafts.openDraft(replyingTo: id) { return open.id }
        let records = services.records
        guard let message = try await records.fetch(MailMessage.self, id: id) else { throw DraftError.messageNotFound }
        guard let account = try await records.fetch(MailAccount.self, id: message.accountID) else { throw DraftError.accountNotFound }
        let mailboxes = try await MailboxDirectory.load(services.database)

        let canDraft = client != nil && services.secrets.hasSecret(for: .anthropicAPIKey)
        let draft = try await records.save(MailDraft(
            accountID: account.id,
            mailMessageID: message.id,
            inReplyTo: message.rfcMessageID,
            referenceIDs: Self.references(of: message),
            to: Self.recipients(of: message, own: mailboxes.isOwn(message)),
            subject: Self.replySubject(message.subject),
            body: "",
            generatedBody: canDraft ? "" : nil,
            courseID: message.courseID,
            state: canDraft ? .generating : .draft,
            createdAt: now()
        ))
        guard canDraft, let client else { return draft.id }
        let request = try await makeRequest(replyingTo: message, account: account, mailboxes: mailboxes)
        start(draft.id, request: request, client: client)
        return draft.id
    }

    /// Stops the agent (the student started typing, or pressed Stop): what came so far stays and
    /// the draft becomes editable. Returns when the draft is settled.
    public func stop(_ draftID: MailDraft.ID) async {
        guard let entry = running[draftID] else { return }
        entry.stream.cancel()
        await entry.finisher.value
    }

    /// Waits until the draft's stream has ended and the row is settled (tests; quitting).
    public func waitUntilSettled(_ draftID: MailDraft.ID) async {
        await running[draftID]?.finisher.value
    }

    /// Launch: drafts left `generating` by a quit or crash become editable drafts.
    @discardableResult
    public func recoverInterrupted() async throws -> Int {
        var recovered = 0
        for draft in try await drafts.drafts(in: [.generating]) where running[draft.id] == nil {
            if try await drafts.transition(draft.id, from: [.generating], to: .draft) != nil { recovered += 1 }
        }
        return recovered
    }

    private func start(_ draftID: MailDraft.ID, request: MessageRequest, client: ClaudeClient) {
        let repository = drafts
        let database = services.database
        let interval = writeInterval
        let stream = Task { () -> StreamOutcome in
            await Self.stream(request, draftID: draftID, client: client, repository: repository, database: database, interval: interval)
        }
        let finisher = Task { [weak self] in
            let outcome = await stream.value
            await self?.finish(draftID, outcome)
        }
        running[draftID] = Running(stream: stream, finisher: finisher)
    }

    private func finish(_ draftID: MailDraft.ID, _ outcome: StreamOutcome) async {
        do {
            try await drafts.streamGenerated(draftID, text: outcome.text)
            try await drafts.transition(draftID, from: [.generating], to: .draft) { draft in
                draft.apiCallID = outcome.apiCallID
                draft.error = outcome.error
            }
        } catch {
            MailIntelligence.log.error("Could not settle a draft: \(String(describing: error), privacy: .public)")
        }
        running[draftID] = nil
    }

    /// Streams the reply; writes the text so far at most every `interval`. Never throws: an error
    /// is part of the outcome.
    static func stream(
        _ request: MessageRequest,
        draftID: MailDraft.ID,
        client: ClaudeClient,
        repository: MailDraftRepository,
        database: any DatabaseReader,
        interval: Duration
    ) async -> StreamOutcome {
        let state = StreamBuffer()
        let clock = ContinuousClock()
        do {
            let message = try await client.streamMessage(request, context: CallContext(purpose: MailIntelligence.Purpose.draft)) { event in
                guard case .contentBlockDelta(_, .text(let delta)) = event else { return }
                let snapshot: String? = state.lock.withLock { state in
                    state.text += delta
                    let now = clock.now
                    if let last = state.lastWrite, now - last < interval { return nil }
                    state.lastWrite = now
                    return state.text
                }
                if let snapshot { _ = try? await repository.streamGenerated(draftID, text: snapshot) }
            }
            let callID = try? await APICallLink.callID(requestID: message.requestID, purpose: MailIntelligence.Purpose.draft, in: database)
            switch message.stopReason {
            case .refusal?:
                // Partial output of a declined request is discarded.
                return StreamOutcome(text: "", error: "Not drafted", apiCallID: callID)
            case .maxTokens?, .modelContextWindowExceeded?:
                return StreamOutcome(text: Self.clean(message.text), error: "Draft cut short", apiCallID: callID)
            default:
                return StreamOutcome(text: Self.clean(message.text), error: nil, apiCallID: callID)
            }
        } catch is CancellationError {
            return StreamOutcome(text: Self.clean(state.lock.withLock { $0.text }), error: nil)
        } catch {
            MailIntelligence.log.error("Drafting failed: \(String(describing: error), privacy: .public)")
            let partial = state.lock.withLock { $0.text }
            return StreamOutcome(text: Self.clean(partial), error: "Drafting stopped")
        }
    }

    struct StreamState {
        var text = ""
        var lastWrite: ContinuousClock.Instant?
    }

    /// The text streamed so far, shared with the stream's event callback.
    final class StreamBuffer: Sendable {
        let lock = Mutex(StreamState())
    }

    /// Trims the reply and drops a subject line the model may have added anyway.
    static func clean(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first?.lowercased(), first.hasPrefix("subject:") || first.hasPrefix("betreff:") {
            lines.removeFirst()
            while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Headers

    /// "Re: " + the subject without its reply prefixes ("Re:", "AW:", "Aw:", "Re[2]:", …).
    static func replySubject(_ subject: String) -> String {
        var rest = Substring(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        while true {
            let lowered = rest.lowercased()
            var matched = false
            for prefix in ["re", "aw", "antw", "sv", "vs"] where lowered.hasPrefix(prefix) {
                var cursor = rest.index(rest.startIndex, offsetBy: prefix.count)
                if cursor < rest.endIndex, rest[cursor] == "[" || rest[cursor] == "(" {
                    guard let close = rest[cursor...].firstIndex(where: { $0 == "]" || $0 == ")" }) else { break }
                    cursor = rest.index(after: close)
                }
                while cursor < rest.endIndex, rest[cursor] == " " { cursor = rest.index(after: cursor) }
                guard cursor < rest.endIndex, rest[cursor] == ":" else { continue }
                rest = rest[rest.index(after: cursor)...].drop { $0 == " " }
                matched = true
                break
            }
            if !matched { break }
        }
        return "Re: " + rest
    }

    /// Reply-To when the mail has one, else From; for the student's own mail, its recipients.
    static func recipients(of message: MailMessage, own: Bool) -> [MailAddress] {
        if own { return message.to }
        if !message.replyTo.isEmpty { return message.replyTo }
        return message.fromAddress.isEmpty ? [] : [message.from]
    }

    /// References of the reply: the mail's own references and its Message-ID (at most 20).
    static func references(of message: MailMessage) -> [String] {
        var ids: [String] = []
        for id in message.referenceIDs + [message.rfcMessageID] where !id.isEmpty && !ids.contains(id) {
            ids.append(id)
        }
        return Array(ids.suffix(20))
    }

    // MARK: - Prompt

    func makeRequest(replyingTo message: MailMessage, account: MailAccount, mailboxes: MailboxDirectory) async throws -> MessageRequest {
        let threadID = message.threadID
        let received = message.receivedAt
        let messageID = message.id
        let (thread, course) = try await services.database.read { db -> ([MailMessage], Course?) in
            var thread: [MailMessage] = []
            if !threadID.isEmpty {
                thread = try MailMessage
                    .where { $0.threadID.eq(threadID) && $0.receivedAt.lte(received) && $0.id.neq(messageID) }
                    .order { $0.receivedAt.desc() }
                    .limit(12)
                    .fetchAll(db)
            }
            let course = try message.courseID.flatMap { try Course.find($0).fetchOne(db) }
            return (thread, course)
        }
        var earlier: [MailMessage] = []
        var seen: Set<String> = [message.rfcMessageID]
        for candidate in thread where earlier.count < Self.threadLimit - 1 {
            guard candidate.rfcMessageID.isEmpty || seen.insert(candidate.rfcMessageID).inserted else { continue }
            earlier.append(candidate)
        }
        let ordered = earlier.reversed() + [message]
        let envelopes = ordered.enumerated().map { index, item in
            MailEnvelope.render(
                item, id: "m\(index + 1)", budget: MailEnvelope.Budget.drafting,
                extraAttributes: mailboxes.isOwn(item) ? ["written_by": "the student"] : [:]
            )
        }
        let language = Self.language(of: message)
        let system = Self.system(account: account, course: course, language: language, register: Self.register(of: message, language: language))
        let text = envelopes.joined(separator: "\n\n")
            + "\n\nDraft the student's reply to the last message (id=\"m\(ordered.count)\")."
        return MessageRequest(
            model: .opus55, maxTokens: Self.maxTokens, effort: .medium,
            messages: [.user(text)],
            system: MessageRequest.systemPrompt(system)
        )
    }

    /// "de" or "en": the mail's detected language, else a guess from its text.
    static func language(of message: MailMessage) -> String {
        let code = message.language.prefix(2).lowercased()
        if code == "de" || code == "en" { return code }
        return Lemmatizer().language(of: message.subject + "\n" + message.bodyText, fallback: "en")
    }

    /// How a German mail addresses the reader: "Sie", "du", or nil (unclear or English).
    static func register(of message: MailMessage, language: String) -> String? {
        guard language == "de" else { return nil }
        var formal = 0
        var informal = 0
        var previousEndsSentence = true
        var current = ""
        func count(_ word: String, sentenceStart: Bool) {
            switch word {
            case "Sie", "Ihnen", "Ihre", "Ihr", "Ihren", "Ihrem", "Ihrer":
                if !sentenceStart || word == "Ihnen" { formal += 1 }
            case "du", "dich", "dir", "dein", "deine", "euch", "euer", "eure", "ihr", "Du", "Dich", "Dir", "Euch":
                informal += 1
            default: break
            }
        }
        for character in message.bodyText + " " {
            if character.isLetter {
                current.append(character)
            } else {
                if !current.isEmpty {
                    count(current, sentenceStart: previousEndsSentence)
                    previousEndsSentence = false
                }
                current = ""
                if ".!?\n:".contains(character) { previousEndsSentence = true }
            }
        }
        if formal > informal { return "Sie" }
        if informal > formal { return "du" }
        return nil
    }

    static func system(account: MailAccount, course: Course?, language: String, register: String?) -> String {
        let name = account.displayName.trimmingCharacters(in: .whitespaces)
        let firstName = name.split(separator: " ").first.map(String.init) ?? name
        var lines: [String] = []
        lines.append("""
            You draft a reply for \(name.isEmpty ? "the student" : name), a university student at \
            Example University, to the last mail of the thread below. The student reads your draft, \
            edits it and sends it themselves.
            """)
        if let course {
            var courseLine = "The mail is about the course \(course.name)"
            if !course.professors.isEmpty { courseLine += " (lecturers: \(course.professors.joined(separator: ", ")))" }
            lines.append(courseLine + ".")
            let rules = course.rules.filter { !$0.text.isEmpty }.map { "\($0.title): \($0.text)" }
            if !rules.isEmpty { lines.append("Course rules the student knows: " + rules.joined(separator: "; ") + ".") }
        }
        let languageName = language == "de" ? "German" : "English"
        var style = "Write the reply in \(languageName), the language of the mail, and match its register"
        if let register {
            style += register == "Sie" ? ": the sender writes \"Sie\", so address them with \"Sie\"" : ": the sender writes \"du\", so use \"du\""
        }
        lines.append(style + ".")
        lines.append("""
            Output only the reply's text: plain text, no subject line, no Markdown, no quoted original, no \
            placeholders in brackets. Open with a fitting greeting and close with \(firstName.isEmpty ? "the student's first name" : firstName). \
            Keep it short. Do not invent facts, dates, reasons or commitments the student has not given; where the \
            student would have to decide something, ask a neutral question instead.
            """)
        lines.append(MailEnvelope.dataRule)
        return lines.joined(separator: "\n\n")
    }
}
