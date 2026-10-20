import Foundation
import os
import StudyCore

/// Mail intelligence (workstream B, docs/plan-m2.md §4): routing, extraction with verified quotes,
/// digest data, reply drafts, mail search chunks and read-only Q&A tools. Mail content is
/// untrusted data: it reaches a model only inside `<mail>` delimiters, never as instructions.
/// The package cannot send mail (no dependency on `Mail`). Logs through
/// `Log.logger(category: "mail-intelligence")`.
public enum MailIntelligenceModule {
    public static let moduleName = "MailIntelligence"

    /// The university's time zone (the profile's, else the system's): dates in mail are read in it.
    public static var timeZone: TimeZone { UniversityProfile.current.zone }
}

/// Shared constants of the package.
enum MailIntelligence {
    /// Never log mail bodies, subjects or addresses at `.public` privacy.
    static let log = Log.logger(category: "mail-intelligence")

    static var timeZone: TimeZone { MailIntelligenceModule.timeZone }

    /// `api_call.purpose` values of this package.
    enum Purpose {
        static let route = "mail.route"
        static let extract = "mail.extract"
        static let draft = "mail.draft"
        static let qa = "mail.qa"
        /// Every purpose starts with this (the cost guard sums them).
        static let prefix = "mail."
    }
}

extension Calendar {
    /// Gregorian in `timeZone`.
    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
