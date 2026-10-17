import ClaudeKit
import Foundation
import GRDB
import StudyCore
import Synchronization

/// The mail intelligence loop: route → index → extract, whenever mail arrives or changes, and
/// again after the rules change (which re-runs the rules first). Runs off the main actor and
/// never blocks the UI; the screens observe the rows it writes.
///
/// Model steps run only with a client and a saved API key, and only while today's mail calls cost
/// less than the daily limit (`MailCostGuard`, $1 by default). Without them it still routes by
/// rules and indexes; the rest waits as `pending` until `wake()` (e.g. after the key is saved).
public actor MailPipeline {
    /// What one pass did.
    public struct PassReport: Sendable, Equatable {
        public var routing = MailRouter.Report()
        public var indexing = MailIndexer.Report()
        public var extraction = MailExtractor.Report()
        public var usedModel = false
    }

    public nonisolated let services: StudyServices
    public nonisolated let router: MailRouter
    public nonisolated let extractor: MailExtractor
    public nonisolated let indexer: MailIndexer
    public nonisolated let drafter: ReplyDrafter
    public nonisolated let search: MailSearch
    public nonisolated let actions: TrackedItemActions
    public nonisolated let digest: MailDigestBuilder
    public nonisolated let costGuard: MailCostGuard

    private let client: ClaudeClient?
    private let debounce: Duration
    private var observations: [AnyDatabaseCancellable] = []
    private var loop: Task<Void, Never>?
    private var isRunning = false
    private var runAgain = false
    private var rulesChanged = false

    public init(
        services: StudyServices,
        client: ClaudeClient?,
        now: @escaping @Sendable () -> Date = { Date() },
        dailyCostLimitUSD: Double = MailCostGuard.defaultDailyLimit,
        debounce: Duration = .seconds(1)
    ) {
        self.services = services
        self.client = client
        self.debounce = debounce
        router = MailRouter(services: services, client: client, now: now)
        extractor = MailExtractor(services: services, client: client, now: now)
        indexer = MailIndexer(services: services)
        drafter = ReplyDrafter(services: services, client: client, now: now)
        search = MailSearch(services: services)
        actions = TrackedItemActions(services: services, now: now)
        digest = MailDigestBuilder(services: services)
        costGuard = MailCostGuard(
            database: services.database, dailyLimitUSD: dailyCostLimitUSD, timeZone: MailIntelligenceModule.timeZone, now: now
        )
    }

    /// Recovers drafts a quit left `generating`, starts observing mail and rules, and runs a first
    /// pass. Returns after that pass; later changes are handled until `stop()`.
    public func start() async {
        guard loop == nil else { return }
        do {
            let recovered = try await drafter.recoverInterrupted()
            if recovered > 0 { MailIntelligence.log.info("Recovered \(recovered) interrupted drafts") }
        } catch {
            MailIntelligence.log.error("Draft recovery failed: \(String(describing: error), privacy: .public)")
        }

        // One pending signal at most (a sync burst becomes one pass); whether the rules changed
        // is a flag beside it, so a rules signal is never lost behind a mail signal.
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let rulesFlag = ChangeFlag()
        let onError: @Sendable (any Error) -> Void = { error in
            MailIntelligence.log.error("Mail observation failed: \(String(describing: error), privacy: .public)")
        }
        // New and re-routed mail (rows added or removed, or their route changed).
        observations.append(DatabaseRegionObservation(
            tracking: SQLRequest<Row>(sql: "SELECT id, category, course_id FROM mail_message")
        ).start(in: services.database, onError: onError, onChange: { _ in continuation.yield() }))
        // Course Settings ▸ Mail.
        observations.append(DatabaseRegionObservation(
            tracking: SQLRequest<Row>(sql: "SELECT * FROM mail_rule")
        ).start(in: services.database, onError: onError, onChange: { _ in
            rulesFlag.raise()
            continuation.yield()
        }))

        let debounce = debounce
        loop = Task { [weak self] in
            for await _ in stream {
                // A quiet moment first, so a sync burst is handled in one pass.
                do { try await Task.sleep(for: debounce) } catch { return }
                if rulesFlag.lower() { await self?.noteRulesChanged() }
                await self?.wake()
            }
        }
        await wake()
    }

    /// Stops observing (a running pass finishes).
    public func stop() {
        for observation in observations { observation.cancel() }
        observations = []
        loop?.cancel()
        loop = nil
    }

    /// Runs a pass now (new mail, the API key was saved, wake from sleep). A wake during a pass
    /// runs one more pass afterwards instead of a second one alongside.
    public func wake() async {
        guard !isRunning else {
            runAgain = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            runAgain = false
            if rulesChanged {
                rulesChanged = false
                do {
                    let changed = try await router.rerunRules()
                    if changed > 0 { MailIntelligence.log.info("Rules re-routed \(changed) messages") }
                } catch {
                    MailIntelligence.log.error("Re-running rules failed: \(String(describing: error), privacy: .public)")
                }
            }
            _ = await pass()
        } while runAgain
    }

    /// Bodies of these messages changed (parsed again): their chunks are rebuilt, then a pass runs.
    public func messagesChanged(_ ids: [MailMessage.ID]) async {
        do {
            try await indexer.reindex(ids)
        } catch {
            MailIntelligence.log.error("Re-indexing failed: \(String(describing: error), privacy: .public)")
        }
        await wake()
    }

    private func noteRulesChanged() {
        rulesChanged = true
    }

    /// One pass: route (batched), index, extract (at most two calls at a time).
    @discardableResult
    public func pass() async -> PassReport {
        var report = PassReport()
        let useModel = canUseModel
        report.usedModel = useModel
        let costGuard = costGuard
        let allow: @Sendable () async -> Bool = { await costGuard.allowsModelCalls() }
        do {
            report.routing = try await router.routePending(useModel: useModel, allowCall: allow)
        } catch {
            MailIntelligence.log.error("Routing pass failed: \(String(describing: error), privacy: .public)")
        }
        do {
            report.indexing = try await indexer.catchUp()
        } catch {
            MailIntelligence.log.error("Mail indexing failed: \(String(describing: error), privacy: .public)")
        }
        do {
            report.extraction = try await extractor.extractPending(useModel: useModel, allowCall: allow)
        } catch {
            MailIntelligence.log.error("Extraction pass failed: \(String(describing: error), privacy: .public)")
        }
        let routing = report.routing
        let extraction = report.extraction
        if routing != MailRouter.Report() || extraction != MailExtractor.Report() {
            MailIntelligence.log.info("""
                Mail pass: routed \(routing.byRule) by rule, \(routing.byModel) by model, \(routing.own) own, \
                \(routing.waiting) waiting; extraction \(extraction.done) done, \(extraction.skipped) skipped, \
                \(extraction.failed) failed, \(extraction.waiting) waiting, \(extraction.itemsCreated) items
                """)
        }
        return report
    }

    /// A client and a saved API key.
    private var canUseModel: Bool {
        client != nil && services.secrets.hasSecret(for: .anthropicAPIKey)
    }
}

/// A flag the database observation raises (synchronously, on its own queue) and the pipeline's
/// loop lowers.
final class ChangeFlag: Sendable {
    private let state = Mutex(false)

    func raise() { state.withLock { $0 = true } }

    /// Lowers the flag; returns whether it was raised.
    func lower() -> Bool {
        state.withLock { raised in
            defer { raised = false }
            return raised
        }
    }
}
