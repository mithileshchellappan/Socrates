import Deadlines
import Foundation
import StudyCore

/// The daily budget of the agent's background calls (default $0.50): what the `api_call` rows of
/// purposes `agent.*` cost since midnight in the university's time zone. Once it is reached, transcript extraction
/// waits until the next day (rows stay `pending`, nothing on screen). What the student asks the
/// agent directly is counted but never blocked.
public struct AgentCostGuard: Sendable {
    public static let defaultDailyLimit = 0.50

    public var dailyLimitUSD: Double
    let database: any DatabaseReader
    let now: @Sendable () -> Date
    let timeZone: TimeZone

    public init(
        database: any DatabaseReader,
        dailyLimitUSD: Double = AgentCostGuard.defaultDailyLimit,
        timeZone: TimeZone = DeadlinesModule.timeZone,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.dailyLimitUSD = dailyLimitUSD
        self.timeZone = timeZone
        self.now = now
    }

    /// Midnight today in the university's time zone.
    public var startOfToday: Date { CalendarDay(now(), in: timeZone).start(in: timeZone) }

    /// USD spent on `agent.*` calls today.
    public func spentToday() async throws -> Double {
        let since = startOfToday
        let prefix = AgentModule.purposePrefix
        return try await database.read { db in
            try APICall
                .where { $0.createdAt.gte(since) && $0.purpose.like("\(prefix)%") }
                .select { $0.costUSD.sum() }
                .fetchOne(db)?
                .flatMap { $0 } ?? 0
        }
    }

    /// True while today's agent calls cost less than the limit.
    public func allowsCalls() async -> Bool {
        do {
            let spent = try await spentToday()
            if spent >= dailyLimitUSD {
                AgentModule.log.notice("Agent background calls paused: \(spent, privacy: .public) USD spent today")
                return false
            }
            return true
        } catch {
            AgentModule.log.error("Cost guard could not read spending: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
