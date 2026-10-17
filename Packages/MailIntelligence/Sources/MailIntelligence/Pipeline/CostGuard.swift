import Foundation
import StudyCore

/// The daily budget for mail model calls (default $1). Spending is what the `api_call` rows of
/// purposes `mail.*` cost since local midnight; once it reaches the limit the pipeline's model
/// steps (routing, extraction) pause until the next day. Drafts the student asks for are counted
/// but never blocked.
public struct MailCostGuard: Sendable {
    public static let defaultDailyLimit = 1.0

    public var dailyLimitUSD: Double
    private let spent: @Sendable (Date) async throws -> Double
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    /// `spent(since)`: USD of mail calls since a date; by default read from `api_call`.
    public init(
        database: any DatabaseReader,
        dailyLimitUSD: Double = MailCostGuard.defaultDailyLimit,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        spent: (@Sendable (Date) async throws -> Double)? = nil
    ) {
        self.dailyLimitUSD = dailyLimitUSD
        self.now = now
        self.timeZone = timeZone
        self.spent = spent ?? { since in
            try await database.read { db in
                try APICall
                    .where { $0.createdAt.gte(since) && $0.purpose.like("\(MailIntelligence.Purpose.prefix)%") }
                    .select { $0.costUSD.sum() }
                    .fetchOne(db)?
                    .flatMap { $0 } ?? 0
            }
        }
    }

    /// Start of today in the guard's time zone.
    public var startOfToday: Date {
        Calendar.gregorian(in: timeZone).startOfDay(for: now())
    }

    /// USD spent on mail calls today.
    public func spentToday() async throws -> Double {
        try await spent(startOfToday)
    }

    /// True while today's mail calls cost less than the limit.
    public func allowsModelCalls() async -> Bool {
        do {
            let spent = try await spentToday()
            if spent >= dailyLimitUSD {
                MailIntelligence.log.notice("Mail model steps paused: \(spent, privacy: .public) USD spent today")
                return false
            }
            return true
        } catch {
            MailIntelligence.log.error("Cost guard could not read spending: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
