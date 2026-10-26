import Agent
import ClaudeKit
import Foundation
import GRDB
import StudyCore
import UniformTypeIdentifiers

/// M7 (docs/plan-m7.md §4, §5.2.5): the Mac answers the questions asked on the iPhone. The phone
/// writes each as an `agent_request` (+ `agent_request_file`) row, iCloud sync carries it here,
/// and this answers them through `AppAgent.send` (the panel's own path: the `app` conversation,
/// the interactive slot, unchanged prompts), oldest first, one at a time:
///
/// 1. `claim` (pending → running);
/// 2. the files into the BlobStore (`AgentAttachment.make(data:contentType:fileName:blobs:)`);
/// 3. `send(text, context: request.context ?? .today, attachments:, to: request.conversationID)`;
/// 4. `finish` with the conversation once the run ended with its answer turn stored, or `fail`
///    with the run's readable sentence.
///
/// Claude Code missing or signed out: nothing is claimed (a wake comes when it turns available).
/// A usage pause before the send `release`s the request (pending again) and wakes at the reset;
/// a pause or any failure after the message was stored fails it with the readable sentence (its
/// message is in the conversation: sending it again would ask twice). The Mac's own panel
/// answering in that conversation (`busy`): released, retried after that run. A conversation not
/// synced yet: released, retried in a minute. A thrown send: failed with a readable reason. A
/// quit leaves it `running`: `requeueInterrupted` at the next start (its message may then go
/// twice, as for a sub-agent task). Woken by the database observation of `agent_request`; no
/// polling. Mac only (`AppAgent.start` starts it on macOS).
actor AgentRequestPickup {
    /// The panel's `send`: the words, the screen, the files, when the student asked on the
    /// iPhone (the clock and the quote checks read "today" against it), the conversation.
    typealias Send = @Sendable (String, AgentContext, [AgentAttachment], Date, AgentConversation.ID?) async throws -> AgentConversation.ID

    let services: StudyServices
    let client: ClaudeClient
    let runtime: AgentRuntime
    let send: Send
    let now: @Sendable () -> Date

    private var started = false
    private var observation: AnyDatabaseCancellable?
    private var follower: Task<Void, Never>?
    private var runner: Task<Void, Never>?
    private var again = false
    /// Requests that wait for something first (a conversation to sync): not before then.
    private var notBefore: [AgentRequest.ID: Date] = [:]
    private var retry: Task<Void, Never>?
    private var retryAt: Date?

    /// A conversation that has not arrived yet is looked for again after this long.
    static let unknownConversationDelay: TimeInterval = 60

    init(services: StudyServices, client: ClaudeClient, runtime: AgentRuntime, now: @escaping @Sendable () -> Date, send: @escaping Send) {
        self.services = services
        self.client = client
        self.runtime = runtime
        self.now = now
        self.send = send
    }

    private var requests: AgentRequestRepository { AgentRequestRepository(store: services.records) }

    /// Re-queues what a quit left running, follows `agent_request`, and answers what waits.
    func start() async {
        guard !started else { return }
        started = true
        do {
            try await requests.requeueInterrupted()
        } catch {
            AppAgentModule.log.error("Re-queueing the phone's questions failed: \(String(describing: error), privacy: .public)")
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        observation = DatabaseRegionObservation(tracking: SQLRequest<Row>(sql: "SELECT id, state FROM agent_request"))
            .start(
                in: services.database,
                onError: { error in AppAgentModule.log.error("Request observation failed: \(String(describing: error), privacy: .public)") },
                onChange: { _ in continuation.yield() }
            )
        follower = Task { [weak self] in
            for await _ in stream {
                await self?.wake()
            }
        }
        wake()
    }

    /// Looks for questions to answer; one pass at a time (a wake meanwhile runs one more).
    func wake() {
        guard started else { return }
        if runner != nil {
            again = true
            return
        }
        runner = Task { await self.run() }
    }

    func stop() {
        started = false
        observation?.cancel()
        observation = nil
        follower?.cancel()
        follower = nil
        retry?.cancel()
        retry = nil
        retryAt = nil
    }

    private func run() async {
        repeat {
            again = false
            await answerPending()
        } while again && started
        runner = nil
    }

    private enum Outcome {
        case next
        /// Nothing more now (a pause, a storage error).
        case stop
    }

    /// The pending questions of other devices, oldest first, one at a time.
    private func answerPending() async {
        let date = now()
        let pending: [AgentRequest]
        do {
            pending = try await requests.pending(excludingDevice: AgentRequest.mac)
                .filter { (notBefore[$0.id] ?? .distantPast) <= date }
        } catch {
            AppAgentModule.log.error("Reading the phone's questions failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard !pending.isEmpty else { return }
        let availability = await client.availability()
        // Not installed or signed out: they wait (the app wakes the agent when it turns ready).
        guard availability.isReady else { return }
        if let until = availability.pausedUntil {
            scheduleRetry(at: until)
            return
        }
        for request in pending {
            guard started else { return }
            if await answer(request) == .stop { return }
        }
    }

    private func answer(_ request: AgentRequest) async -> Outcome {
        do {
            guard try await requests.claim(request.id) else { return .next }
        } catch {
            AppAgentModule.log.error("Claiming a phone question failed: \(String(describing: error), privacy: .public)")
            return .stop
        }
        // A usage pause that began meanwhile: the question waits for the reset.
        if let until = await client.availability().pausedUntil {
            await release(request)
            scheduleRetry(at: until)
            return .stop
        }
        let attachments: [AgentAttachment]
        do {
            attachments = try await files(of: request)
        } catch {
            await fail(request, String(localized: "A file of the question could not be read on the Mac."))
            return .next
        }
        let conversationID: AgentConversation.ID
        do {
            conversationID = try await send(request.text, request.context ?? .today, attachments, request.createdAt, request.conversationID)
        } catch AgentRuntime.RuntimeError.busy {
            // The Mac's panel is answering in that conversation: after its run.
            await release(request)
            if let id = request.conversationID { _ = await runtime.outcome(id) }
            try? await Task.sleep(for: .seconds(2))
            again = true
            return .stop
        } catch AgentRuntime.RuntimeError.unknownConversation {
            // The conversation has not synced yet: later.
            await release(request)
            let at = now().addingTimeInterval(Self.unknownConversationDelay)
            notBefore[request.id] = at
            scheduleRetry(at: at)
            return .next
        } catch {
            AppAgentModule.log.error("Answering a phone question failed: \(ReadableError.kind(of: error), privacy: .public)")
            await fail(request, ReadableError.sentence(for: error, otherwise: String(localized: "The question could not be answered."), now: now()))
            return .next
        }
        // Answered once the run ended with its turns stored.
        let ended = await runtime.outcome(conversationID)
        if ended?.state == .finished {
            do {
                try await requests.finish(request.id, conversationID: conversationID)
            } catch {
                AppAgentModule.log.error("Finishing a phone question failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            let reason = (ended?.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            await fail(request, reason.isEmpty ? String(localized: "The answer could not be saved.") : reason)
        }
        notBefore[request.id] = nil
        return .next
    }

    /// The question's files into the BlobStore (the accept rule and limits of the Mac's panel).
    private func files(of request: AgentRequest) async throws -> [AgentAttachment] {
        let rows = try await requests.files(of: request.id)
        let blobs = services.blobs
        return try rows.map { row in
            let type = UTType(row.contentType) ?? UTType(filenameExtension: (row.fileName as NSString).pathExtension) ?? .data
            return try AgentAttachment.make(data: row.data, contentType: type, fileName: row.fileName, blobs: blobs)
        }
    }

    private func release(_ request: AgentRequest) async {
        do {
            try await requests.release(request.id)
        } catch {
            AppAgentModule.log.error("Releasing a phone question failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func fail(_ request: AgentRequest, _ reason: String) async {
        notBefore[request.id] = nil
        do {
            try await requests.fail(request.id, error: reason)
        } catch {
            AppAgentModule.log.error("Failing a phone question failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One timer for the earliest time something can go again (a reset, a conversation to sync).
    private func scheduleRetry(at date: Date) {
        if retry != nil, let retryAt, retryAt <= date { return }
        retry?.cancel()
        retryAt = date
        let delay = max(1, date.timeIntervalSince(now()) + 5)
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retryEnded()
        }
    }

    private func retryEnded() {
        retry = nil
        retryAt = nil
        wake()
    }
}
