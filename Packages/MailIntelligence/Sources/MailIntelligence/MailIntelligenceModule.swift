import Foundation
import StudyCore

/// Mail intelligence (workstream B, docs/plan-m2.md §4): routing, extraction with verified quotes,
/// digest data, reply drafts, mail search chunks and read-only Q&A tools. Mail content is
/// untrusted data: it reaches a model only inside `<mail>` delimiters, never as instructions.
/// The package cannot send mail (no dependency on `Mail`). Logs through
/// `Log.logger(category: "mail-intelligence")`.
public enum MailIntelligenceModule {
    public static let moduleName = "MailIntelligence"
}
