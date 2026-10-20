import Foundation
import StudyCore

/// Time for the sync engine and the sender: the wall clock and sleeping, injectable so tests run
/// back-off and polling without waiting.
public struct MailClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// The university's time zone (IMAP SINCE days, Date headers of sent mail).
    public static var zone: TimeZone { UniversityProfile.current.zone }
}

/// Tuning of the sync engine (defaults per docs/plan-m2.md §3).
public struct MailSyncConfiguration: Sendable {
    /// Messages fetched and committed per transaction.
    public var batchSize = 25
    /// Days fetched by the first sync when the account has no `sync_since`.
    public var defaultWindowDays = 30
    /// Sent and Archive (and INBOX without IDLE) are polled this often.
    public var pollInterval: Duration = .seconds(5 * 60)
    /// Network errors back off from `minimumBackoff`, doubling, up to `maximumBackoff`.
    public var minimumBackoff: Duration = .seconds(2)
    public var maximumBackoff: Duration = .seconds(5 * 60)
    /// Local flag changes are pushed after this pause (a burst of reads becomes one push).
    public var pushDelay: Duration = .seconds(2)
    /// IDLE on INBOX (when the server offers it).
    public var usesIdle = true
    /// Rows re-derived from their raw message per pass after a parser upgrade.
    public var reparseLimit = 200
    /// Messages up to this size are fetched whole (BODY.PEEK[]) and kept as .eml; larger ones as
    /// headers, structure and text parts, attachments by section when opened. SwiftMail gives a
    /// whole-message fetch 10 seconds, which a slow link manages for about 2 MB.
    public var wholeMessageLimit = 2 * 1024 * 1024
    /// A message whose download failed this many times is stored with its headers only, so it
    /// no longer holds back the mail after it.
    public var fetchAttempts = 3

    public init() {}

    /// The back-off after `failures` consecutive failures (1 → minimum).
    func backoff(after failures: Int) -> Duration {
        guard failures > 0 else { return pollInterval }
        var delay = minimumBackoff
        for _ in 1..<min(failures, 20) {
            delay *= 2
            if delay >= maximumBackoff { return maximumBackoff }
        }
        return min(delay, maximumBackoff)
    }
}

/// Points where tests inject failures (a crash between batches, a dropped connection).
struct MailSyncFaults: Sendable {
    /// Called inside the batch transaction after the messages are written and before the
    /// checkpoint is; throwing rolls the whole batch back.
    var beforeCheckpoint: (@Sendable (_ mailboxPath: String, _ batch: Int) throws -> Void)?

    init(beforeCheckpoint: (@Sendable (String, Int) throws -> Void)? = nil) {
        self.beforeCheckpoint = beforeCheckpoint
    }
}
