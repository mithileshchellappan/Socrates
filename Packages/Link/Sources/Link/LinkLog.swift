import StudyCore
import os

/// The link's loggers, one category per area.
enum LinkLog {
    /// Identity, trust, the services' lifecycle, commands.
    static let link = Log.logger(category: "link")
    /// Connections: TLS, hellos, liveness, goodbyes.
    static let direct = Log.logger(category: "link.direct")
    /// The Mac's staging and hand-off to filing.
    static let inbox = Log.logger(category: "link.inbox")
    /// The phone's outbox: listing, hashing, sending, receipts.
    static let outbox = Log.logger(category: "link.outbox")
}
